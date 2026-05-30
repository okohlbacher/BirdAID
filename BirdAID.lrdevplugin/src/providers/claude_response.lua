-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/claude_response.lua (Phase 7 Plan 02 — PROV2-01 map half)
--
-- PURE module: the only require is the shared src.providers.response_util (created in 07-01;
-- itself pure). It imports NO Lr* module, runs NO network, spawns NO process, and does NO file
-- I/O — so it is require-able under stock lua / lua5.1 / luajit for offline unit testing (the
-- CODEX-mandated separation invariant; the no-Lr purity grep stays clean).
--
-- This is the response side of the Claude provider: it turns a DECODED Anthropic Messages-API
-- body (the table src/json.decode yields from the HTTP body string) into our canonical common
-- schema (contract.validateResponse), or — for ANY failure mode — the token-free degrade shape
-- { bird_present = false, detections = {} }.
--
-- CRITICAL difference vs OpenAI (07-RESEARCH Pitfall 2): the structured output is delivered as a
-- forced-tool tool_use block whose `.input` is ALREADY a PARSED OBJECT (a Lua table) — there is
-- NO nested JSON-string to decode. We therefore call response_util.finalize(input) DIRECTLY and
-- NEVER json.decode the input. (If a misbehaving body delivers input as a STRING, finalize sees a
-- non-object and degrades — proving we do not double-decode.)
--
-- map(parsedBody) is TOTAL (FR2 / PROV-04 / threats T-07-06): it NEVER indexes a nil, NEVER
-- raises, and NEVER returns an unvalidated body. Logic (07-RESEARCH Code Examples lines 476-491):
--   1. Guard parsedBody is a table.
--   2. stop_reason 'max_tokens' (truncated) or 'refusal' -> degrade (do NOT trust a partial/
--      declined body).
--   3. content must be an array; iterate it and select the FIRST block whose type == 'tool_use'
--      AND whose name == the expected tool name AND whose .input is a TABLE. SKIP leading text
--      blocks AND tool_use blocks with the WRONG name (CODEX NIT N3).
--   4. finalize(input) -> normalize-nulls -> validate -> repair-once -> degrade. ALWAYS valid.
--   5. No matching tool_use block (or no valid input) -> degrade.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local ru = require 'src.providers.response_util'

-- The expected forced-tool name. Mirrors claude_request.M.TOOL_NAME (kept as a local literal so
-- this mapper does not require the request builder — they share the same constant by contract).
local TOOL_NAME = 'report_bird_identification'

local M = {}

local degrade  = ru.degrade
local finalize = ru.finalize

-- map(parsedBody) -> a contract-valid common-schema table (mapped response OR degrade shape).
-- TOTAL: never indexes a nil, never raises, never returns an unvalidated body.
function M.map(parsedBody)
    if type(parsedBody) ~= 'table' then return degrade() end

    -- Truncated (token cap) or model refusal: do NOT trust a partial/declined body -> degrade.
    local sr = parsedBody.stop_reason
    if sr == 'max_tokens' or sr == 'refusal' then
        return degrade()
    end

    local content = parsedBody.content
    if type(content) ~= 'table' then return degrade() end

    -- Select the FIRST tool_use block with the EXPECTED name whose input is a TABLE. Skipping
    -- text blocks AND wrong-named tool_use blocks (CODEX NIT N3). The input is ALREADY parsed —
    -- we hand it straight to finalize (NO json.decode); a non-table input falls through to degrade.
    for i = 1, #content do
        local block = content[i]
        if type(block) == 'table'
            and block.type == 'tool_use'
            and block.name == TOOL_NAME
            and type(block.input) == 'table' then
            return finalize(block.input)
        end
    end

    -- No matching tool_use block (e.g. end_turn with only text, or wrong-named only) -> degrade.
    return degrade()
end

return M
