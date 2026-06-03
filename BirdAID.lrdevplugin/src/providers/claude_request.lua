-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/claude_request.lua (Phase 7 Plan 02 — PROV2-01 PURE builder)
--
-- PURE module: imports NO Lr* module, NO LrStringUtils, performs NO base64 encoding and NO
-- network I/O. It is pure table composition, so it is require-able under stock lua / lua5.1 /
-- luajit for offline unit testing (the CODEX-mandated separation invariant; the no-Lr purity grep
-- stays clean). The RAW base64 image bytes are SUPPLIED BY THE CALLER (the shared Lr glue's
-- attachImage sets image.b64); this builder NEVER encodes them.
--
-- build(prompt, image, model) -> the Anthropic Messages-API request body table for a single-shot,
-- single-image vision call with FORCED tool use (07-RESEARCH lines 102-135). Shape:
--   { model = <model>,                                    -- passed THROUGH unvalidated
--     max_tokens = 2048,                                  -- REQUIRED by the Messages API
--     tool_choice = { type='tool', name='report_bird_identification' },  -- FORCE the tool
--     tools = { { name='report_bird_identification', description=..., strict=true,
--                 input_schema=M.SCHEMA } },              -- a SINGLE forced tool
--     messages = { { role='user', content = {
--       { type='text',  text=<prompt> },
--       { type='image', source={ type='base64', media_type='image/jpeg', data=<image.b64> } } } } } }
--
-- CRITICAL difference vs OpenAI (07-RESEARCH): Claude wants the RAW base64 string in source.data
-- (with a separate media_type), NOT a "data:image/jpeg;base64,..." URL. The shared glue's
-- attachImage produces BOTH shapes; this builder reads image.b64 (raw) only.
--
-- M.SCHEMA is the strict-subset translation of contract.lua's CTR-02 response, kept in the
-- Claude strict-tool-use supported subset [07-RESEARCH Pitfall 3]: nullable confidence is
-- expressed via anyOf:[{type='number'},{type='null'}] (NOT a {'number','null'} type union), and
-- bbox is {type='array', items={type='number'}} with NO array length bounds (a min/max element
-- count can 400 under strict). The bbox length==4 rule (and [0,1] ordering, degenerate-box) is
-- DOWNSTREAM by contract.validateResponse, NOT by the schema. Under strict EVERY object sets
-- additionalProperties=false and lists EVERY property in `required`, so the schema is a STRICT
-- SUPERSET of the contract: confidence + alternatives are required+nullable HERE even though
-- confidence is OPTIONAL in the contract (the response mapper accepts confidence number/null and
-- alternatives present/empty/null).
--
-- M.DETECTION_KEYS / M.ALT_KEYS export the exact required-key arrays this module used to build
-- the schema, so the spec can deep-equal the emitted schema's `required` arrays against them
-- WITHOUT parsing any source [CODEX MUST-FIX 12]. They MIRROR contract.lua's allowed key sets.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local M = {}

-- The single forced tool's name. Used both in tool_choice and tools[1].name; the response mapper
-- selects the content block whose name equals this.
M.TOOL_NAME = 'report_bird_identification'

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

-- An identified_rank property: a string constrained to the RANKS enum. Each call returns a FRESH
-- table (and a fresh enum copy) so detection + alternatives do not share a node.
local function rankProperty()
    return { type = 'string', enum = copyArray(RANKS) }
end

-- A nullable confidence property expressed via anyOf number|null (NOT a type union — 07-RESEARCH
-- Pitfall 3). Each call returns a FRESH table so detection + alternatives do not share a node.
local function confidenceProperty()
    return { anyOf = { { type = 'number' }, { type = 'null' } } }
end

-- The alternatives[] item schema (strict-subset object). confidence is required+nullable (anyOf).
local function altItemSchema()
    return {
        type = 'object',
        additionalProperties = false,
        required = copyArray(M.ALT_KEYS),
        properties = {
            common_name     = { type = 'string' },
            scientific_name = { type = 'string' },
            confidence      = confidenceProperty(),
            identified_rank = rankProperty(),
            rank_name       = { type = 'string' },
        },
    }
end

-- The detections[] item schema (strict-subset object). bbox is {array of number} with NO array
-- length bounds; confidence + alternatives are required+nullable (strict superset).
local function detectionItemSchema()
    return {
        type = 'object',
        additionalProperties = false,
        required = copyArray(M.DETECTION_KEYS),
        properties = {
            bbox            = { type = 'array', items = { type = 'number' } },
            common_name     = { type = 'string' },
            scientific_name = { type = 'string' },
            confidence      = confidenceProperty(),
            identified_rank = rankProperty(),
            rank_name       = { type = 'string' },
            alternatives    = { type = 'array', items = altItemSchema() },
        },
    }
end

-- The full strict input_schema constant (built once at load; field names mirror contract.lua).
M.SCHEMA = {
    type = 'object',
    additionalProperties = false,
    required = { 'bird_present', 'detections' },
    properties = {
        bird_present = { type = 'boolean' },
        detections   = { type = 'array', items = detectionItemSchema() },
    },
}

-- build(prompt, image, model) -> the Messages-API request body table (see header).
-- image.b64 is the caller-supplied RAW base64 string (may be nil if the caller has not yet
-- attached it; the builder never invents/encodes one — source.data stays nil).
-- DEEP (Files-API) variant: when image.fileId is a non-empty string the image source becomes
-- { type='file', file_id=image.fileId } (no media_type/data) — the opaque handle is set by
-- 13-03's uploadFile glue; the builder stays pure and never encodes. fileId wins over b64.
local function imageSource(image)
    if type(image.fileId) == 'string' and image.fileId ~= '' then
        return { type = 'file', file_id = image.fileId }
    end
    return { type = 'base64', media_type = 'image/jpeg', data = image.b64 }
end

function M.build(prompt, image, model)
    image = image or {}
    return {
        model = model,
        max_tokens = 2048,
        tool_choice = { type = 'tool', name = M.TOOL_NAME },
        tools = {
            {
                name = M.TOOL_NAME,
                description = 'Report whether the image contains a bird and identify each bird.',
                strict = true,
                input_schema = M.SCHEMA,
            },
        },
        messages = {
            {
                role = 'user',
                content = {
                    { type = 'text', text = prompt },
                    {
                        type = 'image',
                        source = imageSource(image),
                    },
                },
            },
        },
    }
end

return M
