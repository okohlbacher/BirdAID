-- test/gemini_response_spec.lua (Phase 7 Plan 03 — PROV2-02 pure response mapper + box matrix)
--
-- Exercises BirdAID.lrdevplugin/src/providers/gemini_response.lua: a PURE module that requires the
-- shared src.providers.response_util (from 07-01) for finalize/degrade. Proves:
--   * geminiBoxToContract reorders + scales box_2d [ymin,xmin,ymax,xmax]/1000 -> contract
--     [x_min,y_min,x_max,y_max] in [0,1] (the worked example + full-frame + thin);
--   * [CODEX phase-7 #4/N1] STRICT range — NO tolerance band: any raw coord <0 or >1000 (e.g.
--     -0.1, 1000.1, 1001) -> nil (detection DROPPED, NOT clamped — no manufactured crop);
--   * [CODEX phase-7 #5/N1] a NON-INTEGER coord (e.g. 200.5) -> nil (DROPPED; never scale a fraction);
--   * degenerate / inverted boxes -> validateBbox rejects -> the detection drops;
--   * a success body maps to a validateResponse-ok result with the reordered bbox AND no output
--     detection carries a box_2d key (NIT N2);
--   * finishReason MAX_TOKENS/SAFETY/RECITATION/PROHIBITED_CONTENT -> degrade; promptFeedback
--     blockReason -> degrade; malformed text -> salvage-once then degrade; non-table / empty
--     candidates / empty parts / missing content -> degrade. map NEVER raises.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local mapper   = require('src.providers.gemini_response')
local contract = require('src.contract')
local F        = dofile('test/fixtures/gemini/body_fixtures.lua')

assert_true(type(mapper) == 'table', "require 'src.providers.gemini_response' resolves")
assert_true(type(mapper.map) == 'function', "mapper exposes map()")
assert_true(type(mapper.geminiBoxToContract) == 'function', "mapper exposes geminiBoxToContract()")

-- isDegrade(r): true iff r is the EXACT degrade shape {bird_present=false, detections={}}.
local function isDegrade(r)
    return type(r) == 'table'
        and r.bird_present == false
        and type(r.detections) == 'table'
        and #r.detections == 0
end

-- callMap(body, label): map MUST be total — call under pcall, assert NEVER raises, assert the
-- produced response is contract-valid; return it for further assertions.
local function callMap(body, label)
    local ok, resp = pcall(mapper.map, body)
    assert_true(ok, "map() never raises for " .. tostring(label) .. " (err=" .. tostring(resp) .. ")")
    assert_true(contract.validateResponse(resp),
        "map() output passes validateResponse for " .. tostring(label))
    return resp
end

-- approxEqArray(a, b, eps): same length + per-element within eps (float-safe).
local function approxEqArray(a, b, eps)
    eps = eps or 1e-9
    if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then return false end
    for i = 1, #a do
        local d = a[i] - b[i]
        if d < 0 then d = -d end
        if d > eps then return false end
    end
    return true
end

-- =====================================================================
-- (1) geminiBoxToContract: the box matrix (reorder + scale).
-- =====================================================================
do
    -- worked doc example {200,300,700,800} -> {0.3,0.2,0.8,0.7}.
    local r = mapper.geminiBoxToContract(F.BOX.known.raw)
    assert_true(approxEqArray(r, F.BOX.known.want),
        "geminiBoxToContract({200,300,700,800}) -> {0.3,0.2,0.8,0.7}")
    -- exact deep-equal too (the worked check is exact in floating point for these values).
    assert_eq(r[1], 0.3, "known x_min == 0.3")
    assert_eq(r[2], 0.2, "known y_min == 0.2")
    assert_eq(r[3], 0.8, "known x_max == 0.8")
    assert_eq(r[4], 0.7, "known y_max == 0.7")
    -- the contract validates the resulting box.
    local okBox = contract.validateResponse({
        bird_present = true,
        detections = { { bbox = r, common_name = 'X', scientific_name = 'Y',
            identified_rank = 'species', rank_name = 'Y', alternatives = {} } },
    })
    assert_true(okBox, "known box validates as a contract bbox")

    -- full frame {0,0,1000,1000} -> {0,0,1,1}.
    local ff = mapper.geminiBoxToContract(F.BOX.fullFrame.raw)
    assert_true(approxEqArray(ff, F.BOX.fullFrame.want), "full-frame -> {0,0,1,1}")

    -- thin box stays valid.
    local thin = mapper.geminiBoxToContract(F.BOX.thin.raw)
    assert_true(approxEqArray(thin, F.BOX.thin.want), "thin box reorder/scale matches")

    -- [CODEX phase-7 #4/N1] STRICT DROP (NO clamp): any coord <0 or >1000 -> nil.
    assert_eq(mapper.geminiBoxToContract(F.BOX.overHigh.raw), nil,
        "1001 (>1000) -> nil (STRICT drop, no clamp)")
    assert_eq(mapper.geminiBoxToContract(F.BOX.underLow.raw), nil,
        "-0.1 (<0) -> nil (STRICT drop, no clamp)")
    assert_eq(mapper.geminiBoxToContract(F.BOX.overHighFrac.raw), nil,
        "1000.1 (>1000) -> nil (STRICT drop, no clamp)")
    -- explicit edge-just-over literals too (defence: independent of the fixtures).
    assert_eq(mapper.geminiBoxToContract({ -1, 0, 1000, 1000 }), nil, "raw -1 -> nil (drop)")
    assert_eq(mapper.geminiBoxToContract({ 0, 0, 1001, 1000 }), nil, "raw 1001 -> nil (drop)")

    -- [CODEX phase-7 #5/N1] STRICT DROP: a NON-INTEGER coord (in range) -> nil (never scale a fraction).
    assert_eq(mapper.geminiBoxToContract(F.BOX.fractional.raw), nil,
        "{200.5,300,700,800} non-integer coord -> nil (STRICT drop)")
    assert_eq(mapper.geminiBoxToContract({ 200, 300.25, 700, 800 }), nil,
        "fractional xmin 300.25 -> nil (drop)")

    -- MATERIAL out-of-range -> nil (drop, no manufactured crop).
    assert_eq(mapper.geminiBoxToContract(F.BOX.materialOut.raw), nil,
        "material out-of-range box_2d -> nil (detection dropped)")

    -- the in-range integer EDGES (0 and 1000) are still ACCEPTED (boundary is inclusive).
    assert_true(approxEqArray(mapper.geminiBoxToContract({ 0, 0, 1000, 1000 }), { 0, 0, 1, 1 }),
        "edges 0 and 1000 are in-range integers -> accepted (boundary inclusive)")

    -- malformed shapes -> nil.
    assert_eq(mapper.geminiBoxToContract(nil), nil, "nil box -> nil")
    assert_eq(mapper.geminiBoxToContract({ 1, 2, 3 }), nil, "length!=4 box -> nil")
    assert_eq(mapper.geminiBoxToContract('nope'), nil, "non-table box -> nil")
end

-- =====================================================================
-- (2) SUCCESS body -> validateResponse-ok with the reordered bbox AND no box_2d key (NIT N2).
-- =====================================================================
do
    local r = callMap(F.success, 'success')
    assert_eq(r.bird_present, true, "success: bird_present == true")
    assert_true(#r.detections == 1, "success: one detection")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME, "success: common_name carried")
    assert_true(approxEqArray(r.detections[1].bbox, F.SUCCESS_BBOX),
        "success: bbox reordered+scaled to {0.3,0.2,0.8,0.7}")
    -- NIT N2: the output detection must NOT carry a leftover box_2d key.
    assert_eq(r.detections[1].box_2d, nil, "success: box_2d key REMOVED before validate")
end

-- =====================================================================
-- (3) NULL-CONFIDENCE: confidence null (top + alternatives) normalized to nil, validates.
-- =====================================================================
do
    local r = callMap(F.nullConfidence, 'nullConfidence')
    assert_eq(r.bird_present, true, "nullConfidence: bird_present true")
    assert_eq(r.detections[1].confidence, nil, "nullConfidence: detection confidence -> nil")
    assert_true(type(r.detections[1].alternatives) == 'table', "nullConfidence: alternatives kept")
    assert_eq(r.detections[1].alternatives[1].confidence, nil,
        "nullConfidence: alternative confidence -> nil")
    assert_eq(r.detections[1].box_2d, nil, "nullConfidence: box_2d still removed")
end

-- =====================================================================
-- (4) MIXED: one material-out-of-range detection dropped, one valid survives.
-- =====================================================================
do
    local r = callMap(F.mixedDrop, 'mixedDrop')
    assert_eq(r.bird_present, true, "mixedDrop: bird_present true")
    assert_eq(#r.detections, 1, "mixedDrop: the out-of-range detection was DROPPED (1 survives)")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME,
        "mixedDrop: the surviving detection is the valid one")
    assert_true(approxEqArray(r.detections[1].bbox, F.SUCCESS_BBOX),
        "mixedDrop: surviving bbox reordered+scaled correctly")
end

-- =====================================================================
-- (5) DEGENERATE / INVERTED single-detection bodies -> the detection drops -> degrade (no bird).
-- =====================================================================
do
    local function singleBoxText(raw)
        local b = string.format('[%d,%d,%d,%d]', raw[1], raw[2], raw[3], raw[4])
        return {
            candidates = { { content = { parts = { { text =
                '{"bird_present":true,"detections":[{"box_2d":' .. b ..
                ',"common_name":"X","scientific_name":"Y","confidence":0.5,' ..
                '"identified_rank":"species","rank_name":"Y","alternatives":[]}]}' } } },
                finishReason = 'STOP' } },
        }
    end
    -- degenerate -> the only detection drops -> bird_present must be coerced to a valid shape.
    local rd = callMap(singleBoxText(F.BOX.degenerate.raw), 'degenerate')
    assert_eq(#rd.detections, 0, "degenerate: the only detection dropped")
    assert_eq(rd.bird_present, false, "degenerate: empty detections -> bird_present false (valid)")

    local ri = callMap(singleBoxText(F.BOX.inverted.raw), 'inverted')
    assert_eq(#ri.detections, 0, "inverted: the only detection dropped")
    assert_eq(ri.bird_present, false, "inverted: empty detections -> bird_present false (valid)")
end

-- =====================================================================
-- (6) finishReason / promptFeedback degrade + structural degrade + malformed.
-- =====================================================================
do
    assert_true(isDegrade(callMap(F.maxTokens, 'maxTokens')), "MAX_TOKENS -> degrade")
    assert_true(isDegrade(callMap(F.safety, 'safety')), "SAFETY -> degrade")
    assert_true(isDegrade(callMap(F.recitation, 'recitation')), "RECITATION -> degrade")
    assert_true(isDegrade(callMap(F.prohibitedContent, 'prohibitedContent')),
        "PROHIBITED_CONTENT -> degrade")
    assert_true(isDegrade(callMap(F.promptBlocked, 'promptBlocked')),
        "promptFeedback.blockReason -> degrade")
    assert_true(isDegrade(callMap(F.malformedText, 'malformedText')), "malformed text -> degrade")
    assert_true(isDegrade(callMap(F.nonTable, 'nonTable')), "non-table body -> degrade")
    assert_true(isDegrade(callMap(nil, 'nil-body')), "nil body -> degrade")
    assert_true(isDegrade(callMap(42, 'number-body')), "number body -> degrade")
    assert_true(isDegrade(callMap(F.emptyCandidates, 'emptyCandidates')),
        "empty candidates -> degrade")
    assert_true(isDegrade(callMap(F.emptyParts, 'emptyParts')), "empty parts -> degrade")
    assert_true(isDegrade(callMap(F.missingContent, 'missingContent')), "missing content -> degrade")
end

-- =====================================================================
-- (7) FENCED text JSON -> salvage strips the fence, maps + validates.
-- =====================================================================
do
    local r = callMap(F.fencedText, 'fencedText')
    assert_eq(r.bird_present, true, "fencedText: bird_present true (fence salvaged)")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME, "fencedText: common_name carried")
    assert_true(approxEqArray(r.detections[1].bbox, F.SUCCESS_BBOX), "fencedText: bbox correct")
end

-- =====================================================================
-- (8) NO-BIRD body -> validated {bird_present=false, detections={}}.
-- =====================================================================
do
    local r = callMap(F.noBird, 'noBird')
    assert_true(isDegrade(r), "noBird: validated no-bird shape")
end
