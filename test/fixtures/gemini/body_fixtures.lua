-- test/fixtures/gemini/body_fixtures.lua (Phase 7 Plan 03 — PROV2-02 Gemini mapper fixtures)
--
-- Self-contained, OFFLINE *decoded* Gemini generateContent body tables (the shape src/json.decode
-- yields from the HTTP body string), returned as a plain Lua table so test/gemini_response_spec.lua
-- can require it (no Lr, no network). Mirrors test/fixtures/claude/body_fixtures.lua style.
--
-- CRITICAL Gemini convention (07-RESEARCH): the structured output rides inside
-- candidates[1].content.parts[i].text as a JSON STRING per the responseSchema, and EACH detection
-- carries a native box as box_2d = [ymin, xmin, ymax, xmax] normalized to 0-1000 (top-left). The
-- pure gemini_response mapper decodes the text, REORDERS+SCALES box_2d -> our contract bbox
-- [x_min, y_min, x_max, y_max] in [0,1], REMOVES the box_2d key, and validates. A MATERIALLY
-- out-of-range raw coord (<0 or >1000 by a margin) drops the detection (no manufactured crop).
--
-- These fixtures provide the inner JSON-string text part (Northern Cardinal) PLUS a set of raw
-- box_2d vectors the spec feeds to geminiBoxToContract directly (the box matrix). A `null`
-- confidence is written as the dkjson null SENTINEL inside the text-decoded object analog so the
-- mapper's normalizeNulls drops it; for the wire-shaped text fixtures we use a JSON literal `null`
-- in the string (the provider's json.decode yields the sentinel, then normalizeNulls drops it).
--
-- Strictly Lua 5.1 common subset.

local F = {}

F.EXPECTED_COMMON_NAME = 'Northern Cardinal'

-- ---------------------------------------------------------------------------
-- BOX MATRIX: raw Gemini box_2d vectors [ymin, xmin, ymax, xmax] (0-1000) and the EXPECTED
-- contract bbox [x_min, y_min, x_max, y_max] in [0,1] after geminiBoxToContract (reorder + /1000).
-- The mapper's geminiBoxToContract is fed these directly by the spec.
--
-- [CODEX phase-7 #4/#5/N1] STRICT policy — NO tolerance band: any coord <0, >1000, or NON-INTEGER
-- DROPS the detection (returns nil). The prior "tiny overshoot clamps" expectation is removed.
-- ---------------------------------------------------------------------------
F.BOX = {
    -- (a) the worked doc example: {200,300,700,800} -> {0.3,0.2,0.8,0.7}.
    known       = { raw = { 200, 300, 700, 800 }, want = { 0.3, 0.2, 0.8, 0.7 } },
    -- (b) full frame: {0,0,1000,1000} -> {0,0,1,1} (validates — full-frame box, the in-range edges).
    fullFrame   = { raw = { 0, 0, 1000, 1000 }, want = { 0, 0, 1, 1 } },
    -- (c) a thin (but positive-area) box stays valid.
    thin        = { raw = { 100, 100, 110, 900 }, want = { 0.1, 0.1, 0.9, 0.11 } },
    -- (d) [CODEX phase-7 #4] STRICT DROP, just over the upper edge: 1001 > 1000 -> nil (NO clamp).
    overHigh    = { raw = { 0, 0, 1001, 1000 } },
    -- (e) [CODEX phase-7 #4] STRICT DROP, fractional just below 0: -0.1 < 0 -> nil (NO clamp).
    underLow    = { raw = { -0.1, 0, 1000, 1000 } },
    -- (f) [CODEX phase-7 #4] STRICT DROP, fractional just above 1000: 1000.1 > 1000 -> nil.
    overHighFrac = { raw = { 0, 0, 1000.1, 1000 } },
    -- (g) [CODEX phase-7 #5] STRICT DROP, in-range but NON-INTEGER coord (200.5) -> nil (never scale
    --     a fractional coord).
    fractional  = { raw = { 200.5, 300, 700, 800 } },
    -- (h) MATERIAL out-of-range: a raw coord materially <0 (here -100) -> nil (DROPPED, no crop).
    materialOut = { raw = { -100, 100, 100, 900 } },
    -- (i) degenerate (zero-area): ymin==ymax AND xmin==xmax -> reorder/scale is in-range but
    --     validateBbox rejects (x_min>=x_max) -> the detection drops.
    degenerate  = { raw = { 500, 500, 500, 500 } },
    -- (j) inverted: ymax < ymin -> reorder gives y_min > y_max -> validateBbox rejects -> drop.
    inverted    = { raw = { 800, 300, 200, 700 } },
}

-- ---------------------------------------------------------------------------
-- WIRE-SHAPED success text part: the JSON STRING the live API delivers in parts[1].text. A single
-- Northern-Cardinal detection with the worked-example box_2d {200,300,700,800}. After the mapper:
-- bbox == {0.3,0.2,0.8,0.7}, box_2d key REMOVED, validateResponse-ok.
-- ---------------------------------------------------------------------------
F.SUCCESS_TEXT =
    '{"bird_present":true,"detections":[{' ..
    '"box_2d":[200,300,700,800],' ..
    '"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis",' ..
    '"confidence":0.82,' ..
    '"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis",' ..
    '"alternatives":[]}]}'

-- The EXPECTED reordered+scaled bbox for the success detection.
F.SUCCESS_BBOX = { 0.3, 0.2, 0.8, 0.7 }

-- A success generateContent envelope (decoded) with finishReason STOP.
F.success = {
    candidates = {
        {
            content = { parts = { { text = F.SUCCESS_TEXT } } },
            finishReason = 'STOP',
        },
    },
    label = 'success: STOP candidate with a box_2d detection text part',
}

-- A success envelope whose text JSON carries a `null` confidence (top + alternatives) — the
-- mapper's normalizeNulls drops the dkjson sentinel before validation.
F.NULL_CONF_TEXT =
    '{"bird_present":true,"detections":[{' ..
    '"box_2d":[200,300,700,800],' ..
    '"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis",' ..
    '"confidence":null,' ..
    '"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis",' ..
    '"alternatives":[{"common_name":"Pyrrhuloxia","scientific_name":"Cardinalis sinuatus",' ..
    '"confidence":null,"identified_rank":"species","rank_name":"Cardinalis sinuatus"}]}]}'

F.nullConfidence = {
    candidates = {
        {
            content = { parts = { { text = F.NULL_CONF_TEXT } } },
            finishReason = 'STOP',
        },
    },
    label = 'success with null confidence (top + alternatives) -> normalized to nil, validates',
}

-- A multi-detection text where ONE detection has a material out-of-range box (dropped) and ONE is
-- valid: the valid one survives, the out-of-range one is dropped, validateResponse-ok.
F.MIXED_TEXT =
    '{"bird_present":true,"detections":[' ..
    '{"box_2d":[-100,100,100,900],"common_name":"Bad Box","scientific_name":"Badus boxus",' ..
    '"confidence":0.5,"identified_rank":"species","rank_name":"Badus boxus","alternatives":[]},' ..
    '{"box_2d":[200,300,700,800],"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis","confidence":0.82,"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis","alternatives":[]}]}'

F.mixedDrop = {
    candidates = {
        {
            content = { parts = { { text = F.MIXED_TEXT } } },
            finishReason = 'STOP',
        },
    },
    label = 'mixed: one material-out-of-range detection dropped, one valid survives',
}

-- finishReason degrade cases: MAX_TOKENS / SAFETY / RECITATION / PROHIBITED_CONTENT.
local function finishCase(reason)
    return {
        candidates = {
            {
                content = { parts = { { text = F.SUCCESS_TEXT } } },
                finishReason = reason,
            },
        },
        label = 'finishReason ' .. reason .. ' -> degrade',
    }
end
F.maxTokens         = finishCase('MAX_TOKENS')
F.safety            = finishCase('SAFETY')
F.recitation        = finishCase('RECITATION')
F.prohibitedContent = finishCase('PROHIBITED_CONTENT')

-- A top-level promptFeedback.blockReason -> degrade (the prompt was blocked).
F.promptBlocked = {
    promptFeedback = { blockReason = 'SAFETY' },
    candidates = {},
    label = 'promptFeedback.blockReason -> degrade',
}

-- Malformed text JSON (truncated) -> salvage-once then degrade.
F.malformedText = {
    candidates = {
        {
            content = { parts = { { text = '{"bird_present":true,"detections":[{"box_2d' } } },
            finishReason = 'STOP',
        },
    },
    label = 'malformed text JSON -> degrade',
}

-- Fenced text JSON: a ```json code fence around the valid object -> salvage strips the fence,
-- re-decodes, maps + validates.
F.fencedText = {
    candidates = {
        {
            content = { parts = { { text = '```json\n' .. F.SUCCESS_TEXT .. '\n```' } } },
            finishReason = 'STOP',
        },
    },
    label = 'fenced text JSON -> salvage strips fence, maps + validates',
}

-- Structural degrade cases: non-table body / empty candidates / empty parts / missing content.
F.nonTable      = 'not a table'
F.emptyCandidates = { candidates = {}, label = 'empty candidates -> degrade' }
F.emptyParts    = {
    candidates = { { content = { parts = {} }, finishReason = 'STOP' } },
    label = 'empty parts -> degrade',
}
F.missingContent = {
    candidates = { { finishReason = 'STOP' } },
    label = 'missing content -> degrade',
}

-- A no-bird success: bird_present false, empty detections (the model found no bird).
F.NOBIRD_TEXT = '{"bird_present":false,"detections":[]}'
F.noBird = {
    candidates = {
        { content = { parts = { { text = F.NOBIRD_TEXT } } }, finishReason = 'STOP' },
    },
    label = 'no bird -> validated {bird_present=false, detections={}}',
}

return F
