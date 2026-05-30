-- test/preview_spec.lua (Phase 3 — Preview, pure core: PREV-01 pure half)
--
-- Exercises BirdAID.lrdevplugin/src/preview.lua: a PURE module (imports NO Lr*),
-- require-able under stock lua / luajit. Covers parseJpegDims (length-walking SOF dim
-- parser) against baseline (SOF0), progressive (SOF2), and EXIF-embedded-thumbnail
-- fixtures (the OUTER SOF must win), the full failing-input matrix (each returns
-- (nil, err) and NEVER raises), and the newState/onCallback/decide state machine.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

-- The fixtures live under test/fixtures/ which is outside the plugin folder that
-- run.lua adds to package.path, so reach the repo root explicitly here.
package.path = package.path .. ";./?.lua"

local P = require('src.preview')
local F = require('test.fixtures.jpeg_fixtures')
local H = F.helpers

-- =====================================================================
-- parseJpegDims: the three fixtures return their known OUTER dims
-- =====================================================================
do
    local w, h = P.parseJpegDims(F.baseline.bytes)
    assert_eq(w, F.baseline.width, "baseline SOF0 width")
    assert_eq(h, F.baseline.height, "baseline SOF0 height")
end
do
    local w, h = P.parseJpegDims(F.progressive.bytes)
    assert_eq(w, F.progressive.width, "progressive SOF2 width (SOF2 accepted)")
    assert_eq(h, F.progressive.height, "progressive SOF2 height")
end
do
    -- CODEX MUST-FIX 5: the OUTER dims win; the embedded thumbnail's SOF is NEVER returned.
    local w, h = P.parseJpegDims(F.exifThumbnail.bytes)
    assert_eq(w, F.exifThumbnail.width, "EXIF case returns OUTER width (1920), not thumb")
    assert_eq(h, F.exifThumbnail.height, "EXIF case returns OUTER height (1280), not thumb")
    assert_true(w ~= F.exifThumbnail.thumbWidth and h ~= F.exifThumbnail.thumbHeight,
        "EXIF returned dims are NOT the thumbnail's (160x120)")
end

-- Helper: assert parse returns (nil, expectedErr) and does not raise.
local function rejects(bytes, expectErr, msg)
    local w, e = P.parseJpegDims(bytes)
    assert_eq(w, nil, msg .. " (nil width)")
    assert_eq(e, expectErr, msg .. " err=" .. expectErr)
end

-- =====================================================================
-- parseJpegDims: the full failing-input matrix (each returns (nil,err))
-- =====================================================================
rejects("", 'not-a-jpeg', "empty string")
rejects(H.u8(0xFF) .. H.u8(0xD8), 'not-a-jpeg', "too-short (<4 bytes)")
-- non-string inputs (number / table / boolean) -> 'not-a-jpeg'
rejects(12345, 'not-a-jpeg', "number input")
rejects({}, 'not-a-jpeg', "table input")
rejects(true, 'not-a-jpeg', "boolean input")
-- nil input (positional) -> not-a-jpeg, no raise
do local w, e = P.parseJpegDims(nil); assert_eq(w, nil, "nil input nil width"); assert_eq(e, 'not-a-jpeg', "nil input err") end

-- no SOI
rejects(H.u8(0x00) .. H.u8(0x01) .. H.u8(0x02) .. H.u8(0x03), 'no-soi', "no SOI")

-- valid APP/COM segments but NO SOF
rejects(H.SOI .. H.segment(0xE0, "JFIF\0") .. H.segment(0xFE, "a comment") .. H.EOI,
    'no-sof', "valid APP0+COM but no SOF")

-- truncated length: a marker that should carry a length, but bytes end right after it
rejects(H.SOI .. H.u8(0xFF) .. H.u8(0xE0), 'truncated-len', "truncated length bytes")

-- truncated mid-segment: APP0 declares a 20-byte length but payload is cut short
rejects(H.SOI .. H.u8(0xFF) .. H.u8(0xE0) .. H.be16(20) .. "short",
    'truncated', "truncated mid-segment (declared len overruns buffer)")

-- SOF whose DECLARED length (11) overruns the buffer (only 2 payload bytes present):
-- CODEX review item 2 rejects this as 'truncated' (declared length past EOF) — it must
-- never be trusted for dims. (Previously this fixture was mislabelled 'truncated-sof';
-- the buffer ends well before the declared segment, so 'truncated' is correct.)
rejects(H.SOI .. H.u8(0xFF) .. H.u8(0xC0) .. H.be16(11) .. H.u8(8) .. H.u8(0),
    'truncated', "SOF declared length overruns buffer")

-- bad-segment-length: a non-standalone segment whose declared length < 2 (CODEX MUST-FIX 4)
rejects(H.SOI .. H.u8(0xFF) .. H.u8(0xE0) .. H.be16(1) .. H.u8(0) .. H.u8(0),
    'bad-segment-length', "declared segment length < 2 rejected")
