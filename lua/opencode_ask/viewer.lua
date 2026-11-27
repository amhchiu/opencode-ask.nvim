local ui = require("opencode_ask.ui")

local M = {}

local DEFAULT_BORDER = "rounded"
local DEFAULT_COMMAND = "opencode"

local function error_message(message)
  return "opencode-ask: " .. message
end

local function describe(err)
  if type(err) == "table" then
    local message = err.message
    if type(message) == "string" and message ~= "" then
      return message
    end
    return vim.inspect(err)
  end
  if type(err) == "string" and err ~= "" then
    return err
  end
  return tostring(err)
end

local function notify(message, level)
  message = describe(message)
  local prefix = "opencode-ask: "
  if message:sub(1, #prefix) ~= prefix then
    message = prefix .. message
  end
  vim.notify(message, level)
end

local function options()
  -- Read lazily so requiring this module cannot create a circular dependency
  -- with opencode_ask/init.lua, and so tests can override the options.
  return require("opencode_ask").options
end

local function session_label(session)
  if type(session) ~= "table" then
    return "session"
  end

  local title = type(session.title) == "string" and vim.trim(session.title) or ""
  if title ~= "" then
    return title
  end

  return type(session.id) == "string" and session.id ~= "" and session.id or "session"
end

--- Truncate a title without splitting a multibyte character.
local function truncate_title(title, max_chars)
  if max_chars <= 0 then
    return ""
  end
  if vim.fn.strchars(title) <= max_chars then
    return title
  end
  return vim.fn.strcharpart(title, 0, max_chars)
end

--- Return the number of extra rows and columns a border occupies.
local function border_size(border)
  if border == "none" then
    return 0, 0
  end
  if border == "shadow" then
    return 1, 1
  end
  return 2, 2
end

--- Center `value` inside `span` cells.
local function center(value, span)
  return math.floor((span - value) / 2)
end

--- Resolve a fraction in (0, 1] or an integer span against `total` cells.
local function resolve_span(value, total, min_size)
  total = math.max(0, math.floor(total))
  min_size = math.max(0, math.floor(min_size))

  local span
  if type(value) == "number" and value == value then
    if value > 0 and value <= 1 then
      span = math.floor(total * value)
    else
      span = math.floor(value)
    end
  else
    span = total
  end

  return math.max(math.min(min_size, total), math.min(span, total))
end

--- Compute the viewer geometry.
---
--- This is an internal helper exported for tests. `dimensions` may override the
--- current editor size so the clamping rules can be tested without resizing
--- the editor.
function M._layout(viewer_opts, dimensions)
  viewer_opts = viewer_opts or {}
  local columns = math.max(1, math.floor((dimensions and dimensions.columns) or vim.o.columns))
  local lines = math.max(1, math.floor((dimensions and dimensions.lines) or vim.o.lines))
  local cmdheight = math.max(
    0,
    math.floor((dimensions and dimensions.cmdheight) or vim.o.cmdheight)
  )
  local avail_lines = math.max(1, lines - cmdheight)

  local layout = viewer_opts.layout or "float"

  if layout == "right" then
    return {
      layout = "right",
      split = "right",
      width = resolve_span(viewer_opts.width, columns, 1),
    }
  end

  if layout == "bottom" then
    return {
      layout = "bottom",
      split = "below",
      height = resolve_span(viewer_opts.height, avail_lines, 1),
    }
  end

  local border = viewer_opts.border or DEFAULT_BORDER
  local border_rows, border_cols = border_size(border)

  local width = resolve_span(viewer_opts.width, columns, 1)
  width = math.max(1, math.min(width, columns - border_cols))

  local height = resolve_span(viewer_opts.height, avail_lines, 1)
  height = math.max(1, math.min(height, avail_lines - border_rows))

  local total_width = width + border_cols
  local total_height = height + border_rows

  local row = center(total_height, avail_lines)
  row = math.max(0, math.min(row, math.max(0, avail_lines - total_height)))

  local col = center(total_width, columns)
  col = math.max(0, math.min(col, math.max(0, columns - total_width)))

  return {
    layout = "float",
    width = width,
    height = height,
    row = row,
    col = col,
    border = border,
  }
end

--- Build the command line used to attach the viewer to a session.
function M._build_argv(session, api_opts)
  if type(session) ~= "table" then
    error(error_message("missing session; expected a table with an id"), 2)
  end
  if type(session.id) ~= "string" or vim.trim(session.id) == "" then
    error(error_message("session id must be a non-empty string"), 2)
  end

  local command = (api_opts and api_opts.command) or DEFAULT_COMMAND
  if type(command) ~= "string" or vim.trim(command) == "" then
    command = DEFAULT_COMMAND
  end

  return { command, "mini", "--session", session.id }
end

--- Normalize a project root so equivalent paths share one state entry.
local function normalize_root(root)
  if type(root) ~= "string" then
    return root
  end
  return vim.fs.normalize(root)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- Whether a job id still refers to a running process.
local function is_job_alive(job_id)
  return type(job_id) == "number" and job_id > 0 and vim.fn.jobwait({ job_id }, 0)[1] == -1
end

--- One entry per project root: { root, bufnr, win, session_id, job_id, prev_win }.
local state_by_root = {}

local function get_entry(root)
  return state_by_root[normalize_root(root)]
end

--- Open a window for an existing (or freshly created) viewer buffer.
local function open_window(entry, viewer_opts, session, layout)
  local prev_win = vim.api.nvim_get_current_win()
  entry.prev_win = prev_win

  local win
  if layout.layout == "float" then
    ui.ensure_highlights()

    local win_config = {
      relative = "editor",
      style = "minimal",
      border = layout.border,
      width = layout.width,
      height = layout.height,
      row = layout.row,
      col = layout.col,
    }
    if layout.border ~= "none" then
      local title = "OpenCode: " .. session_label(session)
      win_config.title = truncate_title(title, layout.width - 4)
      win_config.title_pos = "center"
    end

    win = vim.api.nvim_open_win(entry.bufnr, true, win_config)
    vim.wo[win].winhighlight =
      "NormalFloat:OpencodeAskNormal,FloatBorder:OpencodeAskBorder,FloatTitle:OpencodeAskTitle"
    if type(viewer_opts.winblend) == "number" then
      vim.wo[win].winblend = viewer_opts.winblend
    end
  else
    win = vim.api.nvim_open_win(entry.bufnr, true, {
      split = layout.split,
      win = -1,
      width = layout.width,
      height = layout.height,
    })
  end

  entry.win = win
  return win
end

--- Move to the newest output so the window follows the answer as it streams.
---
--- Neovim does not follow terminal output in Terminal-Normal mode, so a viewer
--- opened at line 1 would stay at the oldest scrollback. Jumping to the last
--- line also makes the window follow later output.
local function scroll_to_bottom(win)
  if not valid_win(win) then
    return
  end

  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! G")
  end)
