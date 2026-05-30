-- test/crop_bbox_transform_spec.lua (Phase 6 — Crop-for-ID, PURE bbox transform, CROP-03)
--
-- Exercises BirdAID.lrdevplugin/src/crop/bbox_transform.lua: a PURE module (pulls in NO
-- Lightroom SDK namespace at load time), require-able under stock lua / luajit. Covers the
-- normalized-bbox -> integer-pixel-rect mapping: scale, padding (normalized-space), clamp
-- (never x+w>W or y+h>H), min-size, the maxEdge longest-edge CAP [CODEX #14], integer
-- rounding, and the (nil,err) invalid-input gate [CODEX #10] (degenerate/inverted/
-- out-of-range/zero-dim/nil/bad-export-dims). NEVER crashes on bad input.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local T = require('src.crop.bbox_transform')

-- =====================================================================
-- Scale: a top-left quadrant box maps to an exact pixel rect (pad=0, minPx=1, no cap).
-- =====================================================================
do
    local r = T.transform({ 0.0, 0.0, 0.5, 0.5 }, 1000, 800, { pad = 0, minPx = 1, maxEdge = 99999 })
    assert_true(type(r) == "table", "transform returns a table for a valid box")
    assert_eq(r.x, 0, "scale: x == 0")
    assert_eq(r.y, 0, "scale: y == 0")
    assert_eq(r.w, 500, "scale: w == 500 (0.5*1000)")
    assert_eq(r.h, 400, "scale: h == 400 (0.5*800)")
    assert_eq(type(r.x), "number", "scale: x is a number")
end

-- =====================================================================
-- Integer rounding: all four fields are integers (round-half-up via floor(v+0.5)).
-- A box that lands on fractional pixels still yields integer x,y,w,h.
-- =====================================================================
do
    local r = T.transform({ 0.1, 0.1, 0.4, 0.4 }, 1001, 801, { pad = 0, minPx = 1, maxEdge = 99999 })
    assert_eq(r.x, math.floor(r.x), "rounding: x is integer")
    assert_eq(r.y, math.floor(r.y), "rounding: y is integer")
    assert_eq(r.w, math.floor(r.w), "rounding: w is integer")
    assert_eq(r.h, math.floor(r.h), "rounding: h is integer")
end

-- =====================================================================
-- Padding: pad=0.08 expands each side by 8% of box width/height in NORMALIZED space,
-- then clamps to [0,1] BEFORE pixel conversion. A centered box grows in both dims.
-- =====================================================================
do
    -- box width = 0.4, height = 0.4; pad expands by 0.08*0.4 = 0.032 each side.
    -- x range 0.3..0.7 -> 0.268..0.732 ; pixels on a 1000-wide frame: 268..732 -> w ~= 464.
    local r = T.transform({ 0.3, 0.3, 0.7, 0.7 }, 1000, 1000, { pad = 0.08, minPx = 1, maxEdge = 99999 })
    assert_true(r.w > 400, "padding: padded width exceeds the un-padded 400px")
    assert_true(r.w <= 1000, "padding: width stays within the frame")
    assert_eq(r.x, 268, "padding: x == round(0.268*1000)")
    assert_eq(r.w, 464, "padding: w == round((0.732-0.268)*1000)")
end

-- =====================================================================
-- Padding clamps to [0,1] before pixels: an edge-touching box padded outward never
-- produces a negative origin or an over-frame extent.
-- =====================================================================
do
    local r = T.transform({ 0.0, 0.0, 0.3, 0.3 }, 1000, 1000, { pad = 0.5, minPx = 1, maxEdge = 99999 })
    assert_eq(r.x, 0, "padding clamp: x never negative (clamped to 0 before pixels)")
    assert_eq(r.y, 0, "padding clamp: y never negative")
    assert_true(r.x + r.w <= 1000, "padding clamp: x+w <= W")
    assert_true(r.y + r.h <= 1000, "padding clamp: y+h <= H")
end

-- =====================================================================
-- Clamp: a box touching the right/bottom edge never yields x+w>W or y+h>H.
-- =====================================================================
do
    local r = T.transform({ 0.9, 0.9, 1.0, 1.0 }, 1000, 800, { pad = 0, minPx = 1, maxEdge = 99999 })
    assert_true(r.x + r.w <= 1000, "clamp: x+w <= exportW")
    assert_true(r.y + r.h <= 800, "clamp: y+h <= exportH")
    assert_true(r.w >= 1, "clamp: w >= 1")
    assert_true(r.h >= 1, "clamp: h >= 1")
end

-- =====================================================================
-- Min-size: a sub-minPx box is widened to minPx, re-centered, then re-clamped.
-- =====================================================================
do
    local r = T.transform({ 0.5, 0.5, 0.501, 0.501 }, 1000, 1000, { pad = 0, minPx = 32, maxEdge = 99999 })
    assert_true(r.w >= 32, "min-size: w widened to >= minPx (32)")
    assert_true(r.h >= 32, "min-size: h widened to >= minPx (32)")
    assert_true(r.x + r.w <= 1000, "min-size: still clamped x+w <= W")
    assert_true(r.y + r.h <= 1000, "min-size: still clamped y+h <= H")
end

-- =====================================================================
-- maxEdge CAP [CODEX #14]: the FULL-FRAME box on an 8000x6000 export, capped at 2048,
-- yields a rect whose LONGEST edge is <= 2048, aspect preserved within +-1px.
-- =====================================================================
do
    local r = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 8000, 6000, { pad = 0, minPx = 1, maxEdge = 2048 })
    assert_true(r.w <= 2048, "maxEdge cap: w <= 2048")
    assert_true(r.h <= 2048, "maxEdge cap: h <= 2048")
    -- the longest edge should be exactly at (or within 1px of) the cap.
    assert_true(math.max(r.w, r.h) >= 2047, "maxEdge cap: longest edge near the cap (not over-shrunk)")
    -- aspect ratio of 8000:6000 == 4:3; capped longest edge w=2048 -> h ~= 1536.
    local expectedH = math.floor(2048 * 6000 / 8000 + 0.5)
    assert_true(math.abs(r.h - expectedH) <= 1, "maxEdge cap: aspect preserved within +-1px")
    assert_true(r.x + r.w <= 8000, "maxEdge cap: still within frame x")
    assert_true(r.y + r.h <= 6000, "maxEdge cap: still within frame y")
end

-- =====================================================================
-- INVALID INPUT -> (nil, err) [CODEX #10]. NEVER a crash, NEVER a degenerate rect.
-- =====================================================================
do
    -- degenerate / inverted: xmin > xmax
    local r, e = T.transform({ 0.8, 0.2, 0.2, 0.4 }, 1000, 1000, {})
    assert_eq(r, nil, "invalid: inverted bbox (xmin>xmax) -> nil")
    assert_eq(e, "bad-bbox", "invalid: inverted bbox -> 'bad-bbox'")

    -- out-of-range: xmax > 1
    r, e = T.transform({ 0.0, 0.0, 1.2, 1.0 }, 1000, 1000, {})
    assert_eq(r, nil, "invalid: out-of-range bbox -> nil")
    assert_eq(e, "bad-bbox", "invalid: out-of-range bbox -> 'bad-bbox'")

    -- zero-dim: xmin == xmax
    r, e = T.transform({ 0.0, 0.0, 0.0, 1.0 }, 1000, 1000, {})
    assert_eq(r, nil, "invalid: zero-width bbox (xmin==xmax) -> nil")
    assert_eq(e, "bad-bbox", "invalid: zero-width bbox -> 'bad-bbox'")

    -- zero-dim: ymin == ymax
    r, e = T.transform({ 0.0, 0.5, 1.0, 0.5 }, 1000, 1000, {})
    assert_eq(r, nil, "invalid: zero-height bbox (ymin==ymax) -> nil")
    assert_eq(e, "bad-bbox", "invalid: zero-height bbox -> 'bad-bbox'")

    -- exportW = 0
    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 0, 1000, {})
    assert_eq(r, nil, "invalid: exportW=0 -> nil")
    assert_eq(e, "bad-export-dims", "invalid: exportW=0 -> 'bad-export-dims'")

    -- exportH = nil
    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 1000, nil, {})
    assert_eq(r, nil, "invalid: exportH=nil -> nil")
    assert_eq(e, "bad-export-dims", "invalid: exportH=nil -> 'bad-export-dims'")

    -- bbox = nil
    r, e = T.transform(nil, 1000, 1000, {})
    assert_eq(r, nil, "invalid: bbox=nil -> nil")
    assert_eq(e, "bad-bbox", "invalid: bbox=nil -> 'bad-bbox'")

    -- non-table bbox
    r, e = T.transform("not-a-table", 1000, 1000, {})
    assert_eq(r, nil, "invalid: non-table bbox -> nil")
    assert_eq(e, "bad-bbox", "invalid: non-table bbox -> 'bad-bbox'")

    -- NaN / inf element rejected (mirror contract isNum finite guard)
    r, e = T.transform({ 0.0, 0.0, 1 / 0, 1.0 }, 1000, 1000, {})
    assert_eq(r, nil, "invalid: +inf bbox element -> nil")
    assert_eq(e, "bad-bbox", "invalid: +inf bbox element -> 'bad-bbox'")

    -- negative export dim
    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, -10, 1000, {})
    assert_eq(r, nil, "invalid: negative exportW -> nil")
    assert_eq(e, "bad-export-dims", "invalid: negative exportW -> 'bad-export-dims'")

    -- [CODEX #8] non-integer export dims rejected (the clamp invariant must hold on integers).
    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 0.5, 0.5, {})
    assert_eq(r, nil, "invalid: fractional exportW/H (0.5) -> nil")
    assert_eq(e, "bad-export-dims", "invalid: fractional export dims -> 'bad-export-dims'")

    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 1000.5, 1000, {})
    assert_eq(r, nil, "invalid: fractional exportW (1000.5) -> nil")
    assert_eq(e, "bad-export-dims", "invalid: fractional exportW -> 'bad-export-dims'")

    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 1000, 800.25, {})
    assert_eq(r, nil, "invalid: fractional exportH (800.25) -> nil")
    assert_eq(e, "bad-export-dims", "invalid: fractional exportH -> 'bad-export-dims'")

    -- +inf export dim rejected by the finite guard.
    r, e = T.transform({ 0.0, 0.0, 1.0, 1.0 }, 1 / 0, 1000, {})
    assert_eq(r, nil, "invalid: +inf exportW -> nil")
    assert_eq(e, "bad-export-dims", "invalid: +inf exportW -> 'bad-export-dims'")
