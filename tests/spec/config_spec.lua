local config = require("opencode_ask.config")

return function(t)
  t.test("merge deep-copies the defaults without mutating them", function()
    local defaults = config.defaults
    local default_command = defaults.api.command
    local default_timeout = defaults.api.timeout

    local merged = config.merge({
      keymap = "<leader>oa",
      api = { command = "/custom/opencode" },
    })

    t.equal("<leader>oa", merged.keymap)
    t.equal("/custom/opencode", merged.api.command)
    t.equal(default_timeout, merged.api.timeout, "nested defaults should be preserved")
    t.equal("<leader>oq", defaults.keymap, "defaults should not be mutated")
    t.equal(default_command, defaults.api.command, "nested defaults should not be mutated")

    merged.api.command = "changed"
    t.equal(default_command, defaults.api.command, "merged values should not alias defaults")
  end)

  t.test("merge accepts the documented defaults", function()
    local merged = config.merge({})

    t.equal(nil, merged.session)
    t.equal("<leader>oq", merged.keymap)
    t.equal(true, merged.save)
    t.equal("fzf-lua", merged.picker)
    t.equal(vim.fn.stdpath("state") .. "/opencode-ask/sessions.json", merged.state_path)
    t.equal("opencode", merged.api.command)
    t.equal(15000, merged.api.timeout)
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
end
