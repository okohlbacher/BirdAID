-- test/worker_gate_spec.lua (Wave-2 R2 — REAL unit tests for the PURE per-provider-call gate)
--
-- Exercises BirdAID.lrdevplugin/src/net/worker_gate.lua: the per-PROVIDER-CALL decision logic
-- extracted PURE from the worker_pool.lua glue so the ACTUAL gate sequence is the thing under test
-- (no manual model). The gate performs EXACTLY: acquire a token (sleeping via the injected sleep
-- while denied) -> re-check isCanceled (true => 'cancelled', identify NOT called) -> re-check
-- breaker.shouldStop (true => 'deferred', identify NOT called) -> else identify (BLOCKER C + B + D).
--
-- EVERYTHING is injected (bucket, now, sleep, isCanceled, breaker, identify) so the suite is
-- deterministic and runs under stock lua / luajit. The KEY regression these tests catch: deleting
-- the after-token cancel or breaker re-check. Because the injected `sleep` flips cancel/breaker
-- DURING the token wait, a gate that checked cancel/breaker only BEFORE the token (or not at all
-- after the wait) would wrongly call identify — and the call-count assertions would FAIL.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local gate = require('src.net.worker_gate')
local token_bucket = require('src.net.token_bucket')

assert_true(type(gate) == 'table', "require 'src.net.worker_gate' resolves")
assert_true(type(gate.gate) == 'function', "worker_gate exposes gate")

-- a SPY breaker: shouldStop reads a latch; record increments a counter the tests assert stays 0.
local function spyBreaker()
    local s = { open = false, recordCount = 0 }
    s.shouldStop = function() return s.open end
    s.record = function() s.recordCount = s.recordCount + 1 end
    return s
end

-- a deterministic injected clock that the injected sleep advances. now() reads it; advance(d) bumps.
local function fakeClock(start)
    local c = { t = start or 0 }
    c.now = function() return c.t end
    c.advance = function(d) c.t = c.t + (tonumber(d) or 0) end
    return c
end

-- a counting identify: records call count + the item it was called with; returns a configured value.
local function spyIdentify(response, err)
    local s = { calls = 0, lastItem = nil }
    s.fn = function(item)
        s.calls = s.calls + 1
        s.lastItem = item
        return response, err
    end
    return s
end

-- =====================================================================
-- HAPPY PATH: token immediately available, not cancelled, breaker closed -> identify called ONCE,
-- 'identified' with the response; the response is the provider's value; identify saw the item.
-- =====================================================================
do
    local br = spyBreaker()
    local clk = fakeClock(0)
    local bucket = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })  -- starts FULL (1 token).
    local idf = spyIdentify({ ok = true, name = 'cardinal' }, nil)
    local napped = 0

    local status, response, err = gate.gate({
        item       = 'anchor',
        bucket     = bucket,
        now        = clk.now,
        sleep      = function(secs) napped = napped + 1; clk.advance(secs) end,
        isCanceled = function() return false end,
        breaker    = br,
        identify   = idf.fn,
    })

    assert_eq(status, 'identified', "happy path -> identified")
    assert_true(response ~= nil and response.name == 'cardinal', "identified carries the provider response")
    assert_eq(err, nil, "identified carries no error")
    assert_eq(idf.calls, 1, "happy path: identify called exactly ONCE")
    assert_eq(idf.lastItem, 'anchor', "identify received the item")
    assert_eq(napped, 0, "token available immediately -> no sleep")
    assert_eq(br.recordCount, 0, "gate NEVER records into the breaker (happy path)")
end

