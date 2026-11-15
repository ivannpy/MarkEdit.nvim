local config = require("markedit.config")
local log = require("markedit.log")
local meta = require("markedit.meta")
local server = require("markedit.server")
local tracker = require("markedit.tracker")

local M = {}

M.version = meta.version

local initialized = false

-- The server only runs while there is something to follow.
tracker.on_empty = function()
    server.stop()
end

local function notify(msg, level)
    if config.options.notify then
        vim.notify("markedit: " .. msg, level or vim.log.levels.INFO)
    end
end

local function ensure_setup()
    if not initialized then
        M.setup()
    end
end

---@param opts? markedit.Config
function M.setup(opts)
    config.setup(opts)
    tracker.setup(config.options)
    initialized = true
end

local function launch(path)
    local o = config.options
    if type(o.open) == "function" then
        return o.open(path)
    end
    if vim.fn.has("mac") == 0 then
        return notify("opening the viewer is only supported on macOS, set the `open` option to customize it", vim.log.levels.WARN)
    end

    local cmd = { "open" }
    if o.background then
        cmd[#cmd + 1] = "-g"
    end
    vim.list_extend(cmd, { "-a", o.app, path })
    vim.system(cmd, { text = true }, function(res)
        if res.code ~= 0 then
            vim.schedule(function()
                notify(("could not open %s: %s"):format(o.app, vim.trim(res.stderr or "")), vim.log.levels.ERROR)
            end)
        end
    end)
end

local handlers = {
    on_connect = function(client)
        tracker.send_to(client)
    end,
    on_disconnect = function() end,
    on_client_message = function(msg, origin)
        log.add("client", vim.json.encode(msg) .. (origin and (" origin=" .. origin) or ""))
    end,
}

local function start_server()
    local o = config.options
    local ok, result = server.start({
        host = o.host,
        port = o.port,
        token = o.token,
        allowed_origins = o.allowed_origins,
    }, handlers)
    if not ok then
        notify(
            ("could not start the bridge on %s:%d (%s). Another Neovim may already be using that port, change `port`."):format(
                o.host,
                o.port,
                tostring(result)
            ),
            vim.log.levels.ERROR
        )
    end
    return ok
end

--- Opens the current buffer in the viewer and starts following it.
function M.open()
    ensure_setup()
    local bufnr = vim.api.nvim_get_current_buf()

    if not vim.tbl_contains(config.options.filetypes, vim.bo[bufnr].filetype) then
        return notify(("filetype '%s' is not enabled, see the `filetypes` option"):format(vim.bo[bufnr].filetype), vim.log.levels.WARN)
    end

    -- The viewer reads the file from disk, so what you see must be saved first.
    if vim.bo[bufnr].modified and vim.api.nvim_buf_get_name(bufnr) ~= "" then
        vim.cmd("silent update")
    end

    local path, err = tracker.attach(bufnr)
    if not path then
        return notify(err or "cannot open this buffer", vim.log.levels.WARN)
    end
    if not start_server() then
        tracker.detach(bufnr)
        return
    end
    launch(path)
end

--- Stops following the current buffer.
function M.close()
    local bufnr = vim.api.nvim_get_current_buf()
    if not tracker.is_tracked(bufnr) then
        return notify("this buffer is not open in the viewer", vim.log.levels.WARN)
    end
    tracker.detach(bufnr)
end

function M.toggle()
    if tracker.is_tracked(vim.api.nvim_get_current_buf()) then
        M.close()
    else
        M.open()
    end
end

---@return table
function M.status()
    local clients = {}
    for _, c in ipairs(server.clients()) do
        clients[#clients + 1] = { id = c.id, path = c.path, origin = c.origin, since = c.since }
    end
    return {
        version = meta.version,
        protocol = meta.protocol,
        running = server.is_running(),
        host = config.options.host,
        port = server.port(),
        tracked = tracker.list(),
        clients = clients,
    }
end

function M.show_status()
    local s = M.status()
    local lines = {
        ("markedit.nvim %s (protocol %d)"):format(s.version, s.protocol),
        s.running and ("server: listening on %s:%d"):format(s.host, s.port) or "server: stopped",
        ("tracked buffers: %d"):format(vim.tbl_count(s.tracked)),
    }
    for bufnr, path in pairs(s.tracked) do
        lines[#lines + 1] = ("  [%d] %s"):format(bufnr, path)
    end
    lines[#lines + 1] = ("connected viewers: %d"):format(#s.clients)
    if s.running and #s.clients == 0 then
        lines[#lines + 1] = "  none yet: see :MarkEditLog for a `loaded` or `error` message from the extension"
    end
    for _, c in ipairs(s.clients) do
        lines[#lines + 1] = ("  #%d %s (origin %s)"):format(c.id, c.path, c.origin)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Opens a scratch buffer with the plugin log.
function M.show_log()
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "markedit://log")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, log.lines())
    vim.bo[buf].modifiable = false
end

return M
