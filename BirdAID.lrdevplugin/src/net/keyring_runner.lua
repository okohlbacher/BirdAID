-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/keyring_runner.lua (Phase 11 / Plan 11-05 — DKEY-02 live-failover
-- coordinator + DKEY-03 no-leak)
--
-- PURE module: imports NO Lr* module, reads NO wall clock (NO os.time/os.date/os.clock), and uses
-- NO randomness (NO math.random). It is fully deterministic and require-able under stock lua /
-- lua5.1 / luajit for offline unit testing (the CODEX-mandated separation invariant). NO
-- network/process here. The ONLY require is the pure src.net.backoff (the single-key per-attempt
-- delay policy is REUSED, not duplicated — mirrors how keyring.lua requires backoff). EVERYTHING
-- else (keyring, breaker, the per-slot attemptOnce, now, sleep) is INJECTED via opts.
--
-- WHAT THIS IS: the per-photo FAILOVER coordinator. It owns the failover DECISION over a keyring
-- and a STRUCTURED single-attempt result. The provider (in single-attempt mode, deps.maxAttempts
-- == 1) performs exactly ONE HTTP attempt and returns the token-free table
--   { outcome = 'ok' | 'retry' | 'auth-fatal' | 'request-fatal',
--     status = <httpStatusInt | nil>, retryAfter = <secs | nil>,
--     response = <parsed | nil>, err = <token-free string | nil> }
-- so the HTTP STATUS is reliably available (NOT buried in an opaque err string). attemptOnce(idx)
-- is the INJECTED closure that builds the per-slot deps (maxAttempts=1) and returns that table.
--
-- DECISIONS encoded here:
--   D-01  SINGLE ACTIVE SLOT, run-wide. The coordinator is serial by construction: it selects one
--         slot, does one attempt, decides, loops. There is no concurrency primitive here; the
--         Lr wiring (Task 3) enforces the serial path for multi-key runs so this never becomes
--         accidental concurrent DISTRIBUTION (deferred, Phase 17).
--   D-04  AUTH-fatal (status 401/403) -> keyring.record('retire') (park the slot for the run) then
--         fail over. REQUEST-fatal (400/404/422 / any non-auth fatal) -> return the per-photo
--         provider error WITHOUT retiring/cooling/failing over (keyring 'request-error' is a no-op).
--         The split is keyed on result.STATUS, NEVER on a string-match of result.err.
--   D-06  On retry (429/5xx/transport): keyring.record('cooldown') then immediately re-select. If
--         another healthy slot exists -> fail over IMMEDIATELY with NO sleep. If NO other slot is
--         healthy AND this is a SINGLE-key run -> fall back to the backoff per-attempt sleep
--         (backoff.next); if it says retry, sleep and try the SAME slot again (once its cooldown
--         elapses); else exhaust.
--   D-07  The coordinator is the SOLE recorder of breaker 'exhausted', and ONLY when
--         keyring.select() returns nil (all keys cooling/retired/exhausted). A single bad key never
--         latches the run breaker prematurely (Assumption A3).
--
-- NO-LEAK (SC3 / DKEY-03 / T-11-22): all coordinator state is token-free (storage ordinals +
-- counts + the provider's already-token-free err). The returned result references the winning slot
-- by an integer storage ORDINAL only — never a token value or physical-key identity.
--
-- run(opts) -> result, where opts = {
--     keyring,        -- the keyring.new(...) object: select(now)/record(idx,outcome,now,attempt,retryAfter)
--     attemptOnce,    -- function(storageIndex) -> { outcome, status, retryAfter, response, err }
--     now,            -- function() -> integer tick (injected; NEVER a wall clock here)
--     sleep,          -- function(seconds) (the single-key backoff fallback wait; recorder in tests)
--     breaker,        -- the run-level breaker: record('exhausted'|...)/shouldStop()
--     backoff,        -- optional; the pure backoff module (defaults to the required src.net.backoff)
--     priorityCount,  -- the number of slots in the priority order (single-key fallback gate)
--   }
--   result on success         : { outcome='ok', response=<parsed>, storageIndex=<ordinal> }
--   result on request-fatal   : { outcome='request-fatal', err=<token-free>, status=<int>, storageIndex=<ordinal> }
--   result on all-keys-down   : { outcome='defer', degraded=true, response=nil }
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local defaultBackoff = require 'src.net.backoff'

local M = {}

-- nowTickOf(now): call the injected now() and coerce to a numeric tick (0 on any non-number).
local function nowTickOf(now)
    if type(now) ~= 'function' then return 0 end
    local t = now()
    if type(t) == 'number' and t == t then return t end
    return 0
end

-- run(opts): drive select -> attemptOnce -> classify-by-status -> record -> failover/cooldown/
-- exhausted until a terminal result. PURE; never sleeps while another healthy slot exists (D-06).
function M.run(opts)
    opts = type(opts) == 'table' and opts or {}
    local keyring       = opts.keyring
    local attemptOnce   = opts.attemptOnce
    local now           = opts.now
    local sleep         = opts.sleep
    local breaker       = opts.breaker
    local backoff       = opts.backoff or defaultBackoff
    local priorityCount = opts.priorityCount

    -- recordExhausted(): the ONLY place the coordinator records 'exhausted' (D-07 / A3).
    local function recordExhausted()
        if type(breaker) == 'table' and type(breaker.record) == 'function' then
            breaker.record('exhausted')
        end
    end

    -- record(idx, outcome, ...): drive the keyring health state machine. The keyring OWNS its
    -- per-slot attempt counter (11-01 deviation): record('cooldown') bumps slot.attempt then calls
    -- backoff.next internally, so we pass nil for the advisory attempt arg and let the keyring
    -- sequence it. We are the SOLE driver: ONE record('cooldown') per failure.
    local function record(idx, outcome, nowTick, retryAfter)
        if type(keyring) == 'table' and type(keyring.record) == 'function' then
            keyring.record(idx, outcome, nowTick, nil, retryAfter)
        end
    end

    -- forcedSlot: set after a SINGLE-key backoff sleep so the next iteration re-attempts the SAME
    -- slot directly. select(now) would skip a slot still inside its cooldown window when now() is a
    -- fixed/slowly-advancing tick (in production now() advances past the cooldown after the sleep;
    -- in tests it is fixed) — but the sleep IS that cooldown wait, so the slot is due for a retry.
    -- This is ONLY ever reached on the single-key path (priorityCount == 1, no other healthy slot).
    local forcedSlot = nil

    -- The failover loop. Each iteration selects the highest-priority healthy slot and does exactly
    -- ONE attempt against it, then maps the structured result by its STATUS/OUTCOME.
    while true do
        local nowTick = nowTickOf(now)

        -- (1) select the highest-priority healthy slot. nil => all keys down (D-07).
        local idx = nil
        if forcedSlot ~= nil then
            idx = forcedSlot
            forcedSlot = nil
        elseif type(keyring) == 'table' and type(keyring.select) == 'function' then
            idx = keyring.select(nowTick)
        end
        if idx == nil then
            recordExhausted()
            return { outcome = 'defer', degraded = true, response = nil }
        end

        -- (2) one HTTP attempt against the selected slot (single-attempt mode, maxAttempts=1).
        local r = nil
        if type(attemptOnce) == 'function' then r = attemptOnce(idx) end
        if type(r) ~= 'table' then
            -- A malformed attempt result is treated as a transient retry (token-free, conservative).
            r = { outcome = 'retry', status = nil, retryAfter = nil, response = nil, err = 'attempt-error' }
        end

        local outcome = r.outcome
        local status  = r.status

        -- (3) map by outcome, splitting fatals by STATUS (never by parsing r.err).
        if outcome == 'ok' then
            record(idx, 'ok', nowTick)
            return { outcome = 'ok', response = r.response, storageIndex = idx }

        elseif outcome == 'auth-fatal' or status == 401 or status == 403 then
            -- AUTH-fatal (401/403): park the slot retired for the run, then fail over (D-04).
            record(idx, 'retire', nowTick)
            -- loop: re-select; a healthy slot continues, else select()==nil records exhausted.

        elseif outcome == 'request-fatal' then
            -- REQUEST-fatal (400/404/422/other non-auth fatal): a per-photo provider error. NO
            -- retire, NO cooldown, NO failover (keyring 'request-error' is a no-op). Surface it.
            record(idx, 'request-error', nowTick)
            return { outcome = 'request-fatal', err = r.err, status = status, storageIndex = idx }

        else
            -- 'retry' (429/5xx/transport): cool THIS slot, then decide failover vs single-key sleep.
            record(idx, 'cooldown', nowTick, r.retryAfter)

            local nextTick = nowTickOf(now)
            local nextIdx = nil
            if type(keyring) == 'table' and type(keyring.select) == 'function' then
                nextIdx = keyring.select(nextTick)
            end

            if nextIdx ~= nil then
                -- Another healthy slot is available -> fail over IMMEDIATELY with NO sleep (D-06).
                -- (loop continues; the next iteration selects nextIdx.)

            elseif priorityCount == 1 then
                -- SINGLE-key run, no other slot: fall back to the backoff per-attempt sleep (D-06).
                -- The keyring bumped this slot's attempt on record('cooldown'); mirror that attempt
                -- number for the policy delay so the sleep matches backoff.next for this attempt.
                local attempt = 1
                if type(keyring.state) == 'function' then
                    local snap = keyring.state()
                    if type(snap) == 'table' and type(snap[idx]) == 'table'
                        and type(snap[idx].attempt) == 'number' then
                        attempt = snap[idx].attempt
                    end
                end
                local nxt = backoff.next(attempt, 429, r.retryAfter)
                if type(nxt) == 'table' and nxt.retry == true then
                    if type(sleep) == 'function' then sleep(nxt.delay) end
                    -- Re-attempt the SAME slot: the sleep IS its cooldown wait (select() would skip a
                    -- still-cooling slot at a fixed/under-advanced tick). Single-key only.
                    forcedSlot = idx
                    -- loop: re-attempt the SAME slot once its cooldown window elapses.
                else
                    -- The single slot is exhausted (cap / over-cap). select() will now return nil on
                    -- the next iteration (the keyring parked it EXHAUSTED), recording 'exhausted'.
                    -- loop continues; the select()==nil branch is the single exhausted recorder.
                end

            else
                -- Multiple keys but none currently healthy (all cooling/retired/exhausted). The next
                -- select() returns nil -> the select()==nil branch records 'exhausted' (D-07).
                -- loop continues to that branch (do NOT record here — keep a single recorder).
            end
        end
    end
end

return M
