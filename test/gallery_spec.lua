-- test/gallery_spec.lua (12-02 Task 2 — PURE viz/gallery.render combined HTML page)
--
-- Exercises BirdAID.lrdevplugin/src/viz/gallery.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. render(photos) returns ONE self-contained
-- HTML page embedding every photo's svg.render body (no per-photo tab flood, GAL-01). EVERY
-- dynamic string is XML-escaped (markup-injection defense, T-12-04) and image embedding is
-- constrained to GENERATED RASTER base64 only (jpeg/png) — an svg+xml data URI is REJECTED
-- (T-12-04b / CODEX MEDIUM-2), NOT reusing svg.safeImageUri's loose ^data:image/ guard.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local gallery = require('src.viz.gallery')

assert_true(type(gallery) == 'table', "require 'src.viz.gallery' resolves")
assert_true(type(gallery.render) == 'function', "exposes render")

-- substring helper.
local function has(s, sub) return type(s) == 'string' and s:find(sub, 1, true) ~= nil end
local function countSub(s, sub)
    local n, pos = 0, 1
    while true do
        local f = s:find(sub, pos, true)
        if not f then break end
        n = n + 1; pos = f + 1
    end
    return n
end

-- =====================================================================
-- ONE combined HTML page wrapping N svg bodies. 3 photos -> exactly 3 <svg sections in ONE <html>.
-- =====================================================================
do
    local photos = {
        { frameW = 100, frameH = 100, imageDataUri = "data:image/jpeg;base64,AAAA",
          label = "IMG_1.jpg", detections = { { bbox = { 0.1, 0.1, 0.5, 0.5 }, label = "Robin", title = "t" } } },
        { frameW = 200, frameH = 150, imageDataUri = "data:image/png;base64,BBBB",
          label = "IMG_2.jpg", detections = {} },
        { frameW = 50, frameH = 50, label = "IMG_3.jpg",
          detections = { { bbox = { 0, 0, 1, 1 }, label = "Crow", title = "t2" } } },
    }
    local out = gallery.render(photos)
    assert_true(type(out) == 'string', "render returns a string")
    assert_eq(countSub(out, "<html"), 1, "exactly ONE <html> document")
    assert_eq(countSub(out, "</html>"), 1, "the html is closed once")
    assert_true(has(out, "<body"), "has a <body>")
    assert_eq(countSub(out, "<svg"), 3, "3 photos -> exactly 3 embedded <svg> bodies")
    -- captions present (escaped file labels).
    assert_true(has(out, "IMG_1.jpg"), "photo 1 caption present")
    assert_true(has(out, "IMG_2.jpg"), "photo 2 caption present")
    assert_true(has(out, "IMG_3.jpg"), "photo 3 caption present")
    -- detection labels reflected.
    assert_true(has(out, "Robin"), "detection label Robin reflected in caption")
    assert_true(has(out, "Crow"), "detection label Crow reflected in caption")
end

-- =====================================================================
-- SECURITY (T-12-04): a <script> payload in a label is ESCAPED, never live markup.
-- =====================================================================
do
    local out = gallery.render({
        { frameW = 100, frameH = 100, label = "<script>alert(1)</script>",
          detections = { { bbox = { 0, 0, 1, 1 }, label = "<img src=x onerror=alert(2)>", title = "t" } } },
    })
    assert_true(not has(out, "<script>alert(1)</script>"), "raw <script> payload must NOT survive")
    assert_true(has(out, "&lt;script&gt;"), "the script tag is escaped to &lt;script&gt;")
    assert_true(not has(out, "<img src=x onerror"), "the img/onerror payload must NOT survive as live markup")
end

-- =====================================================================
-- SECURITY: a `&`-containing species name is escaped ONCE (not double-escaped).
-- =====================================================================
do
    local out = gallery.render({
        { frameW = 100, frameH = 100, label = "Black & White Warbler",
          detections = {} },
    })
    assert_true(has(out, "&amp;"), "& escaped to &amp;")
    assert_true(not has(out, " & "), "no bare ` & ` survives unescaped")
    assert_true(not has(out, "&amp;amp;"), "& escaped exactly once (not double)")
end

-- =====================================================================
-- RASTER-ONLY guard (T-12-04b / CODEX MEDIUM-2): a data:image/svg+xml URI is REJECTED (not embedded)
-- while a data:image/jpeg;base64 URI IS embedded. (Do NOT reuse svg.safeImageUri's loose guard.)
-- =====================================================================
do
    local outSvg = gallery.render({
        { frameW = 10, frameH = 10, label = "x",
          imageDataUri = "data:image/svg+xml,<svg onload=alert(1)>", detections = {} },
    })
    assert_true(not has(outSvg, "image/svg+xml"), "svg+xml data URI is REJECTED (not embedded)")
    assert_true(not has(outSvg, "onload=alert"), "the svg+xml active-content payload is not embedded")
    assert_true(has(outSvg, "<svg"), "the photo still renders an svg frame (just no base image)")

    local outJpeg = gallery.render({
        { frameW = 10, frameH = 10, label = "x",
          imageDataUri = "data:image/jpeg;base64,/9j/AAAA", detections = {} },
    })
    assert_true(has(outJpeg, "data:image/jpeg;base64,/9j/AAAA"), "a jpeg base64 URI IS embedded")

    local outPng = gallery.render({
        { frameW = 10, frameH = 10, label = "x",
          imageDataUri = "data:image/png;base64,iVBORw0K", detections = {} },
    })
    assert_true(has(outPng, "data:image/png;base64,iVBORw0K"), "a png base64 URI IS embedded")

    -- a non-base64 data:image/jpeg URI (no ;base64,) is rejected.
    local outRaw = gallery.render({
        { frameW = 10, frameH = 10, label = "x",
          imageDataUri = "data:image/jpeg,rawbytes", detections = {} },
    })
    assert_true(not has(outRaw, "rawbytes"), "a non-base64 data:image/jpeg URI is rejected")

    -- a non-data: scheme is rejected.
    local outJs = gallery.render({
        { frameW = 10, frameH = 10, label = "x",
          imageDataUri = "javascript:alert(1)", detections = {} },
    })
    assert_true(not has(outJs, "javascript:"), "a non-data: scheme is rejected")
end

-- =====================================================================
-- Empty input -> a VALID (empty) HTML page with ZERO svg sections, never errors.
-- =====================================================================
do
    local out = gallery.render({})
    assert_true(type(out) == 'string' and #out > 0, "render({}) returns a non-empty string")
    assert_eq(countSub(out, "<html"), 1, "empty input still emits ONE <html>")
    assert_eq(countSub(out, "</html>"), 1, "the empty html is closed")
    assert_eq(countSub(out, "<svg"), 0, "empty input -> ZERO svg sections")
end

-- =====================================================================
-- render is total: nil / non-table input degrades to a valid empty page (no raise).
-- =====================================================================
do
    local out = gallery.render(nil)
    assert_true(type(out) == 'string' and has(out, "<html"), "render(nil) -> valid empty html page")
    assert_eq(countSub(out, "<svg"), 0, "render(nil) -> ZERO svg sections")
end
