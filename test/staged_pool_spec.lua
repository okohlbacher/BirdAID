-- test/staged_pool_spec.lua (Phase 9 — BL-06 preview-decoupling fix)
--
-- Drives src.lr.staged_pool with an injected FAKE cooperative scheduler (spawn defers the consumer
-- fn; sleep runs the oldest pending consumer; yield is a no-op) so the producer/consumer STATUS +
-- SEQUENCING contract is asserted offline. (True wall-clock concurrency/backpressure timing is
-- verified live in Lightroom — Task 12 — like the other src/lr/ glue.) The module loads offline
-- because its `import 'LrTasks'` is guarded; we inject spawn/sleep/yield.
--
-- Asserts:
--   * fetchJob success -> the consumer's status; response stored ONLY for 'identified'.
--   * fetchJob nil (preview timeout/fail) -> 'error', and identifyJob is NEVER called for it.
--   * a THROWING identifyJob -> 'fatal' (caught), and the drain still completes (no hang).
--   * cancel mid-run -> the remaining undispatched anchors come back 'cancelled'.
--   * breaker open mid-run -> the remaining undispatched anchors come back 'deferred'.
--   * EVERY item resolves exactly once with a defined status.
--
-- Loaded by test/run.lua via dofile; uses assert_eq / assert_true. Lua 5.1 common subset.

package.path = package.path .. ";./?.lua"

local staged = require('src.lr.staged_pool')

