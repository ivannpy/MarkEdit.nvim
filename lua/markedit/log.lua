-- Small in-memory ring buffer so problems can be inspected with :MarkEditLog.
local M = {}

local MAX = 200
local entries = {}

---@param source string  where the message comes from ("server", "client", ...)
---@param message string
function M.add(source, message)
    entries[#entries + 1] = { time = os.time(), source = source, message = message }
    if #entries > MAX then
        table.remove(entries, 1)
    end
end

---@return string[]
function M.lines()
    local out = {}
    for _, e in ipairs(entries) do
        out[#out + 1] = ("%s [%s] %s"):format(os.date("%H:%M:%S", e.time), e.source, e.message)
    end
    return out
end

function M.clear()
    entries = {}
end

return M
