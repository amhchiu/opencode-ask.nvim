local M = {}

local function error_message(message)
  return "opencode-ask: " .. message
end

local function options()
  -- Read lazily so requiring this module cannot create a circular dependency
  -- with opencode_ask/init.lua, and so tests can override the options.
  return require("opencode_ask").options
end

local function once(fn)
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    fn(...)
  end
end

local function typed_error(kind, message, extra)
  local err = extra or {}
  err.kind = kind
  err.message = message
  return err
end

--- Length of a string in UTF-16 code units, which is what the OpenCode API
--- uses for prompt mention offsets. Falls back to the byte length when the
--- string cannot be indexed (for example, invalid UTF-8).
local function utf16_length(value)
  local ok, _, length = pcall(vim.str_utfindex, value)
  if ok and type(length) == "number" then
    return length
  end
  return #value
end

local function configured_timeout()
  local ok, opts = pcall(options)
  if ok and type(opts) == "table" and type(opts.api) == "table" then
    return opts.api.timeout
  end
end

local function decode_json(value)
  if type(value) ~= "string" then
    return nil
  end

  local trimmed = vim.trim(value)
  if trimmed == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, trimmed)
  if not ok then
    return nil
  end
  return decoded
end

local function parsed_message(parsed)
  if type(parsed) == "table" and type(parsed.message) == "string" then
    local message = vim.trim(parsed.message)
    if message ~= "" then
      return message
    end
  end
end

local function session_not_found(parsed, code)
  local detail = parsed_message(parsed)
  if not detail and type(parsed) == "table" and type(parsed.sessionID) == "string" and parsed.sessionID ~= "" then
    detail = "Session not found: " .. parsed.sessionID
  end
  detail = detail or "OpenCode session not found"

  return typed_error("session_not_found", detail, {
    code = code,
    body = parsed,
    session_id = type(parsed) == "table" and parsed.sessionID or nil,
  })
end

--- Build the prompt request body for a question and captured selection.
--- Returns the payload table, or nil and a descriptive error.
function M.build_payload(question, context)
  if type(question) ~= "string" then
    return nil, error_message("question must be a string")
  end
  if vim.trim(question) == "" then
    return nil, error_message("question must not be empty")
  end
  if type(context) ~= "table" then
    return nil, error_message("missing selection context")
  end
  if type(context.uri) ~= "string" or context.uri == "" then
    return nil, error_message("selection context is missing a file URI")
  end
  if type(context.mention) ~= "string" or context.mention == "" then
    return nil, error_message("selection context is missing a mention")
  end

  local start = utf16_length(question) + 2
  local text = question .. "\n\n" .. context.mention

  return {
    text = text,
    files = {
      {
        uri = context.uri,
        mention = {
          start = start,
          ["end"] = start + utf16_length(context.mention),
          text = context.mention,
        },
      },
    },
  }
end

--- Classify a vim.system result.
--- Returns nil and the decoded response body on success, or a typed error.
function M.classify(result)
  if type(result) ~= "table" or type(result.code) ~= "number" then
    return typed_error("invalid_result", "opencode api returned an invalid result", {
      result = result,
    })
  end

  local code = result.code

  if code == 124 then
    local timeout = configured_timeout()
    local message = "opencode api timed out"
    if timeout ~= nil then
      message = message .. " after " .. tostring(timeout) .. "ms"
    end
    return typed_error("timeout", message, {
      code = code,
      timeout = timeout,
    })
  end

  if code == 0 then
    local stdout = type(result.stdout) == "string" and vim.trim(result.stdout) or ""
    if stdout == "" then
      return nil, true
    end

    local ok, decoded = pcall(vim.json.decode, stdout)
    if ok then
      return nil, decoded
    end
    return nil, true
  end

  local parsed = decode_json(result.stdout)
  if type(parsed) == "table" then
    if parsed._tag == "SessionNotFoundError" then
      return session_not_found(parsed, code)
    end
    if parsed._tag == "InvalidRequestError" and parsed.field == "sessionID" then
      return session_not_found(parsed, code)
    end
  end

  local message = parsed_message(parsed)
  if not message and type(result.stderr) == "string" then
    message = vim.trim(result.stderr)
    if message == "" then
      message = nil
    end
  end
  if not message and type(result.stdout) == "string" then
    message = vim.trim(result.stdout)
    if message == "" then
      message = nil
    end
  end
  message = message or ("opencode api exited with code " .. tostring(code))

  return typed_error("api_error", message, {
    code = code,
    body = type(parsed) == "table" and parsed or nil,
  })
end

local function validate_session(session)
  if type(session) ~= "table" then
    return nil, error_message("missing session; expected a table with an id")
  end
  if type(session.id) ~= "string" or vim.trim(session.id) == "" then
    return nil, error_message("session id must be a non-empty string")
  end
  return session
end

--- Send a question and selection context to an OpenCode session.
--- Calls callback(err, result) exactly once from the main loop. API failures
--- are typed tables with a `kind` field; local validation failures are
--- descriptive strings.
function M.send(session, question, context, callback)
  local done = once(type(callback) == "function" and callback or function() end)

  local payload, payload_err = M.build_payload(question, context)
  if not payload then
    vim.schedule(function()
      done(payload_err)
    end)
    return
  end

  local valid_session, session_err = validate_session(session)
  if not valid_session then
    vim.schedule(function()
      done(session_err)
    end)
    return
  end

  vim.schedule(function()
    local opts = options()
    local api = type(opts.api) == "table" and opts.api or {}
    local command = api.command or "opencode"

    if type(command) ~= "string" or command == "" or vim.fn.executable(command) ~= 1 then
      done(typed_error(
        "executable_not_found",
        ("'%s' is not executable; install OpenCode or configure api.command"):format(tostring(command)),
        { command = command }
      ))
      return
    end

    local encoded_ok, encoded = pcall(vim.json.encode, payload)
    if not encoded_ok or type(encoded) ~= "string" then
      done(typed_error("payload_error", "could not encode the prompt payload: " .. tostring(encoded)))
      return
    end

    local cwd = session.directory
    if type(cwd) ~= "string" or cwd == "" then
      cwd = context.project_root
    end
    if type(cwd) ~= "string" or cwd == "" then
      cwd = nil
    end

    local argv = {
      command,
      "api",
      "post",
      "/api/session/" .. session.id .. "/prompt",
      "--data",
      encoded,
    }

    local started, process_or_err = pcall(vim.system, argv, {
      cwd = cwd,
      text = true,
      timeout = api.timeout,
    }, function(result)
      vim.schedule(function()
        local err, response = M.classify(result)
        done(err, response)
      end)
    end)

    if not started then
      done(typed_error("spawn_error", ("could not run '%s api post': %s"):format(command, tostring(process_or_err)), {
        command = command,
        cwd = cwd,
      }))
    end
  end)
end

return M