end

--- Enter the configured mode after the terminal buffer is active.
local function apply_mode(viewer_opts, win)
  scroll_to_bottom(win)

  if viewer_opts.start_insert then
    vim.cmd("startinsert")
  else
    pcall(vim.cmd, "stopinsert")
  end
end

--- Start the terminal job inside the viewer buffer.
local function start_terminal(bufnr, argv, cwd, on_exit)
  local ok, job_id = pcall(function()
    return vim.api.nvim_buf_call(bufnr, function()
      local term_opts = { cwd = cwd, on_exit = on_exit }
      if vim.fn.has("nvim-0.11") == 1 then
        term_opts.term = true
        return vim.fn.jobstart(argv, term_opts)
      end
      return vim.fn.termopen(argv, term_opts)
    end)
  end)

  if not ok then
    return nil, job_id
  end
  if type(job_id) ~= "number" or job_id <= 0 then
    return nil, "terminal job did not start"
  end

  return job_id
end

--- Register the buffer-local hide mapping and guarded cleanup autocmds.
local function configure_buffer(root, entry, bufnr)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false

  vim.keymap.set("n", "q", function()
    M.hide(root)
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "Hide the OpenCode viewer",
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      if state_by_root[root] ~= entry or entry.bufnr ~= bufnr then
        return
      end

      if is_job_alive(entry.job_id) then
        pcall(vim.fn.jobstop, entry.job_id)
      end
      entry.job_id = nil
      entry.bufnr = nil
      state_by_root[root] = nil
    end,
  })
end

--- Clear the entry's window when it is closed from outside the module.
local function register_window_autocmd(root, entry, win)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if state_by_root[root] == entry and entry.win == win then
        entry.win = nil
      end
    end,
  })
end

--- Return the spawn directory for a session, matching client.lua.
local function session_cwd(session, root)
  local cwd = type(session) == "table" and session.directory or nil
  if type(cwd) == "string" and cwd ~= "" then
    return cwd
  end
  return root
end

