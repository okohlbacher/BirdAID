-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/gemini_response.lua (Phase 7 Plan 03 — PROV2-02 map half)
--
-- PURE module: the only require is the shared src.providers.response_util (created in 07-01; itself
-- pure) and the pure src.json (for the text-part decode). It imports NO Lr* module, runs NO
-- network, spawns NO process, and does NO file I/O — so it is require-able under stock lua /
-- lua5.1 / luajit for offline unit testing (the CODEX-mandated separation invariant; the no-Lr
-- purity grep stays clean).
--
-- This is the response side of the Gemini provider. It owns the TWO highest-risk transforms in the
-- phase: (1) the native bounding-box reorder + scale, and (2) the STRICT out-of-range / non-integer
-- DROP policy (CODEX phase-7 #4/#5 — no tolerance band; an out-of-range or fractional coord drops
-- the detection, never clamps/scales). It turns a DECODED Gemini generateContent body (the table
-- HTTP body string) into our canonical common schema (contract.validateResponse), or — for ANY
-- failure mode — the token-free degrade shape { bird_present = false, detections = {} }.
--
-- THE BOX TRANSFORM (07-RESEARCH lines 235-252, Code Example lines 465-473): Gemini returns each
-- detection's box as box_2d = [ymin, xmin, ymax, xmax] normalized to 0-1000 (top-left origin),
-- differing from OUR contract bbox [x_min, y_min, x_max, y_max] in [0,1] on BOTH axis order AND
-- scale. geminiBoxToContract REORDERS to x-first and divides by 1000:
--   box_2d {200,300,700,800} -> bbox {0.300,0.200,0.800,0.700}  (the worked doc check).
--
-- BOX POLICY (CODEX phase-7 #4/#5; supersedes the prior MUST-FIX 10 tolerance band): Gemini
-- returns box_2d coords as INTEGERS in 0..1000. We enforce that STRICTLY — NO tolerance band:
--   * ANY raw coord < 0 or > 1000 is a CONTRACT VIOLATION -> DROP the detection (return nil). We do
--     NOT clamp an out-of-range coord into validity — that would manufacture a bogus crop.
--   * ANY non-integer raw coord (e.g. 200.5) -> DROP the detection. The schema/prompt demand
--     integers; we never scale a fractional coord.
-- An in-range integer box is reordered (x-first) and scaled by /1000 into the contract [0,1] space.
--
-- NIT N2: the box_2d key is REMOVED from each detection before contract.validateResponse, else the
-- validator rejects it as 'unexpected-detection-key:box_2d'. We build a NEW detection table with
-- `bbox` set and box_2d absent.
--
-- map(parsedBody) is TOTAL (FR2 / threats T-07-09/10): it NEVER indexes a nil, NEVER raises, and
-- NEVER returns an unvalidated body. Logic (07-RESEARCH lines 229-233):
--   1. Guard parsedBody is a table.
--   2. promptFeedback.blockReason present -> degrade (the prompt was blocked).
--   3. candidates non-empty array; candidate[1].content.parts non-empty.
--   4. finishReason MAX_TOKENS/SAFETY/RECITATION/PROHIBITED_CONTENT -> degrade. (STOP / nil proceed.)
--   5. Concatenate parts[].text -> the JSON string; json.decode (salvage-once on failure).
--   6. Walk detections: geminiBoxToContract(box_2d) -> bbox (DROP on nil: out-of-range / fractional
--      / malformed); build a NEW detection WITHOUT box_2d; keep only detections whose box mapped to
--      a valid contract bbox.
--   7. response_util.finalize (null-normalize + validate + repair-once + degrade). ALWAYS valid.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local ru   = require 'src.providers.response_util'
local json = require 'src.json'

local M = {}

local degrade  = ru.degrade
local finalize = ru.finalize

-- finishReasons that mean "do not trust this candidate" -> degrade.
local DEGRADE_FINISH = {
    MAX_TOKENS = true, SAFETY = true, RECITATION = true, PROHIBITED_CONTENT = true,
}

-- geminiBoxToContract(b) -> contract bbox {x_min,y_min,x_max,y_max} in [0,1] | nil.
-- b is the native box_2d = {ymin, xmin, ymax, xmax} in 0-1000. Guards table + #==4 + numbers.
-- STRICT policy (CODEX phase-7 #4/#5; NO tolerance band): any coord < 0, > 1000, NaN, or
-- NON-INTEGER -> nil (the caller DROPS the detection; we never clamp/scale an out-of-range or
-- fractional coord into a manufactured crop). An in-range integer box is reordered (x-first) and
-- divided by 1000.
function M.geminiBoxToContract(b)
    if type(b) ~= 'table' or #b ~= 4 then return nil end
    for i = 1, 4 do
        local v = b[i]
        if type(v) ~= 'number' or v ~= v then return nil end  -- non-number or NaN -> drop
        if v < 0 or v > 1000 then return nil end               -- out-of-range -> drop (no clamp)
        if v % 1 ~= 0 then return nil end                      -- non-integer (e.g. 200.5) -> drop
    end
    -- b[1]=ymin, b[2]=xmin, b[3]=ymax, b[4]=xmax (0..1000). Contract wants {x_min,y_min,x_max,y_max}.
    return { b[2] / 1000, b[1] / 1000, b[4] / 1000, b[3] / 1000 }
end

-- detectionWithoutBox(d): return a SHALLOW COPY of detection d carrying every key EXCEPT box_2d
-- (NIT N2). bbox is set by the caller. We copy so the validator never sees a leftover box_2d.
local function detectionWithoutBox(d)
    local out = {}
    for k, v in pairs(d) do
        if k ~= 'box_2d' then out[k] = v end
    end
    return out
end

-- transformDetections(resp): walk resp.detections (if any), translate each box_2d -> bbox via
-- geminiBoxToContract (DROP the detection on nil), build a NEW detection table without box_2d, and
-- replace resp.detections with the surviving array. If resp.detections is not an array we leave it
-- for finalize/validate to reject. PURE; never raises.
local function transformDetections(resp)
    if type(resp) ~= 'table' or type(resp.detections) ~= 'table' then
        return resp
    end
    local kept = {}
    for i = 1, #resp.detections do
        local d = resp.detections[i]
        if type(d) == 'table' then
            local bbox = M.geminiBoxToContract(d.box_2d)
            if bbox ~= nil then
                local nd = detectionWithoutBox(d)
                nd.bbox = bbox
                kept[#kept + 1] = nd
            end
            -- bbox == nil -> DROP this detection (out-of-range / fractional / malformed box).
        end
    end
    resp.detections = kept
    return resp
end

-- map(parsedBody) -> a contract-valid common-schema table (mapped response OR degrade shape).
-- TOTAL: never indexes a nil, never raises, never returns an unvalidated body.
function M.map(parsedBody)
    if type(parsedBody) ~= 'table' then return degrade() end

    -- A blocked prompt (top-level promptFeedback.blockReason) -> degrade.
    local pf = parsedBody.promptFeedback
    if type(pf) == 'table' and pf.blockReason ~= nil then
        return degrade()
    end

    local candidates = parsedBody.candidates
    if type(candidates) ~= 'table' or #candidates == 0 then return degrade() end

    local cand = candidates[1]
    if type(cand) ~= 'table' then return degrade() end

    -- finishReason that means "do not trust this candidate" -> degrade. STOP / nil proceed.
    if DEGRADE_FINISH[cand.finishReason] then
        return degrade()
    end

    local content = cand.content
    if type(content) ~= 'table' then return degrade() end
    local parts = content.parts
    if type(parts) ~= 'table' or #parts == 0 then return degrade() end

    -- Concatenate the text parts into the JSON string.
    local chunks = {}
    for i = 1, #parts do
        local p = parts[i]
        if type(p) == 'table' and type(p.text) == 'string' then
            chunks[#chunks + 1] = p.text
        end
    end
    if #chunks == 0 then return degrade() end
    local text = table.concat(chunks)

    -- Decode the structured JSON; salvage-once (strip fences / surrounding prose) on failure.
    local ok, decoded = json.decode(text)
    if not ok or type(decoded) ~= 'table' then
        ok, decoded = ru.salvage(text)
        if not ok or type(decoded) ~= 'table' then
            return degrade()
        end
    end

    -- REORDER+SCALE every box_2d -> bbox and REMOVE box_2d before validation, dropping any
    -- detection whose box is out-of-range / fractional / malformed (CODEX phase-7 #4/#5, NIT N2).
    decoded = transformDetections(decoded)

    -- finalize: null-normalize -> validate -> repair-once -> degrade. ALWAYS contract-valid.
    return finalize(decoded)
end

return M
