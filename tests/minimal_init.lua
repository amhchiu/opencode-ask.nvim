local source = debug.getinfo(1, "S").source:sub(2)
local path = vim.uv.fs_realpath(source) or vim.fn.fnamemodify(source, ":p")
local root = vim.fs.dirname(vim.fs.dirname(path))

vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
