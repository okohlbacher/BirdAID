-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/contract.lua (CTR-01, CTR-02)
--
-- PURE module: imports NO Lightroom SDK module at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated
-- separation invariant). Run under stock lua/luajit; negative-purity grep clean.
--
-- Provides the two most-reused contracts of the project:
--   * validateImage  (CTR-01) -- the image-transport shape sent to every provider.
--   * validateResponse (CTR-02) -- the canonical provider/AI response schema; EVERY
--     provider output is validated against this before any downstream use.
--   * denormalizeBbox -- the single canonical normalized->pixel mapping helper (Phase 6).
--
-- bbox COORDINATE CONVENTION (SPEC FR4, CTR-02, Risk R2): a bbox is the 4-tuple
-- {x_min, y_min, x_max, y_max}, each normalized to [0,1] with a TOP-LEFT origin,
-- expressed RELATIVE TO THE EXACT FRAME SENT to the provider -- i.e. the preview's
-- ACTUAL decoded width/height (preview.parseJpegDims), NOT the requested size. Phase 6
-- reconciles coordinate spaces across preview/export/develop-crop; Phase 3 locks the
-- convention and the validator. x increases right, y increases down; x_min<=x_max and
-- y_min<=y_max.
--
-- CODEX hardening folded in: numeric guard rejects NaN AND +/-inf (MUST-FIX 10);
-- isArray rejects map/sparse/extra-key tables (MUST-FIX 7); validateResponse rejects
-- unexpected top-level/detection/alternative keys (MUST-FIX 8); alternatives validated
-- as an array of per-item shapes (MUST-FIX 9); bird_present=false with a non-empty
-- detections array is contradictory and rejected (NIT 20); validateImage uses
-- width/height keys consistently, no w/h aliases (NIT 19).
--
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack is global).

local M = {}

-- Allowed taxonomic ranks (most specific to least). CTR-02 enum.
local RANKS = { species = true, genus = true, family = true, order = true, class = true }

-- Numeric guard (CODEX MUST-FIX 10): valid only when it is a number, is not NaN
-- (x == x is false for NaN), and is neither +inf nor -inf. Used for bbox elements,
-- confidence, and image width/height (and, in Plan 03-02, gps/date numerics).
local INF = 1 / 0
local function isNum(x)
    return type(x) == 'number' and x == x and x ~= INF and x ~= -INF
end

-- A number constrained to the unit interval [0,1] (and finite per isNum).
local function inUnit(x)
    return isNum(x) and x >= 0 and x <= 1
end

-- CODEX review item 9 + phase-4 code review #3: a REQUIRED non-empty string. common_name /
-- scientific_name / rank_name carry the identification; an empty string is as useless as a
-- missing one and must be rejected (no degenerate "" names that render as blank keywords).
-- MIRRORS keyword.lua's nonEmptyString: after trimming leading/trailing whitespace, the
-- value must be non-empty AND not the literal "nil" -- so "   " (whitespace-only) and "nil"
-- are REJECTED here just as the renderer treats them as MISSING. Pure Lua 5.1 (the gsub
-- results are parenthesized to drop the substitution count).
local function nonEmptyString(x)
    if type(x) ~= 'string' then return false end
    local t = (x:gsub('^%s+', ''):gsub('%s+$', ''))
    return t ~= '' and t ~= 'nil'
end

-- Array-shape guard (CODEX MUST-FIX 7): true ONLY when t is a table whose keys are
-- EXACTLY the contiguous integers 1..n (n = number of key/value pairs), with NO
-- non-numeric keys and NO gaps. Rejects maps ({a=1}), sparse arrays ({[1]=x,[3]=y}),
-- and tables carrying extra non-numeric keys alongside numeric ones. (#t is unreliable
-- for sparse tables, so we count via pairs and then verify each integer key 1..count.)
local function isArray(t)
    if type(t) ~= 'table' then return false end
    local count = 0
    for k in pairs(t) do
        -- Any non-integer / non-positive key disqualifies it as an array.
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 then
            return false
        end
        count = count + 1
    end
    -- Every integer key 1..count must be present (no gaps); count keys, all integers,
    -- all in [1,count] with none repeated => exactly the set {1..count}.
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- validateImage(img) -> (ok, err)   (CTR-01)
-- Shape per SPEC s6: { kind='bytes'|'file', data=<non-empty string>|nil,
--                      path=<non-empty string>|nil, width=N>0 finite, height=N>0 finite }
-- ---------------------------------------------------------------------------
function M.validateImage(img)
    if type(img) ~= 'table' then return false, 'image-not-table' end
    if img.kind == 'bytes' then
        if type(img.data) ~= 'string' or #img.data == 0 then
            return false, 'bytes-missing-data'
        end
    elseif img.kind == 'file' then
        if type(img.path) ~= 'string' or img.path == '' then
            return false, 'file-missing-path'
        end
    else
        return false, 'bad-kind'
    end
    -- width/height keys consistently (NIT 19); reject non-number, <=0, NaN, +/-inf.
    if not isNum(img.width) or img.width <= 0 then return false, 'bad-width' end
    if not isNum(img.height) or img.height <= 0 then return false, 'bad-height' end
    return true
end

