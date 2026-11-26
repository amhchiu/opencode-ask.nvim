local M = {}

local function error_message(message)
  return "opencode-ask: " .. message
end

--- Resolve the normalized project root.
--- Accepts 0 for the current buffer, a buffer number, or an absolute path
--- (a directory, or a file inside the project). An absolute path without a
--- .git marker falls back to that directory, so callers passing a cached
--- context.project_root get the same key back.
function M.project_root(target)
  target = target or 0

  local root
  local fallback

  if type(target) == "string" then
    local path = vim.fs.normalize(target)
    local is_file = vim.fn.isdirectory(path) == 0 and vim.fn.filereadable(path) == 1
    fallback = is_file and vim.fs.dirname(path) or path

    local ok, found = pcall(vim.fs.root, path, { ".git" })
    if ok then
      root = found
    end
  elseif target == 0 or vim.api.nvim_buf_is_valid(target) then
    local ok, found = pcall(vim.fs.root, target, { ".git" })
    if ok then
      root = found
    end
  end

  root = root or fallback or vim.fn.getcwd()
  return vim.uv.fs_realpath(root) or vim.fs.normalize(root)
end

--- Return the endpoints in ascending order.
function M.normalize(first, last)
  if first <= last then
    return first, last
  end
  return last, first
end

--- Return a path relative to root, or the absolute path when it is outside.
--- vim.fs.relpath returns nil for paths outside root (including sibling
--- directories such as /proj-2 for /proj), so no prefix matching is used.
function M.relative(absolute, root)
  return vim.fs.relpath(root, absolute) or absolute
end

--- Build the OpenCode file attachment URI for a line range.
function M.file_uri(absolute, first, last)
  return vim.uri_from_fname(absolute) .. "?start=" .. first .. "&end=" .. last
end

--- Capture the current selection as a context object.
--- opts may contain bufnr, first, and last. Without endpoints, the visual
--- selection is read from the current buffer.
function M.capture(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, error_message("cannot use an invalid buffer")
  end

  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then
    return nil, error_message(
      ("cannot ask about this buffer because its buftype is '%s'; only normal file buffers are supported"):format(
        buftype
      )
    )
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil, error_message("cannot ask about an unnamed buffer; save it to a file first")
  end

  local first = opts.first
  local last = opts.last
  if first == nil and last == nil then
    first = vim.fn.line("v")
    last = vim.fn.line(".")
  elseif first == nil then
    first = last
  elseif last == nil then
    last = first
  end

  first, last = M.normalize(first, last)
  if first < 1 then
    return nil, error_message("could not determine a line range; select lines in visual mode first")
  end

  local absolute = vim.fn.fnamemodify(name, ":p")
  local project_root = M.project_root(bufnr)
  local relative = M.relative(absolute, project_root)
  local lines = first == last and tostring(first) or (tostring(first) .. "-" .. tostring(last))

  return {
    bufnr = bufnr,
    absolute = absolute,
    relative = relative,
    project_root = project_root,
    first = first,
    last = last,
    ref = relative .. ":" .. lines,
    mention = "@" .. relative .. "#" .. lines,
    uri = M.file_uri(absolute, first, last),
  }
end

--- Save the captured buffer when saving is enabled and the buffer is modified.
--- Returns true when there is nothing to do or the save succeeded, otherwise
--- nil and a descriptive error. Invalid buffers and write failures are
--- reported rather than thrown.
function M.save(context)
  if type(context) ~= "table" then
    return nil, error_message("missing selection context")
  end

  local bufnr = context.bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, error_message("cannot save an invalid buffer")
  end

  -- Read the runtime options lazily so requiring this module cannot create a
  -- circular dependency with opencode_ask/init.lua.
  if not require("opencode_ask").options.save then
    return true
  end

  if not vim.bo[bufnr].modified then
    return true
  end

  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent update")
  end)
  if not ok then
    return nil, tostring(err)
  end

  return true
end

return M
