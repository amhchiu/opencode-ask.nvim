local ui = require("opencode_ask.ui")

return function(t)
  local function find_float()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        return win
      end
    end
    return nil
  end

  local function close_float(win)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.cmd, "stopinsert")
      local buf = vim.api.nvim_win_get_buf(win)
      pcall(vim.api.nvim_win_close, win, true)
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  t.test("layout uses centered defaults", function()
    local layout = ui._layout({}, { columns = 120, lines = 30 })

    t.equal(80, layout.width)
    t.equal(4, layout.height)
    t.equal(19, layout.col)
    t.equal(12, layout.row)
    t.equal("rounded", layout.border)
    t.equal("Ask OpenCode", layout.title)
  end)

  t.test("layout honors requested dimensions", function()
    local layout = ui._layout({ width = 30, height = 8 }, { columns = 100, lines = 30 })

    t.equal(30, layout.width)
    t.equal(8, layout.height)
    t.equal(34, layout.col)
    t.equal(10, layout.row)
  end)

  t.test("layout clamps the float including its border to the editor width", function()
    local cases = {
      { columns = 12, expected_width = 10 },
      { columns = 15, expected_width = 13 },
      { columns = 19, expected_width = 17 },
      { columns = 20, expected_width = 18 },
      { columns = 21, expected_width = 19 },
      { columns = 22, expected_width = 20 },
      { columns = 30, expected_width = 20 },
    }

    for _, case in ipairs(cases) do
      local layout = ui._layout({ width = 5 }, { columns = case.columns, lines = 10 })
      t.equal(case.expected_width, layout.width, "width for " .. case.columns .. " columns")
      t.assert(layout.width + 2 <= case.columns, "border exceeded the editor width")
      t.assert(layout.col >= 0, "column must not be negative")
      t.assert(layout.col + layout.width + 1 <= case.columns, "float exceeded the editor width")
    end
  end)

  t.test("layout caps an oversized request", function()
    local layout = ui._layout({ width = 500 }, { columns = 100, lines = 30 })

    t.equal(90, layout.width)
    t.assert(layout.width + 2 <= 100, "border exceeded the editor width")
  end)

  t.test("layout places the float above a selection with room above", function()
    local layout = ui._layout({
      position = "selection",
      anchor = { top_row = 12, bottom_row = 15, win_col = 20, win_width = 50 },
    }, { columns = 100, lines = 30 })

    t.equal(80, layout.width)
    t.equal(4, layout.height)
    t.equal(6, layout.row)
    t.equal(4, layout.col)
  end)

  t.test("layout places the float below a selection near the top", function()
    local layout = ui._layout({
      position = "selection",
      anchor = { top_row = 1, bottom_row = 4, win_col = 10, win_width = 60 },
    }, { columns = 100, lines = 30, cmdheight = 1 })

    t.equal(4, layout.row)
  end)

  t.test("layout centers the float when the selection fills the screen", function()
    local layout = ui._layout({
      position = "selection",
      anchor = { top_row = 1, bottom_row = 9, win_col = 0, win_width = 100 },
    }, { columns = 100, lines = 10, cmdheight = 1 })

    t.equal(2, layout.row)
    t.assert(layout.row >= 0, "row must not be negative")
    t.assert(layout.row + layout.height + 2 <= 10, "float exceeded the editor height")
  end)

  t.test("layout center position ignores the selection anchor", function()
    local layout = ui._layout({
      position = "center",
      anchor = { top_row = 12, bottom_row = 15, win_col = 30, win_width = 20 },
    }, { columns = 100, lines = 30 })

    t.equal(9, layout.col)
    t.equal(12, layout.row)
  end)

  t.test("layout border none does not reserve border cells", function()
    local dimensions = { columns = 12, lines = 7, cmdheight = 1 }
    local rounded = ui._layout({ width = 5, height = 10, border = "rounded" }, dimensions)
    local none = ui._layout({ width = 5, height = 10, border = "none" }, dimensions)

    t.equal(10, rounded.width)
    t.equal(12, none.width)
    t.equal(1, rounded.height)
    t.equal(3, none.height)
    t.equal("none", none.border)
    t.assert(none.width > rounded.width, "border none should use more columns")
    t.assert(none.height > rounded.height, "border none should use more rows")
  end)

  t.test("layout shadow border reserves one row and column", function()
    local dimensions = { columns = 20, lines = 8, cmdheight = 1 }
    local none = ui._layout({ width = 5, height = 10, border = "none" }, dimensions)
    local shadow = ui._layout({ width = 5, height = 10, border = "shadow" }, dimensions)
    local rounded = ui._layout({ width = 5, height = 10, border = "rounded" }, dimensions)

    t.equal(20, none.width)
    t.equal(19, shadow.width)
    t.equal(18, rounded.width)
    t.equal(4, none.height)
    t.equal(3, shadow.height)
    t.equal(2, rounded.height)
    t.equal("shadow", shadow.border)
  end)

  t.test("layout centers horizontally inside a split window", function()
    local layout = ui._layout({
      position = "selection",
      width = 20,
      height = 2,
      border = "none",
      anchor = { top_row = 10, bottom_row = 12, win_col = 10, win_width = 40 },
    }, { columns = 100, lines = 30, cmdheight = 1 })

    t.equal(20, layout.col)
    t.equal(8, layout.row)
  end)

  t.test("layout clamps horizontal alignment inside the editor", function()
    local layout = ui._layout({
      position = "selection",
      width = 20,
      height = 2,
      border = "none",
      anchor = { top_row = 10, bottom_row = 12, win_col = 30, win_width = 15 },
    }, { columns = 40, lines = 30, cmdheight = 1 })

    t.equal(20, layout.col)
  end)

  t.test("measure_anchor uses the bottom of a wrapped last line", function()
    local win = vim.api.nvim_get_current_win()
    local original_buf = vim.api.nvim_win_get_buf(win)
    local original_wrap = vim.wo[win].wrap
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "first",
      string.rep("x", 200),
      "third",
    })
    vim.wo[win].wrap = true
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd("redraw")

    local anchor = ui._measure_anchor(win, 1, 2)
    local width = vim.api.nvim_win_get_width(win)

    vim.api.nvim_win_set_buf(win, original_buf)
    vim.wo[win].wrap = original_wrap
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.cmd("redraw")

    t.assert(anchor ~= nil, "anchor should be measured")
    t.equal(0, anchor.top_row)
    t.equal(4, anchor.bottom_row)
    t.equal(0, anchor.win_col)
    t.equal(width, anchor.win_width)
    t.equal(nil, ui._measure_anchor(9999, 1, 1))
  end)

  t.test("layout keeps at least one row and stays in the editor", function()
    for _, lines in ipairs({ 3, 5, 8 }) do
      local layout = ui._layout({ height = 10 }, { columns = 100, lines = lines })
      t.assert(layout.height >= 1, "height must be at least one row")
      t.assert(layout.height <= math.max(1, lines - 4), "height exceeded the available rows")
      t.assert(layout.row >= 0, "row must not be negative")
      t.assert(layout.row + layout.height + 1 <= lines, "float exceeded the editor height")
    end
  end)

  t.test("layout truncates the default title for narrow floats", function()
    local layout = ui._layout({}, { columns = 15, lines = 10 })

    t.equal(13, layout.width)
    t.equal("Ask OpenC", layout.title)
  end)

  t.test("layout truncates multibyte titles without splitting a character", function()
    local layout = ui._layout({ title = string.rep("語", 30), width = 20 }, { columns = 120, lines = 30 })

    t.equal(16, vim.fn.strchars(layout.title))
    t.equal(string.rep("語", 16), layout.title)
  end)

  t.test("trim_question rejects empty and whitespace-only input", function()
    t.equal("", ui._trim_question(""))
    t.equal("", ui._trim_question("   "))
    t.equal("", ui._trim_question("\t\n \r\n"))
    t.equal("", ui._trim_question(nil))
    t.equal("", ui._trim_question(42))
  end)

  t.test("trim_question trims leading and trailing whitespace", function()
    t.equal("hello", ui._trim_question("  hello  "))
    t.equal("hello", ui._trim_question("\nhello\t"))
    t.equal("hello", ui._trim_question("  \n\thello \t\n "))
  end)

  t.test("trim_question keeps internal newlines and whitespace", function()
    t.equal("hello\nworld", ui._trim_question(" hello\nworld "))
    t.equal("first\n\nsecond", ui._trim_question("\nfirst\n\nsecond\n"))
    t.equal("a\n  b\nc", ui._trim_question("  a\n  b\nc  "))
  end)

  t.test("ensure_highlights links the plugin groups to the standard float groups", function()
    ui.ensure_highlights()

    local expected = {
      OpencodeAskNormal = "NormalFloat",
      OpencodeAskBorder = "FloatBorder",
      OpencodeAskTitle = "FloatTitle",
      OpencodeAskSelection = "Visual",
    }
    for name, target in pairs(expected) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      t.equal(target, hl.link, name .. " should link to " .. target)
    end
  end)

  t.test("ensure_highlights does not overwrite an explicit highlight group", function()
    vim.api.nvim_set_hl(0, "OpencodeAskBorder", { fg = "#ff0000" })
    ui.ensure_highlights()

    local hl = vim.api.nvim_get_hl(0, { name = "OpencodeAskBorder" })
    t.equal(0xff0000, hl.fg, "the custom fg should be preserved")
    t.equal(nil, hl.link, "the custom group should not be re-linked")

    -- Restore the default link so later tests see the module's standard state.
    vim.api.nvim_set_hl(0, "OpencodeAskBorder", { link = "FloatBorder" })
    t.equal("FloatBorder", vim.api.nvim_get_hl(0, { name = "OpencodeAskBorder" }).link)
  end)

  t.test("prompt applies plugin styling and omits the title without a border", function()
    local original_winblend = vim.o.winblend
    vim.o.winblend = 25

    local ok, err = pcall(ui.prompt, {
      width = 20,
      height = 2,
      border = "none",
      winblend = 0,
    }, nil)
    local win = find_float()
    local config = win and vim.api.nvim_win_get_config(win) or {}
    local winhighlight = win and vim.wo[win].winhighlight or nil
    local winblend = win and vim.wo[win].winblend or nil

    close_float(win)
    vim.o.winblend = original_winblend

    t.equal(true, ok, tostring(err))
    t.assert(win ~= nil, "prompt should open a floating window")
    t.equal("none", config.border)
    t.equal(nil, config.title)
    t.equal(nil, config.title_pos)
    t.equal(
      "NormalFloat:OpencodeAskNormal,FloatBorder:OpencodeAskBorder,FloatTitle:OpencodeAskTitle",
      winhighlight
    )
    t.equal(0, winblend, "explicit winblend = 0 should override the global value")
  end)

  t.test("prompt applies an explicit non-zero winblend", function()
    local ok, err = pcall(ui.prompt, {
      width = 20,
      height = 2,
      border = "none",
      winblend = 12,
    }, nil)
    local win = find_float()
    local winblend = win and vim.wo[win].winblend or nil

    close_float(win)

    t.equal(true, ok, tostring(err))
    t.assert(win ~= nil, "prompt should open a floating window")
    t.equal(12, winblend)
  end)

  t.test("prompt cleans up when setup fails after opening", function()
    local function float_count()
      local count = 0
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then
          count = count + 1
        end
      end
      return count
    end

    local function scratch_count()
      local count = 0
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].buftype == "nofile" then
          count = count + 1
        end
      end
      return count
    end

    local before_floats = float_count()
    local before_scratch = scratch_count()
    local original_cmd = vim.cmd
    vim.cmd = function(command)
      if command == "startinsert!" then
        error("insert failed")
      end
      return original_cmd(command)
    end

    local ok, err = pcall(ui.prompt, {}, function() end)
    vim.cmd = original_cmd

    t.equal(false, ok, "prompt should report the setup failure")
    t.matches("insert failed", tostring(err))
    t.equal(before_floats, float_count(), "no floating window should remain")
    t.equal(before_scratch, scratch_count(), "no scratch buffer should remain")
  end)
end
