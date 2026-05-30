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
-- SOS / SOF malformation -> fail-open to nil (no raise). These mutate the VALID gray fixture
-- (a single-component baseline, so SOS = FFDA, len=8, ns=1, then [cs,td_ta], then Ss,Se,AhAl).
-- =====================================================================

-- locate the byte offset (1-based) of the first 0xFFDA (SOS) marker in a JPEG string, or nil.
local function findSOS(s)
    local i = 1
    while i < #s do
        if s:byte(i) == 0xFF and s:byte(i + 1) == 0xDA then return i end
        i = i + 1
    end
    return nil
end

-- replace the single byte at 1-based position `pos` of string `s` with byte `val`.
local function patch(s, pos, val)
    return s:sub(1, pos - 1) .. string.char(val) .. s:sub(pos + 1)
end

do
    local raw = F.gray_sceneC
    assert_true(type(jt.dcLumaGrid(raw)) == 'table', "control: gray fixture decodes before mutation")

    local sos = findSOS(raw)
    assert_true(sos ~= nil, "found the SOS marker in the gray fixture")
    -- SOS layout from `sos`: FF DA | lenHi lenLo | ns | [cs td_ta]*ns | Ss Se AhAl
    -- gray fixture: ns == 1, so Ss is at sos+5, Se at sos+6, AhAl at sos+7 (0-based from FF at sos).
    local nsPos   = sos + 4
    local ns      = raw:byte(nsPos)
    assert_eq(ns, 1, "gray fixture scan has ns=1")
    local ssPos   = nsPos + 1 + ns * 2   -- after ns and the ns component pairs.
    local sePos   = ssPos + 1
    local ahalPos = ssPos + 2

    -- mutate spectral selection 0,63,0 -> 1,1,1 (a progressive-style partial scan) => nil.
    local mut1 = patch(patch(patch(raw, ssPos, 1), sePos, 1), ahalPos, 1)
    assert_eq(jt.dcLumaGrid(mut1), nil, "SOS spectral bytes 1,1,1 (not 0,63,0) => nil")
    -- Ss alone non-zero => nil.
    assert_eq(jt.dcLumaGrid(patch(raw, ssPos, 1)), nil, "SOS Ss != 0 => nil")
    -- Se alone not 63 => nil.
    assert_eq(jt.dcLumaGrid(patch(raw, sePos, 62)), nil, "SOS Se != 63 => nil")
    -- AhAl non-zero (successive approximation) => nil.
    assert_eq(jt.dcLumaGrid(patch(raw, ahalPos, 0x11)), nil, "SOS AhAl != 0 => nil")

    -- bad SOS length: len must be EXACTLY 6 + 2*ns (==8 here). Bump lenLo => nil.
    local badLen = patch(raw, sos + 3, raw:byte(sos + 3) + 2)
    assert_eq(jt.dcLumaGrid(badLen), nil, "SOS declared length != 6+2*ns => nil")
end

-- SOF1 (extended sequential) and SOF9 (arithmetic) are NOT baseline SOF0 => nil. Mutate the
-- gray fixture's SOF0 marker byte (0xFFC0) to 0xC1 / 0xC9.
do
    local raw = F.gray_sceneC
    -- find the SOF0 marker (0xFFC0).
    local sof = nil
    local i = 1
    while i < #raw do
        if raw:byte(i) == 0xFF and raw:byte(i + 1) == 0xC0 then sof = i; break end
        i = i + 1
    end
    assert_true(sof ~= nil, "found the SOF0 marker in the gray fixture")
    assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, 0xC1)), nil, "SOF1 (extended sequential) => nil")
    assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, 0xC9)), nil, "SOF9 (arithmetic) => nil")
    assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, 0xC2)), nil, "SOF2 (progressive) => nil")
end

