-- Local HTTP server that pushes events to the MarkEdit extension.
--
-- The extension opens `GET /events?path=<file>` and keeps the connection open
-- (Server-Sent Events). The server only listens on a loopback address and
-- refuses requests that do not look like they come from the extension.
local uv = vim.uv or vim.loop
local http = require("markedit.http")
local log = require("markedit.log")
local meta = require("markedit.meta")

local M = {}

local HEADER_TIMEOUT_MS = 5000
local PING_INTERVAL_MS = 15000

---@class markedit.Client
---@field id integer
---@field sock userdata
---@field path string      real path of the file the client displays
---@field origin string
---@field since integer

local S = {
    tcp = nil,
    port = nil,
    opts = nil,
    handlers = {},
    clients = {},
    next_id = 0,
    ping = nil,
}

local function close_handle(handle)
    if handle and not handle:is_closing() then
        handle:close()
    end
end

local function write(sock, data, cb)
    if sock:is_closing() then
        return false
    end
    local ok = pcall(sock.write, sock, data, cb)
    return ok
end

--- Writes a response and closes the connection afterwards.
local function finish(sock, data)
    write(sock, data, function()
        close_handle(sock)
    end)
end

local function normalize(path)
    return uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function host_allowed(req)
    local host = req.headers.host
    if not host then
        return false
    end
    host = host:lower()
    local port = tostring(S.port)
    return host == "127.0.0.1:" .. port or host == "localhost:" .. port or host == "[::1]:" .. port
end

--- Web pages always send an http(s) Origin; the extension runs inside an app
--- webview and does not. Rejecting http(s) origins keeps websites out.
local function origin_allowed(req)
    local origin = req.headers.origin
    if not origin or origin == "null" then
        return true
    end
    if origin:match("^https?://") then
        return vim.tbl_contains(S.opts.allowed_origins or {}, origin)
    end
    return true
end

local function token_ok(req)
    local token = S.opts.token
    if not token or token == "" then
        return true
    end
    return req.query.token == token or req.headers["x-markedit-token"] == token
end

local function drop(client)
    if not S.clients[client.id] then
        return
    end
    S.clients[client.id] = nil
    close_handle(client.sock)
    log.add("server", ("client %d disconnected (%s)"):format(client.id, client.path))
    local on_disconnect = S.handlers.on_disconnect
    if on_disconnect then
        vim.schedule(function()
            on_disconnect(client)
        end)
    end
end

local function open_stream(sock, req)
    local path = req.query.path
    if not path or path == "" then
        return finish(sock, http.json_response(400, { error = "missing `path` query parameter" }))
    end

    S.next_id = S.next_id + 1
    local client = {
        id = S.next_id,
        sock = sock,
        path = normalize(path),
        origin = req.headers.origin or "(none)",
        since = os.time(),
    }
    S.clients[client.id] = client
    log.add("server", ("client %d connected for %s (origin %s)"):format(client.id, client.path, client.origin))

    write(sock, http.sse_head())
    M.send(client, "hello", { protocol = meta.protocol, server = meta.name, version = meta.version })

    sock:read_start(function(err, chunk)
        -- The stream is one way; anything the client sends is ignored.
        if err or not chunk then
            drop(client)
        end
    end)

    local on_connect = S.handlers.on_connect
    if on_connect then
        vim.schedule(function()
            on_connect(client)
        end)
    end
end

local function route(sock, req)
    if not host_allowed(req) then
        log.add("server", "rejected request with bad Host: " .. tostring(req.headers.host))
        return finish(sock, http.json_response(403, { error = "forbidden host" }))
    end
    if not origin_allowed(req) then
        log.add("server", "rejected request from origin " .. tostring(req.headers.origin))
        return finish(sock, http.json_response(403, { error = "forbidden origin" }))
    end
    if req.method == "OPTIONS" then
        return finish(sock, http.response(204))
    end
    if not token_ok(req) then
        log.add("server", "rejected request with a missing or wrong token")
        return finish(sock, http.json_response(401, { error = "invalid token" }))
    end

    if req.method == "GET" and req.path == "/tracks" then
        -- Lets the extension find which of several Neovims follows its file.
        local path = req.query.path
        if not path or path == "" then
            return finish(sock, http.json_response(400, { error = "missing `path` query parameter" }))
        end
        local is_tracked = S.handlers.is_tracked
        return finish(sock, http.json_response(200, {
            server = meta.name,
            version = meta.version,
            protocol = meta.protocol,
            tracked = is_tracked ~= nil and is_tracked(normalize(path)) or false,
        }))
    elseif req.method == "GET" and (req.path == "/" or req.path == "/hello") then
        return finish(sock, http.json_response(200, {
            server = meta.name,
            version = meta.version,
            protocol = meta.protocol,
        }))
    elseif req.method == "GET" and req.path == "/events" then
        return open_stream(sock, req)
    elseif req.method == "POST" and req.path == "/client" then
        -- Diagnostics reported by the extension (see docs/protocol.md).
        local ok, msg = pcall(vim.json.decode, req.body)
        if ok and type(msg) == "table" then
            local on_message = S.handlers.on_client_message
            if on_message then
                vim.schedule(function()
                    on_message(msg, req.headers.origin)
                end)
            end
            return finish(sock, http.response(204))
        end
        return finish(sock, http.json_response(400, { error = "body is not valid JSON" }))
    end
    return finish(sock, http.json_response(404, { error = "not found" }))
