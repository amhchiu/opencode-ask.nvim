local selection = require("opencode_ask.selection")

local function make_project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root) or root
  vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p")
  vim.fn.mkdir(vim.fs.joinpath(root, "src"), "p")
  return root
end

local function file_lines(count)
  local lines = {}
  for i = 1, count do
    lines[i] = "line " .. i
  end
  return lines
end

local function named_buffer(path, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function loaded_buffer(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  return bufnr
end

local function cleanup(root, bufnrs)
  for _, bufnr in ipairs(bufnrs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  if root then
    vim.fn.delete(root, "rf")
  end
end

return function(t)
  t.test("normalize orders reversed and single-line ranges", function()
    local first, last = selection.normalize(7, 3)
    t.equal(3, first, "reversed range start")
    t.equal(7, last, "reversed range end")

    first, last = selection.normalize(5, 5)
    t.equal(5, first, "single-line start")
    t.equal(5, last, "single-line end")
  end)

  t.test("relative resolves inside paths and falls back outside", function()
    t.equal("src/a.lua", selection.relative("/proj/src/a.lua", "/proj"))
    t.equal("src/a file.lua", selection.relative("/proj/src/a file.lua", "/proj"))
    t.equal("/proj-2/src/a.lua", selection.relative("/proj-2/src/a.lua", "/proj"))
    t.equal("/other/a.lua", selection.relative("/other/a.lua", "/proj"))
  end)

  t.test("file_uri percent-encodes spaces and appends the range", function()
    t.equal(
      "file:///tmp/my%20project/a%20file.lua?start=2&end=4",
      selection.file_uri("/tmp/my project/a file.lua", 2, 4)
    )
  end)

  t.test("project_root accepts bufnr 0", function()
    local root = make_project()
    local previous = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(root))

    local ok, resolved = pcall(selection.project_root, 0)

    vim.cmd("cd " .. vim.fn.fnameescape(previous))
    cleanup(root)

    t.assert(ok, "project_root should not throw: " .. tostring(resolved))
    t.equal(root, resolved)
  end)

  t.test("project_root finds and normalizes a buffer project root", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "rooted.lua")
    local bufnr = named_buffer(path, { "one line" })

    local resolved = selection.project_root(bufnr)
    cleanup(root, { bufnr })

    t.equal(root, resolved)
  end)

  t.test("capture builds a range context for a file with spaces", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "my file.lua")
    local lines = file_lines(10)
    vim.fn.writefile(lines, path)
    local bufnr = named_buffer(path, lines)

    local ok, context = pcall(selection.capture, { bufnr = bufnr, first = 3, last = 7 })
    cleanup(root, { bufnr })

    t.assert(ok, "capture should not throw: " .. tostring(context))
    t.equal(bufnr, context.bufnr)
    t.equal(path, context.absolute)
    t.equal(root, context.project_root)
    t.equal("src/my file.lua", context.relative)
    t.equal(3, context.first)
    t.equal(7, context.last)
    t.equal("src/my file.lua:3-7", context.ref)
    t.equal("@src/my file.lua#3-7", context.mention)
    t.matches("my%%20file%.lua%?start=3&end=7$", context.uri)
  end)

  t.test("capture formats a single-line ref and mention", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "single.lua")
    local lines = file_lines(5)
    vim.fn.writefile(lines, path)
    local bufnr = named_buffer(path, lines)

    local ok, context = pcall(selection.capture, { bufnr = bufnr, first = 5, last = 5 })
    cleanup(root, { bufnr })

    t.assert(ok, "capture should not throw: " .. tostring(context))
    t.equal(5, context.first)
    t.equal(5, context.last)
    t.equal("src/single.lua:5", context.ref)
    t.equal("@src/single.lua#5", context.mention)
    t.matches("%?start=5&end=5$", context.uri)
  end)

  t.test("capture normalizes reversed endpoints", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "reversed.lua")
    local lines = file_lines(8)
    vim.fn.writefile(lines, path)
    local bufnr = named_buffer(path, lines)

    local ok, context = pcall(selection.capture, { bufnr = bufnr, first = 7, last = 2 })
    cleanup(root, { bufnr })

    t.assert(ok, "capture should not throw: " .. tostring(context))
    t.equal(2, context.first)
    t.equal(7, context.last)
    t.equal("src/reversed.lua:2-7", context.ref)
    t.equal("@src/reversed.lua#2-7", context.mention)
  end)

  t.test("capture uses a lone first line for both endpoints", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "lone.lua")
    local lines = file_lines(6)
    vim.fn.writefile(lines, path)
    local bufnr = named_buffer(path, lines)

    local ok, context = pcall(selection.capture, { bufnr = bufnr, first = 4 })
    cleanup(root, { bufnr })

    t.assert(ok, "capture should not throw: " .. tostring(context))
    t.equal(4, context.first)
    t.equal(4, context.last)
    t.equal("src/lone.lua:4", context.ref)
  end)

  t.test("capture rejects an unnamed buffer without throwing", function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    local ok, context, err = pcall(selection.capture, { bufnr = bufnr, first = 1, last = 1 })
    vim.api.nvim_buf_delete(bufnr, { force = true })

    t.assert(ok, "capture should not throw")
    t.equal(nil, context, "capture should return nil")
    t.matches("unnamed", err, "error should mention the unnamed buffer")
  end)

  t.test("capture rejects a non-file buffer without throwing", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok, context, err = pcall(selection.capture, { bufnr = bufnr, first = 1, last = 1 })
    vim.api.nvim_buf_delete(bufnr, { force = true })

    t.assert(ok, "capture should not throw")
    t.equal(nil, context, "capture should return nil")
    t.matches("buftype", err, "error should mention the buffer type")
  end)

  t.test("save writes a modified buffer when enabled", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "saved.lua")
    vim.fn.writefile({ "old" }, path)
    local bufnr = loaded_buffer(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new" })

    local ok, result, err = pcall(selection.save, { bufnr = bufnr })
    local contents = vim.fn.readfile(path)
    cleanup(root, { bufnr })

    t.assert(ok, "save should not throw: " .. tostring(result) .. " " .. tostring(err))
    t.equal(true, result)
    t.equal({ "new" }, contents)
  end)

  t.test("save is a no-op when disabled", function()
    local plugin = require("opencode_ask")
    local previous = plugin.options.save
    plugin.options.save = false

    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "disabled.lua")
    vim.fn.writefile({ "old" }, path)
    local bufnr = loaded_buffer(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new" })

    local ok, result, err = pcall(selection.save, { bufnr = bufnr })
    plugin.options.save = previous
    local contents = vim.fn.readfile(path)
    cleanup(root, { bufnr })

    t.assert(ok, "save should not throw: " .. tostring(result) .. " " .. tostring(err))
    t.equal(true, result)
    t.equal({ "old" }, contents, "disabled save should leave the file untouched")
  end)

  t.test("save reports read-only failures without throwing", function()
    local root = make_project()
    local path = vim.fs.joinpath(root, "src", "readonly.lua")
    vim.fn.writefile({ "old" }, path)
    local bufnr = loaded_buffer(path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new" })
    vim.bo[bufnr].readonly = true

    local ok, result, err = pcall(selection.save, { bufnr = bufnr })
    cleanup(root, { bufnr })

    t.assert(ok, "save should not throw")
    t.equal(nil, result, "save should fail")
    t.matches("readonly", tostring(err), "error should explain the read-only failure")
  end)

  t.test("save guards invalid buffers without throwing", function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    local ok, result, err = pcall(selection.save, { bufnr = bufnr })
    t.assert(ok, "save should not throw")
    t.equal(nil, result, "save should fail")
    t.matches("invalid", tostring(err), "error should mention the invalid buffer")
  end)
end