-- =====================================================================
-- S4 (CODEX W1-R2 #4): FULL SOF allow-list. ONLY baseline SOF0 (0xC0) may decode; EVERY other
-- SOFn marker (0xC1, 0xC3, 0xC5..0xC7, 0xC9..0xCF) MUST fail-open to nil. And the three non-SOF
-- markers that fall in the 0xC1..0xCF range -- DHT (0xC4), JPG/reserved (0xC8), DAC (0xCC) -- must
-- NOT be misinterpreted as a SOF: a stream carrying one of them but NO valid SOF0 yields nil (no
-- frame header parsed). This proves the marker == 0xC0 ONLY decode path and the
-- (>=0xC1 and <=0xCF and ~=0xC4 and ~=0xC8 and ~=0xCC) reject predicate in src/cluster/jpeg_thumb.lua.
-- =====================================================================
do
    local raw = F.gray_sceneC
    -- locate the SOF0 (0xFFC0) marker in the valid baseline fixture.
    local sof = nil
    local i = 1
    while i < #raw do
        if raw:byte(i) == 0xFF and raw:byte(i + 1) == 0xC0 then sof = i; break end
        i = i + 1
    end
    assert_true(sof ~= nil, "found the SOF0 marker for the full allow-list sweep")

    -- CONTROL: the UNMUTATED baseline SOF0 (0xC0) decodes to a 64-cell grid (only SOF0 decodes).
    assert_eq(cells(jt.dcLumaGrid(raw)), 64, "control: baseline SOF0 (0xC0) DOES decode (64 cells)")

    -- The complete set of non-baseline SOF markers (mutate the SOF0 marker byte to each in turn).
    -- Already covered above: 0xC1, 0xC2, 0xC9. Here we cover the REMAINING SOFn allow-list entries.
    local nonBaselineSOF = {
        { 0xC3, "SOF3 (lossless, Huffman)" },
        { 0xC5, "SOF5 (differential sequential)" },
        { 0xC6, "SOF6 (differential progressive)" },
        { 0xC7, "SOF7 (differential lossless)" },
        { 0xCA, "SOF10 (progressive, arithmetic)" },
        { 0xCB, "SOF11 (lossless, arithmetic)" },
        { 0xCD, "SOF13 (differential sequential, arithmetic)" },
        { 0xCE, "SOF14 (differential progressive, arithmetic)" },
        { 0xCF, "SOF15 (differential lossless, arithmetic)" },
    }
    for _, m in ipairs(nonBaselineSOF) do
        local code, name = m[1], m[2]
        assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, code)), nil,
            string.format("%s (0x%02X) is NOT baseline SOF0 => nil", name, code))
    end

    -- The three NON-SOF markers in the 0xC1..0xCF band MUST NOT be treated as a SOF. Mutating the
    -- ONLY SOF0 in the stream to DHT/JPG/DAC removes the baseline frame header entirely; with no
    -- valid SOF0 remaining the decoder has no frame to decode => nil (it must NOT parse the
    -- DHT/JPG/DAC marker as if it were a frame header).
    assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, 0xC4)), nil,
        "DHT (0xC4) is NOT a SOF: with the only SOF0 overwritten by DHT, no frame header => nil")
    assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, 0xC8)), nil,
        "JPG/reserved (0xC8) is NOT a SOF: no valid SOF0 remains => nil")
    assert_eq(jt.dcLumaGrid(patch(raw, sof + 1, 0xCC)), nil,
        "DAC (0xCC) is NOT a SOF: no valid SOF0 remains => nil")
end

-- An invalid / empty Huffman table (DHT with all-zero counts -> buildHuff returns nil) => nil, no raise.
do
    -- a minimal JPEG: SOI, a DHT whose 16 BITS counts are ALL ZERO (empty table) -> reject.
    local s = string.char(
        0xFF, 0xD8,                      -- SOI
        0xFF, 0xC4, 0x00, 0x13,          -- DHT, len = 19 (2 + 1 + 16)
        0x00,                            -- Tc/Th = 0 (DC table 0)
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  -- 16 all-zero counts (empty)
    )
    assert_eq(jt.dcLumaGrid(s), nil, "empty/invalid Huffman table (all-zero DHT) => nil (no raise)")
end

-- A broken restart sequence: a baseline frame declaring DRI=1 but with NO RSTn marker where one is
-- required degrades to nil (decode hits the missing-marker path) -- proven via a truncated scan that
-- carries a DRI. We reuse the valid gray fixture and INSERT a DRI (FFDD 0004 0001) right before SOS,
-- then truncate the scan so the expected restart marker is absent => nil, no raise.
do
    local raw = F.gray_sceneC
    local sos = findSOS(raw)
    assert_true(sos ~= nil, "found SOS for restart-sequence test")
    -- splice a DRI segment (restart interval = 1 MCU) just before the SOS marker.
    local dri = string.char(0xFF, 0xDD, 0x00, 0x04, 0x00, 0x01)
    local withDri = raw:sub(1, sos - 1) .. dri .. raw:sub(sos)
    -- truncate a few bytes off the end so the restart marker the decoder expects is missing.
    local broken = withDri:sub(1, #withDri - 4)
    assert_eq(jt.dcLumaGrid(broken), nil, "broken restart sequence (missing RSTn) => nil (no raise)")
end

-- =====================================================================
-- Determinism: same bytes -> identical grid (distance 0 across two decodes).
-- =====================================================================
do
    local g1 = jt.dcLumaGrid(F.color420_sceneA)
    local g2 = jt.dcLumaGrid(F.color420_sceneA)
    assert_eq(sim.distance(sim.hash(g1), sim.hash(g2)), 0,
        "decode is deterministic (same bytes -> distance 0)")
end
