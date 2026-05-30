-- test/contract_spec.lua (Phase 3 — Contracts, pure core: CTR-01 + CTR-02)
--
-- Exercises BirdAID.lrdevplugin/src/contract.lua: a PURE module (imports NO Lr*),
-- require-able under stock lua / luajit. Covers validateImage (CTR-01) with the
-- width/height keys (NIT 19) and NaN/inf dim rejection, and validateResponse (CTR-02)
-- accepting a conforming response (with a valid alternatives array) and rejecting EVERY
-- malformed shape: missing/typed fields, bbox-not-4, bbox out of [0,1], bbox NaN/inf,
-- xmin>xmax, ymin>ymax, bad rank, confidence out of range / NaN / inf, wrong-type names,
-- detections-as-map, detections-sparse-array, unexpected top-level/detection/alternative
-- keys, malformed-alternative-item, and bird_present=false-with-non-empty-detections.
-- Also checks denormalizeBbox pixel mapping.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local C = require('src.contract')

local NAN = 0 / 0
local INF = 1 / 0
local NINF = -1 / 0

-- =====================================================================
-- CTR-01: validateImage
-- =====================================================================
assert_true(C.validateImage({ kind = 'bytes', data = 'JPEGBYTES', width = 100, height = 80 }),
    "validateImage accepts kind=bytes with data+width+height")
assert_true(C.validateImage({ kind = 'file', path = '/tmp/x.jpg', width = 100, height = 80 }),
    "validateImage accepts kind=file with path+width+height")

-- non-table
do local ok, e = C.validateImage("nope"); assert_eq(ok, false, "validateImage rejects non-table"); assert_eq(e, 'image-not-table', "image-not-table err") end
-- bad/missing kind
do local ok, e = C.validateImage({ width = 1, height = 1 }); assert_eq(ok, false, "validateImage rejects missing kind"); assert_eq(e, 'bad-kind', "bad-kind err") end
do local ok, e = C.validateImage({ kind = 'weird', width = 1, height = 1 }); assert_eq(ok, false, "validateImage rejects unknown kind"); assert_eq(e, 'bad-kind', "bad-kind err 2") end
-- bytes with nil/empty data
do local ok, e = C.validateImage({ kind = 'bytes', width = 1, height = 1 }); assert_eq(ok, false, "bytes nil data rejected"); assert_eq(e, 'bytes-missing-data', "bytes-missing-data err") end
do local ok, e = C.validateImage({ kind = 'bytes', data = '', width = 1, height = 1 }); assert_eq(ok, false, "bytes empty data rejected"); assert_eq(e, 'bytes-missing-data', "bytes-missing-data err 2") end
-- file with nil/empty path
do local ok, e = C.validateImage({ kind = 'file', width = 1, height = 1 }); assert_eq(ok, false, "file nil path rejected"); assert_eq(e, 'file-missing-path', "file-missing-path err") end
do local ok, e = C.validateImage({ kind = 'file', path = '', width = 1, height = 1 }); assert_eq(ok, false, "file empty path rejected"); assert_eq(e, 'file-missing-path', "file-missing-path err 2") end
-- width/height: non-number, <=0, NaN, inf
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = 'big', height = 1 }); assert_eq(ok, false, "non-number width rejected"); assert_eq(e, 'bad-width', "bad-width err") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = 0, height = 1 }); assert_eq(ok, false, "zero width rejected"); assert_eq(e, 'bad-width', "bad-width zero") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = -5, height = 1 }); assert_eq(ok, false, "negative width rejected"); assert_eq(e, 'bad-width', "bad-width neg") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = NAN, height = 1 }); assert_eq(ok, false, "NaN width rejected"); assert_eq(e, 'bad-width', "bad-width NaN") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = INF, height = 1 }); assert_eq(ok, false, "inf width rejected"); assert_eq(e, 'bad-width', "bad-width inf") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = 100, height = 0 }); assert_eq(ok, false, "zero height rejected"); assert_eq(e, 'bad-height', "bad-height zero") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = 100, height = NAN }); assert_eq(ok, false, "NaN height rejected"); assert_eq(e, 'bad-height', "bad-height NaN") end
do local ok, e = C.validateImage({ kind = 'bytes', data = 'x', width = 100, height = NINF }); assert_eq(ok, false, "-inf height rejected"); assert_eq(e, 'bad-height', "bad-height -inf") end

-- =====================================================================
-- CTR-02: validateResponse — a CONFORMING response (with alternatives)
-- =====================================================================
local function goodDetection()
    return {
        bbox = { 0.1, 0.2, 0.5, 0.6 },
        common_name = 'Northern Cardinal',
        scientific_name = 'Cardinalis cardinalis',
        confidence = 0.91,
        identified_rank = 'species',
        rank_name = 'Cardinalis cardinalis',
        alternatives = {
            { common_name = 'House Finch', scientific_name = 'Haemorhous mexicanus',
              confidence = 0.4, identified_rank = 'species', rank_name = 'Haemorhous mexicanus' },
        },
    }
