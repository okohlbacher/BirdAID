-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/breaker.lua (Phase 5 — run-level circuit breaker, CODEX MUST-FIX 8)
--
-- PURE module: imports NO Lr* module, uses NO os.time/os.date/os.clock, and uses NO
-- math.random. It is fully deterministic and require-able under stock lua / lua5.1 / luajit
-- for offline unit testing (the CODEX-mandated separation invariant). NO network/process here.
--
-- WHY THIS EXISTS: backoff.lua bounds the PER-PHOTO attempt count, but under a sustained quota
-- outage (e.g. a hard 429 on every photo) a 500-photo run would still issue 500 x maxAttempts
-- requests, burning quota and cost for no benefit. This is a RUN-level circuit breaker the
-- orchestrator (Plan 05-04) consults between photos: after N CONSECUTIVE retryable
-- exhaustions it OPENS and latches open, so the orchestrator can stop hammering the API and
-- defer/degrade the remaining photos (surfaced in the run summary).
--
-- Interface:
--   breaker.new(opts?) -> { record, shouldStop, state }
--     opts.threshold : a small constant default (DEFAULT_THRESHOLD) when absent or non-number;
--                      a setting may drive it later.
--   record('exhausted')         -- a per-photo retry EXHAUSTION; increments the consecutive count.
--   record('ok')                -- a successful (or degraded-from-success) per-photo result; RESET.
--   record('fatal')             -- a non-retryable 401/400 config error; RESET (NOT a run-wide
--                                  outage — a bad key is not a reason to keep the breaker armed).
--   record(<anything else>)     -- treated conservatively as a RESET (only 'exhausted' arms it).
--   shouldStop() -> bool        -- true once consecutive >= threshold; LATCHES true for the run.
--   state() -> { consecutive=<number>, open=<bool> }  -- token-free counts only (logging/summary).
--
-- LATCHING: once OPEN the breaker stays open for the life of THIS breaker object (a run-level
-- cooldown) — a later 'ok' does NOT re-close it. A fresh run creates a fresh breaker.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local M = {}

-- A small default threshold: open after this many CONSECUTIVE exhaustions. Must be > 1 so a
-- single transient exhaustion never trips the run-level breaker.
M.DEFAULT_THRESHOLD = 5

-- new(opts) -> { record, shouldStop, state }
function M.new(opts)
    local threshold = M.DEFAULT_THRESHOLD
    if type(opts) == 'table' and type(opts.threshold) == 'number' and opts.threshold >= 1 then
        threshold = opts.threshold
    end

    -- Private run-level state (closed over; never exposed by reference).
    local consecutive = 0
    local open = false

    local self = {}

    -- record(outcome): 'exhausted' arms the breaker; everything else resets the consecutive
    -- count. Once OPEN we LATCH — record never re-closes a tripped breaker.
    function self.record(outcome)
        if outcome == 'exhausted' then
            consecutive = consecutive + 1
            if consecutive >= threshold then
                open = true
            end
        else
            -- 'ok', 'fatal', or anything else: reset the consecutive run. (Latched `open`
            -- stays open — a fresh breaker is needed to re-arm the run.)
            consecutive = 0
        end
    end

    -- shouldStop() -> true once the breaker has tripped open (latched for the run).
    function self.shouldStop()
        return open
    end

    -- state() -> a token-free snapshot for logging/summary (counts + open flag only).
    function self.state()
        return { consecutive = consecutive, open = open }
    end

    return self
end

return M
