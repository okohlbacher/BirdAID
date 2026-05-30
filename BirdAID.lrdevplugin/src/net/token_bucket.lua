-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/token_bucket.lua (Phase 9 — BL-06 global rate limiter)
--
-- PURE module: imports NO Lr* module, uses NO os.time/os.date/os.clock, and uses NO
-- math.random. It is fully deterministic and require-able under stock lua / lua5.1 / luajit
-- for offline unit testing (the CODEX-mandated separation invariant). NO network/process here.
--
-- WHY THIS EXISTS: with maxConcurrency>1 (BL-06) up to N provider calls are in flight at once.
-- To keep the AGGREGATE provider-call rate honoring the existing serial `rateLimit`, ALL workers
-- share ONE global token bucket. A worker takes ONE token immediately before EVERY provider call
-- (the preview identify AND each crop re-query — BLOCKER C: per-PROVIDER-CALL consumption, NOT on
-- the queue pull), so `rate` is a true aggregate provider-call rate even when the crop pass is on.
--
-- RATE MAPPING (documented contract): the existing `rateLimit` pref is the INTER-CALL SECONDS in
-- serial mode. The caller converts it to a rate of (1/rateLimit) tokens/sec when rateLimit > 0.
-- When rateLimit <= 0 the caller passes rate <= 0 here and the bucket is UNLIMITED (take always
-- true, never blocks). The Wave-2 caller (worker_pool) MUST pass capacity = 1 (NO bursting) so
-- dispatch is strictly PACED at one call per 1/rate seconds even across N workers — this is what
-- bounds a dead-provider thundering herd. capacity is configurable only for tests.
--
-- INTERFACE:
--   M.new(opts) -> { take } where opts = {
--       rate     = <tokens/sec, derived from prefs.rateLimit; <=0 means UNLIMITED>,
--       capacity = <max burst; DEFAULT 1 = no bursting>,
--       now0     = <initial clock seconds (the injected starting time)>,
--   }
--   take(now) -> (true)              when a token is available at time `now` (consumes one), or
--             -> (false, waitSeconds) when none is available (waitSeconds = time to next token).
--   Refill is lazy: elapsed = max(0, now - lastNow); tokens = min(capacity, tokens + elapsed*rate).
--   A BACKWARDS clock (now < lastNow) adds zero (elapsed clamped to >= 0). A NaN/inf `now` is
--   treated as zero elapsed (never grants a spurious token). A NaN/inf/<=0 `rate` is UNLIMITED.
--
-- Strictly Lua 5.1 common subset: no \u{}, no // integer div, no goto, no <close>; unpack global.

local M = {}

local INF = 1 / 0
-- finite(x): a real, non-NaN, non-inf number (NaN: x ~= x; inf: x == +/-INF).
local function finite(x)
    return type(x) == 'number' and x == x and x ~= INF and x ~= -INF
end

-- M.new(opts) -> a closure-based bucket. State is captured locally and never exposed by reference.
function M.new(opts)
    opts = type(opts) == 'table' and opts or {}

    -- rate: <=0 or non-finite => UNLIMITED (the bucket never throttles).
    local rate = opts.rate
    local unlimited = (not finite(rate)) or rate <= 0

    -- capacity: DEFAULT 1 (no bursting). A non-finite/<1 capacity falls back to 1.
    local capacity = opts.capacity
    if not finite(capacity) or capacity < 1 then capacity = 1 end

    -- lastNow: the injected starting clock. A non-finite now0 starts at 0.
    local lastNow = finite(opts.now0) and opts.now0 or 0
    -- A fresh bucket starts FULL (capacity tokens available immediately).
    local tokens = capacity

    local self = {}

    -- take(now) -> (true) | (false, waitSeconds). Lazy refill from elapsed time.
    function self.take(now)
        if unlimited then
            return true                       -- unlimited: always grant, consume nothing, no wait.
        end

        -- elapsed = max(0, now - lastNow); a backwards or non-finite `now` adds zero.
        local elapsed = 0
        if finite(now) then
            local d = now - lastNow
            if d > 0 then elapsed = d end
            lastNow = now                      -- latch the clock forward only on a finite now.
        end

        -- Lazy refill, capped at capacity.
        tokens = tokens + elapsed * rate
        if tokens > capacity then tokens = capacity end

        if tokens >= 1 then
            tokens = tokens - 1
            return true
        end
        -- Not enough: report the time until the next whole token accrues.
        return false, (1 - tokens) / rate
    end

    return self
end

return M