--- Remove a viewer entry without triggering the BufWipeout callback again.
local function discard_entry(root, entry)
  local win = entry.win
  entry.win = nil
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  local job_id = entry.job_id
  entry.job_id = nil
  if is_job_alive(job_id) then
    pcall(vim.fn.jobstop, job_id)
  end

  local bufnr = entry.bufnr
  entry.bufnr = nil
  if valid_buf(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  if state_by_root[root] == entry then
    state_by_root[root] = nil
  end
end

--- Whether the project's viewer window is currently open.
function M.is_open(root)
  local entry = get_entry(root)
  return entry ~= nil and valid_win(entry.win)
end

--- Hide the viewer window that currently has focus, if any.
function M.hide_current()
  local current = vim.api.nvim_get_current_win()
  for _, entry in pairs(state_by_root) do
    if entry.win == current and valid_win(current) then
      M.hide(entry.root)
      return true
    end
  end
  return false
end

--- Open the viewer for a session, reusing a live hidden buffer when possible.
function M.open_for_session(root, session)
  local key = normalize_root(root)
  local opts = options() or {}
  local viewer_opts = opts.viewer or {}
  local api_opts = opts.api or {}

  local command = api_opts.command or DEFAULT_COMMAND
  if type(command) ~= "string" or command == "" or vim.fn.executable(command) ~= 1 then
    notify(
      ("'%s' is not executable; install OpenCode or configure api.command"):format(
        tostring(command)
      ),
      vim.log.levels.WARN
    )
    return
  end

  local argv = M._build_argv(session, api_opts)

  -- Never stack viewers: switching projects hides the other project's window
  -- while keeping its buffer and process alive.
  for other_root, other in pairs(state_by_root) do
    if other_root ~= key and valid_win(other.win) then
      pcall(vim.api.nvim_win_close, other.win, true)
      if other.win and not vim.api.nvim_win_is_valid(other.win) then
        other.win = nil
      end
    end
  end

  local entry = state_by_root[key]

  -- Focus an already-open viewer for the same session.
  if
    entry
    and valid_win(entry.win)
    and entry.session_id == session.id
    and is_job_alive(entry.job_id)
  then
    if
      vim.api.nvim_win_get_tabpage(entry.win) == vim.api.nvim_get_current_tabpage()
    then
      vim.api.nvim_set_current_win(entry.win)
      apply_mode(viewer_opts, entry.win)
      return
    end

    local stale_win = entry.win
    pcall(vim.api.nvim_win_close, stale_win, true)
    if entry.win == stale_win then
      entry.win = nil
    end
  end

  -- Re-attach the hidden buffer when its process is still running.
  if
    entry
    and valid_buf(entry.bufnr)
    and entry.session_id == session.id
    and is_job_alive(entry.job_id)
  then
    open_window(entry, viewer_opts, session, M._layout(viewer_opts, nil))
    apply_mode(viewer_opts, entry.win)
    return
  end

  M.invalidate(key)

  entry = {
    root = key,
    bufnr = nil,
    win = nil,
    session_id = session.id,
    job_id = nil,
    prev_win = nil,
  }
  state_by_root[key] = entry

  local bufnr = vim.api.nvim_create_buf(false, true)
  entry.bufnr = bufnr
  configure_buffer(key, entry, bufnr)

  local win = open_window(entry, viewer_opts, session, M._layout(viewer_opts, nil))
  register_window_autocmd(key, entry, win)

  local job_id, spawn_err = start_terminal(bufnr, argv, session_cwd(session, key), function(exit_job_id)
    if state_by_root[key] ~= entry or entry.job_id ~= exit_job_id then
      return
    end
    -- Keep the window and buffer so CLI startup errors stay readable.
    entry.job_id = nil
  end)

  if not job_id then
    discard_entry(key, entry)
    notify(
      ("could not start the OpenCode viewer: %s"):format(describe(spawn_err)),
      vim.log.levels.WARN
    )
    return
  end

  entry.job_id = job_id
  apply_mode(viewer_opts, entry.win)
end

--- Hide a project's viewer window while keeping its buffer and job alive.
function M.hide(root)
  local entry = get_entry(root)
  if not entry then
    return
  end

  local win = entry.win
  entry.win = nil
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end

  local prev_win = entry.prev_win
  if valid_win(prev_win) and prev_win ~= win then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
end

--- Stop and wipe a project's viewer, or every viewer when root is nil.
---
--- When keep_session_id matches the cached session, the viewer is left alone so
--- re-selecting the same session keeps the running process.
function M.invalidate(root, keep_session_id)
  if root == nil then
    local roots = {}
    for key in pairs(state_by_root) do
      roots[#roots + 1] = key
    end
    for _, key in ipairs(roots) do
      M.invalidate(key, keep_session_id)
    end
    return
  end

  local key = normalize_root(root)
  local entry = state_by_root[key]
  if not entry then
    return
  end

  if keep_session_id ~= nil and entry.session_id == keep_session_id then
    return
  end

  discard_entry(key, entry)
end

return M
