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
  viewer = {
    keymap = "<leader>ot",
    layout = "float", -- "float" | "right" | "bottom"
    width = 0.8,
    height = 0.8,
    border = "rounded",
    winblend = 0,
    auto_open = false,
    start_insert = false,
  },
}

local UI_BORDER_NAMES = { "none", "single", "double", "rounded", "solid", "shadow" }
local UI_BORDER_LIST_LENGTHS = { [1] = true, [2] = true, [4] = true, [8] = true }
local VIEWER_LAYOUT_NAMES = { float = true, right = true, bottom = true }

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

local function border_validation_error(border, name)
  local border_ok = false
  if type(border) == "string" then
    for _, candidate in ipairs(UI_BORDER_NAMES) do
      if border == candidate then
        border_ok = true
        break
      end
    end
  elseif type(border) == "table" and is_border_list(border) then
    border_ok = true
  end

  if not border_ok then
    return "opencode_ask: `" .. name .. "` must be a border name "
      .. '("none", "single", "double", "rounded", "solid", "shadow") '
      .. "or a list of 1, 2, 4, or 8 border strings"
  end

  return nil
end

local function winblend_validation_error(winblend, name)
  if type(winblend) ~= "number"
    or winblend < 0
    or winblend > 100
    or math.floor(winblend) ~= winblend
  then
    return "opencode_ask: `" .. name .. "` must be an integer between 0 and 100"
  end

  return nil
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

  local border_err = border_validation_error(ui.border, "ui.border")
  if border_err then
    return border_err
  end

  return winblend_validation_error(ui.winblend, "ui.winblend")
end

local function viewer_span_ok(value)
  if type(value) ~= "number" or value ~= value then
    return false
  end

  if value > 0 and value <= 1 then
    return true
  end

  return value > 1 and value < math.huge and math.floor(value) == value
end

local function viewer_validation_error(viewer)
  if type(viewer) ~= "table" then
    return "opencode_ask: `viewer` must be a table"
  end

  local keymap = viewer.keymap
  if keymap ~= nil and keymap ~= false then
    if type(keymap) ~= "string" or vim.trim(keymap) == "" then
      return "opencode_ask: `viewer.keymap` must be a non-empty string, false, or nil"
    end
  end

  if not VIEWER_LAYOUT_NAMES[viewer.layout] then
    return 'opencode_ask: `viewer.layout` must be "float", "right", or "bottom"'
  end

  for _, key in ipairs({ "width", "height" }) do
    if not viewer_span_ok(viewer[key]) then
      return "opencode_ask: `viewer."
        .. key
        .. "` must be a fraction in (0, 1] or an integer greater than 1"
    end
  end

  local border_err = border_validation_error(viewer.border, "viewer.border")
  if border_err then
    return border_err
  end

  local winblend_err = winblend_validation_error(viewer.winblend, "viewer.winblend")
  if winblend_err then
    return winblend_err
  end

  for _, key in ipairs({ "auto_open", "start_insert" }) do
    if type(viewer[key]) ~= "boolean" then
      return "opencode_ask: `viewer." .. key .. "` must be a boolean"
    end
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

  local viewer_err = viewer_validation_error(merged.viewer)
  if viewer_err then
    error(viewer_err, 2)
  end

  return merged
end

return M
