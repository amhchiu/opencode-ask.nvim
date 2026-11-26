local source = debug.getinfo(1, "S").source:sub(2)
local run_path = vim.uv.fs_realpath(source) or vim.fn.fnamemodify(source, ":p")
local tests_dir = vim.fs.dirname(run_path)
local spec_dir = vim.fs.joinpath(tests_dir, "spec")

local harness = dofile(vim.fs.joinpath(tests_dir, "harness.lua"))

local ok, iterator = pcall(vim.fs.dir, spec_dir)
if not ok then
  print("FAIL could not read spec directory " .. spec_dir .. ": " .. tostring(iterator))
  os.exit(1)
end

local specs = {}
for name, kind in iterator do
  if kind == "file" and name:match("_spec%.lua$") then
    table.insert(specs, name)
  end
end
table.sort(specs)

for _, name in ipairs(specs) do
  local path = vim.fs.joinpath(spec_dir, name)
  local chunk, load_err = loadfile(path)
  if not chunk then
    print("FAIL could not load " .. path .. ": " .. tostring(load_err))
    os.exit(1)
  end

  local load_ok, register = pcall(chunk)
  if not load_ok then
    print("FAIL could not evaluate " .. path .. ": " .. tostring(register))
    os.exit(1)
  end
  if type(register) ~= "function" then
    print("FAIL " .. path .. " must return a function(harness)")
    os.exit(1)
  end

  local register_ok, register_err = pcall(register, harness)
  if not register_ok then
    print("FAIL could not register " .. path .. ": " .. tostring(register_err))
    os.exit(1)
  end
end

os.exit(harness.run() and 0 or 1)
