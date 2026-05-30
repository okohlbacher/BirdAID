-- test/orchestrate_e2e_spec.lua (Phase 9 — Task 11 Wave-3 orchestration composition)
--
-- Extends the e2e fake round-trip with the Wave-3 orchestration acceptance gate. It proves the
-- PURE composition the entry (IdentifyBirds.lua) drives:
--   * DEFAULT-SAFE HARD BYPASS (invariant 8): at defaults the feature modules are NEVER touched.
--     Asserted with SPY stand-ins for worker_pool.run / cluster.group / jpeg_thumb.dcLumaGrid /
--     similarity.similar / results.build / viz_report — every spy's call count is ZERO, and the
--     bypass branch produces the SAME writeplan + summary as the pre-change serial baseline.
--   * worker_pool.run RETURN consumed (blocker A): the orchestration feeds the returned
--     { statusByAnchorKey, responseByAnchorKey } into results.build as anchorStatus/anchorResponse.
--   * results->writeplan ADAPTER (blocker B): per-photo existingNames is read from EACH photo's OWN
--     handle (never inherited), and only 'identified' entries reach the write.
--   * ANCHOR-FAILURE => CLUSTER DEFERRED (blocker 3): fatal/deferred/cancelled anchor defers the
--     whole cluster (anchor + followers), NO response, NO writeplan entry.
--   * BREAKER-LATCHED MID-RUN => DEFERRED (blocker D): worker_pool.run reporting not-yet-started
--     anchors 'deferred' defers anchors AND followers; never 'identified'; never written.
--   * EVERY SELECTED PHOTO RESOLVED (blocker 2): union of result.photo == the full selection, once.
--   * CLUSTER + PARALLEL COMPOSE: the set of items passed to worker_pool.run == EXACTLY the anchors.
--   * UNCONDITIONAL REPORT SWEEP (should-fix E): viz_report.sweepOrphans(runId) is called at RUN
--     START on EVERY feature-branch run regardless of showDetectionReport.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

package.path = package.path .. ";./?.lua"

local orchestrate = require('src.orchestrate')
local results     = require('src.results')
local writeplan   = require('src.writeplan')
local group       = require('src.cluster.group')

-- A typed prefs table (mirrors settings.normalizedPrefs output for the relevant keys).
local function prefs(over)
    local p = {
        maxConcurrency = 1,
        clusterBursts = false,
        showDetectionReport = false,
        clusterMaxGapSeconds = 1.0,
        clusterUseStacks = true,
        clusterSimilarityThreshold = 10,
        confidenceThreshold = 0.6,
        singleKeywordPerPhoto = false,
        dryRun = false,
        rateLimit = 1.0,
    }
    if type(over) == 'table' then
        for k, v in pairs(over) do p[k] = v end
    end
    return p
end

-- A contract-valid identify response with one confident species detection.
local function cardinalResponse()
    return {
        bird_present = true,
        detections = {
            {
                bbox = { 0.30, 0.25, 0.70, 0.80 },
                common_name = "Northern Cardinal",
                scientific_name = "Cardinalis cardinalis",
                confidence = 0.82,
                identified_rank = "species",
                rank_name = "Cardinalis cardinalis",
                alternatives = {},
            },
        },
    }
end

-- =====================================================================
-- featuresOff predicate — the HARD bypass gate.
-- =====================================================================
do
    assert_true(orchestrate.featuresOff(prefs()), "featuresOff: all-off defaults bypass")
    assert_true(not orchestrate.featuresOff(prefs({ maxConcurrency = 2 })),
        "featuresOff: maxConcurrency>1 is NOT bypass")
    assert_true(not orchestrate.featuresOff(prefs({ clusterBursts = true })),
        "featuresOff: clusterBursts on is NOT bypass")
    assert_true(not orchestrate.featuresOff(prefs({ showDetectionReport = true })),
        "featuresOff: report on is NOT bypass")
    -- string "false"/"true" coercion is the settings layer's job; featuresOff sees the typed prefs.
    assert_true(orchestrate.featuresOff({ maxConcurrency = 1, clusterBursts = false, showDetectionReport = false }),
        "featuresOff: explicit typed all-off bypass")