end
local function goodResponse()
    return { bird_present = true, detections = { goodDetection() } }
end

assert_true(C.validateResponse(goodResponse()),
    "validateResponse accepts a conforming response with a valid alternatives array")
-- bird_present=false WITH empty detections is valid
assert_true(C.validateResponse({ bird_present = false, detections = {} }),
    "validateResponse accepts bird_present=false with empty detections")
-- detection without alternatives (optional) is valid
do
    local d = goodDetection(); d.alternatives = nil
    assert_true(C.validateResponse({ bird_present = true, detections = { d } }),
        "validateResponse accepts a detection with no alternatives (optional)")
end

-- Helper: mutate a fresh good response and assert it is rejected with the expected err.
local function rejects(mutate, expectErr, msg)
    local r = goodResponse()
    mutate(r)
    local ok, e = C.validateResponse(r)
    assert_eq(ok, false, msg .. " (rejected)")
    if expectErr then assert_eq(e, expectErr, msg .. " err=" .. expectErr) end
end

-- top-level shape
do local ok, e = C.validateResponse("x"); assert_eq(ok, false, "non-table response rejected"); assert_eq(e, 'resp-not-table', "resp-not-table err") end
rejects(function(r) r.bird_present = nil end, 'bird_present-not-bool', "missing bird_present")
rejects(function(r) r.bird_present = "yes" end, 'bird_present-not-bool', "typed bird_present")
rejects(function(r) r.bird_present = false end, 'bird_present-false-with-detections', "bird_present=false with non-empty detections")
rejects(function(r) r.extra = 1 end, 'unexpected-top-key:extra', "unexpected top-level key")

-- detections not an ARRAY: map, sparse
rejects(function(r) r.detections = { foo = goodDetection() } end, 'detections-not-array', "detections as a MAP rejected")
rejects(function(r) r.detections = { [1] = goodDetection(), [3] = goodDetection() } end, 'detections-not-array', "detections SPARSE rejected")
rejects(function(r) r.detections = "nope" end, 'detections-not-array', "detections non-table rejected")

-- per-detection
rejects(function(r) r.detections[1] = "nope" end, 'detection-not-table@1', "detection not a table")
rejects(function(r) r.detections[1].surprise = true end, 'unexpected-detection-key:surprise@1', "unexpected detection key")
rejects(function(r) r.detections[1].bbox = { 0.1, 0.2, 0.5 } end, 'bbox-not-4@1', "bbox not length 4")
rejects(function(r) r.detections[1].bbox = { [1] = 0.1, [2] = 0.2, [4] = 0.6 } end, 'bbox-not-4@1', "bbox sparse rejected (isArray)")
rejects(function(r) r.detections[1].bbox = { 0.1, 0.2, 1.5, 0.6 } end, 'bbox-out-of-[0,1]@1', "bbox out of [0,1]")
rejects(function(r) r.detections[1].bbox = { 0.1, 0.2, NAN, 0.6 } end, 'bbox-out-of-[0,1]@1', "bbox NaN rejected")
rejects(function(r) r.detections[1].bbox = { 0.1, 0.2, INF, 0.6 } end, 'bbox-out-of-[0,1]@1', "bbox inf rejected")
rejects(function(r) r.detections[1].bbox = { 0.8, 0.2, 0.3, 0.6 } end, 'bbox-xmin>xmax@1', "xmin>xmax rejected")
rejects(function(r) r.detections[1].bbox = { 0.1, 0.8, 0.5, 0.3 } end, 'bbox-ymin>ymax@1', "ymin>ymax rejected")
rejects(function(r) r.detections[1].common_name = 42 end, 'common_name@1', "common_name wrong type")
rejects(function(r) r.detections[1].scientific_name = nil end, 'scientific_name@1', "scientific_name missing")
rejects(function(r) r.detections[1].confidence = 1.4 end, 'confidence-out-of-[0,1]@1', "confidence out of range")
rejects(function(r) r.detections[1].confidence = NAN end, 'confidence-out-of-[0,1]@1', "confidence NaN rejected")
rejects(function(r) r.detections[1].confidence = INF end, 'confidence-out-of-[0,1]@1', "confidence inf rejected")
rejects(function(r) r.detections[1].identified_rank = 'kingdom' end, 'bad-rank@1', "bad rank enum")
rejects(function(r) r.detections[1].rank_name = 99 end, 'rank_name@1', "rank_name wrong type")

