-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/response_util.lua (Plan 07-01 — shared response helpers)
--
-- PURE module: the only requires are the pure src.json, src.contract, and src.lib.dkjson (for
-- its null SENTINEL). It imports NO Lr* module, runs NO network, spawns NO process, and does NO
-- file I/O — so it is require-able under stock lua / lua5.1 / luajit for offline unit testing
-- (the CODEX-mandated separation invariant; the no-Lr purity grep stays clean).
--
-- These provider-agnostic helpers were FACTORED OUT of openai_response.lua in 07-01 (CODEX
-- MUST-FIX 2) so ALL three response mappers (openai/claude/gemini) share ONE implementation and
-- the two wave-2 providers (07-02 Claude, 07-03 Gemini) can depend on them via THIS wave-1 plan
-- with no inter-wave-2 file race. Behavior is preserved byte-for-byte from openai_response;
-- openai_response_spec staying green is the regression backstop.
--
--   * degrade()          -> the canonical token-free no-bird shape {bird_present=false,detections={}}.
--   * normalizeNulls(v)  -> drop the dkjson null SENTINEL anywhere (top + nested) to Lua nil.
--   * salvage(content)   -> strip ```json fences / surrounding prose, re-decode ONCE (LOCAL, no net).
--   * repairOnce(resp)   -> ONE deterministic structural fix (drop contradictory detections when
--                           bird_present==false), no loop.
--   * finalize(resp)     -> normalize-nulls -> validate -> (repair-once -> re-validate) -> degrade.
--                           ALWAYS returns a contract-valid table.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local json     = require 'src.json'
local contract = require 'src.contract'
local dkjson   = require 'src.lib.dkjson'

-- The dkjson null SENTINEL: a valid JSON `null` materializes as this exact table (compared by
-- identity), NOT a bare nil. normalizeNulls recognizes and drops it.
local NULL = dkjson.null

local M = {}

-- The canonical token-free graceful-degrade response (a VALID contract.validateResponse shape).
-- Built fresh each call so a caller mutating it can never corrupt a shared constant.
function M.degrade()
    return { bird_present = false, detections = {} }
end

-- normalizeNulls(v): recursively replace any value identical to the dkjson null SENTINEL with
-- Lua nil (dropping the key). This drops `confidence:null` at the detection level and inside each
-- alternatives item BEFORE validation, and is general enough to scrub a null anywhere in the
-- decoded structure. Pure Lua 5.1; the decoded structured output is acyclic plain data, so the
-- recursion terminates.
function M.normalizeNulls(v)
    if v == NULL then
        return nil
    end
    if type(v) ~= 'table' then
        return v
    end
    -- Collect keys first so we can safely assign nil during iteration (removing keys mid-pairs
    -- is undefined; building a key list avoids that).
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    for i = 1, #keys do
        local k = keys[i]
        v[k] = M.normalizeNulls(v[k])
    end
    return v
end

-- salvage(content) -> (ok, decodedTableOrNil). LOCAL repair-once for a content string whose
-- direct decode failed: strip a leading markdown code fence (``` or ```json) and a trailing
-- fence, then trim to the FIRST '{' .. LAST '}' (discarding any surrounding prose), and re-decode
-- ONCE via src.json. NO network. Returns (true, table) only on a clean re-decode that yields a
-- table; otherwise (false, nil). Never raises.
function M.salvage(content)
    if type(content) ~= 'string' then
        return false, nil
    end
    local s = content
    -- Strip an opening fence: optional ``` with an optional language tag on its own line.
    -- (gsub result is parenthesized to drop the substitution count — Lua 5.1 subset.)
    s = (s:gsub('^%s*```%a*%s*\n?', ''))
    -- Strip a closing fence anywhere after the JSON.
    s = (s:gsub('```%s*$', ''))
    -- Trim to the first '{' through the last '}' so trailing/leading prose is discarded.
    local first = s:find('{', 1, true)
    local last
    do
        -- find the LAST '}' by scanning (Lua 5.1 has no rfind; reverse-search via repeated find).
        local pos = s:find('}', 1, true)
        while pos do
            last = pos
            pos = s:find('}', pos + 1, true)
        end
    end
    if not first or not last or last < first then
        return false, nil
    end
    local candidate = s:sub(first, last)
    local ok, value = json.decode(candidate)
    if ok and type(value) == 'table' then
        return true, value
    end
    return false, nil
end

-- repairOnce(resp, verr) -> a structurally repaired COPY (or the same table) to re-validate.
-- ONE deterministic fix only (no loop): the documented case is bird_present==false carrying a
-- non-empty detections array (contradictory; validateResponse rejects it). The honest repair is
-- to drop the detections (the model said no bird). Any other validation error is NOT auto-repaired
-- here — the caller degrades. Never raises.
function M.repairOnce(resp, verr)
    if type(resp) ~= 'table' then
        return resp
    end
    if resp.bird_present == false then
        -- Drop a contradictory non-empty detections array.
        resp.detections = {}
        return resp
    end
    return resp
end

-- finalize(resp): null-normalize then validate; on failure attempt exactly one structural repair
-- and re-validate; degrade on any remaining failure. resp is the table produced by a (possibly
-- salvaged) decode. Returns a contract-valid table ALWAYS.
function M.finalize(resp)
    if type(resp) ~= 'table' then
        return M.degrade()
    end
    resp = M.normalizeNulls(resp)
    local ok = contract.validateResponse(resp)
    if ok then
        return resp
    end
    local _, verr = contract.validateResponse(resp)
    local repaired = M.repairOnce(resp, verr)
    if contract.validateResponse(repaired) then
        return repaired
    end
    return M.degrade()
end

return M
