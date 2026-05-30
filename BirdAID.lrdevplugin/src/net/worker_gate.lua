-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/worker_gate.lua (Phase 9 — BL-06 PURE per-provider-call gate)
--
-- PURE module: imports NO Lr* module, uses NO os.time/os.date/os.clock, and uses NO
-- math.random. It is fully deterministic and require-able under stock lua / lua5.1 / luajit
-- for offline unit testing (the CODEX-mandated separation invariant). NO network/process here.
--
-- WHY THIS EXISTS (TESTABILITY): the per-PROVIDER-CALL decision logic — take a token, then
-- re-check cancel, then re-check the breaker, then (only if both closed) call the provider — is
-- the safety-critical sequence (BLOCKER B + C + D). Previously it lived inline in worker_pool.lua
-- (a thin Lr-glue driver that CANNOT run under stock lua), so the only test of the after-token
-- cancel/breaker re-check was a MANUAL MODEL that called pool.onResult(...) directly and never
-- exercised the real gate. A regression deleting the after-token cancel/breaker check would still
-- pass that model. Extracting the gate here — with EVERYTHING injected (clock, sleep, cancel,
-- breaker, identify, bucket) — lets a real spec drive the ACTUAL decision path offline and assert
-- that identify is NEVER reached when cancel/breaker fire mid-wait, and that EACH gate call costs
-- exactly one token. worker_pool.lua becomes thin glue that injects LrTasks.sleep + the real clock
-- + the real cancel/breaker/identify into this pure gate.
--
-- EXACT SEQUENCE (identical to the prior inline logic; this is a refactor, not a behavior change):
--   (1) ACQUIRE A TOKEN: loop { ok,wait = bucket.take(now()); if ok break else sleep(wait) }.
--       capacity=1 in production (no bursting) so each provider call costs exactly one token and
--       the AGGREGATE provider-call rate honors rateLimit. A nil/absent bucket is UNLIMITED.
--       Because sleep() yields cooperatively in production, cancel/breaker may flip DURING the wait.
--   (2) AFTER-TOKEN CANCEL GATE (checked FIRST): if isCanceled() -> return 'cancelled'; the
--       provider is NEVER called. A token already taken just paces the next call.
--   (3) AFTER-TOKEN BREAKER GATE: if breaker.shouldStop() -> return 'deferred'; provider NOT called
--       (even though it would return a valid degrade). Cancel WINS over breaker (checked first).
--   (4) ELSE call identify(item): (response, nil) -> 'identified'(+response); (nil, err) -> 'fatal'.
--
-- RETURN CONTRACT: gate(ctx) -> (status, response, err) where status is one of
--   'cancelled' | 'deferred' | 'identified' | 'fatal'. Only 'identified' carries a response; only
--   'fatal' carries an err. The gate NEVER raises for a normal outcome (no sentinels leak out);
--   it maps every path to a plain status. (worker_pool.lua wraps the gate call in its yield-safe
--   ypcall ONLY to contain a THROWING identify/sleep — a throw is mapped to 'fatal' by the glue.)
--
-- BREAKER OWNERSHIP (resolves the double-ownership blocker): the gate READS breaker.shouldStop()
-- ONLY; it NEVER calls breaker.record. The provider (inside identify) owns recording.
--
-- ctx = {
--   item       = <the work item passed to identify>,
--   bucket     = <token_bucket {take=fn}|nil>,  -- nil => unlimited (no token cost).
--   now        = function() -> seconds,          -- injected monotonic clock (NOT os.clock).
--   sleep      = function(secs) end,             -- injected cooperative sleep; in tests it may
--                                                --   advance the clock AND flip cancel/breaker.
--   isCanceled = function() -> bool|nil,         -- cooperative cancel (opt; absent => never).
--   breaker    = <{shouldStop=fn}|nil>,          -- READ-ONLY here (opt; absent => never stops).
--   identify   = function(item) -> (response|nil, err),  -- the PROVIDER call.
-- }
--
-- Strictly Lua 5.1 common subset: no \u{}, no // integer div, no goto, no <close>; unpack global.

local M = {}

-- safeCall(fn) -> bool result. An absent/throwing predicate must never crash the gate; a throw or
-- a non-function yields a SAFE default of false (not cancelled / not stopping).
local function safeBool(fn)
    if type(fn) ~= 'function' then return false end
    local ok, v = pcall(fn)
    return (ok and v) and true or false
end

-- acquireToken(bucket, now, sleep): take ONE token, sleeping (via the injected sleep) until granted.
-- A nil/invalid bucket is UNLIMITED (no token cost, returns immediately). The injected sleep yields
-- cooperatively in production AND, in tests, may advance the clock and flip cancel/breaker mid-wait.
local function acquireToken(bucket, now, sleep)
    if type(bucket) ~= 'table' or type(bucket.take) ~= 'function' then
        return                                   -- no bucket -> unlimited, no token cost.
    end
    local clock = type(now) == 'function' and now or function() return 0 end
    local nap   = type(sleep) == 'function' and sleep or function() end
    while true do
        local ok, wait = bucket.take(clock())
        if ok then return end
        -- Not enough tokens: sleep the reported wait (>=0). Guard a bad/absent wait with a small
        -- floor so we always yield and re-check (never a busy spin).
        local w = tonumber(wait)
        if type(w) ~= 'number' or w ~= w or w < 0 then w = 0 end
        if w < 0.001 then w = 0.001 end
        nap(w)
    end
end

-- breakerOpen(breaker) -> bool. READ-ONLY shouldStop; NEVER records. Absent/throwing => false.
local function breakerOpen(breaker)
    if type(breaker) ~= 'table' or type(breaker.shouldStop) ~= 'function' then
        return false
    end
    local ok, v = pcall(breaker.shouldStop)
    return (ok and v) and true or false
end

-- M.gate(ctx) -> (status, response, err). See the EXACT SEQUENCE + RETURN CONTRACT above.
function M.gate(ctx)
    ctx = type(ctx) == 'table' and ctx or {}
    local item     = ctx.item
    local identify = type(ctx.identify) == 'function' and ctx.identify
        or function() return nil, 'no-identify' end

    -- (1) TAKE A TOKEN (per-provider-call cost). sleep() yields in production; cancel/breaker may
    --     flip DURING this wait (the injected sleep models that in tests).
    acquireToken(ctx.bucket, ctx.now, ctx.sleep)

    -- (2) AFTER-TOKEN CANCEL GATE (checked FIRST — cancel WINS over breaker). Do NOT call identify.
    if safeBool(ctx.isCanceled) then
        return 'cancelled', nil, nil
    end

    -- (3) AFTER-TOKEN BREAKER GATE. Do NOT call identify (even though it would degrade-return).
    if breakerOpen(ctx.breaker) then
        return 'deferred', nil, nil
    end

    -- (4) CALL THE PROVIDER. Map (response,nil) -> 'identified'; (nil,err) -> 'fatal'.
    local response, err = identify(item)
    if response ~= nil and err == nil then
        return 'identified', response, nil
    end
    return 'fatal', nil, (err ~= nil and tostring(err) or 'identify-failed')
end

return M
