local init = require("opencode_ask")
local client = require("opencode_ask.client")
local selection = require("opencode_ask.selection")
local sessions = require("opencode_ask.sessions")
local ui = require("opencode_ask.ui")

local source = debug.getinfo(1, "S").source:sub(2)
local spec_dir = vim.fs.dirname(source)
local repo_root = vim.fs.dirname(vim.fs.dirname(spec_dir))
local plugin_path = vim.fs.joinpath(repo_root, "plugin", "opencode_ask.lua")

local INFO = vim.log.levels.INFO
local WARN = vim.log.levels.WARN

local function with_options(changes, fn)
  local original = init.options
  local options = {}
  for key, value in pairs(original) do
    options[key] = value
  end
  for key, value in pairs(changes or {}) do
    options[key] = value
  end

  init.options = options
  local ok, err = pcall(fn)
  init.options = original
  if not ok then
    error(err, 0)
  end
end

local function with_stubs(stubs, fn)
  local saved = {}
  for index, stub in ipairs(stubs) do
    local owner, key = stub[1], stub[2]
    saved[index] = owner[key]
    owner[key] = stub[3]
  end

  local ok, err = pcall(fn)

  for index = #stubs, 1, -1 do
    local owner, key = stubs[index][1], stubs[index][2]
    owner[key] = saved[index]
  end
  if not ok then
    error(err, 0)
  end
end

local function notification_stub(notifications)
  return function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
end

local function make_context(overrides)
  local context = {
    bufnr = vim.api.nvim_get_current_buf(),
    absolute = "/tmp/project/src/example.lua",
    relative = "src/example.lua",
    project_root = "/tmp/project",
    first = 2,
    last = 4,
    ref = "src/example.lua:2-4",
    mention = "@src/example.lua#2-4",
    uri = "file:///tmp/project/src/example.lua?start=2&end=4",
  }
  for key, value in pairs(overrides or {}) do
    context[key] = value
  end
  return context
end

local function delete_mapping(mode, key)
  pcall(vim.keymap.del, mode, key)
end

--- Clear the mapping installed by any earlier setup() call without leaving
--- setup-specific options in place.
local function reset_plugin_keymap()
  with_options({}, function()
    init.setup({ keymap = false, state_path = vim.fn.tempname() })
  end)
end

