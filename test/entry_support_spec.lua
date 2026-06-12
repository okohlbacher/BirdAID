-- test/entry_support_spec.lua (Wave-D D8 — shared entry-point scaffold)
--
-- Exercises BirdAID.lrdevplugin/src/lr/entry_support.lua. The module is glue (loaded by an entry),
-- but every Lr touch is via an INJECTED closure/dep, so its helpers are exercisable offline with
-- fakes: cancelled (guarded isCanceled), photoName (injected metadata reader), and flushWrite (the
-- shared batched-write fold, with a fake batcher + catalogWriter).
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local es = require('src.lr.entry_support')

assert_true(type(es) == 'table', "require 'src.lr.entry_support' resolves")
assert_true(type(es.cancelled) == 'function', "exposes cancelled")
assert_true(type(es.photoName) == 'function', "exposes photoName")
assert_true(type(es.flushWrite) == 'function', "exposes flushWrite")

-- ---- cancelled(progress): guarded read of progress:isCanceled() ----
do
    assert_eq(es.cancelled({ isCanceled = function() return true end }), true, "true when scope reports cancelled")
    assert_eq(es.cancelled({ isCanceled = function() return false end }), false, "false when not cancelled")
    -- a throwing isCanceled never crashes -> false.
    assert_eq(es.cancelled({ isCanceled = function() error("boom") end }), false, "throwing isCanceled -> false")
    -- a missing method (nil progress fields) -> false (the method-call pcall fails).
    assert_eq(es.cancelled({}), false, "missing isCanceled -> false")
end

-- ---- photoName(photo, metadataReader): best-effort name, never raises ----
do
    local reader = { formattedFileName = function(_) return "DSC_0001.NEF" end }
    assert_eq(es.photoName("photo", reader), "DSC_0001.NEF", "returns the formatted file name")
    -- a throwing reader degrades to the placeholder (never raises, never PII-leaks).
    local badReader = { formattedFileName = function(_) error("nope") end }
    assert_eq(es.photoName("photo", badReader), "(unknown file)", "throwing reader -> placeholder")
end

-- ---- flushWrite: builds applyFn with the PARAMETERIZED actionName, folds chunk statuses ----

-- A fake batcher whose flushAll calls applyFn ONCE per pre-programmed plan and returns the captured
-- statuses, recording every actionName the applyFn passed to catalogWriter.apply.
local function makeFakeBatcher(numChunks)
    return {
        flushAll = function(results, prefs, applyFn)
            local statuses = {}
            for _ = 1, numChunks do
                statuses[#statuses + 1] = applyFn({ entries = {} }, {})
            end
            return { statuses = statuses }
        end,
    }
end

-- A catalogWriter spy that returns a programmed status sequence and records the actionName arg.
local function makeWriter(statusSeq)
    local calls = { actions = {}, n = 0 }
    local w = {
        apply = function(catalog, plan, actionName, ctx, opts)
            calls.n = calls.n + 1
            calls.actions[#calls.actions + 1] = actionName
            return statusSeq[calls.n] or 'executed'
        end,
    }
    return w, calls
end

-- (a) single committed chunk -> writeResult is that committed status; actionName is forwarded.
do
    local writer, calls = makeWriter({ 'executed' })
    local out = es.flushWrite({
        catalogWriter = writer,
        catalog = {},
        batcher = makeFakeBatcher(1),
        results = {}, prefs = {},
        runId = "r-1",
        actionName = "BirdAID: write bird keywords",
        pcall = pcall,
    })
    assert_eq(out, 'executed', "single executed chunk -> writeResult 'executed'")
    assert_eq(calls.actions[1], "BirdAID: write bird keywords", "applyFn forwards the parameterized actionName")
end

-- (b) the " (deep)" actionName variant is forwarded verbatim (the ONLY per-entry difference).
do
    local writer, calls = makeWriter({ 'noop' })
    local out = es.flushWrite({
        catalogWriter = writer, catalog = {}, batcher = makeFakeBatcher(1),
        results = {}, prefs = {}, runId = "r-2",
        actionName = "BirdAID: write bird keywords (deep)",
        pcall = pcall,
    })
    assert_eq(out, 'noop', "noop chunk -> writeResult 'noop'")
    assert_eq(calls.actions[1], "BirdAID: write bird keywords (deep)", "deep actionName forwarded verbatim")
end

-- (c) multi-chunk fold: ANY 'error' chunk -> writeResult 'error' (and short-circuits).
do
    local writer = makeWriter({ 'executed', 'error', 'executed' })
    local out = es.flushWrite({
        catalogWriter = writer, catalog = {}, batcher = makeFakeBatcher(3),
        results = {}, prefs = {}, runId = "r-3",
        actionName = "BirdAID: write bird keywords",
        pcall = pcall,
    })
    assert_eq(out, 'error', "an errored chunk makes the whole writeResult 'error'")
end

-- (d) multi-chunk all-committed: writeResult is the LAST committed status.
do
    local writer = makeWriter({ 'executed', 'noop' })
    local out = es.flushWrite({
        catalogWriter = writer, catalog = {}, batcher = makeFakeBatcher(2),
        results = {}, prefs = {}, runId = "r-4",
        actionName = "BirdAID: write bird keywords",
        pcall = pcall,
    })
    assert_eq(out, 'noop', "no error -> writeResult is the LAST committed status")
end

-- (e) no chunks (empty statuses) -> default 'noop'.
do
    local writer = makeWriter({})
    local out = es.flushWrite({
        catalogWriter = writer, catalog = {}, batcher = makeFakeBatcher(0),
        results = {}, prefs = {}, runId = "r-5",
        actionName = "BirdAID: write bird keywords",
        pcall = pcall,
    })
    assert_eq(out, 'noop', "zero chunks -> default writeResult 'noop'")
end
