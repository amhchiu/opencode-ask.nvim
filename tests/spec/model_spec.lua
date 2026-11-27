local model = require("opencode_ask.model")

local function write_state(dir, contents)
  vim.fn.mkdir(vim.fs.joinpath(dir, "opencode"), "p")
  vim.fn.writefile(contents, vim.fs.joinpath(dir, "opencode", "model.json"))
end

local function with_state_home(value, fn)
  local saved = vim.env.XDG_STATE_HOME
  vim.env.XDG_STATE_HOME = value
  local ok, err = pcall(fn)
  vim.env.XDG_STATE_HOME = saved
  if not ok then
    error(err, 0)
  end
end

return function(t)
  t.test("parse accepts provider/model and provider/model#variant strings", function()
    local ref, err = model.parse("opencode-go/deepseek-v4.1-flash")
    t.equal(nil, err)
    t.equal({ providerID = "opencode-go", id = "deepseek-v4.1-flash" }, ref)

    ref, err = model.parse("  opencode-go/deepseek-v4.1-flash#high  ")
    t.equal(nil, err)
    t.equal({
      providerID = "opencode-go",
      id = "deepseek-v4.1-flash",
      variant = "high",
    }, ref)
  end)

  t.test("parse accepts model reference tables", function()
    local ref, err = model.parse({
      providerID = "opencode-go",
      id = "deepseek-v4.1-flash",
      variant = "high",
    })
    t.equal(nil, err)
    t.equal({
      providerID = "opencode-go",
      id = "deepseek-v4.1-flash",
      variant = "high",
    }, ref)

    ref, err = model.parse({ providerID = "opencode-go", modelID = "glm-5.3" })
    t.equal(nil, err)
    t.equal({ providerID = "opencode-go", id = "glm-5.3" }, ref)
  end)

  t.test("parse rejects malformed model references", function()
    local cases = {
      42,
      true,
      "",
      "   ",
      "no-separator",
      "/missing-provider",
      "missing-model/",
      "opencode-go/deepseek-v4.1-flash#",
      {},
      { id = "deepseek-v4.1-flash" },
      { providerID = "opencode-go" },
      { providerID = "", id = "deepseek-v4.1-flash" },
    }

    for _, value in ipairs(cases) do
      local ref, err = model.parse(value)
      t.equal(nil, ref, "parse should reject " .. vim.inspect(value))
      t.matches("^opencode%-ask: ", err)
      t.matches("model", err)
    end
  end)

  t.test("state_path honors XDG_STATE_HOME", function()
    with_state_home("/tmp/state-home", function()
      t.equal("/tmp/state-home/opencode/model.json", model.state_path())
    end)
  end)

  t.test("recent returns the first usable model and its variant", function()
    local state_home = vim.fn.tempname()
    write_state(state_home, {
      '{"recent":[',
      '{"providerID":"opencode-go","modelID":"deepseek-v4.1-flash"},',
      '{"providerID":"opencode","modelID":"space-bunny-free"}',
      '],"variant":{"opencode-go/deepseek-v4.1-flash":"high"}}',
    })

    with_state_home(state_home, function()
      t.equal({
        providerID = "opencode-go",
        id = "deepseek-v4.1-flash",
        variant = "high",
      }, model.recent())
    end)

    vim.fn.delete(state_home, "rf")
  end)

  t.test("recent skips malformed entries and missing state", function()
    local state_home = vim.fn.tempname()
    write_state(state_home, {
      '{"recent":[null,{"providerID":"opencode-go"},',
      '{"providerID":"opencode-go","modelID":"glm-5.3"}],"variant":{}}',
    })

    with_state_home(state_home, function()
      t.equal({ providerID = "opencode-go", id = "glm-5.3" }, model.recent())
    end)

    vim.fn.delete(state_home, "rf")

    with_state_home(vim.fn.tempname(), function()
      t.equal(nil, model.recent())
    end)
  end)

  t.test("recent treats corrupt state as missing", function()
    local state_home = vim.fn.tempname()
    write_state(state_home, { "not json" })

    with_state_home(state_home, function()
      t.equal(nil, model.recent())
    end)

    vim.fn.delete(state_home, "rf")
  end)

  t.test("resolve selects between opt-out, explicit, and recent models", function()
    local state_home = vim.fn.tempname()
    write_state(state_home, {
      '{"recent":[{"providerID":"opencode-go","modelID":"deepseek-v4.1-flash"}],"variant":{}}',
    })

    with_state_home(state_home, function()
      t.equal(nil, model.resolve(false))
      t.equal({ providerID = "opencode", id = "fast" }, model.resolve("opencode/fast"))
      t.equal({ providerID = "opencode-go", id = "deepseek-v4.1-flash" }, model.resolve(nil))
    end)

    vim.fn.delete(state_home, "rf")
  end)
end
