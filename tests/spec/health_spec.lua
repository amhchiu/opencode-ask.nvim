local health = require("opencode_ask.health")
local init = require("opencode_ask")

local function with_options(changes, fn)
  local saved = {}
  for key in pairs(changes) do
    saved[key] = init.options[key]
  end
  for key, value in pairs(changes) do
    init.options[key] = value
  end

  local ok, err = pcall(fn)

  for key in pairs(changes) do
    init.options[key] = saved[key]
  end
  if not ok then
    error(err, 0)
  end
end

local function with_stub(owner, key, value, fn)
  local original = owner[key]
  owner[key] = value
  local ok, err = pcall(fn)
  owner[key] = original
  if not ok then
    error(err, 0)
  end
end

local function with_temp(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir) or dir
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

--- Replace vim.health with a collector, run fn(entries), then restore it.
local function with_health(fn)
  local original = vim.health
  local entries = {}

  local function report(level)
    return function(message)
      entries[#entries + 1] = { level = level, message = message }
    end
  end

  vim.health = {
    start = function(name)
      entries[#entries + 1] = { level = "start", message = name }
    end,
    ok = report("ok"),
    warn = report("warn"),
    error = report("error"),
    info = report("info"),
  }

  local ok, err = pcall(fn, entries)
  vim.health = original
  if not ok then
    error(err, 0)
  end
  return entries
end

local function process(result)
  return {
    wait = function()
      if result == "wait_error" then
        error("wait exploded")
      end
      return result
    end,
  }
end

--- Return a vim.system replacement keyed by the CLI subcommand.
local function fake_system(results, calls)
  return function(argv, opts)
    if calls then
      calls[#calls + 1] = { argv = argv, opts = opts }
    end

    local result = results[argv[2]]
    if type(result) == "function" then
      result = result(argv, opts)
    end
    if result == "throw" then
      error("spawn exploded")
    end
    return process(result)
  end
end

local function healthy_results(session_stdout)
  return {
    api = {
      code = 0,
      stdout = '{"version":"2.4.2","pid":1,"urls":["http://127.0.0.1:1234"]}',
      stderr = "",
    },
    session = {
      code = 0,
      stdout = session_stdout or '[{"id":"ses_a"},{"id":"ses_b"}]',
      stderr = "",
    },
  }
end

local function run_health(config, options)
  options = options or {}
  local entries
  local calls = {}

  with_health(function(collected)
    with_options(config, function()
      with_stub(vim.fn, "executable", function()
        return options.executable or 1
      end, function()
        with_stub(vim, "system", options.system or fake_system(healthy_results(), calls), function()
          if options.before then
            options.before()
          end
          health.check()
        end)
      end)
    end)
    entries = collected
  end)

  return entries, calls
end

local function messages(entries, level)
  local found = {}
  for _, entry in ipairs(entries) do
    if entry.level == level then
      found[#found + 1] = entry.message
    end
  end
  return found
end

local function contains(messages_list, pattern)
  for _, message in ipairs(messages_list) do
    if message:find(pattern) then
      return true, message
    end
  end
  return false
end

local function assert_contains(t, messages_list, pattern, description)
  local found, message = contains(messages_list, pattern)
  t.assert(found, (description or "expected a message matching " .. pattern) .. "; got " .. vim.inspect(messages_list))
  return message
end

local function with_package_loaded(name, value, fn)
  local saved_loaded = package.loaded[name]
  local saved_preload = package.preload[name]
  package.loaded[name] = value
  if value == nil then
    package.preload[name] = function()
      error(name .. " is not installed in tests")
    end
  end

  local ok, err = pcall(fn)

  package.loaded[name] = saved_loaded
  package.preload[name] = saved_preload
  if not ok then
    error(err, 0)
  end
end

return function(t)
  t.test("health starts the opencode_ask section", function()
    with_temp(function(dir)
      local entries = run_health({ state_path = vim.fs.joinpath(dir, "state", "sessions.json") })
      t.equal("start", entries[1].level)
      t.equal("opencode_ask", entries[1].message)
    end)
  end)

  t.test("health errors on a missing CLI and skips CLI checks", function()
    with_temp(function(dir)
      local system_called = false
      local entries = run_health({
        state_path = vim.fs.joinpath(dir, "state", "sessions.json"),
        api = { command = "opencode-ask-missing-cli-for-health", timeout = 1234 },
      }, {
        executable = 0,
        system = function()
          system_called = true
          return process({ code = 0, stdout = "", stderr = "" })
        end,
      })

      t.equal(false, system_called, "CLI checks must be skipped when the executable is missing")

      local errors = messages(entries, "error")
      local message = assert_contains(t, errors, "not executable", "missing CLI should be an actionable error")
      assert_contains(t, errors, "api%.command", "the error should mention api.command")
      t.assert(message:find("opencode-ask-missing-cli-for-health", 1, true) ~= nil)

      t.equal(false, contains(messages(entries, "ok"), "session"), "no session check should run")
      assert_contains(t, messages(entries, "ok"), "State directory is writable")
    end)
  end)

  t.test("health reports a healthy CLI, service, session list, state, and picker", function()
    with_temp(function(dir)
      local state_path = vim.fs.joinpath(dir, "state", "sessions.json")
      local entries, calls
      with_package_loaded("fzf-lua", {}, function()
        entries, calls = run_health({ state_path = state_path, api = { command = "opencode", timeout = 1234 } }, {
          before = function()
            vim.fn.mkdir(vim.fs.dirname(state_path), "p")
            vim.fn.writefile({ '{"version":1,"projects":{}}' }, state_path)
          end,
        })
      end)

      local oks = messages(entries, "ok")
      assert_contains(t, oks, "'opencode' executable found")
      local api_message = assert_contains(t, oks, "OpenCode API is reachable")
      t.assert(api_message:find("2.4.2", 1, true) ~= nil, "the API message should include the version")
      t.assert(api_message:find("http://127.0.0.1:1234", 1, true) ~= nil, "the API message should include the URL")
      assert_contains(t, oks, "returned 2 session%(s%)")
      assert_contains(t, oks, "State directory is writable")
      assert_contains(t, oks, "State file is valid")
      assert_contains(t, oks, "fzf%-lua is available")

      t.equal(0, #messages(entries, "warn"), "no warnings expected")
      t.equal(0, #messages(entries, "error"), "no errors expected")

      t.equal(2, #calls, "api info and session list should each run once")
      t.equal(1234, calls[1].opts.timeout)
      t.equal(1234, calls[2].opts.timeout)
    end)
  end)

  t.test("health accepts a valid empty session list as info", function()
    with_temp(function(dir)
      local entries = run_health(
        { state_path = vim.fs.joinpath(dir, "state", "sessions.json") },
        { system = fake_system(healthy_results("[]")) }
      )

      local infos = messages(entries, "info")
      local message = assert_contains(t, infos, "no sessions")
      t.assert(message:find("project%-scoped") ~= nil, "empty list info should explain project scope")
      t.assert(message:find(":OpencodeSession", 1, true) ~= nil, "empty list info should point at :OpencodeSession")
      t.assert(message:find("create", 1, true) ~= nil, "empty list info should explain creation")
      t.equal(0, #messages(entries, "warn"), "an empty session list is not a failure")
    end)
  end)

  t.test("health warns on invalid session JSON", function()
    with_temp(function(dir)
      local entries = run_health({ state_path = vim.fs.joinpath(dir, "state", "sessions.json") }, {
        system = fake_system({
          api = { code = 0, stdout = '{"version":"2.4.2"}', stderr = "" },
          session = { code = 0, stdout = "not json", stderr = "" },
        }),
      })

      local warns = messages(entries, "warn")
      assert_contains(t, warns, "invalid session list")
      assert_contains(t, warns, "JSON array")
    end)
  end)

  t.test("health warns with reset guidance when the state file is corrupt", function()
    with_temp(function(dir)
      local state_path = vim.fs.joinpath(dir, "state", "sessions.json")
      local entries = run_health({ state_path = state_path }, {
        before = function()
          vim.fn.mkdir(vim.fs.dirname(state_path), "p")
          vim.fn.writefile({ "not json" }, state_path)
        end,
      })

      local warns = messages(entries, "warn")
      local message = assert_contains(t, warns, "State file")
      t.assert(message:find(state_path, 1, true) ~= nil, "the warning should include the state path")
      t.assert(message:find(":OpencodeSession", 1, true) ~= nil, "the warning should suggest :OpencodeSession")
      t.assert(message:find("delete the file", 1, true) ~= nil, "the warning should explain how to reset")
      t.equal(0, #messages(entries, "error"), "a corrupt state file is a warning, not an error")
    end)
  end)

  t.test("health warns when OpenCode is unreachable", function()
    with_temp(function(dir)
      local entries = run_health({ state_path = vim.fs.joinpath(dir, "state", "sessions.json") }, {
        system = fake_system({
          api = { code = 1, stdout = "", stderr = "HTTP 500 Internal Server Error" },
          session = { code = 0, stdout = "[]", stderr = "" },
        }),
      })

      local warns = messages(entries, "warn")
      local message = assert_contains(t, warns, "not reachable")
      t.assert(message:find("Start OpenCode", 1, true) ~= nil, "the warning should tell the user to start OpenCode")
      t.assert(message:find("HTTP 500", 1, true) ~= nil, "the warning should include the CLI detail")
    end)
  end)

  t.test("health reports a stopped service timeout", function()
    with_temp(function(dir)
      local entries = run_health({ state_path = vim.fs.joinpath(dir, "state", "sessions.json") }, {
        system = fake_system({
          api = { code = 124, stdout = "", stderr = "" },
          session = { code = 0, stdout = "[]", stderr = "" },
        }),
      })

      local warns = messages(entries, "warn")
      assert_contains(t, warns, "did not answer")
      assert_contains(t, warns, "5000ms", "the health timeout should be capped at 5000ms")
    end)
  end)

  t.test("health reports a missing fzf-lua with the vim.ui.select fallback", function()
    with_temp(function(dir)
      local entries
      with_package_loaded("fzf-lua", nil, function()
        entries = run_health({ state_path = vim.fs.joinpath(dir, "state", "sessions.json") })
      end)

      assert_contains(t, messages(entries, "info"), "vim%.ui%.select")
      t.equal(false, contains(messages(entries, "ok"), "fzf%-lua is available"), "fzf-lua should not be reported present")
    end)
  end)

  t.test("health does not throw when vim.system fails", function()
    with_temp(function(dir)
      local failures = {
        function()
          error("spawn exploded")
        end,
        function()
          return nil
        end,
        function()
          return { wait = function()
            error("wait exploded")
          end }
        end,
      }

      for index, system in ipairs(failures) do
        local ok, err = pcall(function()
          local entries = run_health({ state_path = vim.fs.joinpath(dir, "state", "sessions.json") }, {
            system = system,
          })
          local warns = messages(entries, "warn")
          t.assert(#warns > 0, "system failure " .. index .. " should produce a warning")
          assert_contains(t, warns, "could not")
          t.equal(0, #messages(entries, "error"), "system failures should not be reported as health errors")
        end)
        t.assert(ok, "health should not throw for system failure " .. index .. ": " .. tostring(err))
      end
    end)
  end)
end
