local M = {}

local SELECTION_NS = vim.api.nvim_create_namespace("opencode_ask_selection")

local DEFAULT_TITLE = "Ask OpenCode"
local DEFAULT_WIDTH = 80
local DEFAULT_HEIGHT = 4
local MIN_WIDTH = 20
local DEFAULT_BORDER = "rounded"

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

--- Compute the float geometry.
---
--- This is an internal helper exported for tests. `dimensions` may override
--- the current editor size so the clamping rules can be tested without
--- resizing the editor.
function M._layout(opts, dimensions)
  opts = opts or {}
  local columns = math.max(1, math.floor((dimensions and dimensions.columns) or vim.o.columns))
  local lines = math.max(1, math.floor((dimensions and dimensions.lines) or vim.o.lines))
  local cmdheight = math.max(
    0,
    math.floor((dimensions and dimensions.cmdheight) or vim.o.cmdheight)
  )

  local border = opts.border or DEFAULT_BORDER
  local border_rows, border_cols = border_size(border)

  local width
  if columns < MIN_WIDTH then
    width = math.max(1, columns - border_cols)
  else
    width = math.max(MIN_WIDTH, math.min(opts.width or DEFAULT_WIDTH, columns - 10))
  end
  -- Keep the content plus its border inside the editor.
  width = math.max(1, math.min(width, columns - border_cols))

  local max_height = math.max(1, lines - 4 - border_rows)
  local height = math.max(1, math.min(opts.height or DEFAULT_HEIGHT, max_height))

  local total_width = width + border_cols
  local total_height = height + border_rows
  local max_bottom = math.max(total_height, lines - cmdheight)

  local anchor = opts.anchor
  local position = opts.position or (anchor and "selection" or "center")
  local use_anchor = position == "selection"
    and type(anchor) == "table"
    and anchor.top_row >= 0
    and anchor.bottom_row > anchor.top_row

  local row
  if use_anchor then
    if anchor.top_row >= total_height then
      row = anchor.top_row - total_height
    elseif max_bottom - anchor.bottom_row >= total_height then
      row = anchor.bottom_row
    else
      row = center(total_height, lines)
    end
  else
    row = center(total_height, lines)
  end
  row = math.max(0, math.min(row, math.max(0, lines - total_height)))

  local col
  if use_anchor and anchor.win_col ~= nil and anchor.win_width ~= nil then
    col = anchor.win_col + center(total_width, anchor.win_width)
  else
    col = center(total_width, columns)
  end
  col = math.max(0, math.min(col, math.max(0, columns - total_width)))

  local title = opts.title or DEFAULT_TITLE
  if type(title) ~= "string" then
    title = tostring(title)
  end
  title = truncate_title(title, width - 4)

  return {
    width = width,
    height = height,
    row = row,
    col = col,
    border = border,
    title = title,
  }
end

--- Measure the on-screen rows covered by a line range in a window.
---
--- Returns nil when the window is invalid or the range is not visible. This is
--- an internal helper exported for tests.
function M._measure_anchor(win, first, last)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local ok, anchor = pcall(function()
    local bufnr = vim.api.nvim_win_get_buf(win)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    first = math.max(1, math.min(first, line_count))
    last = math.max(1, math.min(last, line_count))
    if first > last then
      return nil
    end

    -- Measure the end of the last selected line so wrapped lines resolve to
    -- their actual bottom screen row.
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
    local last_col = math.max(1, #last_line)

    local top = vim.fn.screenpos(win, first, 1)
    local bottom = vim.fn.screenpos(win, last, last_col)
    if top.row <= 0 or bottom.row <= 0 then
      return nil
    end

    local win_pos = vim.fn.win_screenpos(win)
    return {
      top_row = top.row - 1,
      bottom_row = bottom.row,
      win_col = win_pos[2] - 1,
      win_width = vim.api.nvim_win_get_width(win),
    }
  end)

  if not ok then
    return nil
  end
  return anchor
end

--- Open a floating question prompt.
---
--- opts supports title, default, width, height, border, position, winblend,
--- anchor, and highlight. highlight may contain bufnr, first, and last to keep
--- the selected lines highlighted while the prompt is open. on_submit is
--- called with the trimmed question after the float has closed. An empty
--- question leaves the prompt open and emits a warning notification.
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
  local hl_bufnr
  local submit
  local cancel

  local function close(autocmd_args)
    if closed then
      return
    end
    closed = true

    pcall(vim.cmd, "stopinsert")

    if hl_bufnr and vim.api.nvim_buf_is_valid(hl_bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, hl_bufnr, SELECTION_NS, 0, -1)
    end

    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end

    -- When BufWipeout triggers close, the scratch buffer is already being
    -- wiped; deleting it again raises E937 and aborts the external close.
    local wiping = type(autocmd_args) == "table"
      and autocmd_args.event == "BufWipeout"
      and autocmd_args.buf == bufnr
    if not wiping and vim.api.nvim_buf_is_valid(bufnr) then
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

    local highlight = opts.highlight
    if
      type(highlight) == "table"
      and type(highlight.first) == "number"
      and type(highlight.last) == "number"
      and highlight.bufnr
      and vim.api.nvim_buf_is_valid(highlight.bufnr)
    then
      hl_bufnr = highlight.bufnr
      pcall(function()
        local line_count = vim.api.nvim_buf_line_count(hl_bufnr)
        local first = math.max(1, math.min(highlight.first, line_count))
        local last = math.max(1, math.min(highlight.last, line_count))
        vim.api.nvim_buf_clear_namespace(hl_bufnr, SELECTION_NS, 0, -1)
        vim.api.nvim_buf_set_extmark(hl_bufnr, SELECTION_NS, first - 1, 0, {
          end_row = last,
          end_col = 0,
          hl_group = "OpencodeAskSelection",
          hl_eol = true,
          priority = 200,
        })
      end)
    end

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
      win_config.title = layout.title
      win_config.title_pos = "center"
    end

    win = vim.api.nvim_open_win(bufnr, true, win_config)

    -- Closing the float externally (:q, <C-w>c, nvim_win_close) wipes the
    -- scratch buffer, so use BufWipeout to run the same cleanup path.
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = close,
    })

    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].winhighlight =
      "NormalFloat:OpencodeAskNormal,FloatBorder:OpencodeAskBorder,FloatTitle:OpencodeAskTitle"
    if type(opts.winblend) == "number" then
      vim.wo[win].winblend = opts.winblend
    end

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