end

local function on_connection(err)
    if err then
        return
    end
    local sock = uv.new_tcp()
    S.tcp:accept(sock)

    local buf = ""
    local handled = false
    local timer = uv.new_timer()
    local function stop_timer()
        if timer then
            timer:stop()
            close_handle(timer)
            timer = nil
        end
    end
    timer:start(HEADER_TIMEOUT_MS, 0, function()
        if not handled then
            stop_timer()
            close_handle(sock)
        end
    end)

    sock:read_start(function(rerr, chunk)
        if handled then
            return
        end
        if rerr or not chunk then
            stop_timer()
            close_handle(sock)
            return
        end
        buf = buf .. chunk
        local req, perr = http.parse_request(buf)
        if req == nil then
            return
        end
        handled = true
        stop_timer()
        if req == false then
            log.add("server", "bad request: " .. tostring(perr))
            return finish(sock, http.json_response(perr == "header too large" and 431 or 400, { error = perr }))
        end
        route(sock, req)
    end)
end

--- Listens on one port. libuv may report a busy port in `bind` or in `listen`.
---@return userdata? tcp
---@return string? err
---@return string? code  libuv error name, e.g. "EADDRINUSE"
local function listen(host, port)
    local tcp = uv.new_tcp()
    local ok, err, code = tcp:bind(host, port)
    if ok then
        ok, err, code = tcp:listen(128, on_connection)
    end
    if not ok then
        close_handle(tcp)
        return nil, err or "could not listen", code
    end
    return tcp
end

--- Last port of the range a configuration allows.
---@param port integer
---@param count? integer
---@return integer
function M.last_port(port, count)
    if port == 0 then
        return 0
    end
    return math.max(port, math.min(port + (count or 1) - 1, 65535))
end

--- Starts the server on the first free port of the range.
---@param opts { host: string, port: integer, port_count?: integer, token?: string, allowed_origins?: string[] }
---@param handlers { on_connect?: fun(client: markedit.Client), on_disconnect?: fun(client: markedit.Client), on_client_message?: fun(msg: table, origin?: string), is_tracked?: fun(path: string): boolean }
---@return boolean ok
---@return integer|string result  the port on success, an error message otherwise
function M.start(opts, handlers)
    if S.tcp then
        return true, S.port
    end

    local tcp, err, code
    for port = opts.port, M.last_port(opts.port, opts.port_count) do
        tcp, err, code = listen(opts.host, port)
        -- Only a busy port is worth trying the next one.
        if tcp or code ~= "EADDRINUSE" then
            break
        end
        log.add("server", ("port %d is busy"):format(port))
    end
    if not tcp then
        return false, err
    end

    S.tcp = tcp
    S.port = tcp:getsockname().port
    S.opts = opts
    S.handlers = handlers or {}

    S.ping = uv.new_timer()
    S.ping:start(PING_INTERVAL_MS, PING_INTERVAL_MS, function()
        for _, client in pairs(S.clients) do
            if not write(client.sock, ": ping\n\n") then
                drop(client)
            end
        end
    end)

    log.add("server", ("listening on %s:%d"):format(opts.host, S.port))
    return true, S.port
end

function M.stop()
    if not S.tcp then
        return
    end
    for _, client in pairs(S.clients) do
        close_handle(client.sock)
    end
    S.clients = {}
    if S.ping then
        S.ping:stop()
        close_handle(S.ping)
    end
    close_handle(S.tcp)
    log.add("server", "stopped")
    S.tcp, S.port, S.opts, S.ping, S.handlers = nil, nil, nil, nil, {}
end

---@return boolean
function M.is_running()
    return S.tcp ~= nil
end

---@return integer?
function M.port()
    return S.port
end

---@return markedit.Client[]
function M.clients()
    local out = {}
    for _, client in pairs(S.clients) do
        out[#out + 1] = client
    end
    table.sort(out, function(a, b)
        return a.id < b.id
    end)
    return out
end

---@param client markedit.Client
---@param event string
---@param data table
function M.send(client, event, data)
    if not write(client.sock, http.sse_event(event, data)) then
        drop(client)
    end
end

--- Sends an event to every client displaying `path` (all clients when nil).
---@param path string|nil
---@param event string
---@param data table
---@return integer count  clients the event was sent to
function M.broadcast(path, event, data)
    local count = 0
    for _, client in pairs(S.clients) do
        if path == nil or client.path == path then
            M.send(client, event, data)
            count = count + 1
        end
    end
    return count
end

return M