end

-- =====================================================================
-- NEVER raises (pcall battery over all the invalid inputs above plus odd opts).
-- =====================================================================
do
    local bads = {
        { nil, 1000, 1000, {} },
        { "x", 1000, 1000, {} },
        { { 0.8, 0.2, 0.2, 0.4 }, 1000, 1000, {} },
        { { 0, 0, 1, 1 }, 0, 1000, {} },
        { { 0, 0, 1, 1 }, 1000, nil, {} },
        { { 0, 0, 1, 1 }, 1000, 1000, nil },
        { { 0, 0, 1 / 0, 1 }, 1000, 1000, {} },
        { { 0, 0, 1, 1 }, 1000, 1000, { pad = "x", minPx = "y", maxEdge = "z" } },
    }
    for i = 1, #bads do
        local args = bads[i]
        local ok = pcall(function() return T.transform(args[1], args[2], args[3], args[4]) end)
        assert_true(ok, "transform never raises (battery item " .. i .. ")")
    end
end

-- =====================================================================
-- Defaults: omitting opts uses pad=0.08, minPx=32, maxEdge default (>=2048). A valid
-- box with no opts still returns a sane integer rect within the frame.
-- =====================================================================
do
    local r = T.transform({ 0.25, 0.25, 0.75, 0.75 }, 4000, 4000)
    assert_true(type(r) == "table", "defaults: valid box with no opts returns a rect")
    assert_true(r.x >= 0 and r.y >= 0, "defaults: origin within frame")
    assert_true(r.x + r.w <= 4000 and r.y + r.h <= 4000, "defaults: extent within frame")
    assert_true(r.w >= 32 and r.h >= 32, "defaults: min-size honored")
end
