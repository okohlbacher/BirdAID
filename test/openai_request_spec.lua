-- test/openai_request_spec.lua (Phase 5 — PROV-02/03: pure Chat Completions request builder)
--
-- Exercises BirdAID.lrdevplugin/src/providers/openai_request.lua: a PURE module (the only
-- thing it touches is plain table composition; NO Lr, NO base64, NO network), require-able
-- under stock lua / luajit (the CODEX-mandated separation invariant). Proves:
--   * build(prompt, image, model) emits the exact Chat Completions body shape (model passed
--     through unvalidated; messages[1].role=='user'; a {type='text'} part + a
--     {type='image_url'} part carrying the caller-supplied data URL; detail OMITTED for v1).
--   * response_format == {type='json_schema', json_schema={name=..., strict=true,
--     schema=M.SCHEMA}}.
--   * M.SCHEMA is in the STRICT-SUPPORTED SUBSET ONLY (CODEX MUST-FIX 1): every object has
--     additionalProperties=false; EVERY property is in that object's required array;
--     confidence (detection item AND alternatives item) is {type={'number','null'}} and STILL
--     required; identified_rank is an enum of exactly species|genus|family|order|class; bbox is
--     {type='array', items={type='number'}} with NO minItems/maxItems; the ONLY keywords used
--     anywhere are type/enum/required/additionalProperties/properties/items.
--   * The detection-item required array deep-equals the literal key list and the alt required
--     array deep-equals its literal list (asserted INLINE — CODEX MUST-FIX 12 — and ALSO
--     against the module's exported M.DETECTION_KEYS / M.ALT_KEYS).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local req = require('src.providers.openai_request')

assert_true(type(req) == 'table', "require 'src.providers.openai_request' resolves")
assert_true(type(req.build) == 'function', "openai_request exposes build")
assert_true(type(req.SCHEMA) == 'table', "openai_request exposes SCHEMA constant")

-- --------------------------------------------------------------------------
-- small pure helpers local to the spec
-- --------------------------------------------------------------------------
local function arrayEq(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- count keys in a table (for "is a 1-element / 2-element array" assertions)
local function keyCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- recursively walk a schema table asserting NO forbidden / out-of-subset keyword appears.
-- Allowed keyword set (strict-supported subset only):
local ALLOWED_KEYWORDS = {
    type = true, enum = true, required = true,
    additionalProperties = true, properties = true, items = true,
}
local function walkSchema(node, path, sawAdditionalFalse)
    if type(node) ~= 'table' then return end
    -- Detect object nodes (type == 'object') and assert additionalProperties == false.
    if node.type == 'object' then
        assert_eq(node.additionalProperties, false,
            "object at " .. path .. " has additionalProperties=false")
        -- every property MUST be in required
        assert_true(type(node.properties) == 'table',
            "object at " .. path .. " has properties table")
        assert_true(type(node.required) == 'table',
            "object at " .. path .. " has required array")
        local reqSet = {}
        for _, k in ipairs(node.required) do reqSet[k] = true end
        for propName in pairs(node.properties) do
            assert_true(reqSet[propName] == true,
                "property '" .. propName .. "' at " .. path .. " is in required")
        end
    end
    -- A schema NODE (one that carries a 'type') must use only allowed keywords. We only
    -- police keyword-bearing schema nodes (those with a 'type' key) so that the
    -- 'properties' MAP and 'required' ARRAY contents are not mis-flagged.
    if node.type ~= nil then
        for k in pairs(node) do
            assert_true(ALLOWED_KEYWORDS[k] == true,
                "schema node at " .. path .. " uses only-subset keyword (offending: '"
                .. tostring(k) .. "')")
            -- explicit minItems/maxItems trap (CODEX MUST-FIX 1)
            assert_true(k ~= 'minItems' and k ~= 'maxItems',
                "schema node at " .. path .. " has NO minItems/maxItems")
        end
    end
    -- recurse into properties
    if type(node.properties) == 'table' then
        for propName, sub in pairs(node.properties) do
            walkSchema(sub, path .. ".properties." .. propName)
        end
    end
    -- recurse into items (array element schema)
    if type(node.items) == 'table' then
        walkSchema(node.items, path .. ".items")
    end
end

-- --------------------------------------------------------------------------
-- build() body shape
-- --------------------------------------------------------------------------
do
    local prompt = "Identify the bird in this photo. Return strict JSON."
    local image = { dataUrl = "data:image/jpeg;base64,QUJD" } -- caller-supplied data URL
    local model = "gpt-5.5-custom-model-xyz"                  -- arbitrary; must pass through

    local body = req.build(prompt, image, model)
    assert_true(type(body) == 'table', "build returns a table")

    -- model passed through unvalidated (Pitfall 6)
    assert_eq(body.model, model, "body.model is the passed model (pass-through)")

    -- messages is a 1-element array
    assert_true(type(body.messages) == 'table', "body.messages is a table")
    assert_eq(#body.messages, 1, "body.messages is a 1-element array")
    local msg = body.messages[1]
    assert_eq(msg.role, 'user', "messages[1].role == 'user'")

    -- content is a 2-element array: a text part and an image_url part
    assert_true(type(msg.content) == 'table', "messages[1].content is a table")
    assert_eq(#msg.content, 2, "content is a 2-element array")

    local textPart = msg.content[1]
    assert_eq(textPart.type, 'text', "content[1].type == 'text'")
    assert_eq(textPart.text, prompt, "content[1].text == prompt")

    local imgPart = msg.content[2]
    assert_eq(imgPart.type, 'image_url', "content[2].type == 'image_url'")
    assert_true(type(imgPart.image_url) == 'table', "content[2].image_url is a table")
    assert_eq(imgPart.image_url.url, image.dataUrl,
        "content[2].image_url.url == image.dataUrl (caller-supplied)")
    -- detail is OMITTED for v1 (API default — locked decision)
    assert_eq(imgPart.image_url.detail, nil, "detail is OMITTED (API default)")

    -- response_format strict json_schema
    local rf = body.response_format
    assert_true(type(rf) == 'table', "body.response_format is a table")
    assert_eq(rf.type, 'json_schema', "response_format.type == 'json_schema'")
    assert_true(type(rf.json_schema) == 'table', "response_format.json_schema is a table")
    assert_eq(rf.json_schema.name, 'bird_identification', "json_schema.name")
    assert_eq(rf.json_schema.strict, true, "json_schema.strict == true")
    assert_true(rf.json_schema.schema == req.SCHEMA,
        "json_schema.schema is the M.SCHEMA constant")
end

-- --------------------------------------------------------------------------
-- The pure builder does NOT base64-encode: a missing dataUrl yields a nil url
-- (it never invents/encodes one). Confirms base64 stays in glue.
-- --------------------------------------------------------------------------
do
    local body = req.build("p", {}, "m") -- image with no dataUrl
    local imgPart = body.messages[1].content[2]
    assert_eq(imgPart.image_url.url, nil,
        "no dataUrl => url is nil (builder never encodes base64 itself)")
end

-- --------------------------------------------------------------------------
-- SCHEMA: top-level shape
-- --------------------------------------------------------------------------
do
    local S = req.SCHEMA
    assert_eq(S.type, 'object', "SCHEMA.type == 'object'")
    assert_eq(S.additionalProperties, false, "SCHEMA additionalProperties == false")
    assert_true(arrayEq(S.required, { 'bird_present', 'detections' }),
        "top-level required == {bird_present, detections}")
    assert_eq(S.properties.bird_present.type, 'boolean', "bird_present is boolean")
    assert_eq(S.properties.detections.type, 'array', "detections is an array")

    local detItem = S.properties.detections.items
    assert_eq(detItem.type, 'object', "detection item is an object")
    assert_eq(detItem.additionalProperties, false, "detection item additionalProperties==false")

    -- bbox: array of numbers WITHOUT minItems/maxItems
    local bbox = detItem.properties.bbox
    assert_eq(bbox.type, 'array', "bbox.type == 'array'")
    assert_eq(bbox.items.type, 'number', "bbox.items.type == 'number'")
    assert_eq(bbox.minItems, nil, "bbox has NO minItems (CODEX MUST-FIX 1)")
    assert_eq(bbox.maxItems, nil, "bbox has NO maxItems (CODEX MUST-FIX 1)")

    -- confidence nullable union, in BOTH detection item and alternatives item
    assert_true(arrayEq(detItem.properties.confidence.type, { 'number', 'null' }),
        "detection confidence is ['number','null']")

    -- identified_rank enum
    assert_eq(detItem.properties.identified_rank.type, 'string', "identified_rank is string")
    assert_true(arrayEq(detItem.properties.identified_rank.enum,
        { 'species', 'genus', 'family', 'order', 'class' }),
        "identified_rank enum is exactly species|genus|family|order|class")

    -- alternatives is an array of objects (additionalProperties false), confidence nullable
    local altItem = detItem.properties.alternatives.items
    assert_eq(detItem.properties.alternatives.type, 'array', "alternatives is an array")
    assert_eq(altItem.type, 'object', "alternative item is an object")
    assert_eq(altItem.additionalProperties, false, "alternative item additionalProperties==false")
    assert_true(arrayEq(altItem.properties.confidence.type, { 'number', 'null' }),
        "alternative confidence is ['number','null']")
end

-- --------------------------------------------------------------------------
-- INLINE required-key-array deep-equals (CODEX MUST-FIX 12) — both against the literal
-- AND against the module's exported expected key arrays.
-- --------------------------------------------------------------------------
do
    local S = req.SCHEMA
    local detReq = S.properties.detections.items.required
    local altReq = S.properties.detections.items.properties.alternatives.items.required

    local LITERAL_DETECTION = {
        'bbox', 'common_name', 'scientific_name', 'confidence',
        'identified_rank', 'rank_name', 'alternatives',
    }
    local LITERAL_ALT = {
        'common_name', 'scientific_name', 'confidence', 'identified_rank', 'rank_name',
    }

    assert_true(arrayEq(detReq, LITERAL_DETECTION),
        "detection-item required deep-equals the inline literal key array")
    assert_true(arrayEq(altReq, LITERAL_ALT),
        "alt-item required deep-equals the inline literal key array")

    -- exported expected arrays exist and match the literals too
    assert_true(type(req.DETECTION_KEYS) == 'table', "M.DETECTION_KEYS exported")
    assert_true(type(req.ALT_KEYS) == 'table', "M.ALT_KEYS exported")
    assert_true(arrayEq(req.DETECTION_KEYS, LITERAL_DETECTION),
        "M.DETECTION_KEYS deep-equals the literal")
    assert_true(arrayEq(req.ALT_KEYS, LITERAL_ALT),
        "M.ALT_KEYS deep-equals the literal")
    -- and the emitted schema's required arrays match the exported arrays
    assert_true(arrayEq(detReq, req.DETECTION_KEYS),
        "emitted detection required == M.DETECTION_KEYS")
    assert_true(arrayEq(altReq, req.ALT_KEYS),
        "emitted alt required == M.ALT_KEYS")
end

-- --------------------------------------------------------------------------
-- WALK the whole schema: only-subset keywords, additionalProperties:false everywhere,
-- all-required, and NO minItems/maxItems anywhere (CODEX MUST-FIX 1).
-- --------------------------------------------------------------------------
do
    walkSchema(req.SCHEMA, "SCHEMA")
end
