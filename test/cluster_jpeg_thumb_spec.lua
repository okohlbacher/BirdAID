-- test/cluster_jpeg_thumb_spec.lua (09-01 Task 5, RISKIEST — PURE baseline-JPEG DC-luma decode)
--
-- Exercises BirdAID.lrdevplugin/src/cluster/jpeg_thumb.lua: a PURE module (no Lr, deterministic,
-- no math.random) require-able under stock lua / luajit. Decodes ONLY the DC luma signal of a
-- baseline JPEG and reduces it to a FIXED 8x8 (64-cell) grid; FAIL-OPEN (nil) on
-- progressive/corrupt/non-JPEG (BL-07: a wrong merge is worse than a missed merge).
--
-- Fixtures: deterministic checked-in JPEG byte blobs (test/fixtures/jpeg_thumb_fixtures.lua),
-- generated offline once. The spec asserts RELATIVE luma patterns + cross-frame similarity, never
-- exact pixel values (the DC-only decode skips the IDCT; only relative luma matters for the aHash).
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local jt  = require('src.cluster.jpeg_thumb')
local sim = require('src.cluster.similarity')
local F   = require('test.fixtures.jpeg_thumb_fixtures')

assert_true(type(jt) == 'table', "require 'src.cluster.jpeg_thumb' resolves")
assert_true(type(jt.dcLumaGrid) == 'function', "exposes dcLumaGrid")

-- count cells in a grid.
local function cells(g)
    if type(g) ~= 'table' then return -1 end
    local n = 0
    for _ in pairs(g) do n = n + 1 end
    return n
end

-- =====================================================================
-- A baseline JPEG -> a FIXED 8x8 (64-cell) content-bearing grid.
-- =====================================================================
local gA = jt.dcLumaGrid(F.color420_sceneA)
assert_true(type(gA) == 'table', "baseline 4:2:0 scene A decodes to a grid")
assert_eq(cells(gA), 64, "scene A grid has EXACTLY 64 cells")

local gGray = jt.dcLumaGrid(F.gray_sceneC)
assert_true(type(gGray) == 'table', "grayscale baseline scene C decodes to a grid")
assert_eq(cells(gGray), 64, "gray grid has EXACTLY 64 cells")

-- =====================================================================
-- Content-bearing: scene C is left-dark / right-bright. The left columns of the 8x8 grid
-- must be DARKER (lower DC luma) than the right columns. (Relative pattern, not exact values.)
-- =====================================================================
do
    -- average the left 4 columns vs the right 4 columns over all 8 rows.
    local leftSum, rightSum = 0, 0
    for row = 0, 7 do
        for col = 0, 3 do leftSum  = leftSum  + gGray[row * 8 + col + 1] end
        for col = 4, 7 do rightSum = rightSum + gGray[row * 8 + col + 1] end
    end
    assert_true(leftSum < rightSum,
        "scene C: the DARK left half has lower DC luma than the BRIGHT right half")
end

-- =====================================================================
-- A near-identical burst frame -> SMALL distance (frames merge).
-- =====================================================================
do
    local gBurst = jt.dcLumaGrid(F.color420_sceneA_burst)
    assert_true(type(gBurst) == 'table', "burst frame decodes to a grid")
    assert_eq(cells(gBurst), 64, "burst grid has 64 cells")
    local d = sim.distance(sim.hash(gA), sim.hash(gBurst))
    assert_true(d <= 5, "near-identical burst frame -> small Hamming distance (<=5), got " .. d)
    assert_eq(sim.similar(gA, gBurst, 10), true, "near-identical pair is SIMILAR at threshold 10")
end

-- =====================================================================
-- A DIFFERENT scene -> LARGE distance (frames do NOT merge at a sane threshold).
-- =====================================================================
do
    local gB = jt.dcLumaGrid(F.color420_sceneB)
    assert_true(type(gB) == 'table', "scene B decodes to a grid")
    local d = sim.distance(sim.hash(gA), sim.hash(gB))
    assert_true(d >= 16, "different scene (A vs B) -> large Hamming distance (>=16), got " .. d)
    assert_eq(sim.similar(gA, gB, 10), false, "different scenes are NOT similar at threshold 10")
end

-- =====================================================================
-- Grayscale inverted scene -> maximal distance from scene C.
-- =====================================================================
do
    local gInv = jt.dcLumaGrid(F.gray_sceneC_inverted)
    assert_true(type(gInv) == 'table', "inverted gray scene decodes")
    local d = sim.distance(sim.hash(gGray), sim.hash(gInv))
    assert_true(d >= 32, "inverted gray scene -> large distance (>=32), got " .. d)
end

-- =====================================================================
-- FAIL-OPEN: progressive / truncated / non-JPEG / empty / garbage -> nil.
-- =====================================================================
assert_eq(jt.dcLumaGrid(F.progressive_sceneA), nil,
    "a PROGRESSIVE (SOF2) JPEG fails open to nil")

do
    -- truncate a valid baseline JPEG mid-scan -> nil (no raise).
    local raw = F.color420_sceneA
    assert_eq(jt.dcLumaGrid(raw:sub(1, #raw - 6)), nil, "truncated-mid-scan -> nil")
    -- chop off everything after the SOF so there is no SOS -> nil.
    assert_eq(jt.dcLumaGrid(raw:sub(1, 30)), nil, "header-only (no SOS) -> nil")
end

assert_eq(jt.dcLumaGrid("not a jpeg at all"), nil, "non-JPEG -> nil")
assert_eq(jt.dcLumaGrid(""), nil, "empty string -> nil")
assert_eq(jt.dcLumaGrid(nil), nil, "nil input -> nil")
assert_eq(jt.dcLumaGrid(12345), nil, "non-string input -> nil")
assert_eq(jt.dcLumaGrid(string.char(0xFF, 0xD8)), nil, "SOI-only -> nil")
assert_eq(jt.dcLumaGrid(string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 0)), nil,
    "SOI + truncated SOF -> nil (no raise)")

-- =====================================================================
-- Determinism: same bytes -> identical grid (distance 0 across two decodes).
-- =====================================================================
do
    local g1 = jt.dcLumaGrid(F.color420_sceneA)
    local g2 = jt.dcLumaGrid(F.color420_sceneA)
    assert_eq(sim.distance(sim.hash(g1), sim.hash(g2)), 0,
        "decode is deterministic (same bytes -> distance 0)")
end
