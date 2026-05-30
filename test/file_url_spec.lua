-- test/file_url_spec.lua (09 Wave 2 Task 9 — PURE file:// URL builder extracted from viz_report)
--
-- Exercises BirdAID.lrdevplugin/src/viz/file_url.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. It builds the percent-escaped file:// URL
-- that the viz_report Lr glue hands to LrHttp.openUrlInBrowser. The escaping is the security/
-- correctness surface (T-09-06: a path with a space or specials must not malform the URL), so it
-- is extracted here and unit-tested offline; the openUrlInBrowser call itself is verified live
-- (Task 12).
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local fileUrl = require('src.viz.file_url')

assert_true(type(fileUrl) == 'table', "require 'src.viz.file_url' resolves")
assert_true(type(fileUrl.pathToFileUrl) == 'function', "exposes pathToFileUrl")
assert_true(type(fileUrl.encodeSegment) == 'function', "exposes encodeSegment")

-- ---------------------------------------------------------------------------
-- encodeSegment: unreserved pass-through, everything else %XX uppercase.
-- ---------------------------------------------------------------------------
assert_eq(fileUrl.encodeSegment("abcXYZ0189"), "abcXYZ0189", "unreserved alnum passes through")
assert_eq(fileUrl.encodeSegment("a-b_c.d~e"), "a-b_c.d~e", "unreserved -_.~ pass through")
assert_eq(fileUrl.encodeSegment("a b"), "a%20b", "space -> %20")
assert_eq(fileUrl.encodeSegment("a%b"), "a%25b", "percent -> %25")
assert_eq(fileUrl.encodeSegment("a?b#c&d"), "a%3Fb%23c%26d", "reserved ? # & encoded")
assert_eq(fileUrl.encodeSegment("("), "%28", "paren encoded (uppercase hex)")
assert_eq(fileUrl.encodeSegment(""), "", "empty segment stays empty")
-- a '/' inside a segment is reserved -> encoded (pathToFileUrl never passes one, but prove it).
assert_eq(fileUrl.encodeSegment("a/b"), "a%2Fb", "slash inside a segment is encoded")
-- a >=0x80 byte (UTF-8 continuation) is encoded byte-wise. "é" = 0xC3 0xA9 in UTF-8.
assert_eq(fileUrl.encodeSegment("\195\169"), "%C3%A9", "UTF-8 byte sequence encoded per byte, uppercase")

-- ---------------------------------------------------------------------------
-- pathToFileUrl: absolute paths get a 'file://' prefix + per-segment encoding,
-- separators ('/') preserved -> the three-slash file:/// form.
-- ---------------------------------------------------------------------------
assert_eq(fileUrl.pathToFileUrl("/tmp/BirdAID/report-1/report-0.svg"),
    "file:///tmp/BirdAID/report-1/report-0.svg", "plain absolute path -> file:/// with slashes kept")

assert_eq(fileUrl.pathToFileUrl("/Users/me/My Photos/report-0.svg"),
    "file:///Users/me/My%20Photos/report-0.svg", "spaces in a path segment -> %20, slashes kept")

assert_eq(fileUrl.pathToFileUrl("/a/b c/d#e/f.svg"),
    "file:///a/b%20c/d%23e/f.svg", "specials encoded per segment, slashes preserved")

-- the leading '/' yields a leading empty segment -> the result starts with file:/// (three slashes).
local u = fileUrl.pathToFileUrl("/x")
assert_eq(u, "file:///x", "single-segment absolute path -> file:///x (three slashes)")

-- a trailing slash keeps a trailing empty segment -> a trailing '/'.
assert_eq(fileUrl.pathToFileUrl("/a/b/"), "file:///a/b/", "trailing slash preserved")

-- ---------------------------------------------------------------------------
-- pathToFileUrl: fail-closed on bad input (nil/non-string/empty/relative -> nil).
-- ---------------------------------------------------------------------------
assert_eq(fileUrl.pathToFileUrl(nil), nil, "nil -> nil")
assert_eq(fileUrl.pathToFileUrl(123), nil, "non-string -> nil")
assert_eq(fileUrl.pathToFileUrl(""), nil, "empty -> nil")
assert_eq(fileUrl.pathToFileUrl("relative/path.svg"), nil, "relative path -> nil (fail closed)")
assert_eq(fileUrl.pathToFileUrl("./x"), nil, "dot-relative path -> nil")

-- determinism: same input -> identical output across repeated calls.
local a = fileUrl.pathToFileUrl("/p q/r.svg")
local b = fileUrl.pathToFileUrl("/p q/r.svg")
assert_eq(a, b, "deterministic output")
