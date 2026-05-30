-- test/fixtures/claude/body_fixtures.lua (Phase 7 Plan 02 — PROV2-01 Claude mapper fixtures)
--
-- Self-contained, OFFLINE *decoded* Anthropic Messages-API body tables (the shape src/json.decode
-- yields from the HTTP body string), returned as a plain Lua table so test/claude_response_spec.lua
-- can require it (no Lr, no network). Mirrors test/fixtures/openai/body_fixtures.lua style.
--
-- CRITICAL difference from OpenAI: a Claude forced-tool response carries the structured output as
-- an ALREADY-PARSED OBJECT at content[i].input (NOT a nested JSON STRING). So `input` below is a
-- Lua TABLE, never a string. A `null` confidence is written as the dkjson null SENTINEL so the
-- mapper's normalizeNulls drops it to Lua nil before validateResponse (mirroring openai's path,
-- but at the table level since there is no nested decode). The fixtures REQUIRE dkjson to obtain
-- that sentinel — dkjson is pure and require-able under the stock runner.
--
-- Fixtures: success, leadingText (text block BEFORE the tool_use), wrongThenCorrect (a FIRST
-- tool_use with the WRONG name then a SECOND with the correct name — CODEX NIT N3), inputAsString
-- (input is a JSON STRING — must NOT be double-decoded, so it degrades — the behavioral PROOF that
-- the mapper never json.decodes the input), refusal (stop_reason='refusal'), maxTokens
-- (stop_reason='max_tokens'), noToolUse (content has no tool_use block), nullConfidence,
-- nonTable (a non-table body).
--
-- Strictly Lua 5.1 common subset.

local dkjson = require 'src.lib.dkjson'
local NULL = dkjson.null

local F = {}

local TOOL = 'report_bird_identification'
F.TOOL_NAME = TOOL
F.EXPECTED_COMMON_NAME = 'Northern Cardinal'

-- A valid Northern-Cardinal detection as a PARSED OBJECT (what content[i].input carries).
-- bbox strictly ordered (x_min<x_max, y_min<y_max) so it passes validateBbox. Built fresh per
-- accessor so a mutating caller cannot corrupt a shared table.
local function validInput()
    return {
        bird_present = true,
        detections = {
            {
                bbox = { 0.30, 0.25, 0.70, 0.80 },
                common_name = 'Northern Cardinal',
                scientific_name = 'Cardinalis cardinalis',
                confidence = 0.82,
                identified_rank = 'species',
                rank_name = 'Cardinalis cardinalis',
                alternatives = {
                    {
                        common_name = 'Pyrrhuloxia',
                        scientific_name = 'Cardinalis sinuatus',
                        confidence = 0.10,
                        identified_rank = 'species',
                        rank_name = 'Cardinalis sinuatus',
                    },
                },
            },
        },
    }
end

-- The same input but with confidence == the dkjson null SENTINEL at the detection level AND inside
-- the alternatives item — exercises normalizeNulls dropping the sentinel.
local function nullConfidenceInput()
    local v = validInput()
    v.detections[1].confidence = NULL
    v.detections[1].alternatives[1].confidence = NULL
    return v
end

-- (a) SUCCESS: stop_reason='tool_use', a single correctly-named tool_use block whose input is the
-- valid parsed object. Maps + validates.
F.success = {
    stop_reason = 'tool_use',
    content = {
        { type = 'tool_use', id = 'toolu_1', name = TOOL, input = validInput() },
    },
    label = 'success: tool_use block with valid parsed input',
}

-- (b) LEADING-TEXT: a {type='text'} block BEFORE the tool_use block — the mapper must SKIP it and
-- still find the tool_use, validate.
F.leadingText = {
    stop_reason = 'tool_use',
    content = {
        { type = 'text', text = 'Here is the identification:' },
        { type = 'tool_use', id = 'toolu_2', name = TOOL, input = validInput() },
    },
    label = 'leading text block before tool_use -> skipped, still validates',
}

-- (c) WRONG-THEN-CORRECT [CODEX NIT N3]: a FIRST tool_use with the WRONG name, then a SECOND
-- tool_use with the CORRECT name. The mapper must pick the CORRECTLY-NAMED block, validate.
F.wrongThenCorrect = {
    stop_reason = 'tool_use',
    content = {
        { type = 'tool_use', id = 'toolu_x', name = 'some_other_tool',
          input = { junk = true } },
        { type = 'tool_use', id = 'toolu_3', name = TOOL, input = validInput() },
    },
    label = 'wrong-named tool_use first, correct second -> picks the correct-name block',
}

-- (d) INPUT-AS-STRING: the tool_use input is a JSON *STRING* (a misbehaving body). Because the
-- mapper consumes input AS A TABLE (NEVER json.decodes it), a string input is NOT an object and
-- MUST degrade — the behavioral proof that no nested decode happens.
F.inputAsString = {
    stop_reason = 'tool_use',
    content = {
        { type = 'tool_use', id = 'toolu_4', name = TOOL,
          input = '{"bird_present":true,"detections":[]}' },
    },
    label = 'input is a JSON STRING (not an object) -> degrade (proves no double-decode)',
}

-- (e) REFUSAL: stop_reason='refusal'. -> degrade.
F.refusal = {
    stop_reason = 'refusal',
    content = {
        { type = 'text', text = "I can't help with that." },
    },
    label = "refusal (stop_reason='refusal') -> degrade",
}

-- (f) MAX-TOKENS: stop_reason='max_tokens' (truncated). -> degrade, do NOT trust the partial body.
F.maxTokens = {
    stop_reason = 'max_tokens',
    content = {
        -- Even a present tool_use block must be ignored when truncated.
        { type = 'tool_use', id = 'toolu_5', name = TOOL, input = validInput() },
    },
    label = "truncated (stop_reason='max_tokens') -> degrade",
}

-- (g) NO-TOOL-USE: stop_reason='end_turn', content has NO tool_use block (model declined). -> degrade.
F.noToolUse = {
    stop_reason = 'end_turn',
    content = {
        { type = 'text', text = 'No bird detected.' },
    },
    label = 'no tool_use block (end_turn) -> degrade',
}

-- (h) NULL-CONFIDENCE: input has confidence == null SENTINEL (top + alternatives). -> normalize to
-- nil, validate.
F.nullConfidence = {
    stop_reason = 'tool_use',
    content = {
        { type = 'tool_use', id = 'toolu_6', name = TOOL, input = nullConfidenceInput() },
    },
    label = 'null confidence (top + alternatives) -> normalized to nil, validates',
}

-- (i) NON-TABLE: a non-table body. -> degrade, NO index error.
F.nonTable = 'not a table'

return F
