-- test/viz_svg_spec.lua (09-01 Task 6 — PURE SVG detection report renderer)
--
-- Exercises BirdAID.lrdevplugin/src/viz/svg.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. Renders a self-contained SVG string for
-- ONE photo's detections: an <image> base (when a valid data-URI is given) + per-detection
-- <rect> with a child <title> hover + a visible <text> label. ALL text XML-escaped (BL-04).
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local svg = require('src.viz.svg')

assert_true(type(svg) == 'table', "require 'src.viz.svg' resolves")
assert_true(type(svg.render) == 'function', "exposes render")

-- substring helper.
local function has(s, sub) return type(s) == 'string' and s:find(sub, 1, true) ~= nil end

-- =====================================================================
-- A one-detection render contains <svg>, denormalized rect coords, an escaped label,
-- and a <title> with escaped hover text.
-- =====================================================================
do
    local out = svg.render({
        frameW = 1000, frameH = 500,
        detections = {
            { bbox = { 0.1, 0.2, 0.6, 0.8 }, label = "Northern Cardinal", title = "species 0.92" },
        },
    })
    assert_true(type(out) == 'string', "render returns a string")
    assert_true(has(out, "<svg"), "contains <svg")
    assert_true(has(out, 'width="1000"'), "svg width = frameW")
    assert_true(has(out, 'height="500"'), "svg height = frameH")
    assert_true(has(out, 'viewBox="0 0 1000 500"'), "viewBox matches frame dims")
    -- denormalized rect: x=0.1*1000=100, y=0.2*500=100, w=(0.6-0.1)*1000=500, h=(0.8-0.2)*500=300.
    assert_true(has(out, 'x="100"'), "rect x denormalized to 100")
    assert_true(has(out, 'y="100"'), "rect y denormalized to 100")
    assert_true(has(out, 'width="500"'), "rect width denormalized to 500")
    assert_true(has(out, 'height="300"'), "rect height denormalized to 300")
    assert_true(has(out, "<rect"), "contains a <rect>")
    assert_true(has(out, "<title>"), "contains a <title> for hover")
    assert_true(has(out, "Northern Cardinal"), "visible label text present")
    assert_true(has(out, "species 0.92"), "hover title text present")
end

-- =====================================================================
-- SECURITY: a label/title containing < > & " ' is XML-escaped (no markup injection).
-- =====================================================================
do
    local out = svg.render({
        frameW = 100, frameH = 100,
        detections = {
            { bbox = { 0, 0, 1, 1 }, label = "<script>alert('x')</script>",
              title = "a & b < c > d \" '" },
        },
    })
    assert_true(not has(out, "<script"), "raw <script must NOT survive escaping")
    assert_true(has(out, "&lt;script&gt;"), "the script tag is escaped to &lt;script&gt;")
    assert_true(has(out, "&amp;"), "& escaped to &amp;")
    assert_true(has(out, "&quot;"), "double-quote escaped to &quot;")
    assert_true(has(out, "&#39;") or has(out, "&apos;"), "single-quote escaped")
    assert_true(has(out, "&lt;"), "< escaped to &lt;")
    assert_true(has(out, "&gt;"), "> escaped to &gt;")
end

-- =====================================================================
-- Multiple detections -> one rect + title each.
-- =====================================================================
do
    local out = svg.render({
        frameW = 200, frameH = 200,
        detections = {
            { bbox = { 0, 0, 0.5, 0.5 }, label = "A", title = "ta" },
            { bbox = { 0.5, 0.5, 1, 1 }, label = "B", title = "tb" },
            { bbox = { 0.2, 0.2, 0.4, 0.4 }, label = "C", title = "tc" },
        },
    })
    local function countSub(s, sub)
        local n, pos = 0, 1
        while true do
            local f = s:find(sub, pos, true)
            if not f then break end
            n = n + 1; pos = f + 1
        end
        return n
    end
    assert_eq(countSub(out, "<rect"), 3, "three <rect> elements for three detections")
    assert_eq(countSub(out, "<title>"), 3, "three <title> elements")
    assert_true(has(out, ">A<") or has(out, ">A "), "label A present")
    assert_true(has(out, "tb"), "title tb present")