-- A fake cooperative scheduler: spawn() queues the consumer; sleep() runs the oldest queued
-- consumer (this is how the producer's backpressure wait + final drain make progress); yield()
-- is a no-op so dispatched consumers accumulate (modelling in-flight) until a sleep drains them.
local function newSched()
    local pending = {}
    return {
        spawn = function(fn) pending[#pending + 1] = fn end,
        sleep = function() if #pending > 0 then local f = table.remove(pending, 1); f() end end,
        yield = function() end,
    }
end

local function keysResolved(out, items)
    local n = 0
    for _ in pairs(out.statusByAnchorKey) do n = n + 1 end
    if n ~= #items then return false end
    for i = 1, #items do
        if out.statusByAnchorKey[items[i]] == nil then return false end
    end
    return true
end

-- (1) all identified; response stored only for identified; every item resolved once.
do
    local s = newSched()
    local idCalls = 0
    local out = staged.run({
        items = { 'a', 'b', 'c' },
        maxConcurrency = 2,
        fetchJob = function(k) return { key = k } end,
        identifyJob = function(job) idCalls = idCalls + 1; return 'identified', { who = job.key } end,
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
    })
    assert_eq(out.statusByAnchorKey.a, 'identified', "staged: a identified")
    assert_eq(out.statusByAnchorKey.b, 'identified', "staged: b identified")
    assert_eq(out.statusByAnchorKey.c, 'identified', "staged: c identified")
    assert_eq(idCalls, 3, "staged: identifyJob called once per fetched anchor")
    assert_eq(out.responseByAnchorKey.a.who, 'a', "staged: response stored for identified a")
    assert_eq(out.responseByAnchorKey.c.who, 'c', "staged: response stored for identified c")
    assert_true(keysResolved(out, { 'a', 'b', 'c' }), "staged: every item resolved exactly once")
end

-- (1b) BL-12: progress reports BOTH portionComplete AND an "X of Y" caption, reaching the
--      final total once every anchor resolves.
do
    local s = newSched()
    local portions, captions = {}, {}
    local fakeProgress = {
        setPortionComplete = function(_, done, tot) portions[#portions + 1] = { done, tot } end,
        setCaption = function(_, text) captions[#captions + 1] = text end,
    }
    local out = staged.run({
        items = { 'a', 'b', 'c' },
        maxConcurrency = 2,
        fetchJob = function(k) return { key = k } end,
        identifyJob = function() return 'identified', {} end,
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
        progress = fakeProgress,
    })
    assert_true(keysResolved(out, { 'a', 'b', 'c' }), "BL-12: all resolved")
    assert_true(#captions > 0, "BL-12: a caption was set")
    assert_eq(captions[#captions], "Processed 3 of 3", "BL-12: final caption is X-of-Y at total")
    assert_eq(portions[#portions][1], 3, "BL-12: final portionComplete done == total")
    assert_eq(portions[#portions][2], 3, "BL-12: final portionComplete total == 3")
    -- peakConcurrency is observed and bounded by maxConcurrency (2 here).
    assert_eq(out.peakConcurrency, 2, "peakConcurrency: reaches and is bounded by maxConcurrency")
end

-- (2) a preview-fetch failure (fetchJob nil) -> 'error'; identifyJob NEVER called for it.
do
    local s = newSched()
    local identifiedKeys = {}
    local out = staged.run({
        items = { 'a', 'b', 'c' },
        maxConcurrency = 3,
        fetchJob = function(k) if k == 'b' then return nil, 'timeout' end; return { key = k } end,
        identifyJob = function(job) identifiedKeys[job.key] = true; return 'identified', {} end,
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
    })
    assert_eq(out.statusByAnchorKey.b, 'error', "staged: preview-fail anchor -> 'error'")
    assert_eq(identifiedKeys.b, nil, "staged: identifyJob NOT called for the preview-fail anchor")
    assert_eq(out.statusByAnchorKey.a, 'identified', "staged: a still identified")
    assert_eq(out.responseByAnchorKey.b, nil, "staged: no response for the errored anchor")
end

-- (3) a THROWING identifyJob -> 'fatal' (caught by the protector); drain completes (no hang).
do
    local s = newSched()
    local out = staged.run({
        items = { 'a' },
        maxConcurrency = 1,
        fetchJob = function(k) return { key = k } end,
        identifyJob = function() error("boom") end,
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
    })
    assert_eq(out.statusByAnchorKey.a, 'fatal', "staged: throwing identifyJob -> 'fatal' (no hang)")
    assert_eq(out.responseByAnchorKey.a, nil, "staged: no response on fatal")
end

-- (4) cancel mid-run -> remaining undispatched anchors 'cancelled'. isCanceled flips true after the
-- first preview fetch, so 'a' dispatches+identifies and b,c are marked cancelled (never fetched).
do
    local s = newSched()
    local fetched = 0
    local fetchedKeys = {}
    local out = staged.run({
        items = { 'a', 'b', 'c' },
        maxConcurrency = 5,
        fetchJob = function(k) fetched = fetched + 1; fetchedKeys[k] = true; return { key = k } end,
        identifyJob = function() return 'identified', {} end,
        isCanceled = function() return fetched >= 1 end,
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
    })
    assert_eq(out.statusByAnchorKey.a, 'identified', "staged: a identified before cancel")
    assert_eq(out.statusByAnchorKey.b, 'cancelled', "staged: b cancelled (undispatched)")
    assert_eq(out.statusByAnchorKey.c, 'cancelled', "staged: c cancelled (undispatched)")
    assert_eq(fetchedKeys.b, nil, "staged: cancelled anchors are never preview-fetched")
end

-- (5) breaker open mid-run -> remaining undispatched anchors 'deferred'.
do
    local s = newSched()
    local fetched = 0
    local out = staged.run({
        items = { 'a', 'b', 'c' },
        maxConcurrency = 5,
        fetchJob = function(k) fetched = fetched + 1; return { key = k } end,
        identifyJob = function() return 'identified', {} end,
        breaker = { shouldStop = function() return fetched >= 1 end },
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
    })
    assert_eq(out.statusByAnchorKey.a, 'identified', "staged: a identified before breaker")
    assert_eq(out.statusByAnchorKey.b, 'deferred', "staged: b deferred (breaker open)")
    assert_eq(out.statusByAnchorKey.c, 'deferred', "staged: c deferred (breaker open)")
end

-- (6) consumer status passthrough: a 'deferred' from identifyJob (gate refused) is preserved.
do
    local s = newSched()
    local out = staged.run({
        items = { 'a' },
        maxConcurrency = 1,
        fetchJob = function(k) return { key = k } end,
        identifyJob = function() return 'deferred' end,
        spawn = s.spawn, sleep = s.sleep, yield = s.yield,
    })
    assert_eq(out.statusByAnchorKey.a, 'deferred', "staged: consumer 'deferred' status preserved")
end
