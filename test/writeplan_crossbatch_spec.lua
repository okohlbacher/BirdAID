-- test/writeplan_crossbatch_spec.lua (Phase 12 — WBATCH-02: cross-batch cumulative add-only diff)
--
-- Exercises BirdAID.lrdevplugin/src/batcher.lua M.flushAll(results, prefs, applyFn) — the PURE
-- cumulative-diff flush coordinator that threads an already-written set forward across batches
-- through the UNCHANGED writeplan.planReport + an INJECTED apply spy. Covers the riskiest WBATCH-02
-- invariants:
--   (1) HAPPY-PATH: a name COMMITTED in batch 1 ('executed') yields ZERO plan entries for the same
--       photoKey in batch 2 (cross-batch add-only idempotency).
--   (2) CODEX HIGH-1 — a batch-1 NON-committed status ('error' / 'aborted' / 'queued') does NOT fold
--       its names forward, so batch 2 STILL contains them (a failed/aborted/deferred batch can never
--       silently suppress its own keywords; a retry re-attempts them).
--   (3) DRY-RUN never folds (a dry run suppresses nothing from a later real flush).
--   (4) within-batch BL-15: a clustered name repeated across records WITHIN one batch appears once.
--   (5) DEFAULT-SAFE: writeBatchSize=0 yields a single plan equal to a direct writeplan.planReport.
--
-- Loaded by test/run.lua via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local batcher = require('src.batcher')
local writeplan = require('src.writeplan')

assert_true(type(batcher) == 'table', "require 'src.batcher' resolves")
assert_true(type(batcher.flushAll) == 'function', "exposes flushAll")

-- ---- helpers ---------------------------------------------------------------

