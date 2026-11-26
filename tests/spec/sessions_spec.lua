local sessions = require("opencode_ask.sessions")
local selection = require("opencode_ask.selection")

local function temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir) or dir
end

local function with_temp(fn)
  local dir = temp_dir()
  local ok, err = pcall(fn, dir)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

local function with_options(changes, fn)
  local options = require("opencode_ask").options
  local saved = {}
  for key in pairs(changes) do
    saved[key] = options[key]
  end
  for key, value in pairs(changes) do
    options[key] = value
  end

  local ok, err = pcall(fn)

  for key in pairs(changes) do
    options[key] = saved[key]
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

local function state_file(dir)
  return vim.fs.joinpath(dir, "state", "sessions.json")
end

local function project_root(cwd)
  return selection.project_root(cwd)
end

local function no_temp_files(path)
  return vim.fn.glob(path .. ".tmp.*", false, true)
end

return function(t)
  t.test("parse accepts sessions with missing titles and timestamps", function()
    local json = [=[
      [
      {"id":"ses_e3547e887ffegR9A53M0V2y1GO","title":"Managing parallel coding agents and worktrees","updated":1794403014216,"created":1794402424709,"projectId":"p","directory":"/Users/chiua"},
      {"id":"ses_missing_title","updated":1794403014216,"directory":"/tmp"},
      {"id":"ses_empty_title","title":"","updated":1794403014216},
      {"id":"ses_no_updated","title":"No timestamp"}
      ]
    ]=]

    local parsed, err = sessions.parse(json)

    t.equal(nil, err)
    t.equal(4, #parsed)
    t.equal("ses_e3547e887ffegR9A53M0V2y1GO", parsed[1].id)
    t.equal(1794403014216, parsed[1].updated)
    t.equal(nil, parsed[2].title)
    t.equal("", parsed[3].title)
    t.equal(nil, parsed[4].updated)
  end)

  t.test("parse accepts an empty session array", function()
    local parsed, err = sessions.parse("[]")
    t.equal(nil, err)
    t.equal({}, parsed)
  end)

  t.test("parse rejects invalid JSON and bad shapes", function()
    local cases = {
      { input = "not json", pattern = "JSON" },
      { input = "[not json", pattern = "decode" },
      { input = "", pattern = "no JSON" },
      { input = '{"id":"ses_x"}', pattern = "array" },
      { input = "[1]", pattern = "id" },
      { input = '[{"id":42}]', pattern = "id" },
      { input = '[{"id":""}]', pattern = "id" },
      { input = '[{"title":"no id"}]', pattern = "id" },
    }

    for _, case in ipairs(cases) do
      local parsed, err = sessions.parse(case.input)
      t.equal(nil, parsed, "expected parse to fail for: " .. case.input)
      t.matches(case.pattern, err, "unexpected error for: " .. case.input)
    end
  end)

  t.test("label formats the title, date, and short session id", function()
    local updated = 1794403014216
    local id = "ses_e3547e887ffegR9A53M0V2y1GO"
    local expected_date = os.date("%Y-%m-%d %H:%M", math.floor(updated / 1000))
    local expected = ("Managing parallel coding agents and worktrees (%s) [%s]"):format(expected_date, id:sub(-6))

    t.equal(expected, sessions.label({ id = id, title = "Managing parallel coding agents and worktrees", updated = updated }))
  end)

  t.test("label falls back for missing, empty, and whitespace titles", function()
    local updated = 1794403014216
    local id = "ses_title"
    local missing = sessions.label({ id = id, updated = updated })
    t.matches("^Untitled %(", missing)
    t.assert(missing:find(id:sub(-6), 1, true), "missing title should keep the id suffix")

    for _, title in ipairs({ "", "   " }) do
      local label = sessions.label({ id = id, title = title, updated = updated })
      t.matches("^Untitled %(", label)
      t.assert(label:find(id:sub(-6), 1, true), "empty title should keep the id suffix")
    end
  end)

  t.test("label uses a readable fallback for an invalid timestamp", function()
    local missing = sessions.label({ id = "ses_date", title = "Dated" })
    t.matches("unknown date", missing)

    for _, updated in ipairs({ "yesterday", 0 / 0, -1 }) do
      local label = sessions.label({ id = "ses_date", title = "Dated", updated = updated })
      t.matches("unknown date", label)
    end
  end)

  t.test("label distinguishes duplicate titles by session id", function()
    local updated = 1794403014216
    local first = sessions.label({ id = "ses_aaaaaaaaaa111111", title = "Same title", updated = updated })
    local second = sessions.label({ id = "ses_bbbbbbbbbb222222", title = "Same title", updated = updated })

    t.assert(first ~= second, "duplicate titles should produce distinct labels")
    t.assert(first:find("111111", 1, true), "first label should contain the id suffix")
    t.assert(second:find("222222", 1, true), "second label should contain the id suffix")
  end)

  t.test("state round-trips through an atomic write", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local state = {
        version = 1,
        projects = {
          ["/proj/a"] = { id = "ses_a", title = "Project A", directory = "/proj/a", updated = 1794403014216 },
        },
      }

      with_options({ state_path = path }, function()
        t.equal(path, sessions.state_path())

        local ok, err = sessions.write_state(state)
        t.assert(ok, "write_state failed: " .. tostring(err))
        t.equal(state, sessions.read_state())
        t.equal({}, no_temp_files(path), "successful writes should leave no temp file")
      end)
    end)
  end)

  t.test("write_state replaces existing content and reports write failures", function()
    with_temp(function(dir)
      local path = state_file(dir)

      with_options({ state_path = path }, function()
        local first = { version = 1, projects = { ["/proj/a"] = { id = "ses_a" } } }
        local second = { version = 1, projects = { ["/proj/b"] = { id = "ses_b" } } }

        t.assert(sessions.write_state(first))
        t.assert(sessions.write_state(second))
        t.equal(second, sessions.read_state())
        t.equal({}, no_temp_files(path))
      end)

      local blocker = vim.fs.joinpath(dir, "blocked")
      vim.fn.writefile({ "a file, not a directory" }, blocker)
      local blocked_path = vim.fs.joinpath(blocker, "sessions.json")

      with_options({ state_path = blocked_path }, function()
        local ok, written, write_err = pcall(sessions.write_state, { version = 1, projects = {} })
        t.assert(ok, "write_state should not throw")
        t.equal(nil, written)
        t.matches("could not write session state", write_err)
        t.equal({}, no_temp_files(blocked_path), "failed writes should clean up temp files")
      end)
    end)
  end)

  t.test("read_state recovers from missing and corrupt state files", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local empty = { version = 1, projects = {} }

      with_options({ state_path = path }, function()
        t.equal(empty, sessions.read_state(), "missing file")

        vim.fn.mkdir(vim.fs.dirname(path), "p")

        local corrupt = {
          "not json",
          "",
          "[]",
          '{"version":1,"projects":{"a":42}}',
          '{"version":1,"projects":{"a":{"id":42}}}',
          '{"version":2,"projects":{}}',
        }
        for _, contents in ipairs(corrupt) do
          vim.fn.writefile({ contents }, path)
          t.equal(empty, sessions.read_state(), "corrupt state: " .. contents)
        end
      end)
    end)
  end)

  t.test("clear removes only the target project and preserves others", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project_a = vim.fs.joinpath(dir, "project-a")
      local project_b = vim.fs.joinpath(dir, "project-b")
      vim.fn.mkdir(vim.fs.joinpath(project_a, ".git"), "p")
      vim.fn.mkdir(vim.fs.joinpath(project_b, ".git"), "p")

      with_options({ state_path = path }, function()
        local key_a = project_root(project_a)
        local key_b = project_root(project_b)

        t.assert(sessions.write_state({
          version = 1,
          projects = {
            [key_a] = { id = "ses_a", title = "A", directory = project_a, updated = 1 },
            [key_b] = { id = "ses_b", title = "B", directory = project_b, updated = 2 },
          },
        }))

        local ok, err = sessions.clear(project_a)
        t.assert(ok, "clear failed: " .. tostring(err))

        local state = sessions.read_state()
        t.equal(nil, state.projects[key_a], "target project should be removed")
        t.equal("ses_b", state.projects[key_b].id, "other projects should be preserved")
      end)
    end)
  end)

  t.test("clear is a no-op for missing files and entries", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")

      with_options({ state_path = path }, function()
        local ok, err = sessions.clear(project)
        t.equal(true, ok, "clear should succeed without a state file")
        t.equal(nil, err)
        t.equal(nil, vim.uv.fs_stat(path), "an empty clear should not create a state file")
      end)
    end)
  end)

  t.test("resolve prefers a pinned session without listing sessions", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")

      with_options({ state_path = path, session = "ses_pinned" }, function()
        t.assert(sessions.write_state({
          version = 1,
          projects = { [project_root(project)] = { id = "ses_stored", title = "Stored" } },
        }))

        local listed = false
        with_stub(sessions, "list", function()
          listed = true
          error("list should not be called for a pinned session")
        end, function()
          local got_err, got
          local ok, err = pcall(sessions.resolve, project, function(resolve_err, session)
            got_err = resolve_err
            got = session
          end)

          t.assert(ok, "resolve should not throw: " .. tostring(err))
          t.equal(nil, got_err)
          t.equal({ id = "ses_pinned" }, got)
          t.equal(false, listed, "pinned sessions must not list")
        end)
      end)
    end)
  end)

  t.test("resolve reads a stored project entry without the picker", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project = vim.fs.joinpath(dir, "project")
      local nested = vim.fs.joinpath(project, "src")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")
      vim.fn.mkdir(nested, "p")
      local stored = { id = "ses_stored", title = "Stored", directory = project, updated = 3 }

      with_options({ state_path = path }, function()
        t.assert(sessions.write_state({ version = 1, projects = { [project_root(project)] = stored } }))

        with_stub(sessions, "list", function()
          error("list should not be called for a stored session")
        end, function()
          local got_err, got
          local ok, err = pcall(sessions.resolve, nested, function(resolve_err, session)
            got_err = resolve_err
            got = session
          end)

          t.assert(ok, "resolve should not throw: " .. tostring(err))
          t.equal(nil, got_err)
          t.equal(stored, got, "a nested directory should resolve to the project key")
        end)
      end)
    end)
  end)

  t.test("resolve falls through to choose when no session is stored", function()
    with_temp(function(dir)
      local project = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")
      local chosen = { id = "ses_chosen" }
      local choose_cwd

      with_options({ state_path = state_file(dir) }, function()
        with_stub(sessions, "choose", function(cwd, callback)
          choose_cwd = cwd
          callback(nil, chosen)
        end, function()
          local got_err, got
          sessions.resolve(project, function(resolve_err, session)
            got_err = resolve_err
            got = session
          end)

          t.equal(nil, got_err)
          t.equal(chosen, got)
          t.equal(project, choose_cwd)
        end)
      end)
    end)
  end)

  t.test("choose stores the selected session and preserves other projects", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project = vim.fs.joinpath(dir, "project")
      local other = vim.fs.joinpath(dir, "other")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")
      vim.fn.mkdir(vim.fs.joinpath(other, ".git"), "p")

      local chosen = {
        id = "ses_chosen",
        title = "Chosen session",
        directory = project,
        updated = 1794403014216,
      }
      local listed = {
        chosen,
        { id = "ses_other", title = "Other session", directory = "/tmp/other", updated = 1794403014217 },
      }

      with_options({ state_path = path, picker = "none" }, function()
        t.assert(sessions.write_state({
          version = 1,
          projects = { [project_root(other)] = { id = "ses_preserved", title = "Keep me" } },
        }))

        local select_calls = 0
        local selected_items

        with_stub(sessions, "list", function(cwd, callback)
          t.equal(project, cwd)
          callback(nil, listed)
        end, function()
          with_stub(vim.ui, "select", function(items, opts, callback)
            select_calls = select_calls + 1
            selected_items = items
            t.equal("OpenCode sessions", opts.prompt)
            callback(items[1])
          end, function()
            local calls = 0
            local got_err, got

            sessions.choose(project, function(err, session)
              calls = calls + 1
              got_err = err
              got = session
            end)

            t.equal(1, select_calls, "the picker should be shown once")
            t.equal(2, #selected_items, "both sessions should be offered")
            t.equal(1, calls, "the callback should run once")
            t.equal(nil, got_err)
            t.equal(chosen, got)
          end)
        end)

        local state = sessions.read_state()
        local stored = state.projects[project_root(project)]
        t.equal("ses_chosen", stored.id)
        t.equal("Chosen session", stored.title)
        t.equal(project, stored.directory)
        t.equal(1794403014216, stored.updated)
        t.equal("ses_preserved", state.projects[project_root(other)].id, "other projects should be preserved")
      end)
    end)
  end)

  t.test("choose cancellation is a clean no-op", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")

      with_options({ state_path = path, picker = "none" }, function()
        with_stub(sessions, "list", function(_, callback)
          callback(nil, { { id = "ses_a", title = "A" } })
        end, function()
          local function expect_cancel(choice)
            with_stub(vim.ui, "select", function(_, _, callback)
              callback(choice)
            end, function()
              local calls = 0
              sessions.choose(project, function()
                calls = calls + 1
              end)

              t.equal(0, calls, "cancelling the picker must not call the callback")
            end)
          end

          expect_cancel(nil)
          expect_cancel("")
        end)

        t.equal(nil, vim.uv.fs_stat(path), "cancelling the picker must not store a session")
      end)
    end)
  end)

  t.test("choose reports an actionable error when no sessions exist", function()
    with_temp(function(dir)
      local path = state_file(dir)
      local project = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")

      with_options({ state_path = path, picker = "none" }, function()
        with_stub(sessions, "list", function(_, callback)
          callback(nil, {})
        end, function()
          local picker_calls = 0
          with_stub(vim.ui, "select", function()
            picker_calls = picker_calls + 1
          end, function()
            local calls = 0
            local got_err

            sessions.choose(project, function(err)
              calls = calls + 1
              got_err = err
            end)

            t.equal(1, calls, "the callback should run once")
            t.equal(0, picker_calls, "the picker should not open for an empty list")
            t.matches("No OpenCode sessions found", got_err)
            t.assert(got_err:find(project, 1, true), "the error should name the directory")
            t.matches(":OpencodeSession", got_err)
          end)
        end)

        t.equal(nil, vim.uv.fs_stat(path), "no session should be stored")
      end)
    end)
  end)

  t.test("choose propagates list errors without opening the picker", function()
    with_temp(function(dir)
      local project = vim.fs.joinpath(dir, "project")
      vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")

      with_options({ state_path = state_file(dir), picker = "none" }, function()
        with_stub(sessions, "list", function(_, callback)
          callback("opencode-ask: boom")
        end, function()
          local picker_calls = 0
          with_stub(vim.ui, "select", function()
            picker_calls = picker_calls + 1
          end, function()
            local got_err
            sessions.choose(project, function(err)
              got_err = err
            end)

            t.equal("opencode-ask: boom", got_err)
            t.equal(0, picker_calls)
          end)
        end)
      end)
    end)
  end)

  t.test("list classifies timeouts, failures, and invalid JSON", function()
    local cwd = "/some/project"

    local function run(result)
      local done = false
      local got_err, got_sessions

      with_options({ api = { command = vim.v.progpath, timeout = 1234 } }, function()
        with_stub(vim, "system", function(cmd, opts, on_exit)
          t.equal(vim.v.progpath, cmd[1])
          t.equal("session", cmd[2])
          t.equal("list", cmd[3])
          t.equal("--format", cmd[4])
          t.equal("json", cmd[5])
          t.equal(cwd, opts.cwd)
          t.equal(true, opts.text)
          t.equal(1234, opts.timeout)

          on_exit(result)
          return { pid = 0 }
        end, function()
          local ok, err = pcall(sessions.list, cwd, function(list_err, listed)
            done = true
            got_err = list_err
            got_sessions = listed
          end)

          t.assert(ok, "list should not throw: " .. tostring(err))
          t.assert(vim.wait(2000, function()
            return done
          end), "list callback should run")
        end)
      end)

      return got_err, got_sessions
    end

    local err = run({ code = 124, stdout = "", stderr = "" })
    t.matches("timed out", err)

    err = run({ code = 1, stdout = "{}", stderr = "HTTP 500" })
    t.matches("exit code 1", err)
    t.assert(err:find("HTTP 500", 1, true), "the exit error should include stderr")

    err = run({ code = 0, stdout = "not json", stderr = "" })
    t.matches("JSON array", err)

    local _, listed = run({ code = 0, stdout = '[{"id":"ses_a"}]', stderr = "" })
    t.equal("ses_a", listed[1].id)
  end)

  t.test("list reports a missing executable without throwing", function()
    with_temp(function(dir)
      with_options({
        state_path = state_file(dir),
        api = { command = "opencode-ask-missing-cli", timeout = 1000 },
      }, function()
        local done = false
        local got_err, got_sessions

        local ok, call_err = pcall(sessions.list, dir, function(err, listed)
          done = true
          got_err = err
          got_sessions = listed
        end)

        t.assert(ok, "list should not throw: " .. tostring(call_err))
        t.assert(vim.wait(2000, function()
          return done
        end), "list callback should run")

        t.equal(nil, got_sessions)
        t.matches("not executable", got_err)
      end)
    end)
  end)
end
