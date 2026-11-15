# Wire protocol (version 1)

`markedit.nvim` (the server) and the MarkEdit extension (the client) talk over
HTTP on a loopback address. The server pushes events with
[Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html);
the client can report diagnostics with a plain `POST`.

The canonical copy of this document lives in the `markedit.nvim` repository.
`MarkEdit-nvim` keeps a copy for convenience.

## Transport

- Default address: `http://127.0.0.1:47821`.
- The server only binds to the configured `host` (loopback by default).
- All responses carry permissive CORS headers. Access control is not done by
  the browser but by the server, see [Security](#security).

## Endpoints

### `GET /` or `GET /hello`

Returns a JSON description of the server. Useful to check that it is running.

```json
{ "server": "markedit.nvim", "version": "0.1.0", "protocol": 1 }
```

### `GET /events`

Opens an event stream for one document.

| Query | Required | Meaning |
| --- | --- | --- |
| `path` | yes | Absolute path of the document the client displays. The server resolves symlinks, so `/tmp/a.md` and `/private/tmp/a.md` are the same document. |
| `v` | no | Protocol version the client speaks. Informational. |
| `token` | if configured | Shared secret. |

The response is `text/event-stream`. The first bytes are `retry: 1000` followed by
the events below. A `: ping` comment is sent every 15 seconds to detect dead
connections.

`400` is returned when `path` is missing.

### `POST /client`

The client reports diagnostics. The body is a JSON object (any `Content-Type`;
`text/plain` avoids a CORS preflight). `204` on success, `400` if the body is
not a JSON object. The server only logs it (`:MarkEditLog`).

Message types sent by the extension 0.1:

| `type` | Fields | Meaning |
| --- | --- | --- |
| `ready` | `path`, `server`, `lines`, `locked`, `origin` | The handshake finished. `origin` is the page origin the webview reports. |
| `error` | `path`, `where`, `message` | Something failed inside the extension. |
| `debug` | `path`, `message`, ... | Only when the extension setting `debug` is true. |

### `OPTIONS *`

Answers `204` with the CORS headers.

## Events (server to client)

Every event has a JSON object as `data`. Unknown events and unknown fields must
be ignored, so the protocol can grow without breaking old clients.

| Event | Data | When |
| --- | --- | --- |
| `hello` | `{ protocol, server, version }` | Right after the stream opens. A client that does not speak `protocol` should disconnect. |
| `open` | `{ path }` | Neovim is following this document. Sent when the client connects to a document that is already followed, and when `:MarkEditOpen` is run for a document the client was already connected for. |
| `cursor` | see below | The cursor or scroll position changed (debounced), or right after `open`. |
| `saved` | `{ path, tick }` | The buffer was written to disk. |
| `close` | `{ path }` | Neovim stopped following this document. |
| `bye` | `{}` | Neovim is quitting. |

`hello` only identifies the server. A client must **not** treat it as "Neovim
follows this document": that is what `open` means. This matters when the user
opens an unrelated file in MarkEdit while the server is running for another one.

### `cursor`

```json
{
  "path": "/real/path/doc.md",
  "line": 12,
  "col": 3,
  "top": 1,
  "bottom": 40,
  "total": 120,
  "focus": true
}
```

| Field | Meaning |
| --- | --- |
| `line` | Cursor line, **1-based** (like Neovim). |
| `col` | Cursor column inside the line, **0-based UTF-16 code units** (like JavaScript string offsets). |
| `top`, `bottom` | First and last visible line in the Neovim window, 1-based. |
| `total` | Number of lines in the buffer. |
| `focus` | Whether the buffer is the current one in Neovim. |

## Lifecycle

```
client                                   server (Neovim)
  | GET /events?path=...  ------------------> |
  | <------------------------------ hello      |
  | <------------------------------ open       |  (only if Neovim follows `path`)
  | <------------------------------ cursor     |
  | ...                                        |
  | <------------------------------ cursor     |  (on every move)
  | <------------------------------ saved      |  (on every write)
  | <------------------------------ close      |  (:MarkEditClose)
  | <------------------------------ bye        |  (Neovim quits)
```

When the connection drops the client should wait, unlock the document after a
grace period and reconnect with exponential backoff.

## Security

The server is meant to be reachable only by the extension running on the same
machine. It enforces:

1. **Loopback only.** It binds to `127.0.0.1` by default.
2. **`Host` check.** The `Host` header must be `127.0.0.1:<port>`,
   `localhost:<port>` or `[::1]:<port>`. This stops DNS rebinding.
3. **`Origin` check.** Requests whose `Origin` starts with `http://` or
   `https://` are rejected unless listed in `allowed_origins`. Web pages always
   send such an origin; the extension, running inside an app webview, does not.
   Missing origins, `null` and custom schemes are accepted.
4. **Optional token.** When `token` is set, `?token=` (or the
   `X-MarkEdit-Token` header) must match.

Events carry paths and cursor positions, never the text of the document.

## Versioning

`protocol` is an integer. It changes only for incompatible changes. Adding
events or fields does not change it.
