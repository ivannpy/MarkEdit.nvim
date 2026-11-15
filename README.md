# markedit.nvim

Edit Markdown in Neovim and watch it rendered in [MarkEdit](https://github.com/MarkEdit-app/MarkEdit).

`markedit.nvim` opens the current file in MarkEdit, writes your changes to disk
as you type and tells MarkEdit where your cursor is. Together with the
[MarkEdit-nvim](../MarkEdit-nvim) extension, MarkEdit becomes a live, read-only
viewer for what you edit in Neovim.

> **Status: experimental (0.1.0).** The plugin and the extension are tested
> against each other with a simulated MarkEdit. They have not been run against
> the real application yet, see [What is verified](#what-is-verified).

## How it works

```
Neovim (this plugin)  ── events over HTTP/SSE on 127.0.0.1 ──▶  MarkEdit extension
  - tracks the buffer                                              - moves the editor cursor
  - autosaves                                                      - MarkEdit-preview follows it
  - sends cursor / saved                                           - keeps the document read-only
```

1. `:MarkEditOpen` starts a small server on `127.0.0.1`, remembers the buffer and
   runs `open -g -a MarkEdit <file>`.
2. The extension, loaded by MarkEdit in that window, connects to the server and
   asks for events about its file.
3. When you move the cursor, the plugin sends the line and column. The extension
   moves MarkEdit's own cursor there; the preview mode of MarkEdit-preview
   follows the editor selection by itself.
4. When the file is written, the plugin sends `saved`; MarkEdit reloads the file
   (or the extension applies the text from disk).

The protocol is documented in [docs/protocol.md](docs/protocol.md).

## Requirements

- Neovim 0.11 or newer (developed and tested on 0.12.6; older versions are not tested).
- macOS with [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) for the viewer.
  The bridge itself is plain Lua and runs anywhere, other platforms only need
  the `open` option to launch a different viewer.
- The [MarkEdit-nvim](../MarkEdit-nvim) extension installed in MarkEdit.
- Optional but recommended:
  [MarkEdit-preview](https://github.com/MarkEdit-app/MarkEdit-preview) for the
  rendered view.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "markedit.nvim", -- replace with "<user>/markedit.nvim" once it is published
  -- while developing locally: dir = "~/Developer/markedit.nvim",
  ft = "markdown",
  cmd = { "MarkEditOpen", "MarkEditClose", "MarkEditToggle", "MarkEditStatus", "MarkEditLog" },
  opts = {},
  keys = {
    { "<leader>mp", "<cmd>MarkEditToggle<cr>", ft = "markdown", desc = "Markdown in MarkEdit" },
  },
}
```

### Try it without touching your configuration

```sh
nvim -c "set rtp+=$HOME/Developer/markedit.nvim | runtime plugin/markedit.lua" notes.md
```

then run `:MarkEditOpen`. (It has to be `-c`, not `--cmd`: plugin managers such as
lazy.nvim reset the `runtimepath` at startup and would drop the path.)

## Commands

| Command | Does |
| --- | --- |
| `:MarkEditOpen` | Open the current buffer in MarkEdit and follow it. |
| `:MarkEditClose` | Stop following the buffer. The server stops with the last buffer. |
| `:MarkEditToggle` | Open or close. |
| `:MarkEditStatus` | Show the server, followed buffers and connected viewers. |
| `:MarkEditLog` | Show the plugin log, including diagnostics sent by the extension. |

Lua API: `require("markedit").open()`, `.close()`, `.toggle()`, `.status()`.

## Configuration

These are the defaults:

```lua
require("markedit").setup({
  -- macOS application that shows the file
  app = "MarkEdit",
  -- open it without taking focus from the terminal (`open -g`)
  background = true,
  -- bridge server. The extension must use the same host and port
  host = "127.0.0.1",
  port = 47821,
  -- optional shared secret, the extension needs the same `token`
  token = nil,
  -- web origins (http/https) allowed to connect. The default is the origin
  -- MarkEdit's webview reports. Setting it replaces the list.
  allowed_origins = { "http://localhost" },
  filetypes = { "markdown" },
  sync = {
    cursor = true,
    debounce = 40, -- ms
  },
  autosave = {
    enabled = true,
    events = { "InsertLeave", "TextChanged" },
    debounce = 300, -- ms
  },
  notify = true,
  -- replace how the viewer is launched: function(path) ... end
  open = nil,
})
```

To use another viewer, set `open`:

```lua
require("markedit").setup({
  open = function(path)
    vim.system({ "open", "-a", "Typora", path })
  end,
})
```

(The cursor and read-only features need a viewer that speaks the protocol.)

## Security

The server accepts connections only from the loopback address and refuses
requests that look like they come from a web page or a DNS-rebinding attack.
The one `http` origin it lets in by default is exactly `http://localhost`, which
is what MarkEdit's webview reports (observed with MarkEdit 1.37.1).
It never sends the text of your document, only paths, cursor positions and
"saved" notices. See the [protocol notes](docs/protocol.md#security). For an
extra layer, set the same `token` here and in the extension.

## Troubleshooting

- `:MarkEditStatus` shows whether a viewer is connected. If it says `connected
  viewers: 0`, the extension is not loaded or cannot reach the port.
- `:MarkEditLog` shows each connection with the origin MarkEdit reports, and
  every `loaded`, `ready` and `error` message sent by the extension. If there is
  no `loaded` line, MarkEdit did not run the extension at all.
- *"could not start the bridge"*: the port is taken, probably by another
  Neovim running the bridge. Close it or change `port` (in the extension too).
- *rejected request from origin ...* in the log: the sender reports an `http(s)`
  origin that is not allowed. If it is your viewer, add the exact value to
  `allowed_origins` (remember it replaces the default list).

## What is verified

- 33 tests in this repository cover the HTTP parsing, the security checks,
  routing by file, autosave and every event.
- `MarkEdit-nvim` runs an end-to-end test against a real headless Neovim using
  this plugin, with a simulated MarkEdit.

Not verified yet against the real application:

1. That MarkEdit's webview can open the event stream (its CSP, its origin).
2. That MarkEdit reloads a file changed on disk by itself.
3. That moving the editor selection from the extension scrolls
   MarkEdit-preview (read from its source, not run).
4. That making the editor read-only does not interfere with the extension API.

## Tests

```sh
make test
# or
nvim --headless -u NONE -l tests/run.lua
```

## Roadmap

- Send the buffer text so changes show before they are saved.
- Scroll the preview from `top`/`bottom` instead of only the cursor line.
- Several Neovim instances at once (a port per instance, discovered by the
  extension).
- Events from MarkEdit to Neovim (jump to a line by clicking).

## License

MIT
