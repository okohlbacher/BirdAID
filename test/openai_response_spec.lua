-- test/openai_response_spec.lua (Phase 5 — PROV-02/PROV-04 pure response mapper)
--
-- Exercises BirdAID.lrdevplugin/src/providers/openai_response.lua: a PURE module (the only
-- requires are the pure src.json / src.contract / src.lib.dkjson), require-able under stock
-- lua / luajit. Proves map(parsedBody) is TOTAL: a success body maps to a contract-valid
-- common-schema table; refusal / missing-choices / missing-message / empty-content / truncated
-- / content_filter / unrecoverable-malformed all DEGRADE to {bird_present=false,detections={}}
-- with NO index error; a fence-wrapped valid body RECOVERS via local salvage; a null
-- confidence is normalized to Lua nil before validation; map NEVER returns an unvalidated body
-- and NEVER raises.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local mapper   = require('src.providers.openai_response')
local contract = require('src.contract')
local F        = dofile('test/fixtures/openai/body_fixtures.lua')

assert_true(type(mapper) == 'table', "require 'src.providers.openai_response' resolves")
assert_true(type(mapper.map) == 'function', "mapper exposes map()")

-- isDegrade(r): true iff r is the EXACT degrade shape {bird_present=false, detections={}}.
local function isDegrade(r)
    return type(r) == 'table'
        and r.bird_present == false
        and type(r.detections) == 'table'
        and #r.detections == 0
end

-- callMap(body): map MUST be total — call under pcall and assert it NEVER raises, then
-- return the produced response for further assertions.
local function callMap(body, label)
    local ok, resp = pcall(mapper.map, body)
    assert_true(ok, "map() never raises for " .. tostring(label) .. " (err=" .. tostring(resp) .. ")")
    -- map must always return a contract-valid table (a mapped response OR the degrade shape).
    assert_true(contract.validateResponse(resp),
        "map() output passes validateResponse for " .. tostring(label))
    return resp
end

-- =====================================================================
-- SUCCESS: maps to a validated common-schema table carrying the expected common_name.
-- =====================================================================
do
    local r = callMap(F.success, 'success')
    assert_eq(r.bird_present, true, "success: bird_present == true")
    assert_true(#r.detections >= 1, "success: at least one detection")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME,
        "success: detection common_name carried through")
    assert_eq(r.detections[1].scientific_name, "Cardinalis cardinalis",
        "success: scientific_name carried through")
end

-- =====================================================================
-- REFUSAL: message.refusal non-empty string -> the EXACT degrade shape.
-- =====================================================================
do
    local r = callMap(F.refusal, 'refusal')
    assert_true(isDegrade(r), "refusal -> exact degrade shape {bird_present=false,detections={}}")
end

-- =====================================================================
-- NULL-CONFIDENCE: confidence:null (top + alternatives) normalized to nil, then validates.
-- =====================================================================
do
    local r = callMap(F.nullConfidence, 'nullConfidence')
    assert_eq(r.bird_present, true, "nullConfidence: bird_present true")
    assert_eq(r.detections[1].confidence, nil,
        "nullConfidence: detection confidence normalized to nil (key absent)")
    assert_true(type(r.detections[1].alternatives) == 'table',
        "nullConfidence: alternatives preserved")
    assert_eq(r.detections[1].alternatives[1].confidence, nil,
        "nullConfidence: alternative confidence normalized to nil (key absent)")
end

-- =====================================================================
-- STRUCTURAL ABSENCE -> degrade, NO index error (CODEX MUST-FIX 4).
-- =====================================================================
do
    assert_true(isDegrade(callMap(F.missingChoices, 'missingChoices')),
        "missing choices -> degrade (no index error)")
    assert_true(isDegrade(callMap(F.emptyChoices, 'emptyChoices')),
        "empty choices array -> degrade")
    assert_true(isDegrade(callMap(F.missingMessage, 'missingMessage')),
        "missing message -> degrade (no index error)")
    assert_true(isDegrade(callMap(F.emptyContent, 'emptyContent')),
        "empty content -> degrade")
end

-- =====================================================================
-- map is total even for a non-table parsedBody (defensive).
-- =====================================================================
do
    assert_true(isDegrade(callMap(nil, 'nil-body')), "nil parsedBody -> degrade")
    assert_true(isDegrade(callMap("not a table", 'string-body')), "string parsedBody -> degrade")
    assert_true(isDegrade(callMap(42, 'number-body')), "number parsedBody -> degrade")
end

-- =====================================================================
-- Task 2 — SALVAGE (recover) vs DEGRADE, asserted DISTINCTLY (CODEX NIT 2): the
-- fence-wrapped-but-valid body MUST recover to a VALIDATED non-degraded detection (assert the
-- recovered common_name); the unrecoverable body MUST degrade. No "salvages OR degrades" pass.
-- =====================================================================
do
    local r = callMap(F.malformedRecoverable, 'malformedRecoverable')
    assert_true(not isDegrade(r),
        "malformed-RECOVERABLE: did NOT degrade (recovered via fence-strip)")
    assert_eq(r.bird_present, true, "malformed-RECOVERABLE: bird_present true after salvage")
    assert_true(#r.detections >= 1, "malformed-RECOVERABLE: has a detection after salvage")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME,
        "malformed-RECOVERABLE: recovered the expected common_name")
end
do
    local r = callMap(F.malformedUnrecoverable, 'malformedUnrecoverable')
    assert_true(isDegrade(r), "malformed-UNRECOVERABLE -> degrade (fence-strip cannot fix)")
end

-- =====================================================================
-- Task 2 — TRUNCATION (length) and CONTENT_FILTER each degrade token-free (CODEX NIT 3),
-- plus missing-content.
-- =====================================================================
do
    assert_true(isDegrade(callMap(F.truncated, 'truncated')),
        "truncated (finish_reason='length') -> degrade")
    assert_true(isDegrade(callMap(F.contentFilter, 'contentFilter')),
        "content_filter (finish_reason='content_filter') -> degrade")
    assert_true(isDegrade(callMap(F.missingContent, 'missingContent')),
        "missing content (nil, no refusal) -> degrade")
end

-- =====================================================================
-- Task 2 — CONTRADICTORY validated shape: bird_present=false WITH a non-empty detections
-- array is repaired-once (detections dropped) OR degraded; either way the result validates
-- and is the no-bird shape.
-- =====================================================================
do
    local r = callMap(F.contradictory, 'contradictory')
    assert_eq(r.bird_present, false, "contradictory: bird_present false after repair")
    assert_eq(#r.detections, 0, "contradictory: detections dropped (repaired or degraded)")
    assert_true(isDegrade(r), "contradictory: resolves to the valid no-bird shape")
end
