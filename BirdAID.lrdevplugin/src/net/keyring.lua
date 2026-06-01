-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/keyring.lua (Phase 11 — DKEY-02/DKEY-03 multi-key state machine)
--
-- PURE module: imports NO Lr* module, reads NO wall clock, and uses NO randomness.
-- It is fully deterministic and require-able under stock lua / lua5.1 / luajit
-- for offline unit testing (the CODEX-mandated separation invariant). NO network/process here.
-- The ONLY require is the pure src.net.backoff (its per-key cooldown policy is REUSED, not
-- duplicated — mirrors how backoff.lua requires the pure src.json).
--
-- WHAT THIS IS: a per-slot key health / selection / failover state machine. The user supplies
-- multiple API keys per provider with a priority ORDER; this module holds per-slot health and
-- answers "which storage ordinal should the next provider call use?" without ever holding,
-- logging, or emitting a token VALUE (the token lives only in the Lr Keychain glue — SC3).
--
-- DECISIONS encoded here:
--   D-05  select() returns the FIRST healthy slot in priorityOrder — by priority POSITION,
--         NOT numeric minimum (priorityOrder {2,1,3} all healthy -> select()==2). A cooled
--         higher-priority slot PREEMPTS back into use once its coolUntil <= nowTick.
--   D-06  A 429-cooled key fails over immediately to the next healthy key with NO sleep — the
--         keyring just stops selecting the cooled slot until coolUntil passes.
--   D-03  Per-key cooldown delay is computed by backoff.next (deterministic, no jitter); each
--         slot carries its OWN attempt/coolUntil (Pitfall 6 — cooling one key never changes
--         another's delay).
--   D-04  AUTH-fatal (401/403) -> 'retire': the slot is parked permanently for the run.
--         REQUEST-fatal (400/404/422/schema) -> 'request-error': a NO-OP on slot HEALTH (it is
--         a per-photo provider error surfaced by the orchestrator, NOT a key-health problem) —
--         it does NOT retire, cool, or bump the per-slot attempt.
--   EXHAUSTED guard (T-11-03): backoff.next returns retry==false in THREE cases (attempt at
--         MAX_ATTEMPTS, over-cap retryAfter, non-retryable status) — and in ALL THREE delay==0.
--         coolUntil = nowTick + 0 would make the slot INSTANTLY healthy and hammer. So when
--         nxt.retry==false the slot is parked in a distinct EXHAUSTED state (NOT cooled to
--         nowTick) — like a retire-for-run; select() skips it.
--   D-07  When NO slot is healthy, select() returns nil; the ORCHESTRATOR (not the keyring,
--         Assumption A3) then records 'exhausted' on the run-level breaker.
--
-- Interface:
--   keyring.new(opts) -> { select, record, state }
--     opts.priorityOrder : list of storage ordinals in user priority POSITION order, e.g. {2,1,3}.
--   select(nowTick)            -> the first healthy storage ordinal in priorityOrder, else nil.
--   record(idx, outcome, nowTick, attempt, retryAfter)
--       outcome 'ok'            -> recover: clear coolUntil/exhausted, reset attempt.
--       outcome 'retire'        -> 401/403 AUTH-fatal: park retired for the run.
--       outcome 'request-error' -> 400/404/422 REQUEST-fatal: NO-OP on slot health.
--       outcome 'cooldown'      -> 429/5xx: bump attempt, backoff.next; retry==true -> coolUntil;
--                                  retry==false -> EXHAUSTED.
--   state() -> token-free snapshot keyed by storage ordinal:
--       { [ordinal] = { coolUntil=<tick>|nil, retired=bool|nil, exhausted=bool|nil, attempt=<n> } }
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local backoff = require 'src.net.backoff'

local M = {}

-- A slot is healthy when it is neither retired nor exhausted and either has never cooled or its
-- cooldown window has elapsed at nowTick (coolUntil <= nowTick preempts it back into use, D-05).
local function isHealthy(slot, nowTick)
    if slot == nil then return false end
    if slot.retired then return false end
    if slot.exhausted then return false end
    if slot.coolUntil ~= nil and slot.coolUntil > nowTick then return false end
    return true
end

-- new(opts) -> { select, record, state }
function M.new(opts)
    -- priorityOrder is the user priority POSITION order (NOT sorted) — select honors it as-is.
    local priorityOrder = {}
    if type(opts) == 'table' and type(opts.priorityOrder) == 'table' then
        for i = 1, #opts.priorityOrder do
            priorityOrder[i] = opts.priorityOrder[i]
        end
    end

    -- Private per-slot health, keyed by STABLE storage ordinal (closed over; never exposed by
    -- reference — state() returns a fresh copy). Lazily created on first record / select.
    local slots = {}

    local function slotFor(storageIndex)
        local s = slots[storageIndex]
        if s == nil then
            s = { coolUntil = nil, retired = nil, exhausted = nil, attempt = 0 }
            slots[storageIndex] = s
        end
        return s
    end

    local self = {}

    -- select(nowTick): the FIRST healthy storage ordinal in priorityOrder (priority POSITION,
    -- NOT numeric minimum — D-05). nil when none is healthy (D-07 trigger for the orchestrator).
    function self.select(nowTick)
        for i = 1, #priorityOrder do
            local storageIndex = priorityOrder[i]
            local slot = slots[storageIndex]
            -- A slot never recorded against is healthy by default.
            if slot == nil or isHealthy(slot, nowTick) then
                return storageIndex
            end
        end
        return nil
    end

    -- record(storageIndex, outcome, nowTick, attempt, retryAfter)
    function self.record(storageIndex, outcome, nowTick, attempt, retryAfter)
        local slot = slotFor(storageIndex)

        if outcome == 'ok' then
            -- A recovered key rejoins: clear cooldown + exhausted, reset the per-slot attempt.
            slot.coolUntil = nil
            slot.exhausted = nil
            slot.attempt = 0

        elseif outcome == 'retire' then
            -- 401/403 AUTH-fatal (D-04): park retired permanently for the run.
            slot.retired = true

        elseif outcome == 'request-error' then
            -- 400/404/422 REQUEST-fatal (D-04): a per-photo provider error, NOT a key-health
            -- problem. NO-OP on slot health — do NOT retire, cool, or bump attempt.

        elseif outcome == 'cooldown' then
            -- 429/5xx (D-03/D-06): bump the per-slot attempt and consult the deterministic
            -- backoff policy. Each slot carries its OWN attempt (Pitfall 6).
            slot.attempt = (slot.attempt or 0) + 1
            local nxt = backoff.next(slot.attempt, 429, retryAfter)
            if nxt.retry == true then
                -- Within-cap: cool the slot until nowTick + delay (immediate failover, no sleep).
                slot.coolUntil = nowTick + (nxt.delay or 0)
            else
                -- retry==false (MAX_ATTEMPTS / over-cap / non-retryable): park EXHAUSTED — NEVER
                -- coolUntil = nowTick (that would be instantly healthy -> hammer loop, T-11-03).
                slot.exhausted = true
            end
        end
        -- Any other outcome is a conservative no-op (unknown outcomes never change health).
    end

    -- state(): a token-free snapshot keyed by storage ordinal (NEVER a token value). Returns a
    -- FRESH copy so callers cannot mutate private state.
    function self.state()
        local snap = {}
        for storageIndex, slot in pairs(slots) do
            snap[storageIndex] = {
                coolUntil = slot.coolUntil,
                retired = slot.retired,
                exhausted = slot.exhausted,
                attempt = slot.attempt or 0,
            }
        end
        return snap
    end

    return self
end

return M
