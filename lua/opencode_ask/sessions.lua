local M = {}

local selection = require("opencode_ask.selection")

local UNKNOWN_DATE = "unknown date"

M.CREATE_SESSION_LABEL = "Create new session…"

local function error_message(message)
  return "opencode-ask: " .. message
end

local function options()
  -- Read lazily so requiring this module cannot create a circular dependency
  -- with opencode_ask/init.lua, and so tests can override the options.
  return require("opencode_ask").options
end

local function empty_state()
  return { version = 1, projects = {} }
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

--- Resolve the normalized project key for a directory or path.
--- Accepts an absolute path (directory or file) in addition to the buffer
--- numbers understood by selection.project_root. When no .git marker is
--- found, a directory path is used as-is (a file path uses its directory),
--- which matches the cached context.project_root passed by callers.
local function project_key(cwd)
  local ok, root = pcall(selection.project_root, cwd)
  if ok and type(root) == "string" then
    return root
  end
  return vim.uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
end

local function valid_projects(projects)
  if type(projects) ~= "table" then
    return false
  end

  for key, entry in pairs(projects) do
    if type(key) ~= "string" or type(entry) ~= "table" then
      return false
    end
    if entry.id ~= nil and type(entry.id) ~= "string" then
      return false
    end
  end

  return true
end

--- Return the configured state file path.
function M.state_path()
  return options().state_path
end

--- Read the persisted state. Missing, unreadable, invalid, or wrongly shaped
--- files produce a fresh empty state instead of an error.
function M.read_state()
  local ok, state = pcall(function()
    local path = M.state_path()
    if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
      return nil
    end

    local lines = vim.fn.readfile(path)
    local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not decoded_ok or type(decoded) ~= "table" then
      return nil
    end
    if decoded.version ~= 1 or not valid_projects(decoded.projects) then
      return nil
    end

    return decoded
  end)

  if ok and state then
    return state
  end
  return empty_state()
end

--- Persist the state by writing a temporary file in the same directory and
--- atomically renaming it over the target. Returns true or nil, err.
function M.write_state(state)
  local path = M.state_path()
  if type(path) ~= "string" or path == "" then
    return nil, error_message("state_path is not configured")
  end

  local tmp = path .. ".tmp." .. tostring(vim.fn.getpid())
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), "p")

    local encoded = vim.json.encode(state)
    if vim.fn.writefile({ encoded }, tmp) ~= 0 then
      error("could not write temporary state file " .. tmp)
    end

    local renamed, rename_err = vim.uv.fs_rename(tmp, path)
    if not renamed then
      error(("could not replace %s: %s"):format(path, tostring(rename_err)))
    end
  end)

  if not ok then
    pcall(vim.uv.fs_unlink, tmp)
    return nil, error_message("could not write session state: " .. tostring(err))
  end

  return true
end

--- Decode `opencode session list --format json` output.
--- Returns the session array or nil and a descriptive error.
function M.parse(json)
  if type(json) ~= "string" or vim.trim(json) == "" then
    return nil, error_message("opencode session list returned no JSON")
  end
  if not json:match("^%s*%[") then
    return nil, error_message("expected opencode session list to be a JSON array")
  end

  local ok, decoded = pcall(vim.json.decode, json)
  if not ok then
    return nil, error_message("could not decode opencode session list JSON: " .. tostring(decoded))
  end
  if type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil, error_message("expected opencode session list to be a JSON array")
  end

  for index, session in ipairs(decoded) do
    if type(session) ~= "table" or type(session.id) ~= "string" or session.id == "" then
      return nil, error_message(("session list entry %d is missing a string id"):format(index))
    end
  end

  return decoded
end

--- Format one session as a readable picker label.
function M.label(session)
  if type(session) ~= "table" then
    session = {}
  end

  local title = type(session.title) == "string" and vim.trim(session.title) or ""
  if title == "" then
    title = "Untitled"
  end

  local date = UNKNOWN_DATE
  local updated = session.updated
  if
    type(updated) == "number"
    and updated >= 0
    and updated < 1e15
    and updated == updated
  then
    local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(updated / 1000))
    if ok and type(formatted) == "string" then
      date = formatted
    end
  end

  local id = type(session.id) == "string" and session.id or ""
  local suffix = #id > 6 and id:sub(-6) or id
  if suffix == "" then
    return ("%s (%s)"):format(title, date)
  end
  return ("%s (%s) [%s]"):format(title, date, suffix)
end

--- List OpenCode sessions for a directory through the CLI.
--- Calls callback(err, sessions) exactly once from the main loop.
function M.list(cwd, callback)
  cwd = cwd or vim.fn.getcwd()
  local done = once(callback)

  vim.schedule(function()
    local opts = options()
    local api = opts.api or {}
    local command = api.command or "opencode"

    if vim.fn.executable(command) ~= 1 then
      done(error_message(("'%s' is not executable; install OpenCode or configure api.command"):format(command)))
      return
    end

    local started, process = pcall(vim.system, { command, "session", "list", "--format", "json" }, {
      cwd = cwd,
      text = true,
      timeout = api.timeout,
    }, function(result)
      vim.schedule(function()
        if result.code == 124 then
          done(error_message(("'%s session list' timed out after %sms"):format(command, tostring(api.timeout))))
          return
        end

        if result.code ~= 0 then
          local detail = vim.trim(result.stderr or "")
          if detail == "" then
            detail = vim.trim(result.stdout or "")
          end
          if detail == "" then
            detail = "no output"
          end
          done(
            error_message(
              ("'%s session list' failed with exit code %s: %s"):format(command, tostring(result.code), detail)
            )
          )
          return
        end

        local sessions, parse_err = M.parse(result.stdout or "")
        if not sessions then
          done(parse_err)
          return
        end

        done(nil, sessions)
      end)
    end)

    if not started then
      done(error_message(("could not run '%s session list': %s"):format(command, tostring(process))))
    end
  end)
