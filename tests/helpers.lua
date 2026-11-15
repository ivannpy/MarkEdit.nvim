-- Helpers shared by the test files: assertions and a tiny HTTP / SSE client.
local uv = vim.uv or vim.loop

local H = {}

function H.eq(actual, expected, msg)
    if not vim.deep_equal(actual, expected) then
        error(
            ("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
            2
        )
    end
end

function H.truthy(value, msg)
    if not value then
        error(msg or "expected a truthy value", 2)
    end
end

function H.wait(cond, msg, timeout)
    local ok = vim.wait(timeout or 2000, cond, 10)
    if not ok then
        error("timed out waiting for: " .. (msg or "condition"), 2)
    end
end

---@param port integer
---@param raw string  full raw HTTP request
---@return { status: integer, headers: table<string,string>, body: string }
function H.request(port, raw)
    local sock = uv.new_tcp()
    local data, done = "", false
    sock:connect("127.0.0.1", port, function(err)
        assert(not err, err)
        sock:write(raw)
        sock:read_start(function(_, chunk)
            if chunk then
                data = data .. chunk
            else
                done = true
                sock:close()
            end
        end)
    end)
    H.wait(function()
        return done
    end, "HTTP response")

    local head, body = data:match("^(.-)\r\n\r\n(.*)$")
    local status = tonumber(head:match("^HTTP/1%.1 (%d+)"))
    local headers = {}
    for name, value in head:gmatch("\r\n([^:]+):%s*([^\r]*)") do
        headers[name:lower()] = value
    end
    return { status = status, headers = headers, body = body }
end

---@param port integer
---@param target string  request target, e.g. "/hello"
---@param headers? table<string,string>
function H.get(port, target, headers)
    local h = vim.tbl_extend("force", { Host = "127.0.0.1:" .. port }, headers or {})
    local lines = { "GET " .. target .. " HTTP/1.1" }
    for k, v in pairs(h) do
        lines[#lines + 1] = k .. ": " .. v
    end
    return H.request(port, table.concat(lines, "\r\n") .. "\r\n\r\n")
end

---@param port integer
---@param target string
---@param body string
---@param headers? table<string,string>
function H.post(port, target, body, headers)
    local h = vim.tbl_extend("force", { Host = "127.0.0.1:" .. port, ["Content-Length"] = tostring(#body) }, headers or {})
    local lines = { "POST " .. target .. " HTTP/1.1" }
    for k, v in pairs(h) do
        lines[#lines + 1] = k .. ": " .. v
    end
    return H.request(port, table.concat(lines, "\r\n") .. "\r\n\r\n" .. body)
end

---@class TestStream
---@field events { name: string, data: table }[]
---@field status integer?
---@field closed boolean
---@field close fun()

--- Opens a Server-Sent Events stream and collects the events it receives.
---@param port integer
---@param target string
---@param headers? table<string,string>
---@return TestStream
function H.stream(port, target, headers)
    local sock = uv.new_tcp()
    local stream = { events = {}, closed = false, status = nil }
    local buf, head_done = "", false

    local h = vim.tbl_extend("force", { Host = "127.0.0.1:" .. port }, headers or {})
    local lines = { "GET " .. target .. " HTTP/1.1" }
    for k, v in pairs(h) do
        lines[#lines + 1] = k .. ": " .. v
    end

    local function consume()
        if not head_done then
            local head_end = buf:find("\r\n\r\n", 1, true)
            if not head_end then
                return
            end
            stream.status = tonumber(buf:match("^HTTP/1%.1 (%d+)"))
            buf = buf:sub(head_end + 4)
            head_done = true
        end
        while true do
            local sep = buf:find("\n\n", 1, true)
            if not sep then
                return
            end
            local block = buf:sub(1, sep - 1)
            buf = buf:sub(sep + 2)
            local name, data = block:match("^event: ([^\n]+)\ndata: (.*)$")
            if name then
                stream.events[#stream.events + 1] = { name = name, data = vim.json.decode(data) }
            end
        end
    end

    sock:connect("127.0.0.1", port, function(err)
        assert(not err, err)
        sock:write(table.concat(lines, "\r\n") .. "\r\n\r\n")
        sock:read_start(function(_, chunk)
            if chunk then
                buf = buf .. chunk
                consume()
            else
                stream.closed = true
                if not sock:is_closing() then
                    sock:close()
                end
            end
        end)
    end)

    function stream.close()
        if not sock:is_closing() then
            sock:close()
        end
    end

    return stream
end

---@param stream TestStream
---@param name string
---@param timeout? integer
---@return table data  payload of the first event with that name not seen before
function H.next_event(stream, name, timeout)
    stream._seen = stream._seen or 0
    local found
    H.wait(function()
        for i = stream._seen + 1, #stream.events do
            if stream.events[i].name == name then
                stream._seen = i
                found = stream.events[i].data
                return true
            end
        end
        return false
    end, "event '" .. name .. "'", timeout)
    return found
end

--- Creates a markdown file in a fresh temporary directory.
---@param lines string[]
---@return string path
function H.tempfile(lines)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/doc.md"
    vim.fn.writefile(lines, path)
    return path
end

return H
