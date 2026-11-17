-- Keeps track of the buffers shown in the viewer and turns what happens in
-- them (cursor moves, writes) into events for the server.
local uv = vim.uv or vim.loop
local log = require("markedit.log")
local server = require("markedit.server")

local M = {}

local GROUP = "MarkEdit"

---@type table<integer, string>  buffer number -> real path of its file
local tracked = {}
local cursor_timer = nil
local autosave_timers = {}
local options = nil

local function normalize(path)
    return uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- The extension works with UTF-16 offsets, Neovim with byte offsets.
local function utf16_col(text, byte_col)
    local ok, idx = pcall(vim.str_utfindex, text, "utf-16", byte_col)
    if ok and idx then
        return idx
    end
    return byte_col
end

local function find_window(bufnr)
    if vim.api.nvim_win_get_buf(0) == bufnr then
        return vim.api.nvim_get_current_win()
    end
    return vim.fn.win_findbuf(bufnr)[1]
end

--- Builds the `cursor` event payload for a tracked buffer.
---@param bufnr integer
---@return table?
function M.cursor_payload(bufnr)
    local path = tracked[bufnr]
    local win = path and find_window(bufnr)
    if not win then
        return nil
    end
    local pos = vim.api.nvim_win_get_cursor(win)
    local text = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1] or ""
    return {
        path = path,
        -- 1-based line, like Neovim
        line = pos[1],
        -- 0-based UTF-16 offset inside the line, like JavaScript strings
        col = utf16_col(text, pos[2]),
        top = vim.fn.line("w0", win),
        bottom = vim.fn.line("w$", win),
        total = vim.api.nvim_buf_line_count(bufnr),
        focus = vim.api.nvim_get_current_buf() == bufnr,
    }
end

---@param bufnr integer
function M.send_cursor(bufnr)
    local payload = M.cursor_payload(bufnr)
    if payload then
        server.broadcast(payload.path, "cursor", payload)
    end
end

--- Sends the current state of a buffer to a client that has just connected.
---@param client markedit.Client
function M.send_to(client)
    for bufnr, path in pairs(tracked) do
        if path == client.path then
            server.send(client, "follow", { path = path })
            local payload = M.cursor_payload(bufnr)
            if payload then
                server.send(client, "cursor", payload)
            end
        end
    end
end

---@param bufnr integer
function M.send_saved(bufnr)
    local path = tracked[bufnr]
    if path then
        server.broadcast(path, "saved", { path = path, tick = vim.api.nvim_buf_get_changedtick(bufnr) })
    end
end

---@param bufnr integer
---@return string? path
---@return string? err
function M.attach(bufnr)
    if vim.bo[bufnr].buftype ~= "" then
        return nil, "not a regular file buffer"
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return nil, "the buffer has no file name, save it first"
    end
    if not uv.fs_stat(name) then
        return nil, "the file does not exist on disk yet, save it first"
    end
    local path = normalize(name)
    tracked[bufnr] = path
    log.add("tracker", ("tracking buffer %d (%s)"):format(bufnr, path))
    -- Viewers that were already connected for this file start following now.
    server.broadcast(path, "follow", { path = path })
    return path
end

---@param bufnr integer
function M.detach(bufnr)
    local path = tracked[bufnr]
    if not path then
        return
    end
    tracked[bufnr] = nil
    server.broadcast(path, "close", { path = path })
    log.add("tracker", ("stopped tracking buffer %d"):format(bufnr))
    if next(tracked) == nil and M.on_empty then
        M.on_empty()
    end
end

---@param bufnr integer
---@return boolean
function M.is_tracked(bufnr)
    return tracked[bufnr] ~= nil
end

---@return integer
function M.count()
    return vim.tbl_count(tracked)
end

---@return table<integer, string>
function M.list()
    return vim.deepcopy(tracked)
end

function M.detach_all()
    for bufnr in pairs(vim.deepcopy(tracked)) do
        M.detach(bufnr)
    end
end

local function schedule_cursor()
    if not (options and options.sync.cursor) then
        return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    if not tracked[bufnr] then
        return
    end
    if not cursor_timer then
        cursor_timer = uv.new_timer()
    end
    cursor_timer:stop()
    cursor_timer:start(
        options.sync.debounce,
        0,
        vim.schedule_wrap(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                M.send_cursor(bufnr)
            end
        end)
    )
end

local function schedule_autosave(bufnr)
    if not tracked[bufnr] then
        return
    end
    local timer = autosave_timers[bufnr]
    if not timer then
        timer = uv.new_timer()
        autosave_timers[bufnr] = timer
    end
    timer:stop()
    timer:start(
        options.autosave.debounce,
        0,
        vim.schedule_wrap(function()
            if not (vim.api.nvim_buf_is_valid(bufnr) and tracked[bufnr]) then
                return
            end
            local bo = vim.bo[bufnr]
            if bo.modified and bo.modifiable and not bo.readonly and bo.buftype == "" then
                vim.api.nvim_buf_call(bufnr, function()
                    local ok, err = pcall(vim.cmd, "silent update")
                    if not ok then
                        log.add("tracker", "autosave failed: " .. tostring(err))
                    end
                end)
            end
        end)
    )
end

---@param opts markedit.Config
function M.setup(opts)
    options = opts
    local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "BufEnter", "WinEnter" }, {
        group = group,
        desc = "markedit: send the cursor position to the viewer",
        callback = schedule_cursor,
    })

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        desc = "markedit: tell the viewer the file was written",
        callback = function(args)
            M.send_saved(args.buf)
        end,
    })

    if opts.autosave.enabled and #opts.autosave.events > 0 then
        vim.api.nvim_create_autocmd(opts.autosave.events, {
            group = group,
            desc = "markedit: write tracked buffers automatically",
            callback = function(args)
                schedule_autosave(args.buf)
            end,
        })
    end

    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
        group = group,
        desc = "markedit: forget buffers that go away",
        callback = function(args)
            M.detach(args.buf)
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        desc = "markedit: say goodbye to the viewer",
        callback = function()
            server.broadcast(nil, "bye", {})
            -- Give libuv a moment to flush the goodbye before the sockets close.
            vim.wait(30)
            server.stop()
        end,
    })
end

return M
