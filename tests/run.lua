-- Minimal test runner. Usage (from the repository root):
--   nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. package.path

local files = { "tests/http_test.lua", "tests/bridge_test.lua" }

local passed, failed = 0, 0

for _, file in ipairs(files) do
    local suite = dofile(root .. "/" .. file)
    for _, case in ipairs(suite) do
        local ok, err = xpcall(case.fn, debug.traceback)
        if ok then
            passed = passed + 1
            print(("ok     %s :: %s"):format(file, case.name))
        else
            failed = failed + 1
            print(("FAILED %s :: %s\n%s"):format(file, case.name, err))
        end
    end
end

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
