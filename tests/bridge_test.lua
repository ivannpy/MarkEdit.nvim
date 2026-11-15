local h = require("tests.helpers")
local markedit = require("markedit")
local server = require("markedit.server")
local tracker = require("markedit.tracker")
local log = require("markedit.log")

local opened

--- Starts a fresh bridge on a free port for one test.
local function fresh(extra)
    server.stop()
    tracker.detach_all()
    log.clear()
    opened = nil
    markedit.setup(vim.tbl_deep_extend("force", {
        port = 0,
        notify = false,
        sync = { debounce = 10 },
        autosave = { debounce = 20 },
        open = function(path)
            opened = path
        end,
    }, extra or {}))
end

--- Opens a markdown file in the current window and in the viewer.
local function open_doc(lines)
    local path = h.tempfile(lines or { "# one", "", "two", "three" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "markdown"
    markedit.open()
    return path, server.port()
end

local function case(name, fn)
    return { name = name, fn = fn }
end

return {
    case("GET / describes the server", function()
        fresh()
        open_doc()
        local res = h.get(server.port(), "/")
        h.eq(res.status, 200)
        local body = vim.json.decode(res.body)
        h.eq(body.server, "markedit.nvim")
        h.eq(body.protocol, 1)
    end),

    case("open() tracks the buffer and launches the viewer with its path", function()
        fresh()
        local path = open_doc()
        h.truthy(tracker.is_tracked(vim.api.nvim_get_current_buf()))
        h.eq(opened, vim.uv.fs_realpath(path))
    end),

    case("requests with a foreign Host header are rejected", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/", { Host = "evil.example:" .. port }).status, 403)
    end),

    case("requests coming from web pages are rejected", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/", { Origin = "https://evil.example" }).status, 403)
        h.eq(h.get(port, "/", { Origin = "http://localhost:3000" }).status, 403)
    end),

    case("app webview origins are accepted", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/", { Origin = "null" }).status, 200)
        h.eq(h.get(port, "/", { Origin = "file://" }).status, 200)
        h.eq(h.get(port, "/", { Origin = "markedit://editor" }).status, 200)
    end),

    case("the origin reported by MarkEdit's webview is accepted by default", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/", { Origin = "http://localhost" }).status, 200)
        local res = h.post(port, "/client", vim.json.encode({ type = "loaded" }), { Origin = "http://localhost" })
        h.eq(res.status, 204)
    end),

    case("only that exact localhost origin is allowed, not other ports or hosts", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/", { Origin = "http://localhost:8080" }).status, 403)
        h.eq(h.get(port, "/", { Origin = "http://127.0.0.1" }).status, 403)
        h.eq(h.get(port, "/", { Origin = "http://evil.localhost" }).status, 403)
    end),

    case("allowed_origins replaces the default list", function()
        fresh({ allowed_origins = { "http://localhost:3000" } })
        local _, port = open_doc()
        h.eq(h.get(port, "/", { Origin = "http://localhost:3000" }).status, 200)
        h.eq(h.get(port, "/", { Origin = "http://localhost" }).status, 403)
    end),

    case("a token is required when configured", function()
        fresh({ token = "s3cret" })
        local _, port = open_doc()
        h.eq(h.get(port, "/").status, 401)
        h.eq(h.get(port, "/?token=wrong").status, 401)
        h.eq(h.get(port, "/?token=s3cret").status, 200)
        h.eq(h.get(port, "/", { ["X-MarkEdit-Token"] = "s3cret" }).status, 200)
    end),

    case("unknown routes return 404 and bad methods are not served", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/nope").status, 404)
        h.eq(h.post(port, "/events", "{}").status, 404)
    end),

    case("/events requires a path", function()
        fresh()
        local _, port = open_doc()
        h.eq(h.get(port, "/events").status, 400)
    end),

    case("a client receives hello and then the cursor of its file", function()
        fresh()
        local path, port = open_doc({ "# title", "", "body text" })
        vim.api.nvim_win_set_cursor(0, { 3, 2 })
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        local hello = h.next_event(stream, "hello")
        h.eq(hello.protocol, 1)
        h.eq(stream.status, 200)
        h.eq(h.next_event(stream, "open").path, vim.uv.fs_realpath(path))
        local cursor = h.next_event(stream, "cursor")
        h.eq(cursor.line, 3)
        h.eq(cursor.col, 2)
        h.eq(cursor.total, 3)
        h.eq(cursor.path, vim.uv.fs_realpath(path))
        stream.close()
    end),

    case("a viewer connected before open() is told when following starts", function()
        fresh()
        local path = h.tempfile({ "a", "b" })
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.bo.filetype = "markdown"
        -- another file keeps the server alive while this one is not tracked yet
        local other = h.tempfile({ "other" })
        vim.cmd("edit " .. vim.fn.fnameescape(other))
        vim.bo.filetype = "markdown"
        markedit.open()
        local stream = h.stream(server.port(), "/events?path=" .. vim.uri_encode(path))
        h.next_event(stream, "hello")
        vim.wait(100)
        for _, event in ipairs(stream.events) do
            h.truthy(event.name ~= "open", "an untracked file must not be locked")
        end
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.bo.filetype = "markdown"
        markedit.open()
        h.eq(h.next_event(stream, "open").path, vim.uv.fs_realpath(path))
        stream.close()
    end),

    case("moving the cursor sends a new cursor event", function()
        fresh()
        local path, port = open_doc({ "a", "b", "c", "d" })
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        h.next_event(stream, "cursor")
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", {})
        local cursor = h.next_event(stream, "cursor")
        h.eq(cursor.line, 4)
        stream.close()
    end),

    case("the column is reported in UTF-16 units", function()
        fresh()
        -- the emoji takes 4 bytes in UTF-8 and 2 code units in UTF-16
        local path, port = open_doc({ "😀abc" })
        vim.api.nvim_win_set_cursor(0, { 1, 4 })
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        local cursor = h.next_event(stream, "cursor")
        h.eq(cursor.col, 2)
        stream.close()
    end),

    case("a symlinked path reaches the same buffer", function()
        fresh()
        local path, port = open_doc({ "x", "y" })
        local link = vim.fn.tempname() .. ".md"
        vim.uv.fs_symlink(path, link)
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(link))
        local cursor = h.next_event(stream, "cursor")
        h.eq(cursor.path, vim.uv.fs_realpath(path))
        stream.close()
    end),

    case("events only go to clients showing that file", function()
        fresh()
        local path, port = open_doc({ "a", "b" })
        local other = h.tempfile({ "other" })
        local mine = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        local theirs = h.stream(port, "/events?path=" .. vim.uri_encode(other))
        h.next_event(mine, "cursor")
        h.next_event(theirs, "hello")
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", {})
        h.next_event(mine, "cursor")
        vim.wait(100)
        for _, event in ipairs(theirs.events) do
            h.truthy(event.name ~= "cursor", "the other client must not receive cursor events")
        end
        mine.close()
        theirs.close()
    end),

    case("writing the file sends a saved event", function()
        fresh()
        local path, port = open_doc()
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        h.next_event(stream, "cursor")
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# changed" })
        vim.cmd("silent write")
        local saved = h.next_event(stream, "saved")
        h.eq(saved.path, vim.uv.fs_realpath(path))
        stream.close()
    end),

    case("autosave writes the buffer and announces it", function()
        fresh()
        local path, port = open_doc({ "before" })
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        h.next_event(stream, "cursor")
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { "after" })
        vim.api.nvim_exec_autocmds("TextChanged", {})
        h.next_event(stream, "saved")
        h.eq(vim.fn.readfile(path), { "after" })
        stream.close()
    end),

    case("autosave can be turned off", function()
        fresh({ autosave = { enabled = false } })
        local path = open_doc({ "before" })
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { "after" })
        vim.api.nvim_exec_autocmds("TextChanged", {})
        vim.wait(150)
        h.eq(vim.fn.readfile(path), { "before" })
    end),

    case("close() sends a close event and stops the server", function()
        fresh()
        local path, port = open_doc()
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        h.next_event(stream, "hello")
        markedit.close()
        local closed = h.next_event(stream, "close")
        h.eq(closed.path, vim.uv.fs_realpath(path))
        h.truthy(not tracker.is_tracked(vim.api.nvim_get_current_buf()))
        h.truthy(not server.is_running())
    end),

    case("wiping a followed buffer stops the server", function()
        fresh()
        open_doc()
        local bufnr = vim.api.nvim_get_current_buf()
        h.truthy(server.is_running())
        vim.cmd("enew")
        vim.cmd("bwipeout " .. bufnr)
        h.eq(tracker.count(), 0)
        h.truthy(not server.is_running())
    end),

    case("leaving Neovim says bye to every client", function()
        fresh()
        local path, port = open_doc()
        local stream = h.stream(port, "/events?path=" .. vim.uri_encode(path))
        h.next_event(stream, "hello")
        vim.api.nvim_exec_autocmds("VimLeavePre", {})
        h.next_event(stream, "bye")
        h.truthy(not server.is_running())
    end),

    case("POST /client stores diagnostics in the log", function()
        fresh()
        local _, port = open_doc()
        local res = h.post(port, "/client", vim.json.encode({ type = "ready", lines = 12 }))
        h.eq(res.status, 204)
        h.wait(function()
            return vim.tbl_contains(
                vim.tbl_map(function(l)
                    return l:find('"type":"ready"', 1, true) ~= nil
                end, log.lines()),
                true
            )
        end, "the diagnostic in the log")
        h.eq(h.post(port, "/client", "not json").status, 400)
    end),

    case("starting on a busy port reports an error", function()
        fresh()
        -- hold a port with a plain listener, then try to serve on it
        local holder = vim.uv.new_tcp()
        holder:bind("127.0.0.1", 0)
        holder:listen(1, function() end)
        local busy = holder:getsockname().port

        local ok, err = server.start({ host = "127.0.0.1", port = busy }, {})
        holder:close()
        h.eq(ok, false)
        h.truthy(err and err ~= "", "an error message is returned")
        h.truthy(not server.is_running())
    end),

    case("starting twice keeps the same server", function()
        fresh()
        local _, port = open_doc()
        local ok, again = server.start({ host = "127.0.0.1", port = 0 }, {})
        h.eq(ok, true)
        h.eq(again, port)
    end),

    case("unsaved or non-file buffers cannot be opened", function()
        fresh()
        vim.cmd("enew")
        vim.bo.filetype = "markdown"
        markedit.open()
        h.eq(tracker.count(), 0)
        h.truthy(not server.is_running())
    end),

    case("other filetypes are refused", function()
        fresh()
        local path = h.tempfile({ "x" })
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        vim.bo.filetype = "lua"
        markedit.open()
        h.eq(tracker.count(), 0)
    end),
}
