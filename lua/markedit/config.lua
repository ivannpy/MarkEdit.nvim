local M = {}

---@class markedit.Config
M.defaults = {
    -- Name of the macOS application that is opened to view the file.
    app = "MarkEdit",
    -- Open the viewer in the background, without taking focus away from the
    -- terminal (`open -g`). By default MarkEdit comes to the front.
    background = false,
    -- Address of the local bridge server. Only loopback addresses make sense.
    host = "127.0.0.1",
    -- TCP port of the bridge server. 0 lets the OS pick a free port (the
    -- MarkEdit extension then cannot find it, use it only for tests).
    port = 47821,
    -- Optional shared secret. When set, clients must send `?token=<token>`.
    token = nil,
    -- Origins with an http(s) scheme that may connect. Requests coming from
    -- web pages are rejected (drive-by protection). The default is the origin
    -- MarkEdit's webview reports. Setting this replaces the list, so keep
    -- "http://localhost" in it if you add others.
    allowed_origins = { "http://localhost" },
    -- Filetypes that can be opened in the viewer.
    filetypes = { "markdown" },
    -- Send the cursor position so the viewer follows what you are editing.
    sync = {
        cursor = true,
        -- Milliseconds to wait for the cursor to settle before sending it.
        debounce = 40,
    },
    -- Write the buffer to disk by itself so the viewer always sees your edits.
    autosave = {
        enabled = true,
        events = { "InsertLeave", "TextChanged" },
        -- Milliseconds to wait after the last change before writing.
        debounce = 300,
    },
    -- Show messages with vim.notify.
    notify = true,
    -- Replace the function that opens the viewer: `function(path) ... end`.
    open = nil,
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
---@return markedit.Config
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    return M.options
end

return M