-- =====================================================================
-- Phase 4 Task 0: confidence is now OPTIONAL on detections AND alternatives.
-- nil ACCEPTED; if PRESENT it must be a finite number in [0,1] (1.5/"x"/NaN rejected);
-- 0 and 1 boundaries accepted. Mirrors the "confidence is a hint the provider MAY omit;
-- we threshold it ourselves" rule (CLAUDE.md bird-ID reality).
-- =====================================================================
-- detection with NO confidence key -> ACCEPTED.
do
    local d = goodDetection(); d.confidence = nil
    assert_true(C.validateResponse({ bird_present = true, detections = { d } }),
        "Task0: detection with nil confidence ACCEPTED")
end
-- detection confidence = 1.5 -> REJECTED.
rejects(function(r) r.detections[1].confidence = 1.5 end, 'confidence-out-of-[0,1]@1', "Task0: detection confidence 1.5 rejected")
-- detection confidence = "x" (string) -> REJECTED.
rejects(function(r) r.detections[1].confidence = "x" end, 'confidence-out-of-[0,1]@1', "Task0: detection confidence string rejected")
-- detection confidence = NaN -> REJECTED.
rejects(function(r) r.detections[1].confidence = NAN end, 'confidence-out-of-[0,1]@1', "Task0: detection confidence NaN rejected")
-- boundary: confidence == 0 and confidence == 1 -> ACCEPTED.
do
    local d0 = goodDetection(); d0.confidence = 0
    assert_true(C.validateResponse({ bird_present = true, detections = { d0 } }),
        "Task0: detection confidence == 0 (boundary) ACCEPTED")
    local d1 = goodDetection(); d1.confidence = 1
    assert_true(C.validateResponse({ bird_present = true, detections = { d1 } }),
        "Task0: detection confidence == 1 (boundary) ACCEPTED")
end
-- alternatives[] entry with NO confidence key (otherwise valid) -> ACCEPTED.
do
    local d = goodDetection(); d.alternatives[1].confidence = nil
    assert_true(C.validateResponse({ bird_present = true, detections = { d } }),
        "Task0: alternative with nil confidence ACCEPTED")
end
-- alternatives[] entry with confidence = 1.5 -> REJECTED.
rejects(function(r) r.detections[1].alternatives[1].confidence = 1.5 end, 'alt-confidence-out-of-[0,1]@1', "Task0: alt confidence 1.5 rejected")

-- alternatives
rejects(function(r) r.detections[1].alternatives = { foo = 1 } end, 'alternatives-not-array@1', "alternatives as MAP rejected")
rejects(function(r) r.detections[1].alternatives = { "nope" } end, 'alternative-not-table@1', "alternative item not a table")
rejects(function(r) r.detections[1].alternatives[1].bogus = true end, 'unexpected-alt-key:bogus@1', "unexpected alternative key")
rejects(function(r) r.detections[1].alternatives[1].confidence = 9 end, 'alt-confidence-out-of-[0,1]@1', "malformed alternative (bad confidence)")
rejects(function(r) r.detections[1].alternatives[1].common_name = nil end, 'alt-common_name@1', "malformed alternative (missing common_name)")

-- =====================================================================
-- CODEX review item 9: required NON-EMPTY strings + strict (non-degenerate) bbox.
-- =====================================================================
-- empty common_name / scientific_name / rank_name are rejected (not just nil/typed).
rejects(function(r) r.detections[1].common_name = '' end, 'common_name@1', "empty common_name rejected")
rejects(function(r) r.detections[1].scientific_name = '' end, 'scientific_name@1', "empty scientific_name rejected")
rejects(function(r) r.detections[1].rank_name = '' end, 'rank_name@1', "empty rank_name rejected")
-- empty alternative strings likewise rejected.
rejects(function(r) r.detections[1].alternatives[1].rank_name = '' end, 'alt-rank_name@1', "empty alt rank_name rejected")
rejects(function(r) r.detections[1].alternatives[1].common_name = '' end, 'alt-common_name@1', "empty alt common_name rejected")

-- DEGENERATE (zero-area) bbox is rejected: x_min==x_max and y_min==y_max are useless.
rejects(function(r) r.detections[1].bbox = { 0.4, 0.2, 0.4, 0.6 } end, 'bbox-xmin>xmax@1', "x_min==x_max (zero width) rejected")
rejects(function(r) r.detections[1].bbox = { 0.1, 0.5, 0.5, 0.5 } end, 'bbox-ymin>ymax@1', "y_min==y_max (zero height) rejected")
-- the full-frame box [0,0,1,1] is ACCEPTED (0 and 1 remain valid bounds; strict-ordered).
assert_true(C.validateResponse({
    bird_present = true,
    detections = { {
        bbox = { 0, 0, 1, 1 },
        common_name = 'Northern Cardinal', scientific_name = 'Cardinalis cardinalis',
        confidence = 0.9, identified_rank = 'species', rank_name = 'Cardinalis cardinalis',
    } },
}), "item 9: full-frame bbox [0,0,1,1] accepted")

