# markedit.nvim

Edit Markdown in Neovim and watch it rendered in [MarkEdit](https://github.com/MarkEdit-app/MarkEdit).

`markedit.nvim` opens the current file in MarkEdit, writes your changes to disk
as you type and tells MarkEdit where your cursor is. Together with the
[MarkEdit-nvim](https://github.com/ivannpy/MarkEdit-nvim) extension, MarkEdit becomes a live, read-only
viewer for what you edit in Neovim.

> **Status: experimental (0.1.0).** The basic flow works with the real MarkEdit
> (1.37.1). The rest is tested only with a simulated MarkEdit, see
> [What is verified](#what-is-verified).

## How it works

```
Neovim (this plugin)  ── events over HTTP/SSE on 127.0.0.1 ──▶  MarkEdit extension
  - tracks the buffer                                              - moves the editor cursor
  - autosaves                                                      - MarkEdit-preview follows it
  - sends cursor / saved                                           - keeps the document read-only
```

1. `:MarkEditOpen` starts a small server on `127.0.0.1` (each Neovim has its own,
   on the first free port of a small range), remembers the buffer and
   runs `open -a MarkEdit <file>` (MarkEdit comes to the front; set
   `background = true` to keep the focus in the terminal).
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
- The [MarkEdit-nvim](https://github.com/ivannpy/MarkEdit-nvim) extension installed in MarkEdit.
- Optional but recommended:
  [MarkEdit-preview](https://github.com/MarkEdit-app/MarkEdit-preview) for the
  rendered view.

## Installation

It takes two pieces: this plugin in Neovim and the
[MarkEdit-nvim](https://github.com/ivannpy/MarkEdit-nvim#installation) extension in MarkEdit.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ivannpy/MarkEdit.nvim",
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
git clone https://github.com/ivannpy/MarkEdit.nvim ~/markedit.nvim
nvim -c "set rtp+=$HOME/markedit.nvim | runtime plugin/markedit.lua" notes.md
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
  -- open it in the background, keeping the focus in the terminal (`open -g`)
  background = false,
  -- bridge server. The extension must use the same host, port and port count
  host = "127.0.0.1",
  port = 47821,
  -- ports to try, starting at `port`: each Neovim takes the first free one.
  -- 1 allows a single Neovim at a time
  port_count = 10,
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
- *"could not start the bridge"*: every port of the range is taken. Close some
  Neovim, or change `port` or `port_count` (and `port` / `portCount` in the
  extension).
- The second Neovim opens the file but MarkEdit does not follow it: the installed
  extension is 0.1.0 and only knows the first port.
  [Update it](https://github.com/ivannpy/MarkEdit-nvim#installation) and restart MarkEdit.
- *rejected request from origin ...* in the log: the sender reports an `http(s)`
  origin that is not allowed. If it is your viewer, add the exact value to
  `allowed_origins` (remember it replaces the default list).

## What is verified

- 43 tests in this repository cover the HTTP parsing, the security checks,
  routing by file, several Neovims at once, autosave and every event.
- [MarkEdit-nvim](https://github.com/ivannpy/MarkEdit-nvim) runs an end-to-end test against a real headless Neovim using
  this plugin, with a simulated MarkEdit.

Checked by hand with MarkEdit 1.37.1, with a build shortly before 0.1.0:

- `:MarkEditOpen` opens the file, and the extension loads and connects.
- The document is read-only while Neovim follows it.
- The editor cursor follows Neovim, and MarkEdit-preview scrolls along.
- MarkEdit reloads the saved file by itself.

Not checked yet against the real application:

1. That a save does not mark the document as *Edited*.
2. The preview in both modes, side-by-side and overlay.
3. That the document unlocks after `:MarkEditClose`, quitting or killing Neovim.
4. Two files at once, in separate windows or in tabs.
5. That the extension finds the right one of several Neovims.

## Tests

```sh
make test
# or
nvim --headless -u NONE -l tests/run.lua
```

## Roadmap

- Send the buffer text so changes show before they are saved.
- Scroll the preview from `top`/`bottom` instead of only the cursor line.
- Events from MarkEdit to Neovim (jump to a line by clicking).

Bugs and ideas: [plugin issues](https://github.com/ivannpy/MarkEdit.nvim/issues),
[extension issues](https://github.com/ivannpy/MarkEdit-nvim/issues).

## License

[MIT](LICENSE)