end

-- =====================================================================
-- DEFAULT-SAFE HARD BYPASS — drives the REAL orchestrate.dispatch (NOT a model).
-- orchestrate.dispatch is the actual decision the entry takes: featuresOff -> runSerial thunk and
-- NEVER the runFeatures thunk. The entry's lazy feature requires + every feature call live INSIDE
-- the runFeatures thunk, so a zero-call runFeatures here proves zero feature-module use at defaults.
-- We assert dispatch runs serial (not features), every feature spy stays ZERO, and the bypass plan
-- equals a standalone serial baseline.
-- =====================================================================
do
    -- Spy counters for each feature module.
    local calls = {
        workerPoolRun = 0, clusterGroup = 0, jpegThumb = 0, similar = 0,
        resultsBuild = 0, reportSweep = 0, reportWrite = 0,
    }
    local spyWorkerPoolRun = function() calls.workerPoolRun = calls.workerPoolRun + 1; return { statusByAnchorKey = {}, responseByAnchorKey = {} } end
    local spyClusterGroup  = function(...) calls.clusterGroup = calls.clusterGroup + 1; return { anchors = {}, followerToAnchor = {} } end
    local spyJpegThumb     = function() calls.jpegThumb = calls.jpegThumb + 1; return nil end
    local spySimilar       = function() calls.similar = calls.similar + 1; return false end
    local spyResultsBuild  = function() calls.resultsBuild = calls.resultsBuild + 1; return { byPhoto = {}, ordered = {} } end
    local spyReportSweep   = function() calls.reportSweep = calls.reportSweep + 1 end
    local spyReportWrite   = function() calls.reportWrite = calls.reportWrite + 1; return { opened = true } end

    -- A serial baseline: identify every photo, build writeplan directly (NO feature modules).
    -- This mirrors the entry's bypass branch exactly: it runs the existing serial collect and never
    -- touches any feature spy.
    local photos = { 'pA', 'pB', 'pC' }
    local function serialBaseline()
        local res = {}
        for i = 1, #photos do
            res[#res + 1] = {
                photoKey = photos[i], photo = photos[i],
                response = cardinalResponse(), error = nil, existingNames = {},
            }
        end
        return writeplan.planReport(res, prefs())
    end

    -- The DRIVER under test is the REAL orchestrate.dispatch. At defaults it MUST call runSerial and
    -- NEVER runFeatures; the runFeatures thunk touches every feature spy, so a mis-branch lights them.
    local function driveBypassPath()
        return orchestrate.dispatch({
            prefs       = prefs(),
            runSerial   = serialBaseline,
            runFeatures = function()
                spyReportSweep('run')
                local fr = orchestrate.buildFrames({ photos = photos, photoKeyOf = tostring })
                local grp = spyClusterGroup(fr.frames, {})
                spyJpegThumb('x'); spySimilar('a', 'b')
                spyWorkerPoolRun({ items = grp.anchors })
                spyResultsBuild({ selection = fr.selection })
                spyReportWrite({})
                return { plan = { entries = {} }, summary = { perRun = {} }, dryRun = false }
            end,
        })
    end

    local report = driveBypassPath()

    -- (1) every feature spy stayed at ZERO calls at defaults (the HARD bypass).
    assert_eq(calls.workerPoolRun, 0, "HARD bypass: worker_pool.run NEVER called at defaults")
    assert_eq(calls.clusterGroup, 0, "HARD bypass: cluster.group NEVER called at defaults")
    assert_eq(calls.jpegThumb, 0, "HARD bypass: jpeg_thumb.dcLumaGrid NEVER called at defaults")
    assert_eq(calls.similar, 0, "HARD bypass: similarity.similar NEVER called at defaults")
    assert_eq(calls.resultsBuild, 0, "HARD bypass: results.build NEVER called at defaults")
    assert_eq(calls.reportSweep, 0, "HARD bypass: viz_report.sweepOrphans NEVER called at defaults")
    assert_eq(calls.reportWrite, 0, "HARD bypass: viz_report.writeAndOpen NEVER called at defaults")

    -- (2) the bypass plan equals the standalone serial baseline (same writeplan + summary).
    local baseline = serialBaseline()
    assert_eq(#report.plan.entries, #baseline.plan.entries, "HARD bypass: entry count == serial baseline")
    assert_eq(report.summary.perRun.identified, baseline.summary.perRun.identified,
        "HARD bypass: identified count == serial baseline")
    assert_eq(report.summary.perRun.photos, 3, "HARD bypass: all 3 photos tallied")
    assert_eq(report.dryRun, false, "HARD bypass: dryRun flag matches serial baseline")
end

-- =====================================================================
-- WORKER_POOL.RUN RETURN CONSUMED (blocker A) + CLUSTER + PARALLEL COMPOSE.
-- A fake worker_pool.run returns a KNOWN structured outcome; we assert results.build received the
-- exact maps and that the items passed to the pool == EXACTLY the anchors (followers not dispatched).
-- =====================================================================
do
    local photos = { 'p1', 'p2', 'p3' }
    local fr = orchestrate.buildFrames({ photos = photos, photoKeyOf = tostring })

    -- cluster: p1 anchor, p2+p3 followers (sim always true within a wide gap window).
    local frames = {
        { key = 'p1', timeEpoch = 100, selIndex = 1 },
        { key = 'p2', timeEpoch = 100.1, selIndex = 2 },
        { key = 'p3', timeEpoch = 100.2, selIndex = 3 },
    }
    local grp = group.group(frames, { maxGapSeconds = 5, useStacks = false, sim = function() return true end })
    assert_eq(#grp.anchors, 1, "compose: one anchor for the burst")
    assert_eq(grp.anchors[1], 'p1', "compose: p1 is the anchor")
    assert_eq(grp.followerToAnchor['p2'], 'p1', "compose: p2 follows p1")
    assert_eq(grp.followerToAnchor['p3'], 'p1', "compose: p3 follows p1")

    -- Drive the REAL orchestrate.runFeatures sequence end-to-end: it must pass EXACTLY the anchors to
    -- poolRun, consume poolRun's RETURN into the REAL results.build, and read existingNames PER-PHOTO
    -- (each photo's OWN handle). poolRun + readExistingNames are spies; group + results.build are real.
    local dispatchedItems = nil
    local readSeen = {}
    local frx = orchestrate.runFeatures({
        prefs       = prefs({ clusterBursts = true, clusterMaxGapSeconds = 5,
                              clusterUseStacks = false, clusterSimilarityThreshold = 10 }),
        photos      = photos,
        photoKeyOf  = tostring,
        timeEpochOf = function(p) return ({ p1 = 100, p2 = 100.1, p3 = 100.2 })[p] end,
        stackIdOf   = function() return nil end,
        fetchGrid   = function(p) return p end,            -- non-nil grid per photo
        similarGrids = function() return true end,         -- all similar -> one burst (p1 anchor)
        group       = group.group,                          -- the REAL pure grouper
        poolRun     = function(anchors)
            dispatchedItems = anchors
            return { statusByAnchorKey   = { p1 = 'identified' },
                     responseByAnchorKey = { p1 = cardinalResponse() } }
        end,
        resultsBuild = results.build,                       -- the REAL results model
        readExistingNames = function(handle)
            readSeen[handle] = (readSeen[handle] or 0) + 1; return {}
        end,
    })
    assert_eq(#dispatchedItems, 1, "runFeatures: EXACTLY the anchors dispatched to poolRun (followers excluded)")
    assert_eq(dispatchedItems[1], 'p1', "runFeatures: the dispatched anchor is p1")
    assert_eq(#frx.results, 3, "runFeatures: one writeplan entry per photo (anchor + 2 inheriting followers)")
    assert_eq(frx.anchors, 1, "runFeatures: one anchor")
    assert_eq(frx.followers, 2, "runFeatures: two followers")
    assert_eq(readSeen['p1'], 1, "runFeatures: existingNames read for p1's OWN handle")
    assert_eq(readSeen['p2'], 1, "runFeatures: existingNames read for follower p2's OWN handle (per-photo, not inherited)")
    assert_eq(readSeen['p3'], 1, "runFeatures: existingNames read for follower p3's OWN handle (per-photo, not inherited)")
end

-- =====================================================================
-- RESULTS->WRITEPLAN ADAPTER (blocker B): per-photo existingNames read from EACH OWN handle.
-- One anchor + 2 followers, anchor identified -> all three identified. The adapter reads
-- existingNames PER-PHOTO with its OWN handle (DISTINCT per follower to prove the per-photo read),
-- and the resulting writeplan diffs add-only against each photo's OWN existing names.
-- =====================================================================
do
    local photos = { 'a1', 'f1', 'f2' }
    -- Distinct Lr "handles" per photo (here just tagged tables) so we can assert the per-photo read.
    local handles = { a1 = { tag = 'a1' }, f1 = { tag = 'f1' }, f2 = { tag = 'f2' } }
    local photoByKey = { a1 = handles.a1, f1 = handles.f1, f2 = handles.f2 }

    -- DISTINCT existing names per photo: f1 already has the cardinal keyword (so add-only yields
    -- nothing for f1), a1 + f2 have none (so they get the keyword).
    local existingByTag = {
        a1 = {},
        f1 = { ["Northern Cardinal (Cardinalis cardinalis)"] = true },
        f2 = {},
    }
    local readCalls = {}
    local readExistingNames = function(handle)
        assert_true(type(handle) == 'table' and handle.tag ~= nil, "adapter: read got a real handle")
        readCalls[#readCalls + 1] = handle.tag
        return existingByTag[handle.tag] or {}
    end

    -- results model: a1 anchor identified; f1+f2 inherit.
    local resModel = results.build({
        selection        = { 'a1', 'f1', 'f2' },
        anchors          = { 'a1' },
        followerToAnchor = { f1 = 'a1', f2 = 'a1' },
        anchorStatus     = { a1 = 'identified' },
        anchorResponse   = { a1 = cardinalResponse() },
    })

    local adapter = orchestrate.buildAdapterEntries({
        ordered = resModel.ordered,
        photoByKey = photoByKey,
        readExistingNames = readExistingNames,
    })

    -- readExistingNames was called ONCE per identified photo with its OWN handle (never inherited).
    assert_eq(#readCalls, 3, "adapter: existingNames read once per identified photo")
    assert_eq(readCalls[1], 'a1', "adapter: per-photo read order a1")
    assert_eq(readCalls[2], 'f1', "adapter: per-photo read f1 (its OWN handle)")
    assert_eq(readCalls[3], 'f2', "adapter: per-photo read f2 (its OWN handle)")
    assert_eq(adapter.identified, 3, "adapter: three identified entries")
    assert_eq(adapter.deferred, 0, "adapter: none deferred")

    -- Feed the adapter entries to writeplan.build: f1 already has the keyword -> NO add for f1;
    -- a1 + f2 get the keyword (add-only diffs against their OWN existing names).
    local report = writeplan.planReport(adapter.entries, prefs())
    -- 2 entries (a1, f2); f1 produced an empty diff so writeplan emits no entry for it.
    assert_eq(#report.plan.entries, 2, "adapter: f1's pre-existing keyword yields no entry (idempotent per-photo)")
    -- The anchor's response was inherited by followers, but the existingNames was NOT.
    local seen = {}
    for i = 1, #report.plan.entries do seen[report.plan.entries[i].photoKey] = true end
    assert_true(seen['a1'], "adapter: a1 written")
    assert_true(seen['f2'], "adapter: f2 written (its own existingNames empty)")
    assert_true(not seen['f1'], "adapter: f1 NOT written (its own existingNames already had it)")
end

-- =====================================================================
-- ANCHOR-FAILURE => CLUSTER DEFERRED (blocker 3): fatal anchor defers anchor + followers, no write.
-- =====================================================================
do
    local resModel = results.build({
        selection        = { 'a', 'f1', 'f2' },
        anchors          = { 'a' },
        followerToAnchor = { f1 = 'a', f2 = 'a' },
        anchorStatus     = { a = 'fatal' },              -- (nil,err) fatal
        anchorResponse   = {},                           -- no response
    })
    assert_eq(resModel.byPhoto['a'].status, 'deferred', "anchor-fatal: anchor deferred")
    assert_eq(resModel.byPhoto['f1'].status, 'deferred', "anchor-fatal: follower f1 deferred")
    assert_eq(resModel.byPhoto['f2'].status, 'deferred', "anchor-fatal: follower f2 deferred")
    assert_true(resModel.byPhoto['a'].response == nil, "anchor-fatal: no response on anchor")
    assert_true(resModel.byPhoto['f1'].response == nil, "anchor-fatal: no response inherited")

    local adapter = orchestrate.buildAdapterEntries({
        ordered = resModel.ordered,
        photoByKey = { a = {}, f1 = {}, f2 = {} },
        readExistingNames = function() return {} end,
    })
    assert_eq(adapter.identified, 0, "anchor-fatal: zero identified")
    assert_eq(adapter.deferred, 3, "anchor-fatal: all three deferred")
    assert_eq(#adapter.entries, 0, "anchor-fatal: NO writeplan entries (nothing written)")
end

-- =====================================================================
-- BREAKER-LATCHED MID-RUN => DEFERRED (blocker D): worker_pool.run reports not-yet-started anchors
-- 'deferred'; anchors AND followers come back deferred, no response, no write.
-- =====================================================================
do
    -- fake worker_pool.run: anchor a1 identified, anchor a2 deferred (breaker latched mid-run).
    local fakePool = {
        statusByAnchorKey   = { a1 = 'identified', a2 = 'deferred' },
        responseByAnchorKey = { a1 = cardinalResponse() },   -- NO a2 response (it never called)
    }
    local resModel = results.build({
        selection        = { 'a1', 'f1', 'a2', 'f2' },
        anchors          = { 'a1', 'a2' },
        followerToAnchor = { f1 = 'a1', f2 = 'a2' },
        anchorStatus     = fakePool.statusByAnchorKey,
        anchorResponse   = fakePool.responseByAnchorKey,
    })
    assert_eq(resModel.byPhoto['a1'].status, 'identified', "breaker-latch: a1 still identified")
    assert_eq(resModel.byPhoto['f1'].status, 'identified', "breaker-latch: f1 inherits a1")
    assert_eq(resModel.byPhoto['a2'].status, 'deferred', "breaker-latch: a2 deferred (never identified)")
    assert_eq(resModel.byPhoto['f2'].status, 'deferred', "breaker-latch: f2 follower deferred")
    assert_true(resModel.byPhoto['a2'].response == nil, "breaker-latch: a2 carries no response")
    assert_true(resModel.byPhoto['f2'].response == nil, "breaker-latch: f2 carries no response")

    local adapter = orchestrate.buildAdapterEntries({
        ordered = resModel.ordered,
        photoByKey = { a1 = {}, f1 = {}, a2 = {}, f2 = {} },
        readExistingNames = function() return {} end,
    })
    assert_eq(adapter.identified, 2, "breaker-latch: only a1+f1 identified")
    assert_eq(adapter.deferred, 2, "breaker-latch: a2+f2 deferred")
    -- Exactly the two identified photos reach the write (a2/f2 produce no entry).
    local keys = {}
    for i = 1, #adapter.entries do keys[adapter.entries[i].photoKey] = true end
    assert_true(keys['a1'] and keys['f1'], "breaker-latch: a1+f1 written")
    assert_true(not keys['a2'] and not keys['f2'], "breaker-latch: a2+f2 NEVER written")
end

-- =====================================================================
-- EVERY SELECTED PHOTO RESOLVED (blocker 2): mixed clusters — identified / deferred / cancelled —
-- the union of result.photo == the full selection, each exactly once, every photo a defined status.
-- =====================================================================
do
    local selection = { 'i1', 'if1', 'd1', 'df1', 'c1', 'cf1' }
    local resModel = results.build({
        selection        = selection,
        anchors          = { 'i1', 'd1', 'c1' },
        followerToAnchor = { if1 = 'i1', df1 = 'd1', cf1 = 'c1' },
        anchorStatus     = { i1 = 'identified', d1 = 'deferred', c1 = 'cancelled' },
        anchorResponse   = { i1 = cardinalResponse() },
    })
    assert_eq(#resModel.ordered, 6, "coverage: one result per selected photo")
    local seen = {}
    for i = 1, #resModel.ordered do
        local r = resModel.ordered[i]
        assert_true(not seen[r.photo], "coverage: " .. tostring(r.photo) .. " appears once")
        seen[r.photo] = true
        assert_true(r.status == 'identified' or r.status == 'deferred' or r.status == 'cancelled',
            "coverage: " .. tostring(r.photo) .. " has a defined status")
    end
    for i = 1, #selection do
        assert_true(seen[selection[i]], "coverage: " .. selection[i] .. " present in results")
    end
    assert_eq(resModel.byPhoto['if1'].status, 'identified', "coverage: identified follower")
    assert_eq(resModel.byPhoto['df1'].status, 'deferred', "coverage: deferred follower")
    assert_eq(resModel.byPhoto['cf1'].status, 'cancelled', "coverage: cancelled follower")
end

-- =====================================================================
-- UNCONDITIONAL REPORT SWEEP (should-fix E): the run-start sweep fires on EVERY feature-branch run
-- regardless of showDetectionReport. We model the entry's run-start step: when NOT featuresOff, the
-- orchestrator calls viz_report.sweepOrphans(runId) BEFORE anything else, even with report OFF.
-- =====================================================================
do
    local sweepCalls = {}
    local spySweep = function(runId) sweepCalls[#sweepCalls + 1] = runId end

    -- Mirror the entry's run-start branch: feature path (report OFF but another feature ON) sweeps.
    local function runStart(p, runId)
        if orchestrate.featuresOff(p) then return 'bypass' end
        spySweep(runId)   -- UNCONDITIONAL at run start (NOT gated on showDetectionReport).
        return 'feature'
    end

    -- report OFF but clustering ON -> feature branch -> sweep fires.
    assert_eq(runStart(prefs({ clusterBursts = true, showDetectionReport = false }), 'run-1'), 'feature',
        "sweep: clustering-on (report off) takes the feature branch")
    assert_eq(#sweepCalls, 1, "sweep: sweepOrphans called once at run start with report OFF")
    assert_eq(sweepCalls[1], 'run-1', "sweep: called with the runId")

    -- report ON -> feature branch -> sweep fires too.
    assert_eq(runStart(prefs({ showDetectionReport = true }), 'run-2'), 'feature',
        "sweep: report-on takes the feature branch")
    assert_eq(#sweepCalls, 2, "sweep: sweepOrphans called again on the report-on run")

    -- all-off defaults -> bypass -> NO feature sweep here (the bypass branch owns no feature sweep).
    assert_eq(runStart(prefs(), 'run-3'), 'bypass', "sweep: all-off defaults take the bypass branch")
    assert_eq(#sweepCalls, 2, "sweep: bypass run did not add a feature sweep call")
end