rejects(H.SOI .. H.u8(0xFF) .. H.u8(0xE0) .. H.be16(0) .. H.u8(0) .. H.u8(0),
    'bad-segment-length', "declared segment length 0 rejected")

-- =====================================================================
-- CODEX review item 1: SOF with an invalid/short DECLARED length (too small to
-- contain precision+height+width) is rejected ('bad-sof-length') — it must NOT
-- read the trailing bytes as dims. len=2 (< the required 8) with dim-looking bytes
-- after it: a naive parser would return 222x111; we reject.
-- =====================================================================
do
    local bytes = H.SOI .. H.u8(0xFF) .. H.u8(0xC0) .. H.be16(2)
        .. H.u8(8) .. H.be16(111) .. H.be16(222)
    local w, e = P.parseJpegDims(bytes)
    assert_eq(w, nil, "short SOF declared length -> nil width (item 1)")
    assert_eq(e, 'bad-sof-length', "short SOF declared length -> bad-sof-length (item 1)")
    assert_true(w ~= 222, "item 1: does NOT return 222x111 from a too-short SOF")
end

-- =====================================================================
-- CODEX review item 2: SOF whose DECLARED length runs PAST EOF is rejected
-- ('truncated') exactly like a non-SOF segment — it must enforce i+len <= n+1.
-- len=100 with only the dim bytes present: a naive parser would return 444x333.
-- =====================================================================
do
    local bytes = H.SOI .. H.u8(0xFF) .. H.u8(0xC0) .. H.be16(100)
        .. H.u8(8) .. H.be16(333) .. H.be16(444)
    local w, e = P.parseJpegDims(bytes)
    assert_eq(w, nil, "SOF declared length past EOF -> nil width (item 2)")
    assert_eq(e, 'truncated', "SOF declared length past EOF -> truncated (item 2)")
    assert_true(w ~= 444, "item 2: does NOT return 444x333 from an EOF-overrunning SOF")
end

-- =====================================================================
-- CODEX review item 3: reaching SOS (0xDA) before any SOF returns
-- (nil, 'sos-before-sof'); the parser must NOT scan entropy-coded scan data for
-- markers. The scan payload here contains SOF-looking bytes (FF C0 ... 66x55) that a
-- marker-scanning parser would mis-read as 55x66; the length-walking parser stops at SOS.
-- =====================================================================
do
    local sofLooking = H.u8(0xFF) .. H.u8(0xC0) .. H.be16(11)
        .. H.u8(8) .. H.be16(66) .. H.be16(55) .. H.u8(1) .. H.u8(0x11) .. H.u8(0)
    -- SOS segment: FF DA <len=2> then the (entropy-coded) scan data carrying SOF-looking
    -- bytes, then EOI. A correct parser stops AT the SOS and never inspects what follows.
    local bytes = H.SOI .. H.u8(0xFF) .. H.u8(0xDA) .. H.be16(2)
        .. sofLooking .. H.EOI
    local w, e = P.parseJpegDims(bytes)
    assert_eq(w, nil, "SOS-before-SOF -> nil width (item 3)")
    assert_eq(e, 'sos-before-sof', "SOS-before-SOF -> sos-before-sof (item 3)")
    assert_true(w ~= 55, "item 3: does NOT scan scan-data and return 55x66")
end

-- =====================================================================
-- parseJpegDims: structural markers handled correctly
-- =====================================================================
-- mid-stream RST/TEM (standalone, no length) is skipped, then the SOF is found.
do
    local bytes = H.SOI .. H.u8(0xFF) .. H.u8(0xD0)      -- RST0 standalone
        .. H.u8(0xFF) .. H.u8(0x01)                       -- TEM standalone
        .. H.sofSegment(0xC0, 320, 240) .. H.EOI
    local w, h = P.parseJpegDims(bytes)
    assert_eq(w, 320, "RST/TEM skipped, outer SOF width found")
    assert_eq(h, 240, "RST/TEM skipped, outer SOF height found")
end

-- 0xFF fill/padding bytes between markers are collapsed.
do
    local bytes = H.SOI .. H.u8(0xFF) .. H.u8(0xFF) .. H.u8(0xFF)  -- fill run
        .. H.sofSegment(0xC0, 100, 50) .. H.EOI
    local w, h = P.parseJpegDims(bytes)
    assert_eq(w, 100, "0xFF fill collapsed, SOF width found")
    assert_eq(h, 50, "0xFF fill collapsed, SOF height found")
end

