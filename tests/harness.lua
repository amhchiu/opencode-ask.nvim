local M = {
  cases = {},
  passed = 0,
  failed = 0,
}

local function inspect(value)
  return vim.inspect(value):gsub("\n", "\n    ")
end

local function fail(message, level)
  error(message, (level or 1) + 1)
end

--- Register a test case.
function M.test(name, fn)
  table.insert(M.cases, { name = name, fn = fn })
end

function M.assert(condition, message)
  if not condition then
    fail(message or "expected a truthy value", 2)
  end
end

function M.equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail(
      (message or "values differ")
        .. "\n  expected: "
        .. inspect(expected)
        .. "\n  actual:   "
        .. inspect(actual),
      2
    )
  end
end

function M.matches(pattern, value, message)
  if type(value) ~= "string" then
    fail((message or "expected a string") .. " (got " .. type(value) .. ")", 2)
  end
  if not value:find(pattern) then
    fail(
      (message or "value does not match pattern")
        .. "\n  pattern: "
        .. pattern
        .. "\n  value:   "
        .. value,
      2
    )
  end
end

function M.remove(path)
  if path and vim.uv.fs_stat(path) then
    vim.fn.delete(path, "rf")
  end
end

--- Run every registered test and print a summary. Returns true on success.
function M.run()
  print("")
  for _, case in ipairs(M.cases) do
    local ok, err = pcall(case.fn)
    if ok then
      M.passed = M.passed + 1
      print(("PASS %s"):format(case.name))
    else
      M.failed = M.failed + 1
      print(("FAIL %s"):format(case.name))
      print("  " .. tostring(err):gsub("\n", "\n  "))
    end
  end

  local total = M.passed + M.failed
  print("")
  print(("Tests: %d total, %d passed, %d failed"):format(total, M.passed, M.failed))
  return M.failed == 0
end

return M
