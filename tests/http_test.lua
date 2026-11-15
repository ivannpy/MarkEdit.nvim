local http = require("markedit.http")
local h = require("tests.helpers")

local function case(name, fn)
    return { name = name, fn = fn }
end

return {
    case("url_decode handles escapes and plus signs", function()
        h.eq(http.url_decode("a%20b+c%2Bd"), "a b c+d")
        h.eq(http.url_decode("%2Ftmp%2F%C3%B1.md"), "/tmp/ñ.md")
    end),

    case("parse_query splits and decodes pairs", function()
        h.eq(http.parse_query("path=%2Ftmp%2Fa.md&v=1&flag"), { path = "/tmp/a.md", v = "1", flag = "" })
        h.eq(http.parse_query(""), {})
    end),

    case("parse_request waits for the end of the headers", function()
        h.eq(http.parse_request("GET / HTTP/1.1\r\nHost: x"), nil)
    end),

    case("parse_request reads method, path, query and headers", function()
        local req = http.parse_request("GET /events?path=%2Ftmp%2Fa.md HTTP/1.1\r\nHost: 127.0.0.1:1\r\nOrigin: null\r\n\r\n")
        h.eq(req.method, "GET")
        h.eq(req.path, "/events")
        h.eq(req.query.path, "/tmp/a.md")
        h.eq(req.headers.host, "127.0.0.1:1")
        h.eq(req.headers.origin, "null")
    end),

    case("parse_request waits for the whole body", function()
        local head = "POST /client HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        h.eq(http.parse_request(head .. "ab"), nil)
        h.eq(http.parse_request(head .. "abcde").body, "abcde")
    end),

    case("parse_request rejects garbage and oversized input", function()
        local req, err = http.parse_request("NOPE\r\n\r\n")
        h.eq(req, false)
        h.eq(err, "bad request line")
        local big, berr = http.parse_request(("a"):rep(http.MAX_HEADER + 1))
        h.eq(big, false)
        h.eq(berr, "header too large")
    end),

    case("sse_event formats an event", function()
        h.eq(http.sse_event("cursor", { line = 3 }), 'event: cursor\ndata: {"line":3}\n\n')
    end),

    case("response includes length, CORS and a status line", function()
        local res = http.response(200, { ["Content-Type"] = "text/plain" }, "hi")
        h.truthy(res:find("^HTTP/1.1 200 OK\r\n"))
        h.truthy(res:find("Content%-Length: 2"))
        h.truthy(res:find("Access%-Control%-Allow%-Origin: %*"))
        h.truthy(res:find("\r\n\r\nhi$"))
    end),
}
