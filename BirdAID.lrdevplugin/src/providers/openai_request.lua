-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/openai_request.lua (PROV-02/03 — PURE request builder)
--
-- PURE module: imports NO Lr* module, NO LrStringUtils, performs NO base64 encoding and NO
-- network I/O. It is pure table composition, so it is require-able under stock lua / lua5.1 /
-- luajit for offline unit testing (the CODEX-mandated separation invariant). The base64 data
-- URL is SUPPLIED BY THE CALLER (the Lr glue in Plan 05-04 encodes preview bytes and hands us
-- image.dataUrl); this builder NEVER encodes it.
--
-- build(prompt, image, model) -> the OpenAI Chat Completions request body table for a
-- single-shot, single-image vision call with Structured Outputs (strict JSON schema). Shape
-- (VERIFIED 2026, 05-RESEARCH "Chat Completions request body"):
--   { model = <model>,                        -- passed THROUGH unvalidated (Pitfall 6)
--     messages = { { role='user', content = {
--       { type='text',      text=<prompt> },
--       { type='image_url', image_url={ url=<image.dataUrl> } } } } },
--     response_format = { type='json_schema',
--       json_schema = { name='bird_identification', strict=true, schema=M.SCHEMA } } }
-- detail is OMITTED for v1 (API default — locked decision; a cost/quality lever for later).
--
-- M.SCHEMA is the strict translation of contract.lua's CTR-02 response, kept in the
-- STRICT-SUPPORTED SUBSET ONLY [CODEX MUST-FIX 1]: the ONLY schema keywords anywhere are
-- type / enum / required / additionalProperties / properties / items, plus the
-- ["type","null"] nullable union. In particular bbox is {type='array', items={type='number'}}
-- with NO minItems/maxItems (those 400 under strict mode for some models); the bbox length==4
-- rule (and [0,1] ordering, degenerate-box rejection) is enforced DOWNSTREAM by
-- contract.validateResponse, NOT by the schema. Under strict mode EVERY object must set
-- additionalProperties=false and list EVERY property in `required`, so the schema is a STRICT
-- SUPERSET of the contract [CODEX NIT 1]: confidence + alternatives are required+nullable HERE
-- even though confidence is OPTIONAL in the contract (the 05-02 response mapper accepts
-- confidence number/null and alternatives present/empty/null).
--
-- M.DETECTION_KEYS / M.ALT_KEYS export the exact required-key arrays this module used to build
-- the schema, so the spec can deep-equal the emitted schema's `required` arrays against them
-- WITHOUT parsing any source [CODEX MUST-FIX 12]. The contract's ALLOWED_DETECTION /
-- ALLOWED_ALT sets are LOCAL/unexported there; this module mirrors them as ORDERED arrays.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local M = {}

-- The taxonomic-rank enum, mirroring contract.lua's RANKS (most specific to least).
local RANKS = { 'species', 'genus', 'family', 'order', 'class' }

-- The ORDERED required-key arrays (exported for the spec to deep-equal — CODEX MUST-FIX 12).
-- These MIRROR contract.lua's ALLOWED_DETECTION / ALLOWED_ALT key sets exactly.
M.DETECTION_KEYS = {
    'bbox', 'common_name', 'scientific_name', 'confidence',
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

-- An identified_rank property: a string constrained to the RANKS enum. Each call returns a
-- FRESH table (and a fresh enum copy) so detection + alternatives do not share a node.
local function rankProperty()
    return { type = 'string', enum = copyArray(RANKS) }
end

-- The alternatives[] item schema (strict-subset object). confidence is required+nullable.
local function altItemSchema()
    return {
        type = 'object',
        additionalProperties = false,
        required = copyArray(M.ALT_KEYS),
        properties = {
            common_name     = { type = 'string' },
            scientific_name = { type = 'string' },
            confidence      = { type = { 'number', 'null' } },
            identified_rank = rankProperty(),
            rank_name       = { type = 'string' },
        },
    }
end

-- The detections[] item schema (strict-subset object). bbox is {array of number} with NO
-- minItems/maxItems; confidence + alternatives are required+nullable (strict superset).
local function detectionItemSchema()
    return {
        type = 'object',
        additionalProperties = false,
        required = copyArray(M.DETECTION_KEYS),
        properties = {
            bbox            = { type = 'array', items = { type = 'number' } },
            common_name     = { type = 'string' },
            scientific_name = { type = 'string' },
            confidence      = { type = { 'number', 'null' } },
            identified_rank = rankProperty(),
            rank_name       = { type = 'string' },
            alternatives    = { type = 'array', items = altItemSchema() },
        },
    }
end

-- The full strict JSON schema constant (built once at load; field names mirror contract.lua).
M.SCHEMA = {
    type = 'object',
    additionalProperties = false,
    required = { 'bird_present', 'detections' },
    properties = {
        bird_present = { type = 'boolean' },
        detections   = { type = 'array', items = detectionItemSchema() },
    },
}

-- build(prompt, image, model) -> Chat Completions request body table (see header).
-- image.dataUrl is the caller-supplied "data:image/jpeg;base64,..." string (may be nil if the
-- caller has not yet attached it; the builder never invents/encodes one).
function M.build(prompt, image, model)
    image = image or {}
    return {
        model = model,
        messages = {
            {
                role = 'user',
                content = {
                    { type = 'text', text = prompt },
                    { type = 'image_url', image_url = { url = image.dataUrl } },
                },
            },
        },
        response_format = {
            type = 'json_schema',
            json_schema = {
                name = 'bird_identification',
                strict = true,
                schema = M.SCHEMA,
            },
        },
    }
end

return M