return function(t)
  t.test("ask captures, prompts, saves, resolves, and sends", function()
    local context = make_context()
    local capture_opts, prompt_opts, saved_context, resolve_root, sent
    local notifications = {}

    with_options({ save = true, session = nil }, function()
      with_stubs({
        { selection, "capture", function(opts)
          capture_opts = opts
          return context
        end },
        { ui, "prompt", function(opts, on_submit)
          prompt_opts = opts
          on_submit("What does this code do?")
        end },
        { selection, "save", function(ctx)
          saved_context = ctx
          return true
        end },
        { sessions, "resolve", function(root, callback)
          resolve_root = root
          callback(nil, { id = "ses_test", title = "Test session" })
        end },
        { client, "send", function(session, question, ctx, callback)
          sent = { session = session, question = question, context = ctx }
          callback(nil, { accepted = true })
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, { first = 2, last = 4 })
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal({ first = 2, last = 4 }, capture_opts, "ask should pass its range to capture")
    t.equal(context.ref, prompt_opts.title, "the prompt title should be the selection ref")
    t.equal(context, saved_context, "save should receive the captured context")
    t.equal(context.project_root, resolve_root, "resolve should use the project root")
    t.equal("ses_test", sent.session.id)
    t.equal("What does this code do?", sent.question)
    t.equal(context, sent.context)

    t.equal(1, #notifications, "only the success notification should be shown")
    t.equal(INFO, notifications[1].level)
    t.matches("Sent to Test session", notifications[1].message)
    t.matches("src/example.lua:2%-4", notifications[1].message)
  end)

  t.test("ask creates, stores, and sends to a session through the real picker path", function()
    local dir = vim.fn.tempname()
    local project = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(vim.fs.joinpath(project, ".git"), "p")
    project = vim.uv.fs_realpath(project) or project
    local state_path = vim.fs.joinpath(dir, "state", "sessions.json")
    local context = make_context({ project_root = project })
    local created = {
      id = "ses_created",
      title = "Created session",
      directory = project,
      updated = 1794403014222,
    }
    local creation = {}
    local sent = {}
    local notifications = {}

    local ok, err = pcall(function()
      with_options({ save = true, session = nil, state_path = state_path, picker = "none" }, function()
        with_stubs({
          { selection, "capture", function()
            return context
          end },
          { ui, "prompt", function(_, on_submit)
            on_submit("What does this code do?")
          end },
          { selection, "save", function()
            return true
          end },
          { sessions, "list", function(root, callback)
            t.equal(project, root)
            callback(nil, {})
          end },
          { vim.ui, "select", function(items, opts, callback)
            t.equal("OpenCode sessions", opts.prompt)
            t.equal({ sessions.CREATE_SESSION_LABEL }, items)
            callback(sessions.CREATE_SESSION_LABEL)
          end },
          { vim.ui, "input", function(opts, callback)
            t.equal("New OpenCode session title: ", opts.prompt)
            callback("Created session")
          end },
          { client, "create_session", function(root, title, callback)
            creation.root = root
            creation.title = title
            callback(nil, created)
          end },
          { client, "send", function(session, question, sent_context, callback)
            sent.session = session
            sent.question = question
            sent.context = sent_context
            callback(nil, { accepted = true })
          end },
          { vim, "notify", notification_stub(notifications) },
        }, function()
          local ask_ok, ask_err = pcall(init.ask, { first = 2, last = 4 })
          t.assert(ask_ok, "ask should not throw: " .. tostring(ask_err))
        end)

        t.equal(project, creation.root, "creation should use the project root")
        t.equal("Created session", creation.title, "creation should use the entered title")
        t.equal(created, sent.session, "the created session should be passed to send")
        t.equal("What does this code do?", sent.question)
        t.equal(context, sent.context)
        t.equal({
          id = "ses_created",
          title = "Created session",
          directory = project,
          updated = 1794403014222,
        }, sessions.read_state().projects[selection.project_root(project)],
          "the created session should be stored under the project key")
        t.equal(1, #notifications)
        t.equal(INFO, notifications[1].level)
        t.matches("Sent to Created session", notifications[1].message)
      end)
    end)

    vim.fn.delete(dir, "rf")
    if not ok then
      error(err, 0)
    end
  end)

  t.test("ask notifies when the selection cannot be captured", function()
    local prompt_called = false
    local notifications = {}

    with_options({ save = true }, function()
      with_stubs({
        { selection, "capture", function()
          return nil, "opencode-ask: capture failed"
        end },
        { ui, "prompt", function()
          prompt_called = true
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal(false, prompt_called, "the prompt must not open without a context")
    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("capture failed", notifications[1].message)
  end)

  t.test("ask aborts on a modified read-only buffer before prompting", function()
    local function expect_abort(configure)
      local path = vim.fn.tempname() .. ".lua"
      vim.fn.writefile({ "local x = 1", "local y = 2" }, path)
      local original_buf = vim.api.nvim_get_current_buf()
      local buffer

      local ok, err = pcall(function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        buffer = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local x = 1", "local y = 2", "local z = 3" })
        configure(buffer)

        local context = make_context({ bufnr = buffer })
        local prompt_called = false
        local notifications = {}

        with_options({ save = true }, function()
          with_stubs({
            { selection, "capture", function()
              return context
            end },
            { ui, "prompt", function()
              prompt_called = true
            end },
            { vim, "notify", notification_stub(notifications) },
          }, function()
            local call_ok, call_err = pcall(init.ask, {})
            t.assert(call_ok, "ask should not throw: " .. tostring(call_err))
          end)
        end)

        t.equal(false, prompt_called, "the prompt must not open for an unsavable buffer")
        t.equal(1, #notifications)
        t.equal(WARN, notifications[1].level)
        t.matches("read%-only or not modifiable", notifications[1].message)
      end)

      if buffer and vim.api.nvim_buf_is_valid(buffer) then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
      vim.fn.delete(path)
      if vim.api.nvim_buf_is_valid(original_buf) then
        pcall(vim.api.nvim_set_current_buf, original_buf)
      end
      if not ok then
        error(err, 0)
      end
    end

    expect_abort(function(buffer)
      vim.bo[buffer].readonly = true
    end)
    expect_abort(function(buffer)
      vim.bo[buffer].modifiable = false
    end)
  end)

  t.test("ask aborts when saving the captured buffer fails", function()
    local context = make_context()
    local save_called = false
    local resolve_called = false
    local send_called = false
    local notifications = {}

    with_options({ save = true }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "prompt", function(_, on_submit)
          on_submit("Why?")
        end },
        { selection, "save", function()
          save_called = true
          return nil, "opencode-ask: save failed"
        end },
        { sessions, "resolve", function()
          resolve_called = true
        end },
        { client, "send", function()
          send_called = true
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal(true, save_called)
    t.equal(false, resolve_called, "resolve must not run after a save failure")
    t.equal(false, send_called, "send must not run after a save failure")
    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("save failed", notifications[1].message)
  end)

  t.test("ask notifies when session resolution fails", function()
    local context = make_context()
    local send_called = false
    local notifications = {}

    with_options({ save = true }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "prompt", function(_, on_submit)
          on_submit("Why?")
        end },
        { selection, "save", function()
          return true
        end },
        { sessions, "resolve", function(_, callback)
          callback("opencode-ask: resolve exploded")
        end },
        { client, "send", function()
          send_called = true
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal(false, send_called, "send must not run after a resolve error")
    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("resolve exploded", notifications[1].message)
  end)

  t.test("ask notifies client errors as strings or tables", function()
    local context = make_context()

    local function run(send_err)
      local notifications = {}

      with_options({ save = true }, function()
        with_stubs({
          { selection, "capture", function()
            return context
          end },
          { ui, "prompt", function(_, on_submit)
            on_submit("Why?")
          end },
          { selection, "save", function()
            return true
          end },
          { sessions, "resolve", function(_, callback)
            callback(nil, { id = "ses_test", title = "Test" })
          end },
          { client, "send", function(_, _, _, callback)
            callback(send_err)
          end },
          { vim, "notify", notification_stub(notifications) },
        }, function()
          local ok, err = pcall(init.ask, {})
          t.assert(ok, "ask should not throw: " .. tostring(err))
        end)
      end)

      return notifications
    end

    local string_notifications = run("opencode-ask: string failure")
    t.equal(1, #string_notifications)
    t.equal(WARN, string_notifications[1].level)
    t.matches("string failure", string_notifications[1].message)

    local table_notifications = run({ kind = "api_error", message = "table failure" })
    t.equal(1, #table_notifications)
    t.equal(WARN, table_notifications[1].level)
    t.matches("table failure", table_notifications[1].message)
  end)

  t.test("ask tells the user to update a pinned session that disappeared", function()
    local context = make_context()
    local clear_called = false
    local notifications = {}

    with_options({ save = true, session = "ses_pinned" }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "prompt", function(_, on_submit)
          on_submit("Why?")
        end },
        { selection, "save", function()
          return true
        end },
        { sessions, "resolve", function(_, callback)
          callback(nil, { id = "ses_pinned" })
        end },
        { client, "send", function(_, _, _, callback)
          callback({ kind = "session_not_found", message = "Session not found: ses_pinned" })
        end },
        { sessions, "clear", function()
          clear_called = true
          return true
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal(false, clear_called, "a pinned session must not clear the stored state")
    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("config%.session", notifications[1].message)
  end)

  t.test("ask clears the stored session when a stored session disappeared", function()
    local context = make_context()
    local clear_root
    local notifications = {}

    with_options({ save = true, session = nil }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "prompt", function(_, on_submit)
          on_submit("Why?")
        end },
        { selection, "save", function()
          return true
        end },
        { sessions, "resolve", function(_, callback)
          callback(nil, { id = "ses_missing", title = "Stored" })
        end },
        { client, "send", function(_, _, _, callback)
          callback({ kind = "session_not_found", message = "Session not found: ses_missing" })
        end },
        { sessions, "clear", function(root)
          clear_root = root
          return true
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal(context.project_root, clear_root, "clear should receive the project root")
    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches(":OpencodeSession", notifications[1].message)
  end)

  t.test("select_session chooses a session for the current project", function()
    local root_arg
    local notifications = {}

    with_stubs({
      { selection, "project_root", function(target)
        root_arg = target
        return "/tmp/project"
      end },
      { sessions, "choose", function(root, callback)
        t.equal("/tmp/project", root)
        callback(nil, { id = "ses_chosen", title = "Chosen session" })
      end },
      { vim, "notify", notification_stub(notifications) },
    }, function()
      local ok, err = pcall(init.select_session)
      t.assert(ok, "select_session should not throw: " .. tostring(err))
    end)

    t.equal(0, root_arg, "select_session should resolve the current buffer's project")
    t.equal(1, #notifications)
    t.equal(INFO, notifications[1].level)
    t.matches("Chosen session", notifications[1].message)
  end)

  t.test("select_session notifies picker errors and ignores cancellation", function()
    local notifications = {}

    with_stubs({
      { selection, "project_root", function()
        return "/tmp/project"
      end },
      { sessions, "choose", function(_, callback)
        callback("opencode-ask: no sessions found")
      end },
      { vim, "notify", notification_stub(notifications) },
    }, function()
      local ok, err = pcall(init.select_session)
      t.assert(ok, "select_session should not throw: " .. tostring(err))
    end)

    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("no sessions found", notifications[1].message)

    notifications = {}
    with_stubs({
      { selection, "project_root", function()
        return "/tmp/project"
      end },
      { sessions, "choose", function() end },
      { vim, "notify", notification_stub(notifications) },
    }, function()
      local ok, err = pcall(init.select_session)
      t.assert(ok, "select_session should not throw: " .. tostring(err))
    end)

    t.equal(0, #notifications, "picker cancellation should be a no-op")
  end)

  t.test("clear_session clears the current project's stored session", function()
    local root_arg
    local notifications = {}

    with_stubs({
      { selection, "project_root", function(target)
        root_arg = target
        return "/tmp/project"
      end },
      { sessions, "clear", function(root)
        t.equal("/tmp/project", root)
        return true
      end },
      { vim, "notify", notification_stub(notifications) },
    }, function()
      local ok, err = pcall(init.clear_session)
      t.assert(ok, "clear_session should not throw: " .. tostring(err))
    end)

    t.equal(0, root_arg)
    t.equal(1, #notifications)
    t.equal(INFO, notifications[1].level)
    t.matches("Cleared", notifications[1].message)
  end)

  t.test("clear_session notifies clear errors", function()
    local notifications = {}

    with_stubs({
      { selection, "project_root", function()
        return "/tmp/project"
      end },
      { sessions, "clear", function()
        return nil, "opencode-ask: clear failed"
      end },
      { vim, "notify", notification_stub(notifications) },
    }, function()
      local ok, err = pcall(init.clear_session)
      t.assert(ok, "clear_session should not throw: " .. tostring(err))
    end)

    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("clear failed", notifications[1].message)
  end)

  t.test("ask leaves visual mode before opening the prompt", function()
    local context = make_context()

    local function run(mode)
      local order = {}

      with_options({ save = true }, function()
        with_stubs({
          { selection, "capture", function()
            return context
          end },
          { vim.fn, "mode", function()
            return mode
          end },
          { vim.api, "nvim_feedkeys", function(keys, flags)
            order[#order + 1] = { kind = "keys", keys = keys, flags = flags }
          end },
          { ui, "prompt", function()
            order[#order + 1] = { kind = "prompt" }
          end },
          { vim, "notify", function() end },
        }, function()
          local ok, err = pcall(init.ask, {})
          t.assert(ok, "ask should not throw: " .. tostring(err))
        end)
      end)

      return order
    end

    local visual = run("V")
    t.equal(2, #visual)
    t.equal("keys", visual[1].kind)
    t.equal("\27", visual[1].keys, "visual mode should be left with <Esc>")
    t.equal("nx", visual[1].flags)
    t.equal("prompt", visual[2].kind)

    local normal = run("n")
    t.equal(1, #normal, "normal mode should not feed an extra <Esc>")
    t.equal("prompt", normal[1].kind)
  end)

  t.test("setup installs an x-mode keymap only", function()
    local key = "<leader>oq"
    delete_mapping("x", key)
    delete_mapping("s", key)

    local ok, err = pcall(function()
      with_options({}, function()
        local options = init.setup({ keymap = key, state_path = vim.fn.tempname() })
        t.equal(key, options.keymap)
        t.assert(vim.fn.maparg(key, "x") ~= "", "the visual-mode mapping should exist")
        t.equal("", vim.fn.maparg(key, "s"), "no select-mode mapping should be installed")

        local mapping = vim.fn.maparg(key, "x", false, true)
        t.equal("Ask OpenCode about the visual selection", mapping.desc)
      end)
    end)

    delete_mapping("x", key)
    delete_mapping("s", key)
    if not ok then
      error(err, 0)
    end
  end)

  t.test("setup honors a custom keymap", function()
    local default_key = "<leader>oq"
    local custom_key = "<leader>ot"
    delete_mapping("x", default_key)
    delete_mapping("x", custom_key)

    local ok, err = pcall(function()
      with_options({}, function()
        init.setup({ keymap = custom_key, state_path = vim.fn.tempname() })
        t.assert(vim.fn.maparg(custom_key, "x") ~= "", "the custom mapping should exist")
        t.equal("", vim.fn.maparg(default_key, "x"), "the default mapping should not be installed")
      end)
    end)

    delete_mapping("x", default_key)
    delete_mapping("x", custom_key)
    if not ok then
      error(err, 0)
    end
  end)

  t.test("setup installs nothing when the keymap is false", function()
    local key = "<leader>oq"
    delete_mapping("x", key)

    local ok, err = pcall(function()
      with_options({}, function()
        local options = init.setup({ keymap = false, state_path = vim.fn.tempname() })
        t.equal(false, options.keymap)
        t.equal("", vim.fn.maparg(key, "x"), "no mapping should be installed")
      end)
    end)

    delete_mapping("x", key)
    if not ok then
      error(err, 0)
    end
  end)

  t.test("plugin file registers commands with range and callbacks", function()
    local names = { "OpencodeAsk", "OpencodeSession", "OpencodeSessionClear" }
    local saved_loaded = vim.g.loaded_opencode_ask
    for _, name in ipairs(names) do
      pcall(vim.api.nvim_del_user_command, name)
    end
    vim.g.loaded_opencode_ask = nil

    local buffer = vim.api.nvim_create_buf(true, false)
    local calls = {}

    local function command_exists(name)
      return vim.api.nvim_get_commands({ builtin = false })[name] ~= nil
    end

    local ok, err = pcall(function()
      with_stubs({
        { init, "ask", function(opts)
          calls.ask = opts
        end },
        { init, "select_session", function()
          calls.select = (calls.select or 0) + 1
        end },
        { init, "clear_session", function()
          calls.clear = (calls.clear or 0) + 1
        end },
      }, function()
        local loaded, load_err = pcall(dofile, plugin_path)
        t.assert(loaded, "plugin file should load: " .. tostring(load_err))

        for _, name in ipairs(names) do
          t.assert(command_exists(name), name .. " should be registered")
        end

        local commands = vim.api.nvim_get_commands({ builtin = false })
        t.equal(".", commands.OpencodeAsk.range, "OpencodeAsk should accept a range")
        t.equal("0", commands.OpencodeAsk.nargs)
        t.equal("0", commands.OpencodeSession.nargs)
        t.equal("0", commands.OpencodeSessionClear.nargs)

        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "one", "two", "three", "four", "five" })
        vim.api.nvim_set_current_buf(buffer)

        vim.cmd("2,4OpencodeAsk")
        t.equal({ first = 2, last = 4 }, calls.ask)

        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        vim.cmd("OpencodeAsk")
        t.equal({ first = 3, last = 3 }, calls.ask, "without a range the current line is used")

        vim.cmd("OpencodeSession")
        t.equal(1, calls.select)
        vim.cmd("OpencodeSessionClear")
        t.equal(1, calls.clear)

        -- The loaded guard prevents re-sourcing from recreating commands.
        vim.api.nvim_del_user_command("OpencodeSession")
        local reloaded, reload_err = pcall(dofile, plugin_path)
        t.assert(reloaded, "loading the guarded plugin again should not throw: " .. tostring(reload_err))
        t.equal(false, command_exists("OpencodeSession"), "the loaded guard should skip re-registration")
      end)
    end)

    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    for _, name in ipairs(names) do
      pcall(vim.api.nvim_del_user_command, name)
    end
    vim.g.loaded_opencode_ask = saved_loaded
    if not ok then
      error(err, 0)
    end
  end)

  t.test("ask warns without throwing when the prompt cannot open", function()
    local context = make_context()
    local save_called = false
    local resolve_called = false
    local send_called = false
    local notifications = {}

    with_options({ save = false }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "prompt", function()
          error("float exploded")
        end },
        { selection, "save", function()
          save_called = true
        end },
        { sessions, "resolve", function()
          resolve_called = true
        end },
        { client, "send", function()
          send_called = true
        end },
        { vim, "notify", notification_stub(notifications) },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.equal(false, save_called, "save must not run when the prompt fails")
    t.equal(false, resolve_called, "resolve must not run when the prompt fails")
    t.equal(false, send_called, "send must not run when the prompt fails")
    t.equal(1, #notifications)
    t.equal(WARN, notifications[1].level)
    t.matches("could not open the question prompt", notifications[1].message)
    t.matches("float exploded", notifications[1].message)
  end)

  t.test("setup replaces the previous plugin keymap", function()
    local first = "<leader>oz"
    local second = "<leader>oy"
    delete_mapping("x", first)
    delete_mapping("x", second)
    reset_plugin_keymap()

    local ok, err = pcall(function()
      with_options({}, function()
        init.setup({ keymap = first, state_path = vim.fn.tempname() })
        t.assert(vim.fn.maparg(first, "x") ~= "", "the first mapping should be installed")

        init.setup({ keymap = second, state_path = vim.fn.tempname() })
        t.equal("", vim.fn.maparg(first, "x"), "the previous plugin mapping should be removed")
        t.assert(vim.fn.maparg(second, "x") ~= "", "the new mapping should be installed")
      end)
    end)

    delete_mapping("x", first)
    delete_mapping("x", second)
    if not ok then
      error(err, 0)
    end
  end)

  t.test("setup removes the previous plugin keymap when disabled", function()
    local key = "<leader>oz"
    delete_mapping("x", key)
    reset_plugin_keymap()

    local ok, err = pcall(function()
      with_options({}, function()
        init.setup({ keymap = key, state_path = vim.fn.tempname() })
        t.assert(vim.fn.maparg(key, "x") ~= "", "the mapping should be installed")

        local options = init.setup({ keymap = false, state_path = vim.fn.tempname() })
        t.equal(false, options.keymap)
        t.equal("", vim.fn.maparg(key, "x"), "disabling the keymap should remove the plugin mapping")
      end)
    end)

    delete_mapping("x", key)
    if not ok then
      error(err, 0)
    end
  end)

  t.test("setup preserves user mappings it did not install", function()
    local first = "<leader>oz"
    local second = "<leader>oy"
    local unrelated = "<leader>ox"
    local user_callback = function() end
    delete_mapping("x", first)
    delete_mapping("x", second)
    delete_mapping("x", unrelated)
    reset_plugin_keymap()

    local ok, err = pcall(function()
      with_options({}, function()
        init.setup({ keymap = first, state_path = vim.fn.tempname() })

        -- The user replaces the plugin mapping and adds an unrelated mapping.
        vim.keymap.set("x", first, user_callback, { desc = "user mapping" })
        vim.keymap.set("x", unrelated, user_callback, { desc = "unrelated user mapping" })

        init.setup({ keymap = second, state_path = vim.fn.tempname() })

        local replaced = vim.fn.maparg(first, "x", false, true)
        t.equal("table", type(replaced), "the user mapping should still exist")
        t.equal(user_callback, replaced.callback, "the user mapping should not be deleted")
        t.assert(vim.fn.maparg(unrelated, "x") ~= "", "unrelated user mappings should be preserved")
        t.assert(vim.fn.maparg(second, "x") ~= "", "the new plugin mapping should be installed")
      end)
    end)

    delete_mapping("x", first)
    delete_mapping("x", second)
    delete_mapping("x", unrelated)
    if not ok then
      error(err, 0)
    end
  end)

  t.test("ask forwards ui options, anchor, and highlight to the prompt", function()
    local context = make_context()
    local prompt_opts
    local measured = {}

    with_options({
      save = false,
      ui = {
        width = 60,
        height = 6,
        border = "single",
        position = "selection",
        winblend = 12,
      },
    }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "_measure_anchor", function(win, first, last)
          measured.win = win
          measured.first = first
          measured.last = last
          return { top_row = 3, bottom_row = 5, win_col = 0, win_width = 80 }
        end },
        { ui, "prompt", function(opts)
          prompt_opts = opts
        end },
        { vim, "notify", function() end },
      }, function()
        local ok, err = pcall(init.ask, { first = 2, last = 4 })
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.assert(prompt_opts ~= nil, "the prompt should be called")
    t.equal(context.ref, prompt_opts.title)
    t.equal(60, prompt_opts.width)
    t.equal(6, prompt_opts.height)
    t.equal("single", prompt_opts.border)
    t.equal("selection", prompt_opts.position)
    t.equal(12, prompt_opts.winblend)
    t.equal({ top_row = 3, bottom_row = 5, win_col = 0, win_width = 80 }, prompt_opts.anchor)
    t.equal({ bufnr = context.bufnr, first = 2, last = 4 }, prompt_opts.highlight)
    t.equal(vim.api.nvim_get_current_win(), measured.win)
    t.equal(2, measured.first)
    t.equal(4, measured.last)
  end)

  t.test("ask skips anchor measurement with a centered prompt but keeps the highlight", function()
    local context = make_context()
    local prompt_opts
    local measure_called = false

    with_options({
      save = false,
      ui = {
        width = 70,
        height = 5,
        border = "rounded",
        position = "center",
        winblend = 0,
      },
    }, function()
      with_stubs({
        { selection, "capture", function()
          return context
        end },
        { ui, "_measure_anchor", function()
          measure_called = true
          return { top_row = 1, bottom_row = 2, win_col = 0, win_width = 80 }
        end },
        { ui, "prompt", function(opts)
          prompt_opts = opts
        end },
        { vim, "notify", function() end },
      }, function()
        local ok, err = pcall(init.ask, {})
        t.assert(ok, "ask should not throw: " .. tostring(err))
      end)
    end)

    t.assert(prompt_opts ~= nil, "the prompt should be called")
    t.equal(false, measure_called, "a centered prompt must not measure the selection")
    t.equal(nil, prompt_opts.anchor)
    t.equal("center", prompt_opts.position)
    t.equal({
      bufnr = context.bufnr,
      first = context.first,
      last = context.last,
    }, prompt_opts.highlight)
  end)

  t.test("ask omits the anchor when the current window shows another buffer", function()
    local original_buf = vim.api.nvim_get_current_buf()
    local other_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "one", "two", "three", "four" })
    local context = make_context({ bufnr = other_buf, first = 2, last = 3 })
    local prompt_opts
    local measure_called = false

    local ok, err = pcall(function()
      with_options({
        save = false,
        ui = {
          width = 80,
          height = 4,
          border = "rounded",
          position = "selection",
          winblend = 0,
        },
      }, function()
        with_stubs({
          { selection, "capture", function()
            return context
          end },
          { ui, "_measure_anchor", function()
            measure_called = true
            return { top_row = 1, bottom_row = 2, win_col = 0, win_width = 80 }
          end },
          { ui, "prompt", function(opts)
            prompt_opts = opts
          end },
          { vim, "notify", function() end },
        }, function()
          local ask_ok, ask_err = pcall(init.ask, { bufnr = other_buf, first = 2, last = 3 })
          t.assert(ask_ok, "ask should not throw: " .. tostring(ask_err))
        end)
      end)

      t.assert(prompt_opts ~= nil, "the prompt should be called")
      t.equal(false, measure_called, "a different current buffer must not be measured")
      t.equal(nil, prompt_opts.anchor)
      t.equal({ bufnr = other_buf, first = 2, last = 3 }, prompt_opts.highlight)
    end)

    pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
    if vim.api.nvim_buf_is_valid(original_buf) then
      pcall(vim.api.nvim_set_current_buf, original_buf)
    end
    if not ok then
      error(err, 0)
    end
  end)
end
