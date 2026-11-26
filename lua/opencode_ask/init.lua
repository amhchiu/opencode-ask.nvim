local config = require("opencode_ask.config")

local M = {}

M.options = config.merge({})

function M.setup(opts)
  M.options = config.merge(opts)
  return M.options
end

return M
