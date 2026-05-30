-- test/pool_spec.lua (09-01 Task 7, RISKIEST — PURE worker-pool dispatch state machine)
--
-- Exercises BirdAID.lrdevplugin/src/net/pool.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. The concurrency-safe dispatch/drain/cancel
-- LOGIC, extracted pure so cooperative overlap, throttle interaction, breaker-open-drain, and
-- cancel are testable offline.
--
-- BREAKER OWNERSHIP (CRITICAL): the pool NEVER calls breaker.record. It only READS
-- breaker.shouldStop() to decide whether to keep DISPATCHING. onResult accepts a per-item outcome
-- in {'identified','fatal','cancelled','deferred'} (the 'deferred' supports the worker's
-- AFTER-TOKEN pre-call gate, BLOCKER D) and marks the item terminal WITHOUT touching the breaker.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local pool = require('src.net.pool')

assert_true(type(pool) == 'table', "require 'src.net.pool' resolves")
assert_true(type(pool.new) == 'function', "pool exposes new")

-- a SPY breaker: shouldStop reads a latch; record increments a counter the tests assert stays 0.
local function spyBreaker()
    local s = { open = false, recordCount = 0 }
    s.shouldStop = function() return s.open end
    s.record = function() s.recordCount = s.recordCount + 1 end
    return s
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- =====================================================================
-- Serial equivalence (maxConcurrency=1): dispatch in order, one at a time.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b', 'c' }, maxConcurrency = 1, breaker = br })
    local order = {}
    -- drive the controller to completion, resolving each dispatch immediately as identified.
    local guard = 0
    while true do
        guard = guard + 1; if guard > 100 then break end
        local d = p.nextDispatch(0)
        if d.action == 'dispatch' then
            order[#order + 1] = d.key
            -- with maxConcurrency=1 only one may be in flight.
            assert_eq(p.state().inFlight, 1, "serial: exactly 1 in flight at a time")
            p.onResult(d.key, 'identified')
        elseif d.action == 'done' then
            break
        elseif d.action == 'idle' then
            -- shouldn't idle in pure serial drive here, but tolerate.
        end
    end
    assert_eq(#order, 3, "all three dispatched")
    assert_eq(order[1], 'a', "serial order a")
    assert_eq(order[2], 'b', "serial order b")
    assert_eq(order[3], 'c', "serial order c")
    assert_eq(br.recordCount, 0, "pool NEVER calls breaker.record (serial)")
    local ts = p.terminalStatus()
    assert_eq(ts.a, 'identified', "a identified")
    assert_eq(ts.b, 'identified', "b identified")
    assert_eq(ts.c, 'identified', "c identified")
end

-- =====================================================================
-- maxConcurrency=3 allows 3 concurrent then idles until a result frees a slot.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b', 'c', 'd' }, maxConcurrency = 3, breaker = br })
    local d1 = p.nextDispatch(0); assert_eq(d1.action, 'dispatch', "dispatch 1")
    local d2 = p.nextDispatch(0); assert_eq(d2.action, 'dispatch', "dispatch 2")
    local d3 = p.nextDispatch(0); assert_eq(d3.action, 'dispatch', "dispatch 3")
    assert_eq(p.state().inFlight, 3, "3 in flight")
    -- 4th: no free slot -> idle (items remain in flight).
    local d4 = p.nextDispatch(0); assert_eq(d4.action, 'idle', "4th dispatch idles (slots full)")
    -- free a slot.
    p.onResult(d1.key, 'identified')
    assert_eq(p.state().inFlight, 2, "one freed")
    local d5 = p.nextDispatch(0); assert_eq(d5.action, 'dispatch', "slot freed -> 4th dispatches")
    assert_eq(d5.key, 'd', "the 4th item dispatches")
    p.onResult(d2.key, 'identified'); p.onResult(d3.key, 'identified'); p.onResult(d5.key, 'identified')
    assert_eq(p.nextDispatch(0).action, 'done', "all terminal -> done")
    assert_eq(br.recordCount, 0, "pool NEVER calls breaker.record (concurrent)")
end

-- =====================================================================
-- The pool NEVER records into the breaker even across mixed OK/FATAL/DEFERRED interleavings,
-- and once shouldStop latches no NEW dispatch occurs.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b', 'c', 'd', 'e' }, maxConcurrency = 2, breaker = br })
    local da = p.nextDispatch(0); local db = p.nextDispatch(0)
    assert_eq(da.action, 'dispatch', "a dispatched"); assert_eq(db.action, 'dispatch', "b dispatched")
    -- mixed outcomes (the provider would have recorded into the breaker; the POOL does not).
    p.onResult(da.key, 'identified')
    p.onResult(db.key, 'fatal')
    -- model the provider's breaker tripping AFTER its threshold: flip the spy latch.
    br.open = true
    -- now no NEW dispatch occurs; the undispatched remainder becomes 'deferred'; drains to done.
    local d = p.nextDispatch(0)
    assert_eq(d.action, 'done', "breaker open + nothing in flight -> done")
    local ts = p.terminalStatus()
    assert_eq(ts.a, 'identified', "a identified")
    assert_eq(ts.b, 'fatal', "b fatal (pool classifies, does not record)")
    assert_eq(ts.c, 'deferred', "c undispatched-after-latch -> deferred")
    assert_eq(ts.d, 'deferred', "d deferred")
    assert_eq(ts.e, 'deferred', "e deferred")
    assert_eq(br.recordCount, 0, "POOL NEVER recorded into the breaker (mixed interleavings)")
    assert_eq(count(ts), 5, "terminalStatus covers every item exactly once")
end

-- =====================================================================
-- A 'deferred' onResult outcome (the worker's AFTER-TOKEN pre-call gate found the breaker OPEN)
-- marks the item terminal-deferred (NOT identified). breaker-open-AFTER-dispatch case.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b' }, maxConcurrency = 1, breaker = br })
    local da = p.nextDispatch(0)
    assert_eq(da.action, 'dispatch', "a dispatched while breaker CLOSED")
    -- the worker takes a token, then re-checks shouldStop -> finds it OPEN (latched during the
    -- token wait) -> skips the provider and reports 'deferred'.
    br.open = true
    p.onResult(da.key, 'deferred')
    assert_eq(p.terminalStatus().a, 'deferred',
        "an anchor reported 'deferred' via the after-token gate is terminal-deferred, NOT identified")
    -- and no new dispatch now that the breaker is open.
    assert_eq(p.nextDispatch(0).action, 'done', "breaker open -> remainder deferred + done")
    assert_eq(p.terminalStatus().b, 'deferred', "b (undispatched, breaker open) -> deferred")
    assert_eq(br.recordCount, 0, "pool did not record")
end

-- =====================================================================
-- MID-RUN LATCH DURING A TOKEN WAIT (BLOCKER D ordering). Model the worker's after-token gate:
-- the dispatched anchor would WAIT for a token; flip the breaker OPEN while it is mid-wait; the
-- worker reports onResult(key,'deferred') at its after-token pre-call gate. Assert that anchor is
-- terminal-'deferred' (NEVER 'identified', even though the provider would have returned a valid
-- degrade), and its undispatched cluster-mates defer too.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'anchor', 'sibling' }, maxConcurrency = 1, breaker = br })
    local d = p.nextDispatch(0)
    assert_eq(d.action, 'dispatch', "anchor dispatched while breaker closed")
    -- (a token wait is modelled in the worker glue; here the pure controller just learns the
    -- worker's verdict.) The breaker latches DURING the wait:
    br.open = true
    -- the worker's after-token pre-call gate sees shouldStop()==true and defers:
    p.onResult('anchor', 'deferred')
    assert_eq(p.terminalStatus().anchor, 'deferred',
        "latch-during-token-wait -> anchor deferred (NEVER identified)")
    -- the rest is not dispatched (breaker open) -> deferred; drains to done.
    assert_eq(p.nextDispatch(0).action, 'done', "breaker open -> done")
    assert_eq(p.terminalStatus().sibling, 'deferred', "undispatched sibling -> deferred")
    assert_eq(br.recordCount, 0, "pool never recorded during the token-wait latch scenario")
end

-- =====================================================================
-- Breaker-open-at-DISPATCH mid-run: undispatched remainder deferred + drains.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b', 'c' }, maxConcurrency = 1, breaker = br })
    local da = p.nextDispatch(0); assert_eq(da.action, 'dispatch', "a dispatched")
    p.onResult('a', 'identified')
    -- now the breaker latches before b is dispatched.
    br.open = true
    assert_eq(p.nextDispatch(0).action, 'done', "no new dispatch when breaker open -> done")
    local ts = p.terminalStatus()
    assert_eq(ts.a, 'identified', "a identified before latch")
    assert_eq(ts.b, 'deferred', "b deferred (breaker open at dispatch)")
    assert_eq(ts.c, 'deferred', "c deferred")
end

-- =====================================================================
-- Cancel mid-run: remainder cancelled + drains.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b', 'c' }, maxConcurrency = 2, breaker = br })
    local da = p.nextDispatch(0); local db = p.nextDispatch(0)
    p.cancel()
    -- in-flight a,b still resolve; no new dispatch; c becomes cancelled.
    assert_eq(p.nextDispatch(0).action, 'idle', "cancel: in-flight remain -> idle (drain)")
    p.onResult(da.key, 'identified')
    p.onResult(db.key, 'identified')
    assert_eq(p.nextDispatch(0).action, 'done', "drained -> done")
    local ts = p.terminalStatus()
    assert_eq(ts.a, 'identified', "a resolved before cancel-drain")
    assert_eq(ts.c, 'cancelled', "undispatched c -> cancelled")
end

-- =====================================================================
-- terminalStatus covers every item exactly once; state() counts reconcile.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = { 'a', 'b', 'c' }, maxConcurrency = 3, breaker = br })
    local da = p.nextDispatch(0); local db = p.nextDispatch(0); local dc = p.nextDispatch(0)
    p.onResult('a', 'identified'); p.onResult('b', 'fatal'); p.onResult('c', 'deferred')
    assert_eq(p.nextDispatch(0).action, 'done', "all resolved -> done")
    local ts = p.terminalStatus()
    assert_eq(count(ts), 3, "every item present exactly once")
    local st = p.state()
    assert_eq(st.inFlight, 0, "nothing in flight at end")
    assert_eq(st.completed, 3, "completed counts all resolved")
    assert_eq(st.breakerOpen, false, "breakerOpen reflects shouldStop")
end

-- =====================================================================
-- Empty items -> immediately done; terminalStatus empty.
-- =====================================================================
do
    local br = spyBreaker()
    local p = pool.new({ items = {}, maxConcurrency = 2, breaker = br })
    assert_eq(p.nextDispatch(0).action, 'done', "no items -> done immediately")
    assert_eq(count(p.terminalStatus()), 0, "no terminal entries")
end
