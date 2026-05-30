-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/fake.lua (FAKE-01 — PURE core, NO network)
--
-- PURE module: the only require is the pure src.contract, so it is require-able under
-- stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant). NO network, NO process spawn, NO file I/O at load — every fixture is an
-- in-module or injected Lua table. This is the deterministic offline provider that lets
-- Phases 4-5 be built and tested with no API key.
--
-- Interface (SPEC s6): a provider object exposes identify(image, ctx) -> response_table,
-- where the response MUST pass contract.validateResponse.
--
-- CODEX hardening:
--   * MUST-FIX 14: new(fixtures) VALIDATES every fixture with contract.validateResponse at
--     construction and REJECTS (returns nil, err) if any is malformed; identify RE-VALIDATES
--     the selected response and returns (nil, err) if it does not pass — so a "green" path
--     can never hand Phase 5 a response it cannot trust.
--   * MUST-FIX 22: this file contains NO network or external-process primitive of any
--     kind (no HTTP client, no network library, no process spawn, no shell-out). Verified
--     by the no-network grep gate, which is kept clean by avoiding even the literal token
--     names in these comments (the gate is a plain substring search).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local contract = require 'src.contract'

local M = {}

-- deepCopy(v) -> a structurally independent copy of v (tables recursively, scalars as-is).
-- CODEX review item 7: identify must NOT hand the caller a reference INTO the shared
-- fixture store (M.BUILTIN is reused by every providers.get('fake')). A caller that mutates
-- a returned response would otherwise corrupt the fixture for a later get('fake'). Returning
-- a deep copy isolates each call's result. Pure Lua 5.1; fixtures are plain data tables
-- (no cycles, no metatables), so a simple recursive copy is sufficient and terminates.
local function deepCopy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, val in pairs(v) do
        out[k] = deepCopy(val)
    end
    return out
end

-- =====================================================================
-- BUILTIN fixtures. Each MUST pass contract.validateResponse.
-- =====================================================================
M.BUILTIN = {
    -- The canonical "bird present" example (Northern Cardinal, species rank) with a valid
    -- alternatives array.
    default = {
        bird_present = true,
        detections = {
            {
                bbox = { 0.30, 0.25, 0.70, 0.80 },
                common_name = "Northern Cardinal",
                scientific_name = "Cardinalis cardinalis",
                confidence = 0.82,
                identified_rank = "species",
                rank_name = "Cardinalis cardinalis",
                alternatives = {
                    {
                        common_name = "Pyrrhuloxia",
                        scientific_name = "Cardinalis sinuatus",
                        confidence = 0.10,
                        identified_rank = "species",
                        rank_name = "Cardinalis sinuatus",
                    },
                },
            },
        },
    },
    -- The "no bird" example: bird_present=false with an EMPTY detections array.
    none = {
        bird_present = false,
        detections = {},
    },
}

-- new(fixtures) -> (provider) | (nil, err)
--   fixtures = { [name] = response_table, ... }
-- CODEX MUST-FIX 14: validate EVERY fixture up front; reject the whole construction if any
-- fixture is malformed (so a bad canned response is caught at wiring time, not at runtime).
function M.new(fixtures)
    if type(fixtures) ~= 'table' then
        return nil, 'fixtures-not-table'
    end
    for name, resp in pairs(fixtures) do
        local ok, err = contract.validateResponse(resp)
        if not ok then
            return nil, 'bad-fixture:' .. tostring(name) .. ':' .. tostring(err)
        end
    end

    local self = { fixtures = fixtures }

    -- identify(image, ctx[, fixtureName]) -> (response_table) | (nil, err)
    -- Selects a fixture by explicit arg, else ctx.fakeFixture, else 'default'. RE-VALIDATES
    -- the chosen response (defence in depth, CODEX MUST-FIX 14). NO network.
    function self.identify(image, ctx, fixtureName)
        local name = fixtureName
            or (type(ctx) == 'table' and ctx.fakeFixture)
            or 'default'
        local resp = self.fixtures[name] or self.fixtures['default']
        if resp == nil then
            return nil, 'no-fixture:' .. tostring(name)
        end
        local ok, err = contract.validateResponse(resp)
        if not ok then
            return nil, 'fixture-failed-validation:' .. tostring(name) .. ':' .. tostring(err)
        end
        -- CODEX review item 7: return a DEEP COPY, never the stored fixture reference, so a
        -- caller mutating the result cannot corrupt this provider's fixtures or the shared
        -- M.BUILTIN that a later providers.get('fake') reuses.
        return deepCopy(resp)
    end

    return self
end

return M
