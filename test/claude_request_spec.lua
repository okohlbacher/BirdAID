-- test/claude_request_spec.lua (Phase 7 Plan 02 — PROV2-01 pure request builder)
--
-- Exercises BirdAID.lrdevplugin/src/providers/claude_request.lua: a PURE module (pure table
-- composition, no require of Lr / no base64 encoding), require-able under stock lua / luajit.
-- Asserts the Anthropic Messages-API body shape: model + max_tokens (>=1024) + forced single tool
-- (tool_choice) + strict-subset input_schema (required arrays deep-equal the exported
-- DETECTION_KEYS/ALT_KEYS; confidence anyOf number|null; bbox items number with NO maxItems
-- anywhere) + a raw-base64 image block (source.type='base64', media_type='image/jpeg',
-- data == image.b64, NO 'data:' prefix).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local request = require('src.providers.claude_request')

assert_true(type(request) == 'table', "require 'src.providers.claude_request' resolves")
assert_true(type(request.build) == 'function', "claude_request exposes build()")

-- deepEqualArray(a, b): true iff a and b are arrays with identical length + identical elements.
local function deepEqualArray(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- containsKey(t, key) recursively: true iff `key` appears as a key ANYWHERE in the table tree.
local function containsKey(t, key)
    if type(t) ~= 'table' then return false end
    for k, v in pairs(t) do
        if k == key then return true end
        if containsKey(v, key) then return true end
    end
    return false
end

local PROMPT = 'PROMPT-TEXT-SENTINEL ornithologist instructions'
local B64 = 'RAWBASE64SENTINELbytesNoDataPrefix=='
local IMAGE = { kind = 'bytes', b64 = B64, width = 800, height = 600 }
local MODEL = 'claude-opus-4-8'

-- =====================================================================
-- (1) Top-level body shape: model + max_tokens + forced tool + messages.
-- =====================================================================
do
    local body = request.build(PROMPT, IMAGE, MODEL)
    assert_true(type(body) == 'table', "build returns a table")
    assert_eq(body.model, MODEL, "body.model is the passed-through model")
    assert_true(type(body.max_tokens) == 'number' and body.max_tokens >= 1024,
        "body.max_tokens is a number >= 1024")

    -- Forced single tool via tool_choice.
    assert_true(type(body.tool_choice) == 'table', "body.tool_choice is a table")
    assert_eq(body.tool_choice.type, 'tool', "tool_choice.type == 'tool' (forces the tool)")
    assert_eq(body.tool_choice.name, 'report_bird_identification',
        "tool_choice.name names our single tool")

    -- Exactly ONE tool, with the matching name + strict + input_schema.
    assert_true(type(body.tools) == 'table' and #body.tools == 1, "body.tools has exactly one tool")
    local tool = body.tools[1]
    assert_eq(tool.name, 'report_bird_identification', "tools[1].name matches tool_choice")
    assert_eq(tool.strict, true, "tools[1].strict == true (grammar-constrained conformance)")
    assert_true(type(tool.input_schema) == 'table', "tools[1].input_schema is a table")
end

-- =====================================================================
-- (2) input_schema strict-subset: required arrays deep-equal the exported key arrays;
--     confidence is anyOf number|null; bbox items are numbers; NO maxItems anywhere.
-- =====================================================================
do
    local body = request.build(PROMPT, IMAGE, MODEL)
    local schema = body.tools[1].input_schema

    assert_eq(schema.type, 'object', "input_schema.type == 'object'")
    assert_eq(schema.additionalProperties, false, "input_schema additionalProperties == false")
    assert_true(deepEqualArray(schema.required, { 'bird_present', 'detections' }),
        "input_schema.required == {bird_present, detections}")

    local det = schema.properties.detections.items
    assert_eq(det.type, 'object', "detections item is an object")
    assert_eq(det.additionalProperties, false, "detection item additionalProperties == false")
    -- required arrays deep-equal the exported key arrays (no source parsing — CODEX MUST-FIX 12).
    assert_true(type(request.DETECTION_KEYS) == 'table', "claude_request exports DETECTION_KEYS")
    assert_true(type(request.ALT_KEYS) == 'table', "claude_request exports ALT_KEYS")
    assert_true(deepEqualArray(det.required, request.DETECTION_KEYS),
        "detection.required deep-equals exported DETECTION_KEYS")

    -- confidence is anyOf number|null (NOT a {'number','null'} type union — Claude strict needs anyOf).
    local conf = det.properties.confidence
    assert_true(type(conf.anyOf) == 'table' and #conf.anyOf == 2,
        "detection confidence uses anyOf with two members")
    -- the two members are {type='number'} and {type='null'} (order-independent check).
    local sawNumber, sawNull = false, false
    for i = 1, #conf.anyOf do
        if conf.anyOf[i].type == 'number' then sawNumber = true end
        if conf.anyOf[i].type == 'null' then sawNull = true end
    end
    assert_true(sawNumber and sawNull, "confidence anyOf is number|null")

    -- bbox is an array of numbers with NO maxItems (NO minItems either).
    local bbox = det.properties.bbox
    assert_eq(bbox.type, 'array', "bbox.type == 'array'")
    assert_eq(bbox.items.type, 'number', "bbox.items.type == 'number'")
    assert_true(bbox.maxItems == nil, "bbox has NO maxItems")
    assert_true(bbox.minItems == nil, "bbox has NO minItems")

    -- alternatives item required deep-equals exported ALT_KEYS; its confidence is anyOf too.
    local alt = det.properties.alternatives.items
    assert_true(deepEqualArray(alt.required, request.ALT_KEYS),
        "alternative.required deep-equals exported ALT_KEYS")
    assert_true(type(alt.properties.confidence.anyOf) == 'table',
        "alternative confidence also uses anyOf number|null")

    -- NO maxItems key ANYWHERE in the whole schema (strict-mode hazard).
    assert_true(not containsKey(schema, 'maxItems'), "NO maxItems key anywhere in input_schema")
    assert_true(not containsKey(schema, 'minItems'), "NO minItems key anywhere in input_schema")
end

-- =====================================================================
-- (3) messages: a user message whose content has a TEXT block (== prompt) and an IMAGE block
--     with source.type='base64', media_type='image/jpeg', data == image.b64 (RAW, no data: prefix).
-- =====================================================================
do
    local body = request.build(PROMPT, IMAGE, MODEL)
    assert_true(type(body.messages) == 'table' and #body.messages == 1, "one user message")
    local msg = body.messages[1]
    assert_eq(msg.role, 'user', "message role == 'user'")
    assert_true(type(msg.content) == 'table' and #msg.content == 2, "content has two blocks")

    -- find the text block + image block (order-independent).
    local textBlock, imageBlock
    for i = 1, #msg.content do
        local b = msg.content[i]
        if b.type == 'text' then textBlock = b end
        if b.type == 'image' then imageBlock = b end
    end
    assert_true(textBlock ~= nil, "has a text block")
    assert_eq(textBlock.text, PROMPT, "text block carries the prompt verbatim")

    assert_true(imageBlock ~= nil, "has an image block")
    assert_true(type(imageBlock.source) == 'table', "image block has a source")
    assert_eq(imageBlock.source.type, 'base64', "source.type == 'base64'")
    assert_eq(imageBlock.source.media_type, 'image/jpeg', "source.media_type == 'image/jpeg'")
    assert_eq(imageBlock.source.data, B64, "source.data == image.b64 (RAW base64)")
    -- RAW: it must NOT carry a data: URL prefix.
    assert_true(imageBlock.source.data:find('data:', 1, true) == nil,
        "source.data is RAW base64 (no 'data:' prefix)")
end

-- =====================================================================
-- (4) image with NO b64 -> source.data nil (builder never invents one).
-- =====================================================================
do
    local body = request.build(PROMPT, { kind = 'bytes', width = 1, height = 1 }, MODEL)
    local imageBlock
    for i = 1, #body.messages[1].content do
        if body.messages[1].content[i].type == 'image' then
            imageBlock = body.messages[1].content[i]
        end
    end
    assert_true(imageBlock ~= nil, "image block still present without b64")
    assert_eq(imageBlock.source.data, nil, "source.data is nil when image.b64 is absent")
end
