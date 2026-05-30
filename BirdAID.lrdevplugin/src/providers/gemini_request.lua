-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/gemini_request.lua (Phase 7 Plan 03 — PROV2-02 PURE builder)
--
-- PURE module: imports NO Lr* module, NO LrStringUtils, performs NO base64 encoding and NO
-- network I/O. It is pure table composition, so it is require-able under stock lua / lua5.1 /
-- luajit for offline unit testing (the CODEX-mandated separation invariant; the no-Lr purity grep
-- stays clean). The RAW base64 image bytes are SUPPLIED BY THE CALLER (the shared Lr glue's
-- attachImage sets image.b64); this builder NEVER encodes them.
--
-- build(prompt, image, model) -> the Gemini generateContent request body table for a single-shot,
-- single-image vision call with structured output (07-RESEARCH lines 196-214). Shape:
--   { contents = { { parts = {
--       { text = <prompt> },                                          -- the GEMINI box directive
--       { inline_data = { mime_type='image/jpeg', data=<image.b64> } } -- RAW base64
--     } } },
--     generationConfig = { responseMimeType='application/json', responseSchema=M.SCHEMA } }
--
-- NOTE the `prompt` handed in is ALREADY built with the GEMINI box directive — the provider calls
-- prompt.build(ctx, prefs, {boxFormat='gemini'}) (CODEX MUST-FIX 1). This builder just embeds it
-- verbatim; it neither knows nor cares about the box-format option.
--
-- CRITICAL (07-RESEARCH Pitfall 6): Gemini wants the RAW base64 string in inline_data.data (with a
-- separate mime_type), NOT a base64 DATA URL with the scheme/MIME prefix. The shared glue's
-- attachImage produces BOTH shapes; this builder reads image.b64 (raw) only — never the dataUrl.
--
-- M.SCHEMA is the Gemini responseSchema translation of contract.lua's CTR-02 response. The
-- detection's box field is named `box_2d` (the model's LEARNED native field name — reusing it
-- maximizes the chance the native detector emits the right [ymin,xmin,ymax,xmax]/1000 convention)
-- typed {type='array', items={type='integer'}} (07-RESEARCH Pitfall 4 — native boxes are integers
-- 0-1000). The gemini_response mapper translates box_2d -> our bbox + removes the key. We use
-- camelCase generationConfig keys (responseMimeType/responseSchema) + inline_data for the part to
-- match the verified docs examples exactly (snake/camel mismatch can silently no-op).
--
-- M.DETECTION_KEYS / M.ALT_KEYS export the exact required-key arrays this module used to build the
-- schema so the spec can deep-equal the emitted `required` arrays WITHOUT parsing source (CODEX
-- MUST-FIX 12). DETECTION_KEYS names box_2d (NOT bbox) — the gemini wire field.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local M = {}

-- The taxonomic-rank enum, mirroring contract.lua's RANKS (most specific to least).
local RANKS = { 'species', 'genus', 'family', 'order', 'class' }

-- The ORDERED required-key arrays (exported for the spec to deep-equal — CODEX MUST-FIX 12).
-- The detection key set MIRRORS contract.lua's ALLOWED_DETECTION EXCEPT the box field is the
-- Gemini wire name `box_2d` (translated to `bbox` + removed by gemini_response before validate).
M.DETECTION_KEYS = {
    'box_2d', 'common_name', 'scientific_name', 'confidence',
    'identified_rank', 'rank_name', 'alternatives',
}
M.ALT_KEYS = {
    'common_name', 'scientific_name', 'confidence', 'identified_rank', 'rank_name',
}

-- shallow copy of an array (so M.SCHEMA's `required` arrays are independent of the exported
-- M.DETECTION_KEYS / M.ALT_KEYS tables — a caller mutating one must not corrupt the other).
local function copyArray(a)
    local out = {}
    for i = 1, #a do out[i] = a[i] end
    return out
end

-- An identified_rank property: a string constrained to the RANKS enum. Each call returns a FRESH
-- table (and a fresh enum copy) so detection + alternatives do not share a node.
local function rankProperty()
    return { type = 'string', enum = copyArray(RANKS) }
end

-- The alternatives[] item schema. (Gemini structured output supports enum/nullable; we keep the
-- field set mirroring the contract. confidence is a plain number here — the mapper accepts a
-- present-or-absent confidence and normalizeNulls drops a null.)
local function altItemSchema()
    return {
        type = 'object',
        required = copyArray(M.ALT_KEYS),
        properties = {
            common_name     = { type = 'string' },
            scientific_name = { type = 'string' },
            confidence      = { type = 'number' },
            identified_rank = rankProperty(),
            rank_name       = { type = 'string' },
        },
    }
end

-- The detections[] item schema. The box field is `box_2d` typed array-of-integer (07-RESEARCH
-- Pitfall 4); NO array length bounds (length==4 / range / ordering enforced DOWNSTREAM by
-- contract.validateBbox after the gemini_response reorder/scale).
local function detectionItemSchema()
    return {
        type = 'object',
        required = copyArray(M.DETECTION_KEYS),
        properties = {
            box_2d          = { type = 'array', items = { type = 'integer' } },
            common_name     = { type = 'string' },
            scientific_name = { type = 'string' },
            confidence      = { type = 'number' },
            identified_rank = rankProperty(),
            rank_name       = { type = 'string' },
            alternatives    = { type = 'array', items = altItemSchema() },
        },
    }
end

-- The full responseSchema constant (built once at load; field names mirror contract.lua except
-- the gemini box field name box_2d).
M.SCHEMA = {
    type = 'object',
    required = { 'bird_present', 'detections' },
    properties = {
        bird_present = { type = 'boolean' },
        detections   = { type = 'array', items = detectionItemSchema() },
    },
}

-- build(prompt, image, model) -> the Gemini generateContent request body table (see header).
-- image.b64 is the caller-supplied RAW base64 string (may be nil if the caller has not yet
-- attached it; the builder never invents/encodes one — inline_data.data stays nil).
-- The `model` lives in the URL path (set by the provider), NOT the body, so it is unused here.
function M.build(prompt, image, model)
    image = image or {}
    return {
        contents = {
            {
                parts = {
                    { text = prompt },
                    {
                        inline_data = {
                            mime_type = 'image/jpeg',
                            data = image.b64,
                        },
                    },
                },
            },
        },
        generationConfig = {
            responseMimeType = 'application/json',
            responseSchema = M.SCHEMA,
        },
    }
end

return M
