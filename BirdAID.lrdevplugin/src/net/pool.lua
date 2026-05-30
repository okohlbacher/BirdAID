-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/pool.lua (Phase 9 — BL-06 worker-pool dispatch state machine)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
-- NO network/process here — the Lr glue (worker_pool.lua, Wave 2) is a thin driver over this.
--
-- THE CONCURRENCY-SAFE dispatch/drain/cancel LOGIC, extracted PURE so cooperative overlap,
-- throttle interaction, breaker-open-drain, and cancel are unit-testable offline.
--
-- BREAKER OWNERSHIP (CRITICAL, baked here): the pool NEVER calls breaker.record. The PROVIDER is
-- the sole recorder. The pool only READS breaker.shouldStop() to decide whether to keep DISPATCHING
-- new items. onResult receives an outcome purely to free the slot + mark the item terminal +
-- classify identified/deferred/fatal/cancelled — it MUST NOT touch the breaker.
--
-- PRE-CALL GATE SUPPORT (BLOCKER D): the controller accepts a per-item 'deferred' outcome from
-- onResult. The worker (Wave 2) calls breaker.shouldStop() immediately before each provider.identify
-- (AFTER acquiring a token); if open it does NOT call the provider and reports onResult(key,
-- 'deferred'). So a breaker-open-after-dispatch anchor is recorded 'deferred' (NEVER 'identified',
-- even though the provider would have returned a valid degrade). The cluster join (results.lua)
-- defers its followers too.
--
-- INTERFACE:
--   M.new(opts) where opts = { items=<array of opaque work keys>, maxConcurrency=<int>,
--     bucket=<token_bucket|nil, owned by the worker body>, breaker=<breaker, READ-ONLY here> }
--   -> a controller:
--     nextDispatch(now) -> { action='dispatch', key, slot } | { action='wait', seconds }
--                        | { action='idle' } | { action='done' }
--        Gated by a FREE concurrency slot (inFlight < maxConcurrency) AND breaker.shouldStop()
--        (read-only). With BLOCKER C the token bucket is consumed by the WORKER immediately before
--        each provider call, NOT at dispatch, so nextDispatch gates on slot + breaker only.
--     onResult(key, outcome) where outcome in {'identified','fatal','cancelled','deferred'}: frees
--        the slot, marks the item terminal. Does NOT record into the breaker.
--     cancel(): after cancel, nextDispatch dispatches nothing new; drains in-flight to 'done'.
--     terminalStatus() -> { [key]='identified'|'fatal'|'deferred'|'cancelled' } for EVERY item.
--        (This IS worker_pool.run's statusByAnchorKey.)
--     state() -> { inFlight, dispatched, completed, deferred, cancelled, breakerOpen } token-free.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local M = {}

-- normalize an onResult outcome to a terminal status. Unknown -> 'identified' is WRONG; default
-- conservatively. Per the contract the worker only ever reports one of the four.
local function normalizeOutcome(outcome)
    if outcome == 'fatal' then return 'fatal' end
    if outcome == 'deferred' then return 'deferred' end
    if outcome == 'cancelled' then return 'cancelled' end
    if outcome == 'identified' then return 'identified' end
    -- any unexpected value: treat as deferred (SAFE — retried next run, never a false 'identified').
    return 'deferred'
end

function M.new(opts)
    opts = type(opts) == 'table' and opts or {}
    local items = type(opts.items) == 'table' and opts.items or {}
    -- defensively FLOOR + clamp maxConcurrency (settings already floors it, but the controller is
    -- the last line of defence): a fractional / sub-1 value collapses to 1 so inFlight gating is sane.
    local INF = 1 / 0
    local maxConcurrency = math.floor(tonumber(opts.maxConcurrency) or 1)
    if maxConcurrency ~= maxConcurrency then maxConcurrency = 1 end  -- NaN guard.
    -- inf / -inf guard: math.floor(inf) == inf (NOT caught by the NaN or <1 checks below), which
    -- would make `inFlight >= maxConcurrency` ALWAYS false and dispatch EVERY item at once (no
    -- concurrency limit -> over-dispatch). Collapse a non-finite cap to the serial floor (1), the
    -- same conservative path as NaN / sub-1.
    if maxConcurrency == INF or maxConcurrency == -INF then maxConcurrency = 1 end
    if maxConcurrency < 1 then maxConcurrency = 1 end
    local breaker = opts.breaker

    -- private state.
    local cursor = 1            -- next item index to consider dispatching.
    local inFlight = 0
    local cancelled = false
    local terminal = {}         -- [key] = terminal status
    local dispatched = {}       -- [key] = true while in-flight (dispatched, not yet resolved)
    local dispatchedCount = 0
    local total = #items

    -- READ the breaker without ever recording.
    local function breakerOpen()
        return breaker ~= nil and type(breaker.shouldStop) == 'function' and breaker.shouldStop() == true
    end

    -- mark every NOT-yet-terminal remaining item (from `cursor`..end) with `status`.
    local function flushRemaining(status)
        while cursor <= total do
            local key = items[cursor]
            if terminal[key] == nil then
                terminal[key] = status
            end
            cursor = cursor + 1
        end
    end

    local self = {}

    function self.nextDispatch(now)
        -- cancel wins: stop new dispatch; drain in-flight; then mark remainder cancelled.
        if cancelled then
            if inFlight > 0 then return { action = 'idle' } end
            flushRemaining('cancelled')
            return { action = 'done' }
        end
        -- breaker open: stop NEW dispatch; drain in-flight; then mark remainder deferred.
        if breakerOpen() then
            if inFlight > 0 then return { action = 'idle' } end
            flushRemaining('deferred')
            return { action = 'done' }
        end
        -- no free slot but items in flight -> idle.
        if inFlight >= maxConcurrency then
            return { action = 'idle' }
        end
        -- past the end of the item list?
        if cursor > total then
            if inFlight > 0 then return { action = 'idle' } end
            return { action = 'done' }
        end
        -- dispatch the next item. (The worker body, not nextDispatch, consults the token bucket
        -- before the provider call per BLOCKER C.)
        local key = items[cursor]
        cursor = cursor + 1
        inFlight = inFlight + 1
        dispatchedCount = dispatchedCount + 1
        dispatched[key] = true
        return { action = 'dispatch', key = key, slot = inFlight }
    end

    function self.onResult(key, outcome)
        -- free the slot + record the terminal status. NEVER touch the breaker.
        -- GHOST / DUPLICATE GUARD: only a key currently in `dispatched` (in-flight, not yet
        -- resolved) may free a slot. A completion for an unknown key (never dispatched) or for a
        -- key already resolved (duplicate onResult) is IGNORED — no inFlight decrement, no terminal
        -- write, no double-count — so a stray completion can NEVER over-dispatch by freeing a real
        -- in-flight slot.
        if not dispatched[key] then return end
        dispatched[key] = nil
        terminal[key] = normalizeOutcome(outcome)
        if inFlight > 0 then inFlight = inFlight - 1 end
    end

    function self.cancel()
        cancelled = true
    end

    function self.terminalStatus()
        -- a defensive snapshot: ensure EVERY item appears. (nextDispatch's done-path already
        -- flushes the remainder, but a caller may inspect mid-drain — fill any gaps as the
        -- current terminal-cause: cancelled if cancelled, else deferred if the breaker is open,
        -- else leave only the truly-resolved entries. We DO NOT invent statuses for in-flight
        -- items here; the driver resolves every dispatched item via onResult.)
        local out = {}
        for i = 1, total do
            local key = items[i]
            out[key] = terminal[key]
        end
        return out
    end

    function self.state()
        local deferred, cancelledN = 0, 0
        for i = 1, total do
            local st = terminal[items[i]]
            if st == 'deferred' then deferred = deferred + 1 end
            if st == 'cancelled' then cancelledN = cancelledN + 1 end
        end
        local completed = 0
        for _ in pairs(terminal) do completed = completed + 1 end
        return {
            inFlight = inFlight,
            dispatched = dispatchedCount,
            completed = completed,
            deferred = deferred,
            cancelled = cancelledN,
            breakerOpen = breakerOpen(),
        }
    end

    return self
end

return M