end

-- =====================================================================
-- imageDataUri present (valid) -> an <image> element; nil -> no <image>; malformed -> omitted.
-- =====================================================================
do
    local withImg = svg.render({
        frameW = 10, frameH = 10, imageDataUri = "data:image/jpeg;base64,/9j/AAAA",
        detections = {},
    })
    assert_true(has(withImg, "<image"), "valid data:image/ URI -> an <image> element")
    assert_true(has(withImg, "data:image/jpeg;base64,/9j/AAAA"), "the data URI is embedded")

    local noImg = svg.render({ frameW = 10, frameH = 10, detections = {} })
    assert_true(not has(noImg, "<image"), "nil imageDataUri -> no <image> element")

    local badImg = svg.render({
        frameW = 10, frameH = 10, imageDataUri = "javascript:alert(1)", detections = {},
    })
    assert_true(not has(badImg, "<image"), "malformed (non data:image/) URI -> omitted")
    assert_true(not has(badImg, "javascript:"), "the unsafe URI is not embedded")
end

-- =====================================================================
-- Empty detections -> a valid empty <svg>.
-- =====================================================================
do
    local out = svg.render({ frameW = 50, frameH = 40, detections = {} })
    assert_true(has(out, "<svg"), "empty detections still yields an <svg>")
    assert_true(has(out, "</svg>"), "the svg is closed")
    assert_true(not has(out, "<rect"), "no rects when there are no detections")
end

-- =====================================================================
-- The uncertain "?" / genus-family label renders verbatim (escaped). The caller passes
-- keyword.render output (e.g. "Cardinalis sp.?").
-- =====================================================================
do
    local out = svg.render({
        frameW = 100, frameH = 100,
        detections = {
            { bbox = { 0.1, 0.1, 0.9, 0.9 }, label = "Cardinalis sp.?", title = "genus 0.4?" },
        },
    })
    assert_true(has(out, "Cardinalis sp.?"), "genus-family '?' label renders")
    assert_true(has(out, "genus 0.4?"), "uncertain hover title renders")
end

-- =====================================================================
-- Robustness: a detection missing label/title still renders without raising.
-- =====================================================================
do
    local out = svg.render({
        frameW = 100, frameH = 100,
        detections = { { bbox = { 0, 0, 1, 1 } } },  -- no label, no title
    })
    assert_true(has(out, "<rect"), "missing label/title still renders a rect (no raise)")
end

-- =====================================================================
-- S1: a bbox that OVERSHOOTS the frame is CLAMPED to [0,1] (pixels within [0,frameW]/[0,frameH]).
-- {-0.5, 0.2, 1.5, 1.2} on a 100x100 frame must render the rect INSIDE the frame, not x="-50"
-- width="200". After clamp: xmin=0, ymin=0.2, xmax=1, ymax=1 -> x=0,y=20,w=100,h=80.
-- =====================================================================
do
    local out = svg.render({
        frameW = 100, frameH = 100,
        detections = {
            { bbox = { -0.5, 0.2, 1.5, 1.2 }, label = "L", title = "T" },
        },
    })
    assert_true(has(out, "<rect"), "overshooting bbox still renders a rect")
    assert_true(not has(out, 'x="-50"'), "negative x is CLAMPED away (no x=\"-50\")")
    assert_true(not has(out, 'width="200"'), "over-wide width is CLAMPED away (no width=\"200\")")
    assert_true(has(out, 'x="0"'), "clamped x = 0 (xmin -0.5 -> 0)")
    assert_true(has(out, 'y="20"'), "y = 0.2*100 = 20 (within frame)")
    assert_true(has(out, 'width="100"'), "clamped width = full frame (xmax 1.5 -> 1)")
    assert_true(has(out, 'height="80"'), "clamped height = 80 (ymax 1.2 -> 1, 1-0.2)")
