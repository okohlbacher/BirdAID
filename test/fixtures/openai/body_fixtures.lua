-- test/fixtures/openai/body_fixtures.lua (Phase 5 — PROV-02/PROV-04 mapper fixtures)
--
-- Self-contained, OFFLINE *decoded* Chat Completions body tables (the shape src/json.decode
-- yields from the HTTP body string), returned as a plain Lua table so test/openai_response_spec.lua
-- can require it (no Lr, no network). Mirrors test/fixtures/jpeg_fixtures.lua / status_fixtures.lua
-- style (offline plain data tables).
--
-- IMPORTANT: choices[1].message.content is itself a JSON *STRING* (the model's structured
-- output), NOT a nested table — the mapper nested-decodes it via src.json. So each `content`
-- below is a string literal of JSON. A `null` confidence is written as the JSON token `null`
-- inside that string; after nested-decode dkjson materializes it as the dkjson.null SENTINEL,
-- which the mapper's normalizeNulls drops to Lua nil before validateResponse.
--
-- Fixtures (CODEX MUST-FIX 4 + NIT 2/3): success, refusal, null-confidence, missing-choices,
-- missing-message, empty-content, missing-content, malformed-recoverable (fence-wrapped valid
-- JSON + trailing prose), malformed-unrecoverable (garbled/truncated JSON), truncated
-- (finish_reason='length'), content_filter (finish_reason='content_filter'),
-- contradictory (bird_present=false WITH a non-empty detections array — a repair target).
--
-- Strictly Lua 5.1 common subset.

local F = {}

-- A valid Northern-Cardinal detection as a JSON STRING (what message.content carries).
-- bbox strictly ordered (x_min<x_max, y_min<y_max) so it passes validateBbox.
local VALID_CARDINAL_JSON =
    '{"bird_present":true,"detections":[{' ..
    '"bbox":[0.30,0.25,0.70,0.80],' ..
    '"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis",' ..
    '"confidence":0.82,' ..
    '"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis",' ..
    '"alternatives":[{' ..
    '"common_name":"Pyrrhuloxia","scientific_name":"Cardinalis sinuatus",' ..
    '"confidence":0.10,"identified_rank":"species","rank_name":"Cardinalis sinuatus"}]' ..
    '}]}'

-- The same detection but with confidence:null at the detection level AND inside the
-- alternatives item — exercises normalizeNulls dropping the dkjson null sentinel (Pitfalls 1/2).
local NULL_CONFIDENCE_JSON =
    '{"bird_present":true,"detections":[{' ..
    '"bbox":[0.30,0.25,0.70,0.80],' ..
    '"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis",' ..
    '"confidence":null,' ..
    '"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis",' ..
    '"alternatives":[{' ..
    '"common_name":"Pyrrhuloxia","scientific_name":"Cardinalis sinuatus",' ..
    '"confidence":null,"identified_rank":"species","rank_name":"Cardinalis sinuatus"}]' ..
    '}]}'

-- Expose the recovered/expected common_name so the spec can assert the RECOVERY distinctly
-- from a degrade (CODEX NIT 2 — no trivial "salvages OR degrades" pass).
F.EXPECTED_COMMON_NAME = "Northern Cardinal"

-- (a) SUCCESS: finish_reason='stop', content is the valid JSON string. Maps + validates.
F.success = {
    choices = {
        { finish_reason = 'stop', message = { content = VALID_CARDINAL_JSON, refusal = nil } },
    },
    label = 'success: stop, valid structured-output content',
}

-- (b) REFUSAL: message.refusal is a non-empty string. -> degrade.
F.refusal = {
    choices = {
        {
            finish_reason = 'stop',
            message = {
                content = nil,
                refusal = "I'm sorry, but I can't help identify individuals in this image.",
            },
        },
    },
    label = 'refusal: message.refusal is a non-empty string -> degrade',
}

