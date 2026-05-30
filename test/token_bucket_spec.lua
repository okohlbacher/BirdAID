-- test/token_bucket_spec.lua (09-01 Task 2 — PURE global token bucket)
--
-- Exercises BirdAID.lrdevplugin/src/net/token_bucket.lua: a PURE deterministic token bucket
-- (no Lr, no os.time/date/clock, no math.random) require-able under stock lua / luajit. The
-- clock is INJECTED so the AGGREGATE provider-call rate is exact-value testable with a fake clock.
--
-- Behaviors asserted (BLOCKER C: the bucket gates EVERY provider call; capacity=1 = no bursting):
--   * fresh capacity-1 bucket allows ONE immediate take, then (false, 1/rate) wait.
--   * advancing the clock by exactly 1/rate grants the next take; partial elapsed -> partial wait.
--   * capacity>1 allows a burst of `capacity` then throttles (paced proof).
--   * capacity omitted defaults to 1.
--   * rate from rateLimit<=0 means UNLIMITED (always true, no wait).
--   * a BACKWARDS clock never grants extra tokens.
--   * TWO consecutive takes within one worker body (preview identify + crop re-query) at capacity 1
--     require advancing the clock by 1/rate between them (the 2nd is throttled until then).
--
-- Loaded via dofile; uses runner globals assert_eq / assert_true. Lua 5.1 common subset.

local tb = require('src.net.token_bucket')

assert_true(type(tb) == 'table', "require 'src.net.token_bucket' resolves")
assert_true(type(tb.new) == 'function', "token_bucket exposes new")

-- helper: float equality within a small epsilon (deterministic, but guard binary float repr).
local function near(a, b)
    if type(a) ~= 'number' or type(b) ~= 'number' then return false end
    local d = a - b
    if d < 0 then d = -d end
    return d < 1e-9
end

-- =====================================================================
-- Fresh capacity-1 bucket: one immediate take, then throttled.
-- rate = 1/rateLimit; with rateLimit=1.0 -> rate=1 token/sec -> 1/rate = 1.0s wait.
-- =====================================================================
do
    local rate = 1.0  -- tokens/sec (rateLimit = 1.0s between calls)
    local b = tb.new({ rate = rate, capacity = 1, now0 = 100 })
    assert_true(type(b) == 'table', "new returns a table")
    assert_true(type(b.take) == 'function', "object exposes take")

    local ok1 = b.take(100)
    assert_eq(ok1, true, "first take at now0 succeeds (1 token available)")

    local ok2, wait2 = b.take(100)
    assert_eq(ok2, false, "second immediate take at same time is throttled")
    assert_true(near(wait2, 1.0), "wait == 1/rate (1.0s) when empty at capacity 1")
end

-- =====================================================================
-- Advancing the clock by exactly 1/rate grants the next take.
-- =====================================================================
do
    local b = tb.new({ rate = 2.0, capacity = 1, now0 = 0 })  -- rate 2/sec -> 1/rate = 0.5s
    assert_eq(b.take(0), true, "take at t=0 ok")
    local ok, wait = b.take(0)
    assert_eq(ok, false, "immediate retake throttled")
    assert_true(near(wait, 0.5), "wait == 0.5 (1/rate at rate 2)")
    -- partial elapsed -> partial wait.
    local ok2, wait2 = b.take(0.25)
    assert_eq(ok2, false, "at +0.25s only 0.5 token accrued -> still throttled")
    assert_true(near(wait2, 0.25), "remaining wait == 0.25 after 0.25 elapsed")
    -- full token after exactly 1/rate.
    assert_eq(b.take(0.5), true, "take succeeds after exactly 1/rate elapsed")
end

-- =====================================================================
-- capacity>1 allows a burst of `capacity` then throttles (paced-pacing proof).
-- =====================================================================
do
    local b = tb.new({ rate = 1.0, capacity = 3, now0 = 0 })
    assert_eq(b.take(0), true, "burst take 1 of 3")
    assert_eq(b.take(0), true, "burst take 2 of 3")
    assert_eq(b.take(0), true, "burst take 3 of 3")
    local ok, wait = b.take(0)
    assert_eq(ok, false, "4th take in burst throttled (capacity exhausted)")
    assert_true(near(wait, 1.0), "wait == 1/rate after burst drains")
end

-- =====================================================================
-- capacity omitted defaults to 1.
-- =====================================================================
do
    local b = tb.new({ rate = 1.0, now0 = 0 })  -- no capacity
    assert_eq(b.take(0), true, "default-capacity take 1 ok")
    local ok = b.take(0)
    assert_eq(ok, false, "default capacity is 1: second immediate take throttled")
end

-- =====================================================================
-- rate <= 0 means UNLIMITED (rateLimit 0 disables pacing).
-- =====================================================================
do
    local b = tb.new({ rate = 0, capacity = 1, now0 = 0 })
    for i = 1, 5 do
        local ok, wait = b.take(0)
        assert_eq(ok, true, "unlimited bucket: take always true (#" .. i .. ")")
        assert_true(wait == nil or wait == 0, "unlimited bucket: no wait")
    end
    -- negative rate also unlimited.
    local b2 = tb.new({ rate = -3, capacity = 1, now0 = 0 })
    assert_eq(b2.take(0), true, "negative rate -> unlimited")
end

-- =====================================================================
-- Backwards clock never grants extra tokens (elapsed clamped >= 0).
-- =====================================================================
do
    local b = tb.new({ rate = 1.0, capacity = 1, now0 = 100 })
    assert_eq(b.take(100), true, "take at t=100")
    -- go BACKWARDS in time: must not refill.
    local ok, wait = b.take(50)
    assert_eq(ok, false, "backwards clock does not refill -> throttled")
    assert_true(near(wait, 1.0), "backwards clock: full wait remains")
    -- and a forward step still works from the latched lastNow=100.
    assert_eq(b.take(101), true, "forward +1s from latched now grants a token")
end

-- =====================================================================
-- BLOCKER C proof: TWO consecutive takes (preview identify + crop re-query) within one
-- worker body at capacity 1 require advancing the clock by 1/rate between them.
-- =====================================================================
do
    local rate = 4.0  -- 1/rate = 0.25s
    local b = tb.new({ rate = rate, capacity = 1, now0 = 0 })
    -- worker takes a token immediately before the PREVIEW identify call.
    assert_eq(b.take(0), true, "preview-identify take ok")
    -- worker then wants a token for the CROP re-query at the same instant -> throttled.
    local ok, wait = b.take(0)
    assert_eq(ok, false, "crop re-query take throttled at same instant (per-call cost)")
    assert_true(near(wait, 0.25), "crop wait == 1/rate (each provider call costs a token)")
    -- only after 1/rate does the crop re-query token become available.
    assert_eq(b.take(0.25), true, "crop re-query take succeeds after 1/rate elapsed")
end

-- =====================================================================
-- NaN guards: a NaN rate or NaN now must not corrupt state / must be safe.
-- =====================================================================
do
    local b = tb.new({ rate = 0/0, capacity = 1, now0 = 0 })  -- NaN rate -> treated unlimited (safe)
    assert_eq(b.take(0), true, "NaN rate treated as unlimited (always true, never blocks)")
    local b2 = tb.new({ rate = 1.0, capacity = 1, now0 = 0 })
    assert_eq(b2.take(0), true, "first take ok")
    -- a NaN now must not grant a spurious token nor crash.
    local ok = b2.take(0/0)
    assert_eq(ok, false, "NaN now does not grant a token (elapsed treated as 0)")
end
