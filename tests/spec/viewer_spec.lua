local init = require("opencode_ask")
local viewer = require("opencode_ask.viewer")

local WARN = vim.log.levels.WARN

local function with_options(viewer_overrides, fn)
  local original = init.options
  local copy = vim.deepcopy(original)
  copy.viewer = vim.tbl_extend("force", vim.deepcopy(original.viewer or {}), viewer_overrides or {})
  copy.api = vim.tbl_extend("force", vim.deepcopy(original.api or {}), { command = "opencode" })

  init.options = copy
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

local function new_env()
  return {
    next_id = 1000,
    jobs = {},
    spawns = {},
    on_exits = {},
    stopped = {},
    events = {},
  }
end

local function terminal_stubs(env, notifications)
  return {
    {
      vim.fn,
      "executable",
      function()
        if env.executable == nil then
          return 1
        end
        return env.executable
      end,
    },
    {
      vim.fn,
      "jobstart",
      function(argv, opts)
        local record = {
          argv = argv,
          opts = opts,
          bufnr = vim.api.nvim_get_current_buf(),
        }
        env.spawns[#env.spawns + 1] = record
        if env.events then
          env.events[#env.events + 1] = "spawn"
        end
        if env.jobstart_error then
          error(env.jobstart_error)
        end
        if env.jobstart_result ~= nil then
          return env.jobstart_result
        end

        local id = env.next_id
        env.next_id = id + 1
        record.id = id
        env.jobs[id] = true
        env.on_exits[id] = opts and opts.on_exit
        return id
      end,
    },
    {
      vim.fn,
      "jobwait",
      function(ids)
        return { env.jobs[ids[1]] and -1 or -3 }
      end,
    },
    {
      vim.fn,
      "jobstop",
      function(id)
        env.stopped[#env.stopped + 1] = id
        env.jobs[id] = nil
        return 1
      end,
    },
    { vim, "notify", notification_stub(notifications) },
  }
end

--- Run a viewer test with options and stubs, always cleaning up the viewer
--- state while the stubs are still active.
local function run_case(viewer_overrides, stubs, fn)
  with_options(viewer_overrides, function()
    with_stubs(stubs, function()
      local ok, err = pcall(fn)
      pcall(vim.cmd, "stopinsert")
      pcall(viewer.invalidate, nil)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function buffer_mapping_callback(buf, mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if mapping.lhs == lhs then
      return mapping.callback
    end
  end
  return nil
end

local function buffer_mapping(buf, mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if mapping.lhs == lhs then
      return mapping
    end
  end
  return nil
end

local function current_buf()
  return vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
end

local function title_text(config)
  if type(config.title) ~= "table" then
    return nil
  end

  local parts = {}
  for _, chunk in ipairs(config.title) do
    if type(chunk) == "table" then
      parts[#parts + 1] = chunk[1]
    else
      parts[#parts + 1] = chunk
    end
  end
  return table.concat(parts)
end

local function autocmd_callback(event, opts)
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds(opts)) do
    if autocmd.event == event and type(autocmd.callback) == "function" then
      return autocmd.callback
    end
  end
  return nil
end

return function(t)
  t.test("viewer layout sizes a float from fractions", function()
    local layout = viewer._layout({
      layout = "float",
      width = 0.8,
      height = 0.8,
      border = "rounded",
    }, { columns = 100, lines = 30, cmdheight = 1 })

    t.equal("float", layout.layout)
    t.equal(80, layout.width)
    t.equal(23, layout.height)
    t.equal(9, layout.col)
    t.equal(2, layout.row)
    t.equal("rounded", layout.border)
  end)

  t.test("viewer layout accepts integer float sizes", function()
    local layout = viewer._layout({
      layout = "float",
      width = 30,
      height = 10,
      border = "rounded",
    }, { columns = 100, lines = 30, cmdheight = 1 })

    t.equal(30, layout.width)
    t.equal(10, layout.height)
    t.equal(34, layout.col)
    t.equal(8, layout.row)
  end)

  t.test("viewer layout clamps width = 1 to the border and editor", function()
    local dimensions = { columns = 20, lines = 10, cmdheight = 1 }
    local rounded = viewer._layout({
      layout = "float",
      width = 1,
      height = 1,
      border = "rounded",
    }, dimensions)
    local none = viewer._layout({
      layout = "float",
      width = 1,
      height = 1,
      border = "none",
    }, dimensions)

    t.equal(18, rounded.width, "rounded borders should be subtracted")
    t.equal(20, none.width, "no border should use the full editor width")
    t.assert(rounded.width + 2 <= dimensions.columns, "the border must fit")
    t.equal("none", none.border)
  end)

  t.test("viewer layout reserves different cells for none and shadow borders", function()
    local dimensions = { columns = 20, lines = 8, cmdheight = 1 }
    local none = viewer._layout({
      layout = "float",
      width = 1,
      height = 1,
      border = "none",
    }, dimensions)
    local shadow = viewer._layout({
      layout = "float",
      width = 1,
      height = 1,
      border = "shadow",
    }, dimensions)
    local rounded = viewer._layout({
      layout = "float",
      width = 1,
      height = 1,
      border = "rounded",
    }, dimensions)

    t.equal(20, none.width)
    t.equal(19, shadow.width)
    t.equal(18, rounded.width)
    t.equal(7, none.height)
    t.equal(6, shadow.height)
    t.equal(5, rounded.height)
  end)

  t.test("viewer layout keeps a float inside a tiny editor", function()
    for _, columns in ipairs({ 1, 2, 3, 5 }) do
      for _, border in ipairs({ "none", "shadow", "rounded" }) do
        local layout = viewer._layout({
          layout = "float",
          width = 1,
          height = 1,
          border = border,
        }, { columns = columns, lines = 3, cmdheight = 1 })

        t.assert(layout.width >= 1, "width must be at least one")
        t.assert(layout.height >= 1, "height must be at least one")
        t.assert(layout.row >= 0, "row must not be negative")
        t.assert(layout.col >= 0, "col must not be negative")
      end
    end
  end)

  t.test("viewer layout resolves right split widths", function()
    local fraction = viewer._layout({
      layout = "right",
      width = 0.4,
    }, { columns = 100, lines = 30, cmdheight = 1 })
    local integer = viewer._layout({
      layout = "right",
      width = 25,
    }, { columns = 100, lines = 30, cmdheight = 1 })

    t.equal("right", fraction.layout)
    t.equal("right", fraction.split)
    t.equal(40, fraction.width)
    t.equal(25, integer.width)
  end)

  t.test("viewer layout resolves bottom split heights", function()
    local fraction = viewer._layout({
      layout = "bottom",
      height = 0.35,
    }, { columns = 100, lines = 30, cmdheight = 1 })
    local integer = viewer._layout({
      layout = "bottom",
      height = 12,
    }, { columns = 100, lines = 30, cmdheight = 1 })
    local oversized = viewer._layout({
      layout = "bottom",
      height = 1000,
    }, { columns = 100, lines = 30, cmdheight = 1 })

    t.equal("bottom", fraction.layout)
    t.equal("below", fraction.split)
    t.equal(10, fraction.height)
    t.equal(12, integer.height)
    t.equal(29, oversized.height, "the split must fit above the command line")
  end)

  t.test("viewer build_argv builds the mini command", function()
    local argv = viewer._build_argv({ id = "ses_alpha" })
    local custom = viewer._build_argv({ id = "ses_alpha" }, { command = "opencode-dev" })

    t.equal({ "opencode", "mini", "--session", "ses_alpha" }, argv)
    t.equal({ "opencode-dev", "mini", "--session", "ses_alpha" }, custom)
  end)

  t.test("viewer build_argv rejects missing and blank session ids", function()
    local cases = {
      nil,
      {},
      { id = "" },
      { id = "   " },
      { id = 42 },
    }

    for _, session in ipairs(cases) do
      local ok, err = pcall(viewer._build_argv, session, nil)
      t.equal(false, ok, "an invalid session should raise")
      t.matches("opencode%-ask: ", tostring(err))
    end
  end)

  t.test("viewer open creates a hidden buffer and spawns mini", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float", border = "rounded", width = 0.5, height = 0.5, winblend = 10 }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local session = { id = "ses_alpha", title = "Alpha session" }

      viewer.open_for_session(root, session)

      t.equal(true, viewer.is_open(root))
      t.equal(1, #env.spawns)
      t.equal({ "opencode", "mini", "--session", "ses_alpha" }, env.spawns[1].argv)
      t.equal(true, env.spawns[1].opts.term)
      t.equal(root, env.spawns[1].opts.cwd)

      local root_win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_win_get_buf(root_win)
      t.equal(bufnr, env.spawns[1].bufnr, "the terminal should start in the viewer buffer")
      t.equal("hide", vim.bo[bufnr].bufhidden)
      t.equal(false, vim.bo[bufnr].buflisted)
      t.equal(false, vim.bo[bufnr].swapfile)

      local config = vim.api.nvim_win_get_config(root_win)
      t.equal("editor", config.relative)
      t.equal("OpenCode: Alpha session", title_text(config))
      t.equal("center", config.title_pos)
      t.equal(
        "NormalFloat:OpencodeAskNormal,FloatBorder:OpencodeAskBorder,FloatTitle:OpencodeAskTitle",
        vim.wo[root_win].winhighlight
      )
      t.equal(10, vim.wo[root_win].winblend)
      t.equal(0, #notifications)
    end)
  end)

  t.test("viewer open spawns in the session directory when present", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      viewer.open_for_session("/tmp/viewer-project", {
        id = "ses_alpha",
        directory = "/tmp/session-directory",
      })

      t.equal(1, #env.spawns)
      t.equal("/tmp/session-directory", env.spawns[1].opts.cwd)
    end)
  end)

  t.test("viewer applies start_insert after the terminal spawn", function()
    local function run(start_insert)
      local env = new_env()
      local notifications = {}
      local original_cmd = vim.cmd
      local stubs = terminal_stubs(env, notifications)
      stubs[#stubs + 1] = {
        vim,
        "cmd",
        function(command)
          if command == "startinsert" or command == "stopinsert" then
            env.events[#env.events + 1] = command
            return
          end
          return original_cmd(command)
        end,
      }

      run_case({ layout = "float", start_insert = start_insert }, stubs, function()
        viewer.open_for_session("/tmp/viewer-project", { id = "ses_alpha" })

        t.equal("spawn", env.events[1], "the terminal should spawn first")
        t.equal(start_insert and "startinsert" or "stopinsert", env.events[2])
      end)
    end

    run(true)
    run(false)
  end)

  t.test("viewer hide closes the window and reattach reuses the buffer", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local session = { id = "ses_alpha" }
      local prev_win = vim.api.nvim_get_current_win()

      viewer.open_for_session(root, session)
      local viewer_win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_win_get_buf(viewer_win)
      local job_id = env.spawns[1].id

      viewer.hide(root)

      t.equal(false, viewer.is_open(root))
      t.equal(false, vim.api.nvim_win_is_valid(viewer_win), "the window should close")
      t.equal(true, vim.api.nvim_buf_is_valid(bufnr), "the buffer should stay alive")
      t.equal(true, env.jobs[job_id] == true, "the job should stay alive")
      t.equal(prev_win, vim.api.nvim_get_current_win(), "focus should return")

      viewer.open_for_session(root, session)

      t.equal(true, viewer.is_open(root))
      t.equal(1, #env.spawns, "re-attaching must not spawn another process")
      t.equal(bufnr, current_buf(), "re-attaching should reuse the hidden buffer")
    end)
  end)

  t.test("viewer opens at the newest output", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local session = { id = "ses_alpha" }

      viewer.open_for_session(root, session)
      local bufnr = current_buf()

      local lines = {}
      for index = 1, 80 do
        lines[index] = "line " .. index
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      viewer.hide(root)
      viewer.open_for_session(root, session)
      local win = vim.api.nvim_get_current_win()

      local view = vim.api.nvim_win_call(win, function()
        return {
          top = vim.fn.line("w0"),
          bottom = vim.fn.line("w$"),
          cursor = vim.fn.line("."),
        }
      end)

      t.equal(80, view.bottom, "the window should end at the newest line")
      t.assert(view.top > 1, "the window should not start at the oldest line")
      t.equal(80, view.cursor, "the cursor should be on the newest line")
    end)
  end)

  t.test("viewer focuses an already-open viewer without spawning", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local session = { id = "ses_alpha" }
      local base_win = vim.api.nvim_get_current_win()

      viewer.open_for_session(root, session)
      local viewer_win = vim.api.nvim_get_current_win()
      local bufnr = current_buf()

      vim.api.nvim_set_current_win(base_win)
      viewer.open_for_session(root, session)

      t.equal(1, #env.spawns, "refocusing must not spawn another process")
      t.equal(viewer_win, vim.api.nvim_get_current_win())
      t.equal(bufnr, current_buf())
      t.equal(true, viewer.is_open(root))
    end)
  end)

  t.test("viewer re-attaches in the current tabpage when its window is elsewhere", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local session = { id = "ses_alpha" }

      viewer.open_for_session(root, session)
      local first_win = vim.api.nvim_get_current_win()
      local bufnr = current_buf()

      vim.cmd("tabnew")
      local other_tab = vim.api.nvim_get_current_tabpage()

      viewer.open_for_session(root, session)

      t.equal(1, #env.spawns, "re-attaching across tabpages must not spawn")
      t.equal(false, vim.api.nvim_win_is_valid(first_win), "the old tab's window should close")
      t.equal(other_tab, vim.api.nvim_get_current_tabpage())
      t.equal(true, viewer.is_open(root))
      t.equal(bufnr, current_buf(), "the hidden buffer should be reused")

      viewer.invalidate(root)
      pcall(vim.cmd, "tabclose")
    end)
  end)

  t.test("viewer hide_current ignores the working directory", function()
    local env = new_env()
    local notifications = {}
    local stubs = terminal_stubs(env, notifications)
    stubs[#stubs + 1] = {
      vim.fn,
      "getcwd",
      function()
        return "/tmp/elsewhere"
      end,
    }

    run_case({ layout = "float" }, stubs, function()
      viewer.open_for_session("/tmp/viewer-project", { id = "ses_alpha" })
      t.equal(true, viewer.is_open("/tmp/viewer-project"))

      t.equal(true, viewer.hide_current())
      t.equal(false, viewer.is_open("/tmp/viewer-project"))
      t.equal(false, viewer.hide_current(), "a second hide is a no-op")
    end)
  end)

  t.test("viewer hides another project's window without killing its job", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root_a = "/tmp/viewer-project-a"
      local root_b = "/tmp/viewer-project-b"
      local session_a = { id = "ses_alpha" }

      viewer.open_for_session(root_a, session_a)
      local bufnr_a = current_buf()
      local job_a = env.spawns[1].id

      viewer.open_for_session(root_b, { id = "ses_beta" })

      t.equal(2, #env.spawns)
      t.equal(false, viewer.is_open(root_a))
      t.equal(true, viewer.is_open(root_b))
      t.equal(true, vim.api.nvim_buf_is_valid(bufnr_a))
      t.equal(true, env.jobs[job_a] == true, "project A's job must stay alive")

      viewer.open_for_session(root_a, session_a)

      t.equal(2, #env.spawns, "project A should re-attach without a new process")
      t.equal(false, viewer.is_open(root_b), "project B's window should hide")
      t.equal(true, viewer.is_open(root_a))
      t.equal(bufnr_a, current_buf())
    end)
  end)

  t.test("viewer invalidates the old buffer when the session changes", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"

      viewer.open_for_session(root, { id = "ses_alpha" })
      local first_buf = current_buf()
      local first_job = env.spawns[1].id

      viewer.open_for_session(root, { id = "ses_beta" })

      t.equal(2, #env.spawns)
      t.equal(false, vim.api.nvim_buf_is_valid(first_buf), "the old buffer should be wiped")
      t.equal(false, env.jobs[first_job] == true, "the old job should be stopped")
      t.equal(true, contains(env.stopped, first_job))
      t.assert(current_buf() ~= first_buf, "a fresh buffer should be used")
      t.equal(true, viewer.is_open(root))
    end)
  end)

  t.test("viewer reopens with a fresh process after on_exit", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local session = { id = "ses_alpha" }

      viewer.open_for_session(root, session)
      local first_buf = current_buf()
      local first_job = env.spawns[1].id
      local viewer_win = vim.api.nvim_get_current_win()

      -- Simulate the process exiting: the window and buffer stay readable.
      env.jobs[first_job] = nil
      env.on_exits[first_job](first_job, 1, "exit")

      t.equal(true, vim.api.nvim_win_is_valid(viewer_win))
      t.equal(true, vim.api.nvim_buf_is_valid(first_buf))
      t.equal(true, viewer.is_open(root))

      viewer.open_for_session(root, session)

      t.equal(2, #env.spawns, "a dead process must not be re-attached")
      t.equal(false, vim.api.nvim_buf_is_valid(first_buf), "the stale buffer should be wiped")
      t.assert(current_buf() ~= first_buf)
      t.equal(true, viewer.is_open(root))
    end)
  end)

  t.test("viewer ignores stale on_exit callbacks from an older entry", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"

      viewer.open_for_session(root, { id = "ses_alpha" })
      local first_job = env.spawns[1].id
      local first_exit = env.on_exits[first_job]

      viewer.open_for_session(root, { id = "ses_beta" })
      local second_buf = current_buf()
      local second_job = env.spawns[2].id

      first_exit(first_job, 0, "exit")

      t.equal(true, viewer.is_open(root))
      t.equal(second_buf, current_buf(), "the newer viewer must stay focused")
      t.equal(true, env.jobs[second_job] == true, "the newer job must stay alive")

      viewer.open_for_session(root, { id = "ses_beta" })
      t.equal(2, #env.spawns, "the newer entry must not be invalidated")
      t.equal(second_buf, current_buf())
    end)
  end)

  t.test("viewer ignores stale WinClosed and BufWipeout callbacks", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"

      viewer.open_for_session(root, { id = "ses_alpha" })
      local first_buf = current_buf()
      local first_win = vim.api.nvim_get_current_win()
      local stale_win_closed = autocmd_callback("WinClosed", {
        event = "WinClosed",
        pattern = tostring(first_win),
      })
      local stale_buf_wipe = autocmd_callback("BufWipeout", {
        event = "BufWipeout",
        buffer = first_buf,
      })
      t.assert(type(stale_win_closed) == "function", "WinClosed callback should be retrievable")
      t.assert(type(stale_buf_wipe) == "function", "BufWipeout callback should be retrievable")

      viewer.open_for_session(root, { id = "ses_beta" })
      local second_buf = current_buf()
      local second_job = env.spawns[2].id

      stale_win_closed()
      stale_buf_wipe()

      t.equal(true, viewer.is_open(root), "stale callbacks must not clear the newer entry")
      t.equal(second_buf, current_buf())
      t.equal(true, vim.api.nvim_buf_is_valid(second_buf))
      t.equal(true, env.jobs[second_job] == true)
    end)
  end)

  t.test("viewer registers q in normal mode and no duplicate keymaps", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float", keymap = "<leader>ot" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"

      viewer.open_for_session(root, { id = "ses_alpha" })
      local bufnr = current_buf()
      local job_id = env.spawns[1].id

      local hide = buffer_mapping_callback(bufnr, "n", "q")
      t.assert(type(hide) == "function", "q should hide the viewer")
      t.equal(nil, buffer_mapping(bufnr, "t", "<leader>ot"), "no terminal-mode toggle mapping")
      t.equal(nil, buffer_mapping(bufnr, "n", "<leader>ot"), "no duplicate normal-mode toggle mapping")
      t.equal("Hide the OpenCode viewer", buffer_mapping(bufnr, "n", "q").desc)

      hide()

      t.equal(false, viewer.is_open(root))
      t.equal(true, vim.api.nvim_buf_is_valid(bufnr))
      t.equal(true, env.jobs[job_id] == true)
    end)
  end)

  t.test("viewer omits the float title without a border", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float", border = "none" }, terminal_stubs(env, notifications), function()
      viewer.open_for_session("/tmp/viewer-project", { id = "ses_alpha", title = "Alpha" })

      local config = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
      t.equal("none", config.border)
      t.equal(nil, config.title)
      t.equal(nil, config.title_pos)
    end)
  end)

  t.test("viewer warns and creates nothing when the command is missing", function()
    local env = new_env()
    env.executable = 0
    local notifications = {}
    local windows_before = #vim.api.nvim_list_wins()
    local buffers_before = #vim.api.nvim_list_bufs()

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      viewer.open_for_session("/tmp/viewer-project", { id = "ses_alpha" })

      t.equal(false, viewer.is_open("/tmp/viewer-project"))
      t.equal(0, #env.spawns)
      t.equal(windows_before, #vim.api.nvim_list_wins())
      t.equal(buffers_before, #vim.api.nvim_list_bufs())
      t.equal(1, #notifications)
      t.equal(WARN, notifications[1].level)
      t.matches("not executable", notifications[1].message)
    end)
  end)

  t.test("viewer cleans up when spawning returns a bad job id", function()
    local env = new_env()
    env.jobstart_result = 0
    local notifications = {}
    local windows_before = #vim.api.nvim_list_wins()
    local buffers_before = #vim.api.nvim_list_bufs()

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      viewer.open_for_session("/tmp/viewer-project", { id = "ses_alpha" })

      t.equal(false, viewer.is_open("/tmp/viewer-project"))
      t.equal(1, #env.spawns, "the spawn should have been attempted")
      t.equal(windows_before, #vim.api.nvim_list_wins(), "no window should leak")
      t.equal(buffers_before, #vim.api.nvim_list_bufs(), "no buffer should leak")
      t.equal(1, #notifications)
      t.equal(WARN, notifications[1].level)
      t.matches("could not start the OpenCode viewer", notifications[1].message)
    end)
  end)

  t.test("viewer cleans up when spawning throws", function()
    local env = new_env()
    env.jobstart_error = "spawn exploded"
    local notifications = {}
    local windows_before = #vim.api.nvim_list_wins()
    local buffers_before = #vim.api.nvim_list_bufs()

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local ok, err = pcall(viewer.open_for_session, "/tmp/viewer-project", { id = "ses_alpha" })
      t.equal(true, ok, "open_for_session should handle spawn errors: " .. tostring(err))

      t.equal(false, viewer.is_open("/tmp/viewer-project"))
      t.equal(windows_before, #vim.api.nvim_list_wins(), "no window should leak")
      t.equal(buffers_before, #vim.api.nvim_list_bufs(), "no buffer should leak")
      t.equal(1, #notifications)
      t.equal(WARN, notifications[1].level)
      t.matches("spawn exploded", notifications[1].message)
    end)
  end)

  t.test("viewer falls back to termopen before Neovim 0.11", function()
    local env = new_env()
    local notifications = {}
    local termopen_calls = {}

    local stubs = {
      { vim.fn, "executable", function() return 1 end },
      {
        vim.fn,
        "has",
        function(feature)
          if feature == "nvim-0.11" then
            return 0
          end
          return 1
        end,
      },
      {
        vim.fn,
        "termopen",
        function(argv, opts)
          termopen_calls[#termopen_calls + 1] = { argv = argv, opts = opts }
          local id = env.next_id
          env.next_id = id + 1
          env.jobs[id] = true
          env.on_exits[id] = opts and opts.on_exit
          return id
        end,
      },
      {
        vim.fn,
        "jobstart",
        function()
          env.jobstart_called = true
          return 0
        end,
      },
      { vim.fn, "jobwait", function(ids) return { env.jobs[ids[1]] and -1 or -3 } end },
      { vim.fn, "jobstop", function(id) env.jobs[id] = nil; return 1 end },
      { vim, "notify", notification_stub(notifications) },
    }

    run_case({ layout = "float" }, stubs, function()
      viewer.open_for_session("/tmp/viewer-project", { id = "ses_alpha" })

      t.equal(nil, env.jobstart_called, "jobstart should not be used before 0.11")
      t.equal(1, #termopen_calls)
      t.equal({ "opencode", "mini", "--session", "ses_alpha" }, termopen_calls[1].argv)
      t.equal("/tmp/viewer-project", termopen_calls[1].opts.cwd)
      t.equal(nil, termopen_calls[1].opts.term)
      t.equal(true, viewer.is_open("/tmp/viewer-project"))
    end)
  end)

  t.test("viewer invalidate closes, stops, and wipes the viewer", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"

      viewer.open_for_session(root, { id = "ses_alpha" })
      local bufnr = current_buf()
      local job_id = env.spawns[1].id
      local win = vim.api.nvim_get_current_win()

      viewer.invalidate(root, "ses_alpha")

      t.equal(true, viewer.is_open(root), "keeping the same session should be a no-op")
      t.equal(true, vim.api.nvim_win_is_valid(win))
      t.equal(true, vim.api.nvim_buf_is_valid(bufnr))
      t.equal(true, env.jobs[job_id] == true)
      t.equal(0, #env.stopped)

      viewer.invalidate(root)

      t.equal(false, viewer.is_open(root))
      t.equal(false, vim.api.nvim_win_is_valid(win))
      t.equal(false, vim.api.nvim_buf_is_valid(bufnr))
      t.equal(false, env.jobs[job_id] == true)
      t.equal(true, contains(env.stopped, job_id))
    end)
  end)

  t.test("viewer invalidate(nil) clears every project", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "float" }, terminal_stubs(env, notifications), function()
      viewer.open_for_session("/tmp/viewer-project-a", { id = "ses_alpha" })
      local buf_a = current_buf()
      local job_a = env.spawns[1].id

      viewer.open_for_session("/tmp/viewer-project-b", { id = "ses_beta" })
      local buf_b = current_buf()
      local job_b = env.spawns[2].id

      viewer.invalidate(nil)

      t.equal(false, viewer.is_open("/tmp/viewer-project-a"))
      t.equal(false, viewer.is_open("/tmp/viewer-project-b"))
      t.equal(false, vim.api.nvim_buf_is_valid(buf_a))
      t.equal(false, vim.api.nvim_buf_is_valid(buf_b))
      t.equal(false, env.jobs[job_a] == true)
      t.equal(false, env.jobs[job_b] == true)
    end)
  end)

  t.test("viewer opens right splits with the resolved width", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "right", width = 0.4 }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local prev_win = vim.api.nvim_get_current_win()

      viewer.open_for_session(root, { id = "ses_alpha" })
      local win = vim.api.nvim_get_current_win()
      local config = vim.api.nvim_win_get_config(win)

      t.assert(win ~= prev_win, "a split window should open")
      t.equal("", config.relative)
      t.equal(math.floor(vim.o.columns * 0.4), vim.api.nvim_win_get_width(win))
      t.equal(true, viewer.is_open(root))
      t.equal(1, #env.spawns)

      viewer.hide(root)
      t.equal(false, viewer.is_open(root))
      t.equal(prev_win, vim.api.nvim_get_current_win(), "hiding a split should restore focus")
    end)
  end)

  t.test("viewer opens bottom splits with the resolved height", function()
    local env = new_env()
    local notifications = {}

    run_case({ layout = "bottom", height = 0.35 }, terminal_stubs(env, notifications), function()
      local root = "/tmp/viewer-project"
      local prev_win = vim.api.nvim_get_current_win()

      viewer.open_for_session(root, { id = "ses_alpha" })
      local win = vim.api.nvim_get_current_win()
      local config = vim.api.nvim_win_get_config(win)

      t.assert(win ~= prev_win, "a split window should open")
      t.equal("", config.relative)
      t.equal(math.floor(math.max(1, vim.o.lines - vim.o.cmdheight) * 0.35), vim.api.nvim_win_get_height(win))
      t.equal(true, viewer.is_open(root))

      viewer.hide(root)
      t.equal(false, viewer.is_open(root))
    end)
  end)
end
