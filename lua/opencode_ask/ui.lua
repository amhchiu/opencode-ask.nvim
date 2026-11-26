local M = {}

local DEFAULT_TITLE = "Ask OpenCode"
local DEFAULT_WIDTH = 80
local DEFAULT_HEIGHT = 4
local MIN_WIDTH = 20
local BORDER_COLUMNS = 2

local HIGHLIGHT_LINKS = {
  { "OpencodeAskNormal", "NormalFloat" },
  { "OpencodeAskBorder", "FloatBorder" },
  { "OpencodeAskTitle", "FloatTitle" },
  { "OpencodeAskSelection", "Visual" },
}

--- Define the plugin's highlight groups without overriding user overrides.
---
--- `default = true` keeps explicitly defined groups intact while restoring the
--- default links after a colorscheme runs `:highlight clear`.
function M.ensure_highlights()
  for _, group in ipairs(HIGHLIGHT_LINKS) do
    vim.api.nvim_set_hl(0, group[1], { link = group[2], default = true })
  end
end

M.ensure_highlights()

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

--- Trim leading and trailing whitespace from the whole question while
--- preserving newlines inside the text. Exported for tests.
function M._trim_question(text)
  if type(text) ~= "string" then
    return ""
  end

  local trimmed = text:gsub("^%s+", "")
  trimmed = trimmed:gsub("%s+$", "")
  return trimmed
end

--- Compute the centered float geometry.
---
--- This is an internal helper exported for tests. `dimensions` may override
--- the current editor size so the clamping rules can be tested without
--- resizing the editor.
function M._layout(opts, dimensions)
  opts = opts or {}
  local columns = math.max(1, math.floor((dimensions and dimensions.columns) or vim.o.columns))
  local lines = math.max(1, math.floor((dimensions and dimensions.lines) or vim.o.lines))

  local width
  if columns < MIN_WIDTH then
    width = math.max(1, columns - BORDER_COLUMNS)
  else
    width = math.max(MIN_WIDTH, math.min(opts.width or DEFAULT_WIDTH, columns - 10))
  end
  -- Keep the content plus the rounded border inside the editor.
  width = math.max(1, math.min(width, columns - BORDER_COLUMNS))

  local max_height = math.max(1, lines - 4)
  local height = math.max(1, math.min(opts.height or DEFAULT_HEIGHT, max_height))

  local title = opts.title or DEFAULT_TITLE
  if type(title) ~= "string" then
    title = tostring(title)
  end
  title = truncate_title(title, width - 4)

  local row = math.max(0, math.floor((lines - height) / 2))
  local col = math.max(0, math.floor((columns - width) / 2))

  return {
    width = width,
    height = height,
    row = row,
    col = col,
    title = title,
  }
end

--- Open a floating question prompt.
---
--- opts supports title, default, width, and height. on_submit is called with
--- the trimmed question after the float has closed. An empty question leaves
--- the prompt open and emits a warning notification.
function M.prompt(opts, on_submit)
  M.ensure_highlights()
  opts = opts or {}
  if on_submit ~= nil and type(on_submit) ~= "function" then
    error("opencode-ask: on_submit must be a function", 2)
  end

  local layout = M._layout(opts)

  local initial_lines = { "" }
  if type(opts.default) == "string" and opts.default ~= "" then
    initial_lines = vim.split(opts.default, "\n", { plain = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local win
  local closed = false
  local submit
  local cancel

  local function close()
    if closed then
      return
    end
    closed = true

    pcall(vim.cmd, "stopinsert")

    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end

    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  local function setup()
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "markdown"
    vim.b[bufnr].completion = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines)

    win = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = layout.title,
      title_pos = "center",
      width = layout.width,
      height = layout.height,
      row = layout.row,
      col = layout.col,
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(win, { line_count, 0 })
    vim.cmd("startinsert!")

    submit = function()
      if closed then
        return
      end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = M._trim_question(table.concat(lines, "\n"))
      if text == "" then
        vim.notify("opencode-ask: question cannot be empty", vim.log.levels.WARN)
        return
      end

      close()
      if on_submit then
        on_submit(text)
      end
    end

    cancel = function()
      close()
    end

    vim.keymap.set({ "i", "n" }, "<CR>", submit, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Submit question",
    })

    vim.keymap.set("i", "<C-j>", function()
      if closed then
        return
      end
      -- Feed a literal <CR> without remapping so the <CR> submit mapping above
      -- is not triggered recursively.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
    end, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Insert a newline",
    })

    vim.keymap.set({ "i", "n" }, "<Esc>", cancel, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Cancel question",
    })
  end

  local setup_ok, setup_err = pcall(setup)
  if not setup_ok then
    close()
    error(setup_err, 0)
  end
end

return M
