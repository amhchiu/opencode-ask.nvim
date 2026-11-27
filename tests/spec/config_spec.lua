local config = require("opencode_ask.config")

return function(t)
  t.test("merge deep-copies the defaults without mutating them", function()
    local defaults = config.defaults
    local default_command = defaults.api.command
    local default_timeout = defaults.api.timeout

    local merged = config.merge({
      keymap = "<leader>oa",
      api = { command = "/custom/opencode" },
      ui = { width = 60 },
      viewer = { layout = "right" },
    })

    t.equal("<leader>oa", merged.keymap)
    t.equal("/custom/opencode", merged.api.command)
    t.equal(default_timeout, merged.api.timeout, "nested defaults should be preserved")
    t.equal(60, merged.ui.width)
    t.equal(4, merged.ui.height, "ui defaults should be preserved when overriding width")
    t.equal("rounded", merged.ui.border)
    t.equal("selection", merged.ui.position)
    t.equal(0, merged.ui.winblend)
    t.equal("right", merged.viewer.layout)
    t.equal("center", merged.viewer.position)
    t.equal("<leader>ot", merged.viewer.keymap, "viewer defaults should be preserved")
    t.equal(0.8, merged.viewer.width)
    t.equal(0.8, merged.viewer.height)
    t.equal("rounded", merged.viewer.border)
    t.equal(0, merged.viewer.winblend)
    t.equal(false, merged.viewer.auto_open)
    t.equal(false, merged.viewer.start_insert)
    t.equal("<leader>oq", defaults.keymap, "defaults should not be mutated")
    t.equal(default_command, defaults.api.command, "nested defaults should not be mutated")
    t.equal(80, defaults.ui.width, "ui defaults should not be mutated")
    t.equal("float", defaults.viewer.layout, "viewer defaults should not be mutated")

    merged.api.command = "changed"
    merged.ui.width = 42
    merged.viewer.layout = "bottom"
    t.equal(default_command, defaults.api.command, "merged values should not alias defaults")
    t.equal(80, defaults.ui.width, "merged ui values should not alias defaults")
    t.equal("float", defaults.viewer.layout, "merged viewer values should not alias defaults")
  end)

  t.test("merge accepts the documented defaults", function()
    local merged = config.merge({})

    t.equal(nil, merged.session)
    t.equal(nil, merged.model)
    t.equal("<leader>oq", merged.keymap)
    t.equal(true, merged.save)
    t.equal("fzf-lua", merged.picker)
    t.equal(vim.fn.stdpath("state") .. "/opencode-ask/sessions.json", merged.state_path)
    t.equal("opencode", merged.api.command)
    t.equal(15000, merged.api.timeout)
    t.equal(80, merged.ui.width)
    t.equal(4, merged.ui.height)
    t.equal("rounded", merged.ui.border)
    t.equal("selection", merged.ui.position)
    t.equal(0, merged.ui.winblend)
    t.equal("<leader>ot", merged.viewer.keymap)
    t.equal("float", merged.viewer.layout)
    t.equal("center", merged.viewer.position)
    t.equal(0.8, merged.viewer.width)
    t.equal(0.8, merged.viewer.height)
    t.equal("rounded", merged.viewer.border)
    t.equal(0, merged.viewer.winblend)
    t.equal(false, merged.viewer.auto_open)
    t.equal(false, merged.viewer.start_insert)
  end)

  t.test("session accepts a string or nil and rejects other types", function()
    local merged = config.merge({ session = "ses_example" })
    t.equal("ses_example", merged.session)

    merged = config.merge({ session = nil })
    t.equal(nil, merged.session)

    for _, value in ipairs({ 42, true, {} }) do
      local ok, err = pcall(config.merge, { session = value })
      t.equal(false, ok, "session should reject " .. type(value))
      t.matches("session", tostring(err))
    end
  end)

  t.test("model accepts nil, false, strings, and reference tables", function()
    t.equal(nil, config.merge({}).model)
    t.equal(false, config.merge({ model = false }).model)
    t.equal("opencode-go/deepseek-v4.1-flash", config.merge({ model = "opencode-go/deepseek-v4.1-flash" }).model)

    local reference = { providerID = "opencode-go", id = "deepseek-v4.1-flash", variant = "high" }
    t.equal(reference, config.merge({ model = reference }).model)
  end)

  t.test("model rejects malformed values with a clear error", function()
    for _, value in ipairs({ 42, true, "", "no-separator", {}, { id = "deepseek-v4.1-flash" } }) do
      local ok, err = pcall(config.merge, { model = value })
      t.equal(false, ok, "model should reject " .. vim.inspect(value))
      t.matches("^opencode%-ask: ", tostring(err))
      t.matches("model", tostring(err))
    end
  end)

  t.test("keymap accepts a non-empty string or false", function()
    local merged = config.merge({ keymap = "<leader>oa" })
    t.equal("<leader>oa", merged.keymap)

    merged = config.merge({ keymap = false })
    t.equal(false, merged.keymap)

    merged = config.merge({})
    t.equal("<leader>oq", merged.keymap, "omitting keymap should keep the default")
  end)

  t.test("keymap rejects empty and non-string values with a clear error", function()
    for _, value in ipairs({ "", "   ", true, 42, {} }) do
      local ok, err = pcall(config.merge, { keymap = value })
      t.equal(false, ok, "keymap should reject " .. vim.inspect(value))
      t.matches("keymap", tostring(err))
      t.matches("non%-empty string", tostring(err))
    end
  end)

  t.test("ui rejects values that are not tables", function()
    for _, value in ipairs({ true, 42, "wide" }) do
      local ok, err = pcall(config.merge, { ui = value })
      t.equal(false, ok, "ui should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("`ui`", tostring(err))
      t.matches("table", tostring(err))
    end
  end)

  t.test("ui.width and ui.height require positive integers", function()
    for _, key in ipairs({ "width", "height" }) do
      for _, value in ipairs({ 0, -1, 12.5, math.huge, "80", true, {} }) do
        local ok, err = pcall(config.merge, { ui = { [key] = value } })
        t.equal(false, ok, ("ui.%s should reject %s"):format(key, vim.inspect(value)))
        t.matches("^opencode_ask: ", tostring(err))
        t.matches("ui%." .. key, tostring(err))
      end
    end
  end)

  t.test("ui.position accepts selection or center", function()
    for _, value in ipairs({ "selection", "center" }) do
      local merged = config.merge({ ui = { position = value } })
      t.equal(value, merged.ui.position)
    end

    for _, value in ipairs({ "above", "centre", "", true, 42, {} }) do
      local ok, err = pcall(config.merge, { ui = { position = value } })
      t.equal(false, ok, "ui.position should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("ui%.position", tostring(err))
    end
  end)

  t.test("ui.border accepts border names and valid character lists", function()
    for _, value in ipairs({ "none", "single", "double", "rounded", "solid", "shadow" }) do
      local merged = config.merge({ ui = { border = value } })
      t.equal(value, merged.ui.border)
    end

    local lists = {
      { "single" },
      { "single", "double" },
      { "single", "double", "rounded", "solid" },
      { "a", "b", "c", "d", "e", "f", "g", "h" },
    }
    for _, value in ipairs(lists) do
      local merged = config.merge({ ui = { border = value } })
      t.equal(value, merged.ui.border)
    end
  end)

  t.test("ui.border rejects unknown names and invalid lists", function()
    local cases = {
      "ascii",
      "",
      true,
      42,
      {},
      { "single", "double", "rounded" },
      { "a", "b", "c", "d", "e" },
      { "single", 42 },
    }
    for _, value in ipairs(cases) do
      local ok, err = pcall(config.merge, { ui = { border = value } })
      t.equal(false, ok, "ui.border should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("ui%.border", tostring(err))
    end
  end)

  t.test("ui.winblend accepts integers from 0 to 100", function()
    for _, value in ipairs({ 0, 50, 100 }) do
      local merged = config.merge({ ui = { winblend = value } })
      t.equal(value, merged.ui.winblend)
    end
  end)

  t.test("ui.winblend rejects floats and out-of-range values", function()
    for _, value in ipairs({ 12.5, -1, 101, math.huge, "50", true, {} }) do
      local ok, err = pcall(config.merge, { ui = { winblend = value } })
      t.equal(false, ok, "ui.winblend should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("ui%.winblend", tostring(err))
    end
  end)

  t.test("viewer rejects values that are not tables", function()
    for _, value in ipairs({ true, 42, "float" }) do
      local ok, err = pcall(config.merge, { viewer = value })
      t.equal(false, ok, "viewer should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("`viewer`", tostring(err))
      t.matches("table", tostring(err))
    end
  end)

  t.test("viewer.keymap accepts a non-empty string or false", function()
    local merged = config.merge({ viewer = { keymap = "<leader>ov" } })
    t.equal("<leader>ov", merged.viewer.keymap)

    merged = config.merge({ viewer = { keymap = false } })
    t.equal(false, merged.viewer.keymap)

    merged = config.merge({})
    t.equal("<leader>ot", merged.viewer.keymap, "omitting viewer.keymap should keep the default")
  end)

  t.test("viewer.keymap rejects empty and non-string values with a clear error", function()
    for _, value in ipairs({ "", "   ", true, 42, {} }) do
      local ok, err = pcall(config.merge, { viewer = { keymap = value } })
      t.equal(false, ok, "viewer.keymap should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("viewer%.keymap", tostring(err))
      t.matches("non%-empty string", tostring(err))
    end
  end)

  t.test("viewer.layout accepts float, right, or bottom", function()
    for _, value in ipairs({ "float", "right", "bottom" }) do
      local merged = config.merge({ viewer = { layout = value } })
      t.equal(value, merged.viewer.layout)
    end

    for _, value in ipairs({ "left", "", true, 42, {} }) do
      local ok, err = pcall(config.merge, { viewer = { layout = value } })
      t.equal(false, ok, "viewer.layout should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("viewer%.layout", tostring(err))
    end
  end)

  t.test("viewer.position accepts the documented anchors", function()
    for _, value in ipairs({ "center", "top", "bottom", "left", "right" }) do
      local merged = config.merge({ viewer = { position = value } })
      t.equal(value, merged.viewer.position)
    end

    for _, value in ipairs({ "middle", "", true, 42, {} }) do
      local ok, err = pcall(config.merge, { viewer = { position = value } })
      t.equal(false, ok, "viewer.position should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("viewer%.position", tostring(err))
    end
  end)

  t.test("viewer.width and viewer.height accept fractions and integers", function()
    for _, key in ipairs({ "width", "height" }) do
      for _, value in ipairs({ 0.5, 1, 2, 80 }) do
        local merged = config.merge({ viewer = { [key] = value } })
        t.equal(value, merged.viewer[key])
      end
    end
  end)

  t.test("viewer.width and viewer.height reject invalid spans", function()
    for _, key in ipairs({ "width", "height" }) do
      local invalid = { 0, -1, -0.5, 1.5, 2.5, math.huge, 0 / 0, "0.8", true, {} }
      for _, value in ipairs(invalid) do
        local ok, err = pcall(config.merge, { viewer = { [key] = value } })
        t.equal(false, ok, ("viewer.%s should reject %s"):format(key, vim.inspect(value)))
        t.matches("^opencode_ask: ", tostring(err))
        t.matches("viewer%." .. key, tostring(err))
        t.matches("fraction", tostring(err))
      end
    end
  end)

  t.test("viewer.border accepts border names and valid character lists", function()
    for _, value in ipairs({ "none", "single", "double", "rounded", "solid", "shadow" }) do
      local merged = config.merge({ viewer = { border = value } })
      t.equal(value, merged.viewer.border)
    end

    local lists = {
      { "single" },
      { "single", "double" },
      { "single", "double", "rounded", "solid" },
      { "a", "b", "c", "d", "e", "f", "g", "h" },
    }
    for _, value in ipairs(lists) do
      local merged = config.merge({ viewer = { border = value } })
      t.equal(value, merged.viewer.border)
    end
  end)

  t.test("viewer.border rejects unknown names and invalid lists", function()
    local cases = {
      "ascii",
      "",
      true,
      42,
      {},
      { "single", "double", "rounded" },
      { "a", "b", "c", "d", "e" },
      { "single", 42 },
    }
    for _, value in ipairs(cases) do
      local ok, err = pcall(config.merge, { viewer = { border = value } })
      t.equal(false, ok, "viewer.border should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("viewer%.border", tostring(err))
    end
  end)

  t.test("viewer.winblend accepts integers from 0 to 100", function()
    for _, value in ipairs({ 0, 50, 100 }) do
      local merged = config.merge({ viewer = { winblend = value } })
      t.equal(value, merged.viewer.winblend)
    end
  end)

  t.test("viewer.winblend rejects floats and out-of-range values", function()
    for _, value in ipairs({ 12.5, -1, 101, math.huge, "50", true, {} }) do
      local ok, err = pcall(config.merge, { viewer = { winblend = value } })
      t.equal(false, ok, "viewer.winblend should reject " .. vim.inspect(value))
      t.matches("^opencode_ask: ", tostring(err))
      t.matches("viewer%.winblend", tostring(err))
    end
  end)

  t.test("viewer.auto_open and viewer.start_insert require booleans", function()
    for _, key in ipairs({ "auto_open", "start_insert" }) do
      for _, value in ipairs({ true, false }) do
        local merged = config.merge({ viewer = { [key] = value } })
        t.equal(value, merged.viewer[key])
      end

      for _, value in ipairs({ 1, 0, "true", {} }) do
        local ok, err = pcall(config.merge, { viewer = { [key] = value } })
        t.equal(false, ok, ("viewer.%s should reject %s"):format(key, vim.inspect(value)))
        t.matches("^opencode_ask: ", tostring(err))
        t.matches("viewer%." .. key, tostring(err))
        t.matches("boolean", tostring(err))
      end
    end
  end)
end
