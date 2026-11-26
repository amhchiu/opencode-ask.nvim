local ui = require("opencode_ask.ui")

return function(t)
  t.test("layout uses centered defaults", function()
    local layout = ui._layout({}, { columns = 120, lines = 30 })

    t.equal(80, layout.width)
    t.equal(4, layout.height)
    t.equal(20, layout.col)
    t.equal(13, layout.row)
    t.equal("Ask OpenCode", layout.title)
  end)

  t.test("layout honors requested dimensions", function()
    local layout = ui._layout({ width = 30, height = 8 }, { columns = 100, lines = 30 })

    t.equal(30, layout.width)
    t.equal(8, layout.height)
    t.equal(35, layout.col)
    t.equal(11, layout.row)
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
end