-- (c) NULL-CONFIDENCE: content has confidence:null (top + alternatives). -> normalize to nil, validate.
F.nullConfidence = {
    choices = {
        { finish_reason = 'stop', message = { content = NULL_CONFIDENCE_JSON } },
    },
    label = 'null confidence (top + alternatives) -> normalized to nil, validates',
}

-- (d) MISSING-CHOICES: an empty table (choices nil). -> degrade, NO index error.
F.missingChoices = {
    label = 'missing choices entirely -> degrade',
}

-- (d2) EMPTY-CHOICES: choices present but empty (#==0). -> degrade.
F.emptyChoices = {
    choices = {},
    label = 'empty choices array -> degrade',
}

-- (e) MISSING-MESSAGE: choices[1] with no message. -> degrade, NO index error.
F.missingMessage = {
    choices = {
        { finish_reason = 'stop' },
    },
    label = 'choices[1] has no message -> degrade',
}

-- (f) EMPTY-CONTENT: message.content == "". -> degrade.
F.emptyContent = {
    choices = {
        { finish_reason = 'stop', message = { content = "" } },
    },
    label = 'empty content string -> degrade',
}

-- (f2) MISSING-CONTENT: message present, content nil (no refusal). -> degrade (CODEX NIT 3).
F.missingContent = {
    choices = {
        { finish_reason = 'stop', message = { refusal = nil } },
    },
    label = 'missing content (nil, no refusal) -> degrade',
}

-- (g) MALFORMED-RECOVERABLE: content is the VALID JSON wrapped in ```json fences + trailing
-- prose. A naive nested-decode FAILS; salvage (strip fences/prose) recovers it (CODEX NIT 2).
F.malformedRecoverable = {
    choices = {
        {
            finish_reason = 'stop',
            message = {
                content = "```json\n" .. VALID_CARDINAL_JSON .. "\n```\nThat's my best guess.",
            },
        },
    },
    label = 'fence-wrapped valid JSON + prose -> RECOVERS via salvage to a validated detection',
}

-- (h) MALFORMED-UNRECOVERABLE: garbled/truncated JSON that fence-strip cannot fix. -> degrade.
F.malformedUnrecoverable = {
    choices = {
        {
            finish_reason = 'stop',
            message = { content = '{"bird_present":true,"detections":[{"common_name":"North' },
        },
    },
    label = 'garbled/truncated JSON (fence-strip cannot fix) -> degrade',
}

-- (i) TRUNCATED: finish_reason='length' (token cap). -> degrade, do NOT use the partial body.
F.truncated = {
    choices = {
        {
            finish_reason = 'length',
            -- even if some content exists, finish_reason='length' forces a degrade.
            message = { content = '{"bird_present":true,"detections":[{"common_name":"Nor' },
        },
    },
    label = "truncated (finish_reason='length') -> degrade",
}

-- (j) CONTENT_FILTER: finish_reason='content_filter' (output filtered). -> degrade (CODEX NIT 3).
F.contentFilter = {
    choices = {
        {
            finish_reason = 'content_filter',
            message = { content = "" },
        },
    },
    label = "filtered (finish_reason='content_filter') -> degrade",
}

-- (k) CONTRADICTORY: content decodes + is well-formed but bird_present=false WITH a non-empty
-- detections array (rejected by validateResponse). repairOnce drops the detections -> validates.
F.contradictory = {
    choices = {
        {
            finish_reason = 'stop',
            message = {
                content =
                    '{"bird_present":false,"detections":[{' ..
                    '"bbox":[0.30,0.25,0.70,0.80],' ..
                    '"common_name":"Northern Cardinal",' ..
                    '"scientific_name":"Cardinalis cardinalis",' ..
                    '"confidence":0.40,' ..
                    '"identified_rank":"species",' ..
                    '"rank_name":"Cardinalis cardinalis"}]}',
            },
        },
    },
    label = 'bird_present=false WITH detections (contradictory) -> repaired-once or degraded',
}

return F