-- =====================================================================
-- Phase-4 code review #3: nonEmptyString tightened to reject whitespace-only AND the
-- literal "nil" (mirrors keyword.lua). A detection/alternative whose common_name /
-- scientific_name / rank_name is "   " or "nil" must be REJECTED; normal names still pass.
-- =====================================================================
local function detWith(over)
    local d = {
        bbox = { 0, 0, 1, 1 },
        common_name = 'Northern Cardinal', scientific_name = 'Cardinalis cardinalis',
        confidence = 0.9, identified_rank = 'species', rank_name = 'Cardinalis cardinalis',
    }
    for k, v in pairs(over) do d[k] = v end
    return { bird_present = true, detections = { d } }
end

-- whitespace-only names rejected on each carrying field.
do local ok, e = C.validateResponse(detWith({ common_name = '   ' }));     assert_eq(ok, false, "#3: whitespace common_name rejected"); assert_eq(e, 'common_name@1', "#3: common_name@1 err") end
do local ok, e = C.validateResponse(detWith({ scientific_name = ' \t ' })); assert_eq(ok, false, "#3: whitespace scientific_name rejected"); assert_eq(e, 'scientific_name@1', "#3: scientific_name@1 err") end
do local ok, e = C.validateResponse(detWith({ rank_name = '  ' }));        assert_eq(ok, false, "#3: whitespace rank_name rejected"); assert_eq(e, 'rank_name@1', "#3: rank_name@1 err") end
-- the literal "nil" string rejected (it would render as a degenerate keyword otherwise).
do local ok, e = C.validateResponse(detWith({ common_name = 'nil' }));     assert_eq(ok, false, "#3: 'nil' common_name rejected"); assert_eq(e, 'common_name@1', "#3: 'nil' common_name err") end
do local ok, e = C.validateResponse(detWith({ scientific_name = 'nil' })); assert_eq(ok, false, "#3: 'nil' scientific_name rejected"); assert_eq(e, 'scientific_name@1', "#3: 'nil' scientific_name err") end
do local ok, e = C.validateResponse(detWith({ rank_name = 'nil' }));       assert_eq(ok, false, "#3: 'nil' rank_name rejected"); assert_eq(e, 'rank_name@1', "#3: 'nil' rank_name err") end
-- a name with surrounding whitespace but real content still ACCEPTED (trim, not strip).
assert_true(C.validateResponse(detWith({ common_name = '  Northern Cardinal  ' })),
    "#3: padded-but-nonblank common_name still accepted")
-- normal names still accepted (regression guard).
assert_true(C.validateResponse(detWith({})), "#3: normal names still accepted")
-- the same tightening applies to alternatives[] items.
do
    local ok, e = C.validateResponse(detWith({
        confidence = 0.1, identified_rank = 'species',
        alternatives = { { common_name = '   ', scientific_name = 'Cardinalis', identified_rank = 'genus', rank_name = 'Cardinalis' } },
    }))
    assert_eq(ok, false, "#3: whitespace alt common_name rejected")
    assert_eq(e, 'alt-common_name@1', "#3: alt-common_name@1 err")
end
do
    local ok = C.validateResponse(detWith({
        confidence = 0.1, identified_rank = 'species',
        alternatives = { { common_name = 'Cardinal', scientific_name = 'Cardinalis', identified_rank = 'genus', rank_name = 'nil' } },
    }))
    assert_eq(ok, false, "#3: 'nil' alt rank_name rejected")
end

-- =====================================================================
-- denormalizeBbox: normalized -> pixel mapping
-- =====================================================================
do
    local px = C.denormalizeBbox({ 0.1, 0.2, 0.5, 0.6 }, 1000, 500)
    assert_eq(px[1], 100, "denormalizeBbox x_min*width")
    assert_eq(px[2], 100, "denormalizeBbox y_min*height")
    assert_eq(px[3], 500, "denormalizeBbox x_max*width")
    assert_eq(px[4], 300, "denormalizeBbox y_max*height")
end

-- validateResponse / validateImage NEVER raise (pcall battery)
do
    local battery = { nil, {}, "x", 42, true, { bird_present = true }, { bird_present = true, detections = {} } }
    for i = 1, #battery do
        assert_true(pcall(C.validateResponse, battery[i]), "validateResponse never raises (battery " .. i .. ")")
        assert_true(pcall(C.validateImage, battery[i]), "validateImage never raises (battery " .. i .. ")")
    end
    assert_true(pcall(C.validateResponse, nil), "validateResponse(nil) never raises")
end
