local M = {}

M.defaults = {
  session = nil,
  keymap = "<leader>oq",
  save = true,
  picker = "fzf-lua",
  state_path = vim.fn.stdpath("state") .. "/opencode-ask/sessions.json",
  api = {
    command = "opencode",
    timeout = 15000,
  },
}

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepcopy(item)
  end
  return copy
end

local function deep_merge(base, overrides)
  for key, value in pairs(overrides) do
    if type(value) == "table" and type(base[key]) == "table" then
      deep_merge(base[key], value)
    else
      base[key] = deepcopy(value)
    end
  end
  return base
end

function M.merge(opts)
  local merged = deepcopy(M.defaults)
  deep_merge(merged, opts or {})

  if merged.session ~= nil and type(merged.session) ~= "string" then
    error("opencode_ask: `session` must be a string (an OpenCode session ID) or nil", 2)
  end

  if merged.keymap ~= nil and merged.keymap ~= false then
    if type(merged.keymap) ~= "string" or vim.trim(merged.keymap) == "" then
      error("opencode_ask: `keymap` must be a non-empty string, false, or nil", 2)
    end
  end

  return merged
end

return M