-- =====================================================================
-- CANCEL-DURING-TOKEN-WAIT: the bucket is EMPTY (a prior take drained it), so the gate must sleep
-- in the token wait. The injected sleep advances the clock AND flips isCanceled true MID-WAIT. After
-- the wait the gate's AFTER-TOKEN cancel gate sees cancel and returns 'cancelled' WITHOUT calling
-- identify. (A gate that only checked cancel BEFORE the token wait, or not after it, would wrongly
-- call identify here -> idf.calls would be 1 -> assertion FAILS. This catches the regression.)
-- =====================================================================
do
    local br = spyBreaker()
    local clk = fakeClock(0)
    -- capacity 1, rate 1: starts FULL. Drain the one token so the gate must wait for a refill.
    local bucket = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })
    assert_true(bucket.take(0) == true, "precondition: drain the starting token")

    local idf = spyIdentify({ ok = true }, nil)
    local cancelled = false
    local naps = 0

    local status, response, err = gate.gate({
        item   = 'anchor',
        bucket = bucket,
        now    = clk.now,
        -- sleep advances the clock (so the next take eventually grants) AND flips cancel mid-wait.
        sleep  = function(secs) naps = naps + 1; clk.advance(secs); cancelled = true end,
        isCanceled = function() return cancelled end,
        breaker    = br,
        identify   = idf.fn,
    })

    assert_true(naps >= 1, "cancel-during-wait: the gate actually slept in the token wait")
    assert_eq(status, 'cancelled', "cancel observed AFTER the token wait -> 'cancelled'")
    assert_eq(idf.calls, 0, "cancel-after-token: identify was NEVER called (call-count 0)")
    assert_eq(response, nil, "cancelled carries no response")
    assert_eq(err, nil, "cancelled carries no error")
    assert_eq(br.recordCount, 0, "gate NEVER records into the breaker (cancel path)")
end

-- =====================================================================
-- BREAKER-OPEN-DURING-TOKEN-WAIT: bucket empty -> gate sleeps; the injected sleep flips the breaker
-- OPEN mid-wait. After the wait the after-token breaker gate sees shouldStop()==true and returns
-- 'deferred' WITHOUT calling identify. (NOT cancelled — cancel stays false here.)
-- =====================================================================
do
    local br = spyBreaker()
    local clk = fakeClock(0)
    local bucket = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })
    assert_true(bucket.take(0) == true, "precondition: drain the starting token")

    local idf = spyIdentify({ ok = true }, nil)
    local naps = 0

    local status, response, err = gate.gate({
        item   = 'anchor',
        bucket = bucket,
        now    = clk.now,
        sleep  = function(secs) naps = naps + 1; clk.advance(secs); br.open = true end,
        isCanceled = function() return false end,
        breaker    = br,
        identify   = idf.fn,
    })

    assert_true(naps >= 1, "breaker-during-wait: the gate actually slept in the token wait")
    assert_eq(status, 'deferred', "breaker open AFTER the token wait -> 'deferred'")
    assert_eq(idf.calls, 0, "breaker-after-token: identify was NEVER called (call-count 0)")
    assert_eq(response, nil, "deferred carries no response")
    assert_eq(err, nil, "deferred carries no error")
    assert_eq(br.recordCount, 0, "gate NEVER records into the breaker (deferred path)")
end

-- =====================================================================
-- BOTH CANCEL + BREAKER OPEN: cancel is checked FIRST, so cancel WINS -> 'cancelled' (NOT
-- 'deferred'), identify NOT called. Proves the ordering (isCanceled? -> ...) precedes (shouldStop?).
-- =====================================================================
do
    local br = spyBreaker()
    br.open = true                                  -- breaker already open.
    local clk = fakeClock(0)
    local bucket = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })  -- token available now.
    local idf = spyIdentify({ ok = true }, nil)

    local status, response, err = gate.gate({
        item   = 'anchor',
        bucket = bucket,
        now    = clk.now,
        sleep  = function(secs) clk.advance(secs) end,
        isCanceled = function() return true end,    -- cancel ALSO set.
        breaker    = br,
        identify   = idf.fn,
    })

    assert_eq(status, 'cancelled', "cancel + breaker both open -> cancel WINS (checked first)")
    assert_eq(idf.calls, 0, "both gates open: identify NEVER called")
    assert_eq(response, nil, "cancelled carries no response (both-open case)")
    assert_eq(err, nil, "cancelled carries no error (both-open case)")
end

-- =====================================================================
-- IDENTIFY RETURNS (nil, err) -> 'fatal' with the error string; identify was reached (call-count 1).
-- =====================================================================
do
    local br = spyBreaker()
    local clk = fakeClock(0)
    local bucket = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })
    local idf = spyIdentify(nil, 'http-500')

    local status, response, err = gate.gate({
        item   = 'anchor',
        bucket = bucket,
        now    = clk.now,
        sleep  = function(secs) clk.advance(secs) end,
        isCanceled = function() return false end,
        breaker    = br,
        identify   = idf.fn,
    })

    assert_eq(status, 'fatal', "identify (nil,err) -> 'fatal'")
    assert_eq(idf.calls, 1, "fatal path: identify WAS reached (gate passed the cancel+breaker gates)")
    assert_eq(response, nil, "fatal carries no response")
    assert_eq(err, 'http-500', "fatal carries the provider error string")
