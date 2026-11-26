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
  ui = {
    width = 80,
    height = 4,
    border = "rounded",
    position = "selection", -- "selection" (above/below/center) | "center"
    winblend = 0,
  },
}

local UI_BORDER_NAMES = { "none", "single", "double", "rounded", "solid", "shadow" }
local UI_BORDER_LIST_LENGTHS = { [1] = true, [2] = true, [4] = true, [8] = true }

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

local function is_border_list(value)
  if not UI_BORDER_LIST_LENGTHS[#value] then
    return false
  end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

local function ui_validation_error(ui)
  if type(ui) ~= "table" then
    return "opencode_ask: `ui` must be a table"
  end

  for _, key in ipairs({ "width", "height" }) do
    local value = ui[key]
    if type(value) ~= "number" or value < 1 or value >= math.huge or math.floor(value) ~= value then
      return "opencode_ask: `ui." .. key .. "` must be a positive integer"
    end
  end

  if ui.position ~= "selection" and ui.position ~= "center" then
    return 'opencode_ask: `ui.position` must be "selection" or "center"'
  end

  local border = ui.border
  local border_ok = false
  if type(border) == "string" then
    for _, name in ipairs(UI_BORDER_NAMES) do
      if border == name then
        border_ok = true
        break
      end
    end
  elseif type(border) == "table" and is_border_list(border) then
    border_ok = true
  end

  if not border_ok then
    return "opencode_ask: `ui.border` must be a border name "
      .. '("none", "single", "double", "rounded", "solid", "shadow") '
      .. "or a list of 1, 2, 4, or 8 border strings"
  end

  local winblend = ui.winblend
  if type(winblend) ~= "number"
    or winblend < 0
    or winblend > 100
    or math.floor(winblend) ~= winblend
  then
    return "opencode_ask: `ui.winblend` must be an integer between 0 and 100"
  end

  return nil
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

  local ui_err = ui_validation_error(merged.ui)
  if ui_err then
    error(ui_err, 2)
  end

  return merged
end

return M
