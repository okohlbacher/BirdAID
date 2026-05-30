-- test/claude_response_spec.lua (Phase 7 Plan 02 — PROV2-01 pure response mapper)
--
-- Exercises BirdAID.lrdevplugin/src/providers/claude_response.lua: a PURE module that requires the
-- shared src.providers.response_util (from 07-01) for finalize/degrade. Proves map(parsedBody) is
-- TOTAL: a forced-tool body maps to a contract-valid common-schema table; a leading text block is
-- skipped; a wrong-named tool_use followed by the correct-named one selects the CORRECT block;
-- an input that is a JSON STRING (not an object) DEGRADES (proving no double-decode); refusal /
-- max_tokens / missing-tool_use / non-table all degrade with NO index error; a null confidence is
-- normalized to nil before validation; map NEVER returns an unvalidated body and NEVER raises.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local mapper   = require('src.providers.claude_response')
local contract = require('src.contract')
local F        = dofile('test/fixtures/claude/body_fixtures.lua')

assert_true(type(mapper) == 'table', "require 'src.providers.claude_response' resolves")
assert_true(type(mapper.map) == 'function', "mapper exposes map()")

-- isDegrade(r): true iff r is the EXACT degrade shape {bird_present=false, detections={}}.
local function isDegrade(r)
    return type(r) == 'table'
        and r.bird_present == false
        and type(r.detections) == 'table'
        and #r.detections == 0
end

-- callMap(body): map MUST be total — call under pcall and assert it NEVER raises, then assert the
-- produced response is contract-valid; return it for further assertions.
local function callMap(body, label)
    local ok, resp = pcall(mapper.map, body)
    assert_true(ok, "map() never raises for " .. tostring(label) .. " (err=" .. tostring(resp) .. ")")
    assert_true(contract.validateResponse(resp),
        "map() output passes validateResponse for " .. tostring(label))
    return resp
end

-- =====================================================================
-- SUCCESS: a single correctly-named tool_use block -> a validated common-schema table.
-- =====================================================================
do
    local r = callMap(F.success, 'success')
    assert_eq(r.bird_present, true, "success: bird_present == true")
    assert_true(#r.detections >= 1, "success: at least one detection")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME,
        "success: detection common_name carried through")
    assert_eq(r.detections[1].scientific_name, 'Cardinalis cardinalis',
        "success: scientific_name carried through")
end

-- =====================================================================
-- LEADING-TEXT: a {type='text'} block before the tool_use -> still finds tool_use, validates.
-- =====================================================================
do
    local r = callMap(F.leadingText, 'leadingText')
    assert_true(not isDegrade(r), "leadingText: did NOT degrade (skipped the text block)")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME,
        "leadingText: recovered the detection after skipping leading text")
end

-- =====================================================================
-- WRONG-THEN-CORRECT [CODEX NIT N3]: a wrong-named tool_use FIRST, then the correct-named one ->
-- the mapper picks the CORRECTLY-NAMED block, validates.
-- =====================================================================
do
    local r = callMap(F.wrongThenCorrect, 'wrongThenCorrect')
    assert_true(not isDegrade(r),
        "wrongThenCorrect: did NOT degrade (picked the correctly-named block)")
    assert_eq(r.detections[1].common_name, F.EXPECTED_COMMON_NAME,
        "wrongThenCorrect: selected the correct-name tool_use, not the wrong-name first block")
end

-- =====================================================================
-- INPUT-AS-STRING: the tool input is a JSON STRING, not an object. The mapper consumes input AS A
-- TABLE (never json.decodes it) so a string is NOT a valid object -> degrade. This is the
-- BEHAVIORAL PROOF that no nested decode happens.
-- =====================================================================
do
    local r = callMap(F.inputAsString, 'inputAsString')
    assert_true(isDegrade(r),
        "inputAsString: degrades (input is a string -> proves the mapper never json.decodes input)")
end

-- =====================================================================
-- REFUSAL / MAX-TOKENS / NO-TOOL-USE / NON-TABLE -> the EXACT degrade shape, NO index error.
-- =====================================================================
do
    assert_true(isDegrade(callMap(F.refusal, 'refusal')),
        "refusal (stop_reason='refusal') -> degrade")
    assert_true(isDegrade(callMap(F.maxTokens, 'maxTokens')),
        "max_tokens (truncated) -> degrade even if a tool_use block is present")
    assert_true(isDegrade(callMap(F.noToolUse, 'noToolUse')),
        "no tool_use block (end_turn) -> degrade")
    assert_true(isDegrade(callMap(F.nonTable, 'nonTable')),
        "non-table body -> degrade (no index error)")
    assert_true(isDegrade(callMap(nil, 'nil-body')), "nil body -> degrade")
    assert_true(isDegrade(callMap(42, 'number-body')), "number body -> degrade")
end

-- =====================================================================
-- NULL-CONFIDENCE: confidence == null sentinel (top + alternatives) normalized to nil, validates.
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