end

-- =====================================================================
-- PER-CALL SEMANTICS: two SEQUENTIAL gate calls (a preview identify + a crop re-query) each TAKE a
-- token. With capacity=1 + rate large enough that the clock advance between calls refills exactly
-- one token, the SHARED bucket is consumed TWICE (once per provider call) — proving the per-PROVIDER-
-- CALL token cost (BLOCKER C), NOT a per-queue-pull cost. We assert by counting bucket.take grants.
-- =====================================================================
do
    local br = spyBreaker()
    local clk = fakeClock(0)
    -- Wrap a real bucket to COUNT grants (consumed tokens) the gate takes.
    local real = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })  -- starts with 1 token.
    local grants = 0
    local countingBucket = {
        take = function(now)
            local ok, wait = real.take(now)
            if ok then grants = grants + 1 end
            return ok, wait
        end,
    }
    local idf = spyIdentify({ ok = true }, nil)
    local sleepFn = function(secs) clk.advance(secs) end

    -- Call 1 (preview identify): the starting token is granted immediately -> 1 grant.
    local s1 = gate.gate({
        item = 'anchor', bucket = countingBucket, now = clk.now, sleep = sleepFn,
        isCanceled = function() return false end, breaker = br, identify = idf.fn,
    })
    assert_eq(s1, 'identified', "per-call: first (preview) gate identifies")
    assert_eq(grants, 1, "per-call: the FIRST provider call consumed exactly one token")

    -- Call 2 (crop re-query) on the SAME bucket: the bucket is now empty, so the gate sleeps; the
    -- injected sleep advances the clock, the next take refills one token and grants it -> 2nd grant.
    local s2 = gate.gate({
        item = 'anchor', bucket = countingBucket, now = clk.now, sleep = sleepFn,
        isCanceled = function() return false end, breaker = br, identify = idf.fn,
    })
    assert_eq(s2, 'identified', "per-call: second (crop re-query) gate identifies")
    assert_eq(grants, 2, "per-call: the SECOND provider call ALSO consumed a token (bucket twice)")
    assert_eq(idf.calls, 2, "per-call: identify ran once per provider call (two calls)")
end

-- =====================================================================
-- UNLIMITED BUCKET (nil): no token cost, no sleep, straight to the gates -> identify once.
-- =====================================================================
do
    local br = spyBreaker()
    local idf = spyIdentify({ ok = true }, nil)
    local napped = 0

    local status = gate.gate({
        item   = 'anchor',
        bucket = nil,                                   -- nil bucket -> unlimited.
        now    = function() return 0 end,
        sleep  = function() napped = napped + 1 end,
        isCanceled = function() return false end,
        breaker    = br,
        identify   = idf.fn,
    })

    assert_eq(status, 'identified', "nil bucket (unlimited) -> identifies")
    assert_eq(napped, 0, "unlimited bucket never sleeps for a token")
    assert_eq(idf.calls, 1, "unlimited bucket: identify called once")
end

-- =====================================================================
-- ROBUSTNESS: a throwing isCanceled / breaker.shouldStop must NOT crash the gate; they default to
-- the SAFE value (not cancelled / not stopping), so a closed-breaker happy path still identifies.
-- =====================================================================
do
    local clk = fakeClock(0)
    local bucket = token_bucket.new({ rate = 1, capacity = 1, now0 = 0 })
    local idf = spyIdentify({ ok = true }, nil)

    local status = gate.gate({
        item   = 'anchor',
        bucket = bucket,
        now    = clk.now,
        sleep  = function(secs) clk.advance(secs) end,
        isCanceled = function() error('boom') end,         -- throws -> treated as NOT cancelled.
        breaker    = { shouldStop = function() error('boom') end },  -- throws -> NOT stopping.
        identify   = idf.fn,
    })

    assert_eq(status, 'identified', "throwing cancel/breaker predicates default safe -> identifies")
    assert_eq(idf.calls, 1, "robust gate still reached identify once")
end
