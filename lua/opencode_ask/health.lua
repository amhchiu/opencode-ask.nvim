local sessions = require("opencode_ask.sessions")

local M = {}

local MAX_TIMEOUT_MS = 5000
local MAX_DETAIL_LENGTH = 300

local function options()
  -- Read lazily so health uses the configuration that is active when
  -- :checkhealth runs, including changes made after setup().
  return require("opencode_ask").options
end

local function emit(level, message)
  local report = vim.health and vim.health[level]
  if type(report) == "function" then
    pcall(report, message)
  end
end

local function configured_api()
  local opts = options()
  if type(opts) ~= "table" or type(opts.api) ~= "table" then
    return {}
  end
  return opts.api
end

local function configured_command()
  return configured_api().command
end

local function configured_timeout()
  local api = configured_api()
  local timeout = api.timeout
  if type(timeout) ~= "number" or timeout <= 0 or timeout ~= timeout then
    return MAX_TIMEOUT_MS
  end
  return math.min(timeout, MAX_TIMEOUT_MS)
end

local function detail(value)
  if type(value) ~= "string" then
    return ""
  end

  local trimmed = vim.trim(value)
  if #trimmed > MAX_DETAIL_LENGTH then
    trimmed = trimmed:sub(1, MAX_DETAIL_LENGTH) .. "..."
  end
  return trimmed
end

--- Run a command synchronously and wait for it with a short timeout.
--- Returns the vim.system result, or nil and a description when the process
--- could not be started or waited on.
local function run(argv, cwd)
  local command = tostring(argv[1])
  local started, process_or_err = pcall(vim.system, argv, {
    cwd = cwd,
    text = true,
    timeout = configured_timeout(),
  })
  if not started then
    return nil, ("could not run '%s': %s"):format(command, detail(tostring(process_or_err)))
  end
  if type(process_or_err) ~= "table" then
    return nil, ("could not run '%s': vim.system returned %s"):format(command, type(process_or_err))
  end

  local waited, result = pcall(function()
    return process_or_err:wait()
  end)
  if not waited then
    return nil, ("could not wait for '%s': %s"):format(command, detail(tostring(result)))
  end
  return result
end

local function result_detail(result)
  local stderr = detail(result.stderr)
  if stderr ~= "" then
    return stderr
  end
  local stdout = detail(result.stdout)
  if stdout ~= "" then
    return stdout
  end
  return "no output"
end

local function check_executable()
  local command = configured_command()

  if type(command) ~= "string" or command == "" then
    emit(
      "error",
      "api.command is not configured. Set it to the OpenCode executable, for example: "
        .. "opts = { api = { command = \"opencode\" } }"
    )
    return nil
  end

  local ok, executable = pcall(vim.fn.executable, command)
  if not ok then
    emit("error", ("could not check whether '%s' is executable: %s"):format(command, detail(tostring(executable))))
    return nil
  end

  if executable ~= 1 then
    emit(
      "error",
      ("'%s' is not executable. Install OpenCode and make sure it is on PATH, "
        .. "or set api.command to its absolute path."):format(command)
    )
    return nil
  end

  emit("ok", ("'%s' executable found"):format(command))
  return command
end

local function check_api(command)
  local cwd = vim.fn.getcwd()
  local result, run_err = run({ command, "api", "get", "/api/info" }, cwd)

  if not result then
    emit("warn", ("OpenCode service check failed: %s. Start OpenCode and try again."):format(run_err))
    return
  end

  if result.code == 124 then
    emit(
      "warn",
      ("OpenCode did not answer `api get /api/info` within %dms. "
        .. "Start OpenCode or check its background service."):format(configured_timeout())
    )
    return
  end

  if result.code ~= 0 then
    emit(
      "warn",
      ("OpenCode is not reachable (`opencode api get /api/info` exited with code %s): %s. "
        .. "Start OpenCode or check its background service."):format(tostring(result.code), result_detail(result))
    )
    return
  end

  local info
  local decoded, body = pcall(vim.json.decode, vim.trim(result.stdout or ""))
  if decoded and type(body) == "table" then
    info = body
  end

  local version = info and type(info.version) == "string" and info.version or nil
  local urls = info and type(info.urls) == "table" and info.urls or nil
  local url = urls and type(urls[1]) == "string" and urls[1] or nil

  if version and url then
    emit("ok", ("OpenCode API is reachable (version %s at %s)"):format(version, url))
  elseif version then
    emit("ok", ("OpenCode API is reachable (version %s)"):format(version))
  elseif url then
    emit("ok", ("OpenCode API is reachable at %s"):format(url))
  else
    emit("ok", "OpenCode API is reachable")
  end
