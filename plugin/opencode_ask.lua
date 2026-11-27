if vim.g.loaded_opencode_ask then
  return
end
vim.g.loaded_opencode_ask = 1

vim.api.nvim_create_user_command("OpencodeAsk", function(args)
  require("opencode_ask").ask({ first = args.line1, last = args.line2 })
end, {
  range = true,
  nargs = 0,
  desc = "Ask OpenCode about the selected lines",
})

vim.api.nvim_create_user_command("OpencodeSession", function()
  require("opencode_ask").select_session()
end, {
  nargs = 0,
  desc = "Choose the OpenCode session for this project",
})

vim.api.nvim_create_user_command("OpencodeSessionClear", function()
  require("opencode_ask").clear_session()
end, {
  nargs = 0,
  desc = "Clear the stored OpenCode session for this project",
})

vim.api.nvim_create_user_command("OpencodeToggle", function()
  require("opencode_ask").toggle()
end, {
  nargs = 0,
  desc = "Toggle the OpenCode session viewer",
})
