-- test/gemini_request_spec.lua (Phase 7 Plan 03 — PROV2-02 pure request builder)
--
-- Exercises BirdAID.lrdevplugin/src/providers/gemini_request.lua: a PURE module (pure table
-- composition, no require of Lr / no base64 encoding), require-able under stock lua / luajit.
-- Asserts the Gemini generateContent body shape:
--   * contents[1].parts: a text part (== the gemini-directive prompt) + an inline_data part with
--     mime_type='image/jpeg' and data == image.b64 (RAW base64, NO 'data:' prefix);
--   * generationConfig.responseMimeType == 'application/json'; responseSchema present;
--   * the detection box field is named `box_2d` typed {array of integer} (NOT 'bbox');
--   * required arrays deep-equal the exported DETECTION_KEYS/ALT_KEYS (no source parsing);
--   * the gemini-directive prompt contains box_2d / 0-1000 and NOT the [0,1] x-first line;
--   * image with NO b64 -> inline_data.data nil (never invented).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local request = require('src.providers.gemini_request')
local prompt  = require('src.prompt')

assert_true(type(request) == 'table', "require 'src.providers.gemini_request' resolves")
assert_true(type(request.build) == 'function', "gemini_request exposes build()")

local function has(s, sub) return string.find(s, sub, 1, true) ~= nil end

-- deepEqualArray(a, b): identical length + identical elements.
local function deepEqualArray(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- containsKey(t, key) recursively.
local function containsKey(t, key)
    if type(t) ~= 'table' then return false end
    for k, v in pairs(t) do
        if k == key then return true end
        if containsKey(v, key) then return true end
    end
    return false
end

-- The gemini-directive prompt the PROVIDER builds via prompt.build's box-format option.
local GEMINI_PROMPT = prompt.build({}, {}, { boxFormat = 'gemini' })
local B64 = 'RAWBASE64SENTINELbytesNoDataPrefix=='
local IMAGE = { kind = 'bytes', b64 = B64, width = 800, height = 600 }
local MODEL = 'gemini-3.5-flash'

-- =====================================================================
-- (1) Top-level body shape: contents + generationConfig.
-- =====================================================================
do
    local body = request.build(GEMINI_PROMPT, IMAGE, MODEL)
    assert_true(type(body) == 'table', "build returns a table")
    assert_true(type(body.contents) == 'table' and #body.contents == 1, "one contents entry")
    local parts = body.contents[1].parts
    assert_true(type(parts) == 'table' and #parts == 2, "contents[1].parts has two parts")

    -- find the text part + inline_data part (order-independent).
    local textPart, dataPart
    for i = 1, #parts do
        if parts[i].text ~= nil then textPart = parts[i] end
        if parts[i].inline_data ~= nil then dataPart = parts[i] end
    end
    assert_true(textPart ~= nil, "has a text part")
    assert_eq(textPart.text, GEMINI_PROMPT, "text part carries the gemini-directive prompt verbatim")
    -- the prompt text carries the gemini box directive, NOT the [0,1] x-first line.
    assert_true(has(textPart.text, "box_2d"), "text part prompt contains box_2d")
    assert_true(has(textPart.text, "0-1000"), "text part prompt contains 0-1000")
    assert_true(not has(textPart.text, "[x_min, y_min, x_max, y_max] each a number in [0,1]"),
        "text part prompt does NOT carry the [0,1] x-first directive line")

    assert_true(dataPart ~= nil, "has an inline_data part")
    assert_eq(dataPart.inline_data.mime_type, 'image/jpeg', "inline_data.mime_type == 'image/jpeg'")
    assert_eq(dataPart.inline_data.data, B64, "inline_data.data == image.b64 (RAW base64)")
    assert_true(dataPart.inline_data.data:find('data:', 1, true) == nil,
        "inline_data.data is RAW base64 (no 'data:' prefix)")
end

-- =====================================================================
-- (2) generationConfig: responseMimeType + responseSchema with box_2d integer[].
-- =====================================================================
do
    local body = request.build(GEMINI_PROMPT, IMAGE, MODEL)
    local gc = body.generationConfig
    assert_true(type(gc) == 'table', "body.generationConfig is a table")
    assert_eq(gc.responseMimeType, 'application/json', "responseMimeType == 'application/json'")
    assert_true(type(gc.responseSchema) == 'table', "responseSchema present")

    local schema = gc.responseSchema
    assert_eq(schema.type, 'object', "responseSchema.type == 'object'")
    assert_true(deepEqualArray(schema.required, { 'bird_present', 'detections' }),
        "responseSchema.required == {bird_present, detections}")

    local det = schema.properties.detections.items
    assert_eq(det.type, 'object', "detection item is an object")
    -- the box field is named box_2d (NOT bbox), typed array-of-integer (07-RESEARCH Pitfall 4).
    assert_true(det.properties.box_2d ~= nil, "detection schema names the box field 'box_2d'")
    assert_true(det.properties.bbox == nil, "detection schema does NOT name 'bbox'")
    assert_eq(det.properties.box_2d.type, 'array', "box_2d.type == 'array'")
    assert_eq(det.properties.box_2d.items.type, 'integer', "box_2d.items.type == 'integer'")

    -- required arrays deep-equal the exported key arrays (CODEX MUST-FIX 12 idiom). The detection
    -- required set uses box_2d (the gemini box field name) in place of bbox.
    assert_true(type(request.DETECTION_KEYS) == 'table', "gemini_request exports DETECTION_KEYS")
    assert_true(type(request.ALT_KEYS) == 'table', "gemini_request exports ALT_KEYS")
    assert_true(deepEqualArray(det.required, request.DETECTION_KEYS),
        "detection.required deep-equals exported DETECTION_KEYS")
    -- DETECTION_KEYS must name box_2d (not bbox).
    local sawBox2d, sawBbox = false, false
    for i = 1, #request.DETECTION_KEYS do
        if request.DETECTION_KEYS[i] == 'box_2d' then sawBox2d = true end
        if request.DETECTION_KEYS[i] == 'bbox' then sawBbox = true end
    end
    assert_true(sawBox2d, "DETECTION_KEYS names box_2d")
    assert_true(not sawBbox, "DETECTION_KEYS does NOT name bbox")

    local alt = det.properties.alternatives.items
    assert_true(deepEqualArray(alt.required, request.ALT_KEYS),
        "alternative.required deep-equals exported ALT_KEYS")

    -- the body MUST NOT carry a data: URL anywhere (raw base64 only).
    assert_true(not containsKey(body, 'image_url'), "no image_url key anywhere (Gemini uses inline_data)")
end

-- =====================================================================
-- (3) image with NO b64 -> inline_data.data nil (builder never invents one).
-- =====================================================================
do
    local body = request.build(GEMINI_PROMPT, { kind = 'bytes', width = 1, height = 1 }, MODEL)
    local dataPart
    for i = 1, #body.contents[1].parts do
        if body.contents[1].parts[i].inline_data ~= nil then
            dataPart = body.contents[1].parts[i]
        end
    end
    assert_true(dataPart ~= nil, "inline_data part still present without b64")
    assert_eq(dataPart.inline_data.data, nil, "inline_data.data is nil when image.b64 is absent")
end
