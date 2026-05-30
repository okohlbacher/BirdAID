-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/openai_response.lua (PROV-02 map half / PROV-04)
--
-- PURE module: the only requires are the pure src.json, src.contract, and src.lib.dkjson
-- (for its null SENTINEL). It imports NO Lr* module, runs NO network, spawns NO process,
-- and does NO file I/O — so it is require-able under stock lua / lua5.1 / luajit for offline
-- unit testing (the CODEX-mandated separation invariant; the no-Lr purity grep stays clean).
--
-- This is the response side of the OpenAI provider: it turns a DECODED Chat Completions body
-- (the table src/json.decode yields from the HTTP body string) into our canonical common
-- schema (contract.validateResponse), or — for ANY failure mode — the token-free degrade
-- shape { bird_present = false, detections = {} }.
--
-- map(parsedBody) is TOTAL (FR2 / PROV-04 / threat T-05-04): it NEVER indexes a nil, NEVER
-- raises, and NEVER returns an unvalidated body. Every structural access is guarded in order
-- (parsedBody a table? choices nil/empty? choices[1]? message? refusal? content nil/empty?
-- finish_reason length/content_filter?) and any absence degrades token-free. The model's
-- structured-output content is a nested JSON *STRING* — it is decoded with src.json, then:
--   * normalizeNulls drops the dkjson null SENTINEL (confidence at the detection level AND
--     inside each alternatives item) to Lua nil BEFORE validation (Pitfall 1/2, T-05-05);
--   * on a clean decode that validates -> return it;
--   * on a decode FAILURE -> salvage ONCE (strip ```json fences / surrounding prose, re-decode)
--     — LOCAL only, NO network re-prompt (LOCKED, 05-RESEARCH Pattern 2);
--   * on a decode-that-does-not-validate -> repairOnce (one deterministic structural fix:
--     drop a contradictory non-empty detections array when bird_present==false), re-validate;
--   * on truncation (finish_reason=='length') or filtering (finish_reason=='content_filter')
--     or any remaining failure -> degrade (T-05-06). No double-repair, no loop.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local json = require 'src.json'
-- [07-01 / CODEX MUST-FIX 2] The provider-agnostic response helpers (normalizeNulls / salvage /
-- repairOnce / finalize / degrade) were FACTORED OUT into src.providers.response_util so all three
-- providers (openai/claude/gemini) share ONE implementation. openai_response keeps its OWN
-- choices/message/content walk + nested json.decode local to it; only the shared helpers moved.
-- Behavior is byte-for-byte preserved (the unchanged openai_response_spec is the regression gate).
local ru = require 'src.providers.response_util'

local M = {}

-- Local aliases onto the shared helpers (keeps the map() body below identical to its prior form).
local degrade  = ru.degrade
local salvage  = ru.salvage
local finalize = ru.finalize

-- map(parsedBody) -> a contract-valid common-schema table (mapped response OR degrade shape).
-- TOTAL: never indexes a nil, never raises, never returns an unvalidated body.
function M.map(parsedBody)
    -- Guard EVERY structural access in order (CODEX MUST-FIX 4); any absence -> degrade.
    if type(parsedBody) ~= 'table' then return degrade() end

    local choices = parsedBody.choices
    if type(choices) ~= 'table' or #choices == 0 then return degrade() end

    local choice = choices[1]
    if type(choice) ~= 'table' then return degrade() end

    local message = choice.message
    if type(message) ~= 'table' then return degrade() end

    -- A safety-refusal: message.refusal is a non-empty string -> graceful degrade (not a crash).
    if type(message.refusal) == 'string' and message.refusal ~= '' then
        return degrade()
    end

    -- Truncated (token cap) or filtered output: do NOT trust a partial/filtered body -> degrade.
    local fr = choice.finish_reason
    if fr == 'length' or fr == 'content_filter' then
        return degrade()
    end

    -- content must be a non-empty JSON STRING; otherwise degrade.
    local content = message.content
    if type(content) ~= 'string' or content == '' then
        return degrade()
    end

    -- Nested-decode the structured-output JSON string.
    local ok, value = json.decode(content)
    if ok and type(value) == 'table' then
        return finalize(value)
    end

    -- Decode FAILED (or yielded a non-table): salvage ONCE (local fence/prose strip + re-decode).
    local sok, svalue = salvage(content)
    if sok then
        return finalize(svalue)
    end

    -- Unrecoverable -> degrade. NEVER a network re-prompt, NEVER a loop.
    return degrade()
end

return M