-- A capturing apply spy that returns a programmable status string (per call, falling back to a
-- default). Records every (plan, report) it was handed so we can assert call count + per-chunk
-- contents AFTER the run.
local function makeSpy(statusSeq, default)
    statusSeq = statusSeq or {}
    local spy = { calls = {}, plans = {} }
    spy.fn = function(plan, report)
        spy.calls[#spy.calls + 1] = { plan = plan, report = report }
        spy.plans[#spy.plans + 1] = plan
        local status = statusSeq[#spy.calls] or default or 'executed'
        return status
    end
    return spy
end

-- Build a per-photo result record carrying ONE detection that renders to a confident species
-- keyword "Northern Cardinal (Cardinalis cardinalis)". existingNames starts empty.
local function recFor(photoKey)
    return {
        photoKey = photoKey,
        photo = nil,
        response = {
            bird_present = true,
            detections = {
                {
                    bbox = { 0.1, 0.1, 0.9, 0.9 },
                    common_name = "Northern Cardinal",
                    scientific_name = "Cardinalis cardinalis",
                    confidence = 0.95,
                    identified_rank = "species",
                },
            },
        },
        error = nil,
        existingNames = {},
    }
end

local CARDINAL = "Northern Cardinal (Cardinalis cardinalis)"

-- recCased(photoKey, common, scientific): same shape as recFor but with caller-chosen names,
-- used by the A1 cross-batch normalization case (a name committed in batch 1 must not be
-- re-added in batch 2 even when batch 2 renders a different ASCII case).
local function recCased(photoKey, common, scientific)
    return {
        photoKey = photoKey,
        photo = nil,
        response = {
            bird_present = true,
            detections = {
                {
                    bbox = { 0.1, 0.1, 0.9, 0.9 },
                    common_name = common,
                    scientific_name = scientific,
                    confidence = 0.95,
                    identified_rank = "species",
                },
            },
        },
        error = nil,
        existingNames = {},
    }
end

-- Count how many addKeywords entries a plan has for a given photoKey (across its entries).
local function addsForKey(plan, key)
    local count = 0
    for _, e in ipairs(plan.entries) do
        if e.photoKey == key then count = count + #e.addKeywords end
    end
    return count
end

-- =====================================================================
-- (1) HAPPY-PATH cross-batch: same photoKey in TWO single-record batches (batchSize=1), same kept
--     name in both; spy returns 'executed'. batch 1 contains the name; batch 2 contains ZERO.
-- =====================================================================
do
    local results = { recFor("p1"), recFor("p1") }   -- two records, SAME photoKey
    local spy = makeSpy({ 'executed', 'executed' })
    local prefs = { writeBatchSize = 1, confidenceThreshold = 0.6 }

    local out = batcher.flushAll(results, prefs, spy.fn)
    assert_eq(out.applyCount, 2, "two single-record chunks ⇒ apply fired twice")
    assert_eq(#spy.calls, 2, "spy called once per chunk")

    assert_eq(addsForKey(spy.plans[1], "p1"), 1, "batch 1 plan contains the cardinal name")
    assert_true(spy.plans[1].entries[1] ~= nil, "batch 1 has an entry")
    assert_eq(spy.plans[1].entries[1].addKeywords[1], CARDINAL, "batch 1 adds the cardinal")

    assert_eq(addsForKey(spy.plans[2], "p1"), 0,
        "batch 2 has ZERO adds for p1 (committed batch-1 name folded forward)")
    assert_eq(#spy.plans[2].entries, 0, "batch 2 plan has no entries (nothing to write)")
end

-- =====================================================================
-- (1b) D4 / M1 — NO CALLER MUTATION: after a cross-batch fold, the caller's ORIGINAL record and its
--      existingNames table are untouched (flushAll hands writeplan a shallow clone, never reassigns
--      rec.existingNames in place). The record identity and its existingNames identity/contents must
--      be exactly as the caller supplied them.
-- =====================================================================
do
    local rec1 = recFor("p1")
    local rec2 = recFor("p1")            -- SAME photoKey ⇒ batch 2 would fold batch 1's name
    local origExisting2 = rec2.existingNames
    local results = { rec1, rec2 }
    local spy = makeSpy({ 'executed', 'executed' })
    local prefs = { writeBatchSize = 1, confidenceThreshold = 0.6 }

    batcher.flushAll(results, prefs, spy.fn)

    -- The caller's record table identities are preserved (not swapped out).
    assert_true(results[2] == rec2, "caller's record-2 identity is preserved")
    -- existingNames table identity is unchanged (NOT reassigned to the merged clone in place).
    assert_true(rec2.existingNames == origExisting2,
        "caller's record-2 existingNames table identity is unchanged (no in-place reassign)")
    -- And its CONTENTS were not folded into (the merged cardinal name lives only on the clone).
    assert_true(rec2.existingNames[CARDINAL] == nil,
        "caller's record-2 existingNames was NOT mutated with the folded-forward name")
    assert_true(next(rec2.existingNames) == nil, "caller's record-2 existingNames stays empty")
end

-- =====================================================================
-- (2) CODEX HIGH-1: a NON-committed batch-1 status does NOT fold. Test 'error', 'aborted', 'queued'.
--     batch 2 STILL contains batch-1's name in each case.
-- =====================================================================
do
    local function nonCommittedCase(badStatus)
        local results = { recFor("p1"), recFor("p1") }
        local spy = makeSpy({ badStatus, 'executed' })
        local prefs = { writeBatchSize = 1, confidenceThreshold = 0.6 }

        local out = batcher.flushAll(results, prefs, spy.fn)
        assert_eq(out.applyCount, 2, badStatus .. ": apply fired twice")
        assert_eq(addsForKey(spy.plans[1], "p1"), 1, badStatus .. ": batch 1 still proposes the name")
        assert_eq(addsForKey(spy.plans[2], "p1"), 1,
            badStatus .. ": batch 2 STILL contains the name (non-committed batch-1 NOT folded)")
    end

    nonCommittedCase('error')
    nonCommittedCase('aborted')
    nonCommittedCase('queued')
end

-- =====================================================================
-- (3) DRY-RUN never folds: prefs.dryRun=true; even though the spy returns 'executed', batch 2 still
--     contains the name (a dry run must not suppress a later real flush).
-- =====================================================================
do
    local results = { recFor("p1"), recFor("p1") }
    local spy = makeSpy({ 'executed', 'executed' })
    local prefs = { writeBatchSize = 1, confidenceThreshold = 0.6, dryRun = true }

    local out = batcher.flushAll(results, prefs, spy.fn)
    assert_eq(out.applyCount, 2, "dry-run: apply fired twice")
    assert_true(spy.calls[1].report.dryRun == true, "dry-run flag reached the report")
    assert_eq(addsForKey(spy.plans[1], "p1"), 1, "dry-run batch 1 still proposes the name")
    assert_eq(addsForKey(spy.plans[2], "p1"), 1,
        "dry-run batch 2 STILL contains the name (dry-run never folds)")
end

-- =====================================================================
-- (4) within-batch BL-15: a clustered name repeated across MULTIPLE records WITHIN one batch
--     appears exactly ONCE in that batch's plan.entries[photoKey].addKeywords.
--     (Two records, SAME photoKey, SAME rendered name, single chunk via large batchSize.)
-- =====================================================================
do
    local results = { recFor("pX"), recFor("pX") }
    local spy = makeSpy({ 'executed' })
    local prefs = { writeBatchSize = 0, confidenceThreshold = 0.6 }   -- one chunk

    batcher.flushAll(results, prefs, spy.fn)
    assert_eq(#spy.calls, 1, "writeBatchSize 0 ⇒ one chunk")
    assert_eq(addsForKey(spy.plans[1], "pX"), 1,
        "clustered repeat within one batch appears exactly once (BL-15)")
end

-- =====================================================================
-- (5) DEFAULT-SAFE: writeBatchSize=0 produces a single plan EQUAL (entries + addKeywords) to a
--     direct writeplan.planReport(results, prefs) call.
-- =====================================================================
do
    local results = { recFor("a"), recFor("b"), recFor("c") }
    local prefs = { writeBatchSize = 0, confidenceThreshold = 0.6 }

    -- Direct single planReport (today's behavior).
    local direct = writeplan.planReport(results, prefs)

    -- flushAll at size 0 ⇒ exactly one chunk ⇒ one apply with the same plan shape.
    -- Rebuild results fresh (flushAll may have rewritten existingNames in the prior block's copy).
    local results2 = { recFor("a"), recFor("b"), recFor("c") }
    local spy = makeSpy({ 'executed' })
    batcher.flushAll(results2, prefs, spy.fn)
    assert_eq(#spy.calls, 1, "default-safe: one chunk ⇒ one apply")

    local flushed = spy.plans[1]
    assert_eq(#flushed.entries, #direct.plan.entries,
        "default-safe: same entry count as a direct planReport")
    for i, e in ipairs(direct.plan.entries) do
        assert_eq(flushed.entries[i].photoKey, e.photoKey,
            "default-safe: entry " .. i .. " photoKey matches direct planReport")
        assert_eq(#flushed.entries[i].addKeywords, #e.addKeywords,
            "default-safe: entry " .. i .. " addKeywords count matches")
        assert_eq(flushed.entries[i].addKeywords[1], e.addKeywords[1],
            "default-safe: entry " .. i .. " first addKeyword matches")
    end
    -- And the returned aggregate exposes per-chunk status for the caller/report.
    -- (one chunk ⇒ one status entry)
end

-- =====================================================================
-- (A1) CROSS-BATCH NORMALIZATION: a name committed in batch 1 (canonical case) is NOT re-added
--      in batch 2 even though batch 2 renders an upper-case variant of the same keyword. The
--      committed canonical form is folded forward into existingNames; the writeplan diff
--      normalizes (ASCII case-fold + whitespace) at comparison time, so the case-variant matches.
-- =====================================================================
do
    local results = {
        recCased("p1", "Northern Cardinal", "Cardinalis cardinalis"),  -- batch 1 -> canonical
        recCased("p1", "NORTHERN CARDINAL", "CARDINALIS CARDINALIS"),  -- batch 2 -> upper-case
    }
    local spy = makeSpy({ 'executed', 'executed' })
    local prefs = { writeBatchSize = 1, confidenceThreshold = 0.6 }

    local out = batcher.flushAll(results, prefs, spy.fn)
    assert_eq(out.applyCount, 2, "A1 cross-batch: apply fired twice")
    assert_eq(addsForKey(spy.plans[1], "p1"), 1, "A1 cross-batch: batch 1 commits the canonical name")
    assert_eq(spy.plans[1].entries[1].addKeywords[1], CARDINAL, "A1 cross-batch: batch 1 stores canonical form")
    assert_eq(addsForKey(spy.plans[2], "p1"), 0,
        "A1 cross-batch: batch 2 case-variant matches folded canonical -> ZERO re-add")
end

-- =====================================================================
-- Aggregate return shape: applyCount + statuses + perChunkPlans present and consistent.
-- =====================================================================
do
    local results = { recFor("p1"), recFor("p2") }
    local spy = makeSpy({ 'executed', 'noop' })
    local prefs = { writeBatchSize = 1, confidenceThreshold = 0.6 }

    local out = batcher.flushAll(results, prefs, spy.fn)
    assert_eq(out.applyCount, 2, "aggregate applyCount == #chunks")
    assert_eq(#out.statuses, 2, "aggregate statuses has one per chunk")
    assert_eq(out.statuses[1], 'executed', "status 1 captured")
    assert_eq(out.statuses[2], 'noop', "status 2 captured")
    assert_eq(#out.perChunkPlans, 2, "aggregate perChunkPlans has one per chunk")
end