end

-- =====================================================================
-- S1: an INVERTED bbox (max < min) after clamping yields a non-negative width/height (edges ordered).
-- =====================================================================
do
    local out = svg.render({
        frameW = 100, frameH = 100,
        detections = { { bbox = { 0.8, 0.8, 0.2, 0.2 }, label = "L", title = "T" } },
    })
    assert_true(has(out, 'x="20"'), "inverted bbox ordered: x = 0.2*100 = 20")
    assert_true(has(out, 'width="60"'), "inverted bbox ordered: width = (0.8-0.2)*100 = 60")
    assert_true(not has(out, 'width="-'), "no negative width from an inverted bbox")
end

-- =====================================================================
-- S2 (CODEX W1-R2 #1): a bbox carrying NaN and/or inf coordinates is REJECTED/skipped (NOT
-- rendered as a garbage rect), proving denorm()'s NaN/inf guard in src/viz/svg.lua. A NaN/inf
-- coord must produce NO <rect> for that detection, while a VALID sibling detection still renders.
-- =====================================================================
do
    local NAN = 0 / 0
    local INF = 1 / 0

    -- a single detection whose bbox has a NaN coord -> NO rect (skipped, not garbage).
    local nanOut = svg.render({
        frameW = 100, frameH = 100,
        detections = { { bbox = { NAN, 0.2, 0.6, 0.8 }, label = "L", title = "T" } },
    })
    assert_true(has(nanOut, "<svg"), "NaN-coord bbox still yields a valid <svg>")
    assert_true(not has(nanOut, "<rect"), "a bbox with a NaN coord renders NO <rect> (rejected)")
    assert_true(not has(nanOut, "nan") and not has(nanOut, "NaN"),
        "no literal nan leaks into the output as a garbage coord")

    -- +inf and -inf coords are likewise rejected.
    local infOut = svg.render({
        frameW = 100, frameH = 100,
        detections = { { bbox = { 0.1, 0.2, INF, 0.8 }, label = "L", title = "T" } },
    })
    assert_true(not has(infOut, "<rect"), "a bbox with +inf coord renders NO <rect> (rejected)")
    assert_true(not has(infOut, "inf") and not has(infOut, "Inf"),
        "no literal inf leaks into the output")

    local negInfOut = svg.render({
        frameW = 100, frameH = 100,
        detections = { { bbox = { 0.1, -INF, 0.6, 0.8 }, label = "L", title = "T" } },
    })
    assert_true(not has(negInfOut, "<rect"), "a bbox with -inf coord renders NO <rect> (rejected)")

    -- all four coords NaN -> still no rect, no raise.
    local allNan = svg.render({
        frameW = 100, frameH = 100,
        detections = { { bbox = { NAN, NAN, NAN, NAN }, label = "L", title = "T" } },
    })
    assert_true(not has(allNan, "<rect"), "an all-NaN bbox renders NO <rect>")

    -- a NaN/inf detection is SKIPPED but a valid sibling in the same render still draws its rect,
    -- proving the guard rejects only the bad detection (not the whole render).
    local mixed = svg.render({
        frameW = 100, frameH = 100,
        detections = {
            { bbox = { NAN, 0.2, 0.6, 0.8 }, label = "bad",  title = "bad" },   -- rejected
            { bbox = { 0.0, 0.0, 1.0, 1.0 }, label = "good", title = "good" },  -- valid
        },
    })
    local function countSub(s, sub)
        local n, pos = 0, 1
        while true do
            local f = s:find(sub, pos, true)
            if not f then break end
            n = n + 1; pos = f + 1
        end
        return n
    end
    assert_eq(countSub(mixed, "<rect"), 1, "exactly ONE rect: the NaN detection skipped, the valid one drawn")
    assert_true(has(mixed, ">good<") or has(mixed, ">good "), "the valid sibling label renders")
    assert_true(not has(mixed, "bad"), "the rejected detection's label does NOT render")
end