-- C4 (DHT) / C8 (JPG) / CC (DAC) are NOT SOF: they are skipped as ordinary length-bearing
-- segments and the real SOF after them is what supplies the dims.
do
    local bytes = H.SOI
        .. H.segment(0xC4, "huffman-table-bytes")   -- DHT, NOT SOF
        .. H.segment(0xC8, "jpg-ext")               -- JPG, NOT SOF
        .. H.segment(0xCC, "arith-cond")            -- DAC, NOT SOF
        .. H.sofSegment(0xC0, 77, 33) .. H.EOI
    local w, h = P.parseJpegDims(bytes)
    assert_eq(w, 77, "C4/C8/CC skipped (not SOF), real SOF width found")
    assert_eq(h, 33, "C4/C8/CC skipped (not SOF), real SOF height found")
end

-- =====================================================================
-- parseJpegDims NEVER raises: pcall battery over the malformed inputs
-- =====================================================================
do
    local battery = {
        "", nil, 42, {}, true,
        H.u8(0xFF) .. H.u8(0xD8),
        H.SOI .. H.u8(0xFF) .. H.u8(0xE0),
        H.SOI .. H.u8(0xFF) .. H.u8(0xE0) .. H.be16(1) .. H.u8(0),   -- len<2
        H.SOI .. H.u8(0xFF) .. H.u8(0xE0) .. H.be16(20) .. "short",  -- truncated
        H.SOI .. H.u8(0x00),                                         -- bad marker
    }
    for i = 1, #battery do
        assert_true(pcall(P.parseJpegDims, battery[i]), "parseJpegDims never raises (battery " .. i .. ")")
    end
    -- explicit nil case (table hole drops nils above)
    assert_true(pcall(P.parseJpegDims, nil), "parseJpegDims(nil) never raises")
end

-- =====================================================================
-- State machine: newState / onCallback / decide
-- =====================================================================
do
    local st = P.newState()
    assert_eq(st.status, 'pending', "newState default status pending")
    assert_eq(st.timeoutMs, 8000, "newState default timeout 8000")
    assert_eq(P.newState(1234).timeoutMs, 1234, "newState honors timeoutMs arg")
end

-- onCallback: first non-empty string -> ready; records jpeg.
do
    local st = P.newState(8000)
    P.onCallback(st, "JPEGDATA", nil)
    assert_eq(st.status, 'ready', "onCallback string -> ready")
    assert_eq(st.jpeg, "JPEGDATA", "onCallback records jpeg")
end

-- onCallback: first nil/empty/err -> failed; records err.
do
    local st = P.newState(8000)
    P.onCallback(st, nil, "boom")
    assert_eq(st.status, 'failed', "onCallback nil -> failed")
    assert_eq(st.err, "boom", "onCallback records err")
end
do
    local st = P.newState(8000)
    P.onCallback(st, "", nil)
    assert_eq(st.status, 'failed', "onCallback empty string -> failed")
    assert_eq(st.err, "no-preview", "onCallback empty -> default err")
end

-- onCallback: records only the FIRST callback (duplicate fires ignored, no overwrite).
do
    local st = P.newState(8000)
    P.onCallback(st, "FIRST", nil)
    P.onCallback(st, "SECOND", nil)              -- ignored
    P.onCallback(st, nil, "late-error")          -- ignored
    assert_eq(st.status, 'ready', "duplicate callbacks ignored: status stays ready")
    assert_eq(st.jpeg, "FIRST", "duplicate callbacks ignored: jpeg stays FIRST")
end
do
    local st = P.newState(8000)
    P.onCallback(st, nil, "first-error")
    P.onCallback(st, "later-jpeg", nil)          -- ignored
    assert_eq(st.status, 'failed', "first failure not overwritten by later success")
    assert_eq(st.err, "first-error", "first error preserved")
end

-- decide: cancelled WINS over ready.
do
    local st = P.newState(8000)
    P.onCallback(st, "JPEGDATA", nil)
    assert_eq(P.decide(st, 0, true), 'cancelled', "cancelled wins over ready")
    assert_eq(P.decide(st, 0, false), 'ready', "ready when not cancelled")
end

-- decide: failed surfaced.
do
    local st = P.newState(8000)
    P.onCallback(st, nil, "x")
    assert_eq(P.decide(st, 0, false), 'failed', "failed surfaced")
    assert_eq(P.decide(st, 0, true), 'cancelled', "cancelled wins over failed")
end

-- decide: timeout when elapsed >= timeoutMs (mandatory branch for never-firing callback).
do
    local st = P.newState(1000)
    assert_eq(P.decide(st, 999, false), 'pending', "pending below timeout")
    assert_eq(P.decide(st, 1000, false), 'timeout', "timeout at elapsed==timeoutMs")
    assert_eq(P.decide(st, 5000, false), 'timeout', "timeout above timeoutMs")
    assert_eq(P.decide(st, 5000, true), 'cancelled', "cancelled wins over timeout")
    assert_eq(P.decide(st, nil, false), 'pending', "no elapsed -> pending")
end
