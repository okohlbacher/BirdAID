-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/retry_filter.lua (Phase 12 — RETRY-01 re-process-only-incomplete core)
--
-- PURE module: imports NO Lightroom SDK module, uses NO os.time/date/clock, NO math.random.
-- Deterministic and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation
-- invariant). It requires only src.run_state for the terminal/retryable OUTCOME predicate. The Lr
-- persistence that produced the prior-run records (run_state_store) is Plan 03.
--
-- WHAT IT DOES (RETRY-01, filter half): given a prior run's per-photo OUTCOME records, return the
-- photoIds that should be RE-PROCESSED — i.e. the ones whose outcome is NOT terminal (retryable,
-- OR a genuinely-missing / unknown outcome, which is treated as non-terminal so it is retried).
-- written / existing / no-bird / no-detection are TERMINAL and are NEVER re-selected (CODEX HIGH-3:
-- a terminal no-write success — existing keyword, no bird, no detection — is done, not retryable).
--
-- WHY OUTCOME, NOT a catalog read (Pitfall 3 / T-12-06): the plugin writes FLAT keywords with no
-- BirdAID namespace (createKeyword(name,nil,true,nil,true)), so the catalog cannot be introspected
-- to tell "we already processed this photo". The persisted terminal OUTCOME is the source of truth.
--
-- M.selectIncomplete(priorRun) -> { <photoId>, ... } de-duped by photoId, malformed ids dropped,
--   first-occurrence order preserved. selectIncomplete(nil) / selectIncomplete({}) -> {}.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local run_state = require('src.run_state')

local M = {}

-- selectIncomplete(priorRun): iterate the prior-run records, emit the photoId of each record whose
-- outcome is NOT terminal (retryable + unknown/missing), AT MOST ONCE per id (a seen[] guard), in
-- first-occurrence order. A record whose photoId is not a non-empty string is DROPPED (never emits
-- a junk id). A nil / non-table priorRun degrades to {} (never raises).
function M.selectIncomplete(priorRun)
    local out = {}
    if type(priorRun) ~= 'table' then return out end

    local seen = {}
    for i = 1, #priorRun do
        local r = priorRun[i]
        if type(r) == 'table' then
            local id = r.photoId
            -- drop malformed ids: only a non-empty string id can ever be emitted.
            if type(id) == 'string' and id ~= '' and not seen[id] then
                if not run_state.isTerminal(r.outcome) then
                    seen[id] = true
                    out[#out + 1] = id
                end
            end
        end
    end

    return out
end

return M
