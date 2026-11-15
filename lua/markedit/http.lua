-- Minimal HTTP/1.1 helpers. Pure functions, no I/O, so they are easy to test.
local M = {}

M.MAX_HEADER = 16 * 1024
M.MAX_BODY = 64 * 1024

local REASONS = {
    [200] = "OK",
    [204] = "No Content",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
}

-- Allow any origin to read the responses. Access control is done by the server
-- (Host and Origin checks, optional token), not by the browser.
M.CORS = {
    ["Access-Control-Allow-Origin"] = "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type, X-MarkEdit-Token",
    ["Access-Control-Allow-Private-Network"] = "true",
    ["Access-Control-Max-Age"] = "600",
}

---@param s string
---@return string
function M.url_decode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

---@param qs string
---@return table<string, string>
function M.parse_query(qs)
    local out = {}
    for pair in (qs or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then
            out[M.url_decode(k)] = M.url_decode(v)
        end
    end
    return out
end

---@class markedit.Request
---@field method string
---@field target string
---@field path string
---@field query table<string, string>
---@field headers table<string, string>
---@field body string

--- Parses a request from the bytes received so far.
---@param buf string
---@return markedit.Request|nil|false req  nil when more data is needed, false when invalid
---@return string? err
function M.parse_request(buf)
    local header_end = buf:find("\r\n\r\n", 1, true)
    if not header_end then
        if #buf > M.MAX_HEADER then
            return false, "header too large"
        end
        return nil
    end

    local lines = vim.split(buf:sub(1, header_end - 1), "\r\n", { plain = true })
    local method, target = lines[1]:match("^(%u+) (%S+) HTTP/1%.[01]$")
    if not method then
        return false, "bad request line"
    end

    local headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([^:]+):%s*(.-)%s*$")
        if name then
            headers[name:lower()] = value
        end
    end

    local length = tonumber(headers["content-length"] or "0") or 0
    if length < 0 or length > M.MAX_BODY then
        return false, "body too large"
    end
    local body_start = header_end + 4
    if #buf - body_start + 1 < length then
        return nil
    end

    local path, qs = target:match("^([^?]*)%??(.*)$")
    return {
        method = method,
        target = target,
        path = path,
        query = M.parse_query(qs),
        headers = headers,
        body = buf:sub(body_start, body_start + length - 1),
    }
end

---@param status integer
---@param headers? table<string, string>
---@param body? string
---@return string
function M.response(status, headers, body)
    body = body or ""
    local merged = vim.tbl_extend("force", {
        ["Content-Length"] = tostring(#body),
        ["Connection"] = "close",
    }, M.CORS, headers or {})
    local lines = { ("HTTP/1.1 %d %s"):format(status, REASONS[status] or "Unknown") }
    for k, v in pairs(merged) do
        lines[#lines + 1] = k .. ": " .. v
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

---@param status integer
---@param tbl table
---@return string
function M.json_response(status, tbl)
    return M.response(status, { ["Content-Type"] = "application/json" }, vim.json.encode(tbl))
end

--- Response head that opens a Server-Sent Events stream.
---@return string
function M.sse_head()
    local lines = {
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Connection: keep-alive",
        "X-Accel-Buffering: no",
    }
    for k, v in pairs(M.CORS) do
        lines[#lines + 1] = k .. ": " .. v
    end
    -- `retry` makes EventSource reconnect quickly when nvim restarts.
    return table.concat(lines, "\r\n") .. "\r\n\r\nretry: 1000\n\n"
end

---@param name string
---@param data table
---@return string
function M.sse_event(name, data)
    return ("event: %s\ndata: %s\n\n"):format(name, vim.json.encode(data))
end

return M