-- ---------------------------------------------------------------------------
-- Local bbox validator. bb must be a 4-element ARRAY of unit numbers, ordered.
-- ---------------------------------------------------------------------------
local function validateBbox(bb)
    if not isArray(bb) or #bb ~= 4 then return false, 'bbox-not-4' end
    for k = 1, 4 do
        if not inUnit(bb[k]) then return false, 'bbox-out-of-[0,1]' end
    end
    -- CODEX review item 9: reject DEGENERATE (zero-area) boxes. A box is only useful for
    -- cropping if it has positive width AND positive height, so require STRICT ordering:
    -- x_min < x_max AND y_min < y_max. This rejects x_min==x_max / y_min==y_max (and the
    -- inverted cases) while still accepting the full-frame box [0,0,1,1]. 0 and 1 remain
    -- valid bounds (enforced by inUnit above).
    if bb[1] >= bb[3] then return false, 'bbox-xmin>xmax' end
    if bb[2] >= bb[4] then return false, 'bbox-ymin>ymax' end
    return true
end

-- Allowed key sets, used to reject any UNEXPECTED key (CODEX MUST-FIX 8).
local ALLOWED_TOP = { bird_present = true, detections = true }
local ALLOWED_DETECTION = {
    bbox = true, common_name = true, scientific_name = true,
    confidence = true, identified_rank = true, rank_name = true,
    alternatives = true,
}
local ALLOWED_ALT = {
    common_name = true, scientific_name = true, confidence = true,
    identified_rank = true, rank_name = true,
}

-- Validate one alternatives[i] item (CODEX MUST-FIX 9): a table with common_name,
-- scientific_name (strings), confidence in [0,1] finite, identified_rank in enum,
-- rank_name string; reject any unexpected alternative key.
local function validateAlternative(a, idx)
    if type(a) ~= 'table' then return false, 'alternative-not-table@' .. idx end
    for k in pairs(a) do
        if not ALLOWED_ALT[k] then return false, 'unexpected-alt-key:' .. tostring(k) .. '@' .. idx end
    end
    -- CODEX review item 9: required non-empty strings (no blank identifications).
    if not nonEmptyString(a.common_name) then return false, 'alt-common_name@' .. idx end
    if not nonEmptyString(a.scientific_name) then return false, 'alt-scientific_name@' .. idx end
    -- Phase 4 Task 0: confidence is OPTIONAL (a self-reported HINT the provider MAY omit;
    -- we threshold it ourselves). nil is ACCEPTED; if PRESENT it must be finite [0,1].
    if a.confidence ~= nil and not inUnit(a.confidence) then return false, 'alt-confidence-out-of-[0,1]@' .. idx end
    if not RANKS[a.identified_rank] then return false, 'alt-bad-rank@' .. idx end
    if not nonEmptyString(a.rank_name) then return false, 'alt-rank_name@' .. idx end
    return true
end

-- ---------------------------------------------------------------------------
-- validateResponse(r) -> (ok, err)   (CTR-02 canonical schema)
-- Returns (false, errString) on reject; errString is checkable (e.g. 'bad-rank@1').
-- ---------------------------------------------------------------------------
function M.validateResponse(r)
    if type(r) ~= 'table' then return false, 'resp-not-table' end

    -- Reject any unexpected TOP-LEVEL key (CODEX MUST-FIX 8).
    for k in pairs(r) do
        if not ALLOWED_TOP[k] then return false, 'unexpected-top-key:' .. tostring(k) end
    end

    if type(r.bird_present) ~= 'boolean' then return false, 'bird_present-not-bool' end
    -- detections must be a TRUE ARRAY (rejects map/sparse, CODEX MUST-FIX 7).
    if not isArray(r.detections) then return false, 'detections-not-array' end

    -- bird_present=false WITH a non-empty detections array is contradictory (NIT 20).
    if r.bird_present == false and #r.detections > 0 then
        return false, 'bird_present-false-with-detections'
    end

    for idx, d in ipairs(r.detections) do
        if type(d) ~= 'table' then return false, 'detection-not-table@' .. idx end
        -- Reject any unexpected DETECTION key (CODEX MUST-FIX 8).
        for k in pairs(d) do
            if not ALLOWED_DETECTION[k] then
                return false, 'unexpected-detection-key:' .. tostring(k) .. '@' .. idx
            end
        end
        local okb, eb = validateBbox(d.bbox)
        if not okb then return false, eb .. '@' .. idx end
        -- CODEX review item 9: required non-empty strings (no blank identifications).
        if not nonEmptyString(d.common_name) then return false, 'common_name@' .. idx end
        if not nonEmptyString(d.scientific_name) then return false, 'scientific_name@' .. idx end
        -- Phase 4 Task 0: confidence is OPTIONAL (a self-reported HINT the provider MAY omit;
        -- we threshold it ourselves). nil is ACCEPTED; if PRESENT it must be finite [0,1].
        if d.confidence ~= nil and not inUnit(d.confidence) then return false, 'confidence-out-of-[0,1]@' .. idx end
        if not RANKS[d.identified_rank] then return false, 'bad-rank@' .. idx end
        if not nonEmptyString(d.rank_name) then return false, 'rank_name@' .. idx end
        if d.alternatives ~= nil then
            -- alternatives, when present, must be a TRUE ARRAY of per-item shapes.
            if not isArray(d.alternatives) then return false, 'alternatives-not-array@' .. idx end
            for ai, a in ipairs(d.alternatives) do
                local oka, ea = validateAlternative(a, ai)
                if not oka then return false, ea end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- denormalizeBbox(bbox, width, height) -> { x_min*w, y_min*h, x_max*w, y_max*h }
-- The single canonical normalized->pixel mapping (Phase 6). Pure; assumes a valid
-- bbox + finite positive dims (callers validate first via validateBbox/validateImage).
-- ---------------------------------------------------------------------------
function M.denormalizeBbox(bbox, width, height)
    return {
        bbox[1] * width,
        bbox[2] * height,
        bbox[3] * width,
        bbox[4] * height,
    }
end

return M
