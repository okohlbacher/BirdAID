-- test/e2e_fake_spec.lua (Phase 3 — FAKE-01 full OFFLINE identify() round-trip)
--
-- The phase acceptance gate: a complete, fully OFFLINE detection round-trip with NO
-- network. Drives the actual pure modules end to end:
--
--   fixture JPEG bytes
--     -> preview.parseJpegDims(bytes)            (PREV-01, Plan 03-01)
--     -> image = {kind='bytes', data, width, height}
--     -> contract.validateImage(image) == ok     (CTR-01, Plan 03-01)
--     -> prompt.build(ctx, prefs)                 (PRMPT-01, this plan)
--     -> provider.identify(image, ctx)            (FAKE-01, this plan)
--     -> contract.validateResponse(resp) == ok    (CTR-02, Plan 03-01)
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

-- The fixtures live under test/fixtures/ which is outside the plugin folder that run.lua
-- adds to package.path, so reach the repo root explicitly here.
package.path = package.path .. ";./?.lua"

local preview = require('src.preview')
local contract = require('src.contract')
local prompt = require('src.prompt')
local meta = require('src.metadata')
local providers = require('src.providers.init')
local F = require('test.fixtures.jpeg_fixtures')

-- =====================================================================
-- Full offline round-trip on the baseline fixture (bird present, default fixture).
-- =====================================================================
do
    -- 1. fixture JPEG bytes -> ACTUAL decoded dims (no network).
    local w, h = preview.parseJpegDims(F.baseline.bytes)
    assert_eq(w, F.baseline.width, "round-trip: parsed width matches fixture")
    assert_eq(h, F.baseline.height, "round-trip: parsed height matches fixture")

    -- 2. build the image-transport table and validate it (CTR-01).
    local image = { kind = 'bytes', data = F.baseline.bytes, width = w, height = h }
    local okImg, imgErr = contract.validateImage(image)
    assert_true(okImg, "round-trip: validateImage ok (err=" .. tostring(imgErr) .. ")")

    -- 3. shape a privacy-gated ctx (GPS/date ON by default) and build the prompt.
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 0 },
        { sendGpsDate = true, usePathHint = false })
    local p = prompt.build(ctx, { promptAddition = "" })
    assert_true(type(p) == 'string' and #p > 0, "round-trip: prompt built")
    -- the prompt carried the toggled-on context and still ends with the schema directive.
    assert_true(string.find(p, "latitude 51.5", 1, true) ~= nil, "round-trip: prompt has gps")
    assert_true(string.sub(p, #p - #prompt.SCHEMA_DIRECTIVE + 1) == prompt.SCHEMA_DIRECTIVE,
        "round-trip: prompt ends with schema directive")

    -- 4. resolve the OFFLINE fake provider and identify (no network).
    local provider, perr = providers.select({ provider = 'fake' })
    assert_true(provider ~= nil, "round-trip: fake provider resolved (err=" .. tostring(perr) .. ")")
    local resp, rerr = provider.identify(image, ctx)
    assert_true(resp ~= nil, "round-trip: identify returned a response (err=" .. tostring(rerr) .. ")")

    -- 5. the response PASSES the canonical validator (CTR-02).
    local okResp, respErr = contract.validateResponse(resp)
    assert_true(okResp, "round-trip: final validateResponse ok (err=" .. tostring(respErr) .. ")")
    assert_eq(resp.bird_present, true, "round-trip: bird_present true (default fixture)")

    -- 6. the bbox denormalizes against the EXACT decoded frame (Phase 6 inheritance).
    local d = resp.detections[1]
    local px = contract.denormalizeBbox(d.bbox, w, h)
    assert_true(px[3] > px[1] and px[4] > px[2], "round-trip: denormalized bbox is well-ordered")
end

-- =====================================================================
-- Round-trip on the EXIF-thumbnail fixture (OUTER dims) + the 'none' fixture path.
-- =====================================================================
do
    local w, h = preview.parseJpegDims(F.exifThumbnail.bytes)
    assert_eq(w, F.exifThumbnail.width, "round-trip: EXIF outer width (not thumbnail)")
    local image = { kind = 'bytes', data = F.exifThumbnail.bytes, width = w, height = h }
    assert_true(contract.validateImage(image), "round-trip: EXIF image validates")

    local provider = providers.select({ provider = 'fake' })
    -- a no-bird ctx selects the 'none' fixture
    local ctx = { fakeFixture = 'none' }
    local resp, rerr = provider.identify(image, ctx)
    assert_true(resp ~= nil, "round-trip: none identify ok (err=" .. tostring(rerr) .. ")")
    assert_true(contract.validateResponse(resp), "round-trip: none response validates")
    assert_eq(resp.bird_present, false, "round-trip: none -> bird_present false")
end