end

local function check_sessions(command)
  local cwd = vim.fn.getcwd()
  local result, run_err = run({ command, "session", "list", "--format", "json" }, cwd)

  if not result then
    emit("warn", ("Could not list OpenCode sessions: %s"):format(run_err))
    return
  end

  if result.code == 124 then
    emit(
      "warn",
      ("`opencode session list` timed out after %dms. Start OpenCode or check its background service."):format(
        configured_timeout()
      )
    )
    return
  end

  if result.code ~= 0 then
    emit(
      "warn",
      ("`opencode session list` exited with code %s: %s. Start OpenCode or check its background service."):format(
        tostring(result.code),
        result_detail(result)
      )
    )
    return
  end

  local listed, parse_err = sessions.parse(result.stdout or "")
  if not listed then
    emit("warn", ("OpenCode returned an invalid session list for %s: %s"):format(cwd, tostring(parse_err)))
    return
  end

  if #listed == 0 then
    emit(
      "info",
      ("OpenCode returned no sessions for %s. Sessions are project-scoped; "
        .. ":OpencodeSession can create a new session when the query has no matches."):format(cwd)
    )
    return
  end

  emit("ok", ("OpenCode returned %d session(s) for %s"):format(#listed, cwd))
end

local function valid_state(state)
  return type(state) == "table" and state.version == 1 and type(state.projects) == "table"
end

local function check_state()
  local ok, path = pcall(sessions.state_path)
  if not ok or type(path) ~= "string" or path == "" then
    emit(
      "error",
      "state_path is not configured. Set it to a writable file path, for example: "
        .. "vim.fn.stdpath(\"state\") .. \"/opencode-ask/sessions.json\""
    )
    return
  end

  local dir = vim.fs.dirname(path)
  local probe = ("%s/.opencode-ask-health-%d"):format(dir, vim.fn.getpid())

  local created, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
  if not created then
    emit("error", ("State directory %s is not writable: could not create it (%s)"):format(dir, detail(tostring(mkdir_err))))
    return
  end

  local wrote, write_err = pcall(vim.fn.writefile, { "" }, probe)
  if not wrote or vim.fn.filereadable(probe) ~= 1 then
    pcall(vim.fn.delete, probe)
    emit(
      "error",
      ("State directory %s is not writable: could not create a probe file (%s)"):format(
        dir,
        detail(tostring(write_err or "unknown error"))
      )
    )
    return
  end

  local deleted, delete_err = pcall(vim.fn.delete, probe)
  if not deleted then
    emit("warn", ("State directory %s is writable, but the probe file %s could not be removed: %s"):format(
      dir,
      probe,
      detail(tostring(delete_err))
    ))
  else
    emit("ok", ("State directory is writable: %s"):format(dir))
  end

  if vim.fn.filereadable(path) ~= 1 then
    emit("info", ("No state file yet at %s; it is created when you choose or create a session."):format(path))
    return
  end

  local read_ok, lines = pcall(vim.fn.readfile, path)
  local decode_ok, decoded = false, nil
  if read_ok then
    decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  end

  if not decode_ok or not valid_state(decoded) then
    emit(
      "warn",
      ("State file %s is not valid opencode-ask state. Run :OpencodeSession to rewrite it, "
        .. "or delete the file to reset all stored sessions."):format(path)
    )
    return
  end

  emit("ok", ("State file is valid: %s"):format(path))
end

local function check_picker()
  local ok = pcall(require, "fzf-lua")
  if ok then
    emit("ok", "fzf-lua is available for the session picker")
  else
    emit("info", "fzf-lua is not available; :OpencodeSession will use vim.ui.select")
  end
end

local function guarded(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    emit("error", ("%s check failed unexpectedly: %s"):format(name, detail(tostring(err))))
  end
end

local function run_checks()
  pcall(function()
    vim.health.start("opencode_ask")
  end)

  local command
  guarded("Executable", function()
    command = check_executable()
  end)
  if command then
    guarded("OpenCode service", function()
      check_api(command)
    end)
    guarded("OpenCode sessions", function()
      check_sessions(command)
    end)
  end

  guarded("State", check_state)
  guarded("Picker", check_picker)
end

--- Entry point for :checkhealth opencode_ask.
--- Every check is synchronous and self-contained; this function never throws.
function M.check()
  local ok, err = pcall(run_checks)
  if not ok then
    emit("error", ("opencode_ask health check failed unexpectedly: %s"):format(tostring(err)))
  end
end

return M
