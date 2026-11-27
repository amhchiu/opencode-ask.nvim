local M = {}

local function error_message(message)
  return "opencode-ask: " .. message
end

local function clean(value)
  if type(value) ~= "string" then
    return nil
  end

  local trimmed = vim.trim(value)
  if trimmed == "" then
    return nil
  end

  return trimmed
end

--- Normalize a model reference table to the OpenCode API shape.
local function normalize(ref)
  if type(ref) ~= "table" then
    return nil
  end

  local provider = clean(ref.providerID)
  local id = clean(ref.id) or clean(ref.modelID)
  if not provider or not id then
    return nil
  end

  return {
    providerID = provider,
    id = id,
    variant = clean(ref.variant),
  }
end

--- Parse "provider/model" or "provider/model#variant" into an API Model.Ref.
--- A table with providerID and id (or modelID) and an optional variant is also
--- accepted. Returns nil and a descriptive error for invalid input.
function M.parse(value)
  if type(value) == "table" then
    local ref = normalize(value)
    if not ref then
      return nil, error_message('model table must contain "providerID" and "id" (or "modelID")')
    end
    return ref
  end

  if type(value) ~= "string" then
    return nil, error_message('model must look like "provider/model" or "provider/model#variant"')
  end

  local text = vim.trim(value)
  if text == "" then
    return nil, error_message("model must not be empty")
  end

  local provider, rest = text:match("^([^/#]+)/(.+)$")
  if not provider then
    return nil, error_message('model must look like "provider/model" or "provider/model#variant"')
  end

  local id, variant = rest:match("^([^#]+)#(.+)$")
  if not id then
    if rest:find("#", 1, true) then
      return nil, error_message("model variant must not be empty")
    end
    id = rest
  end

  provider = vim.trim(provider)
  id = vim.trim(id)
  if provider == "" or id == "" then
    return nil, error_message('model must look like "provider/model" or "provider/model#variant"')
  end

  return {
    providerID = provider,
    id = id,
    variant = clean(variant),
  }
end

--- Path of the OpenCode CLI's model state, which records the models the TUI
--- used most recently.
function M.state_path()
  local state_home = clean(vim.env.XDG_STATE_HOME)
  if not state_home then
    local home = clean(vim.env.HOME)
    if not home then
      return nil
    end
    state_home = vim.fs.joinpath(home, ".local", "state")
  end

  return vim.fs.joinpath(state_home, "opencode", "model.json")
end

--- Return the OpenCode TUI's most recently used model as an API Model.Ref.
--- Missing, unreadable, or malformed state yields nil rather than an error.
function M.recent(path)
  path = path or M.state_path()
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok or type(lines) ~= "table" then
    return nil
  end

  local decode_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(decoded) ~= "table" then
    return nil
  end

  local recent = decoded.recent
  if type(recent) ~= "table" or not vim.islist(recent) then
    return nil
  end

  local variants = type(decoded.variant) == "table" and decoded.variant or {}
  for _, entry in ipairs(recent) do
    if type(entry) == "table" then
      local provider = clean(entry.providerID)
      local id = clean(entry.modelID)
      if provider and id then
        return {
          providerID = provider,
          id = id,
          variant = clean(variants[provider .. "/" .. id]),
        }
      end
    end
  end

  return nil
end

--- Resolve the model to send when creating a session.
---
--- `false` opts out and lets OpenCode choose; a string or table is used as-is;
--- nil mirrors the OpenCode TUI's most recently used model.
function M.resolve(configured, path)
  if configured == false then
    return nil
  end

  if configured ~= nil then
    return M.parse(configured)
  end

  return M.recent(path)
end

return M