end

local function store_session(cwd, session)
  local state = M.read_state()
  state.projects[project_key(cwd)] = {
    id = session.id,
    title = session.title,
    directory = session.directory,
    updated = session.updated,
  }
  return M.write_state(state)
end

--- Create a session for the project, persist it, and return it.
--- Calls callback(err, session) exactly once from the main loop.
function M.create(cwd, title, callback)
  cwd = cwd or vim.fn.getcwd()
  local done = once(type(callback) == "function" and callback or function() end)
  local root = project_key(cwd)

  require("opencode_ask.client").create_session(root, title, function(err, session)
    if err then
      done(err)
      return
    end

    local stored, write_err = store_session(root, session)
    if not stored then
      vim.notify(write_err, vim.log.levels.WARN)
    end

    done(nil, session)
  end)
end

--- Pick a session for the project and persist it.
--- Cancelling the picker is a clean no-op; the callback is not called.
function M.choose(cwd, callback)
  cwd = cwd or vim.fn.getcwd()
  local done = once(callback)

  M.list(cwd, function(err, sessions)
    if err then
      done(err)
      return
    end

    if type(sessions) ~= "table" then
      sessions = {}
    end

    local items = {}
    local by_label = {}
    for _, session in ipairs(sessions) do
      local label = M.label(session)
      if by_label[label] or label == M.CREATE_SESSION_LABEL then
        local suffix = 2
        while by_label[label .. " (" .. suffix .. ")"] do
          suffix = suffix + 1
        end
        label = label .. " (" .. suffix .. ")"
      end
      items[#items + 1] = label
      by_label[label] = session
    end

    local function selected(label)
      if label == nil or label == "" then
        return
      end

      local session = by_label[label]
      if not session then
        return
      end

      local stored, write_err = store_session(cwd, session)
      if not stored then
        vim.notify(write_err, vim.log.levels.WARN)
      end

      done(nil, session)
    end

    if options().picker == "fzf-lua" then
      local ok, fzf = pcall(require, "fzf-lua")
      if ok and type(fzf) == "table" and type(fzf.fzf_exec) == "function" then
        local shown = pcall(fzf.fzf_exec, items, {
          prompt = "OpenCode sessions> ",
          header = "Type a title; Enter creates when no match",
          fzf_opts = { ["--no-multi"] = true },
          actions = {
            ["enter"] = function(chosen, action_opts)
              vim.schedule(function()
                if type(chosen) == "table" and #chosen > 0 then
                  selected(chosen[1])
                  return
                end

                local query = type(action_opts) == "table"
                    and type(action_opts.last_query) == "string"
                    and vim.trim(action_opts.last_query)
                  or ""

                if query == "" then
                  vim.notify(
                    "opencode-ask: type a session title and press Enter to create one",
                    vim.log.levels.WARN
                  )
                  return
                end

                M.create(cwd, query, function(create_err, session)
                  if create_err then
                    done(create_err)
                  else
                    done(nil, session)
                  end
                end)
              end)
            end,
          },
        })
        if shown then
          return
        end
      end
    end

    items[#items + 1] = M.CREATE_SESSION_LABEL
    vim.ui.select(items, { prompt = "OpenCode sessions" }, function(choice)
      if choice == M.CREATE_SESSION_LABEL then
        vim.ui.input({ prompt = "New OpenCode session title: " }, function(input)
          local title = type(input) == "string" and vim.trim(input) or ""
          if title == "" then
            return
          end

          M.create(cwd, title, function(create_err, session)
            if create_err then
              done(create_err)
            else
              done(nil, session)
            end
          end)
        end)
        return
      end

      selected(choice)
    end)
  end)
end

--- Resolve the session for a project: pinned option, stored entry, or picker.
function M.resolve(cwd, callback)
  cwd = cwd or vim.fn.getcwd()

  local session = options().session
  if type(session) == "string" then
    callback(nil, { id = session })
    return
  end

  local state = M.read_state()
  local entry = state.projects[project_key(cwd)]
  if type(entry) == "table" and type(entry.id) == "string" and entry.id ~= "" then
    callback(nil, entry)
    return
  end

  M.choose(cwd, callback)
end

--- Remove the stored session for a project without disturbing other projects.
function M.clear(cwd)
  cwd = cwd or vim.fn.getcwd()

  local state = M.read_state()
  local key = project_key(cwd)
  if state.projects[key] == nil then
    return true
  end

  state.projects[key] = nil
  return M.write_state(state)
end

return M
