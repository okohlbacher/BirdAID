-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/orchestrate.lua (Phase 9 — BL-06/BL-07/BL-04 PURE orchestration composition)
--
-- PURE module: imports NO Lr* module, uses NO os.time/os.date/os.clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant). It is
-- the TESTABLE composition the Wave-3 orchestrator (IdentifyBirds.lua) drives; every Lr-touching
-- dependency (preview/thumb fetch, provider identify, stack/time read, per-photo existingNames read,
-- worker_pool.run, cluster.group, jpeg_thumb, similarity, results.build, report render) is INJECTED so
-- the e2e spec can drive the WHOLE branch logic offline with fakes + spies. The thin entry file wires
-- the REAL Lr modules into these injection points and owns the LrTasks lifecycle.
--
-- WHY A PURE HELPER: the #1 invariant (default-safe HARD bypass) and the join/adapter logic must be
-- spy-asserted offline. By keeping the branch decision + the results->writeplan adapter PURE here, the
-- e2e fake spec can assert (a) at defaults NONE of the feature modules are constructed/called, and
-- (b) on the feature branch the worker_pool.run return is consumed and the per-photo existingNames
-- read happens per-photo. The entry stays a thin SDK driver.
--
-- ===========================================================================
-- M.featuresOff(prefs) -> bool  (the HARD default-safe bypass predicate)
-- ===========================================================================
--   true IFF maxConcurrency == 1 AND clusterBursts == false AND showDetectionReport == false.
--   When true the caller MUST take the EXISTING serial code path and MUST NOT require/construct/call
--   the pool, clustering, jpeg_thumb/similarity, results.build, or viz_report modules (invariant 8).
--
-- ===========================================================================
-- M.buildFrames(opts) -> { frames = {...}, photoByKey = {...} }   (PURE cluster pre-pass framing)
-- ===========================================================================
--   Builds the ordered-frame array cluster.group consumes + the photoKey->handle map the adapter
--   needs. opts = {
--     photos      = { <Lr handle>, ... },      -- the selection, in order
--     photoKeyOf  = function(photo) -> key,    -- INJECTED stable key (tostring(photo))
--     timeEpochOf = function(photo) -> num|nil,-- INJECTED capture-time read (stack_reader)
--     stackIdOf   = function(photo) -> id|nil, -- INJECTED stack-id read (stack_reader)
--   } -> frames[i] = { key, timeEpoch, stackId, selIndex=i }; photoByKey[key] = photo.
--   NOTE: cluster.group sorts internally (timeEpoch ASC, selIndex ASC) — we pass selIndex so the
--   tie-break is deterministic; we do NOT sort here.
--
-- ===========================================================================
-- M.buildAdapterEntries(opts) -> { entries, identified, deferred, cancelled, errored }
-- ===========================================================================
--   The results->writeplan ADAPTER (BLOCKER B), PURE. For each 'identified' result it maps
--   result.photo -> the Lr handle via photoByKey, attaches the (inherited-for-followers) response,
--   and reads existingNames PER-PHOTO via the INJECTED readExistingNames(handle) — NEVER inherited.
--   deferred|cancelled|error -> NO entry (counted for the summary). opts = {
--     ordered           = { result, ... },           -- results.build().ordered (selection order)
--     photoByKey        = { [key]=handle },           -- photoKey -> Lr handle
--     readExistingNames = function(handle) -> {names}, -- INJECTED per-photo read (catalog_writer)
--   } -> {
--     entries = { { photoKey, photo=handle, response, existingNames }, ... },  -- for writeplan.build
--     identified, deferred, cancelled, errored = <counts>,
--   }
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local M = {}

-- ---------------------------------------------------------------------------
-- featuresOff(prefs) — the HARD default-safe bypass predicate (invariant 8).
-- ---------------------------------------------------------------------------
function M.featuresOff(prefs)
    prefs = type(prefs) == 'table' and prefs or {}
    local serial = (tonumber(prefs.maxConcurrency) or 1) == 1
    local noCluster = (prefs.clusterBursts ~= true)
    local noReport = (prefs.showDetectionReport ~= true)
    return serial and noCluster and noReport
end

-- ---------------------------------------------------------------------------
-- buildFrames(opts) — PURE cluster pre-pass framing + photoByKey map.
-- ---------------------------------------------------------------------------
function M.buildFrames(opts)
    opts = type(opts) == 'table' and opts or {}
    local photos = type(opts.photos) == 'table' and opts.photos or {}
    local photoKeyOf = type(opts.photoKeyOf) == 'function' and opts.photoKeyOf or tostring
    local timeEpochOf = type(opts.timeEpochOf) == 'function' and opts.timeEpochOf or function() return nil end
    local stackIdOf = type(opts.stackIdOf) == 'function' and opts.stackIdOf or function() return nil end

    local frames = {}
    local photoByKey = {}
    local selection = {}

    for i = 1, #photos do
        local photo = photos[i]
        local key = photoKeyOf(photo)
        photoByKey[key] = photo
        selection[#selection + 1] = key
        frames[#frames + 1] = {
            key      = key,
            timeEpoch = timeEpochOf(photo),
            stackId  = stackIdOf(photo),
            selIndex = i,
        }
    end

    return { frames = frames, photoByKey = photoByKey, selection = selection }
end

-- ---------------------------------------------------------------------------
-- buildAdapterEntries(opts) — the PURE results->writeplan adapter (BLOCKER B).
-- ---------------------------------------------------------------------------
function M.buildAdapterEntries(opts)
    opts = type(opts) == 'table' and opts or {}
    local ordered = type(opts.ordered) == 'table' and opts.ordered or {}
    local photoByKey = type(opts.photoByKey) == 'table' and opts.photoByKey or {}
    local readExistingNames = type(opts.readExistingNames) == 'function'
        and opts.readExistingNames or function() return {} end

    local entries = {}
    local identified, deferred, cancelled, errored = 0, 0, 0, 0

    for i = 1, #ordered do
        local r = ordered[i]
        local status = r and r.status
        if status == 'identified' then
            local handle = photoByKey[r.photo]
            -- existingNames is read PER-PHOTO from THIS photo's OWN handle (NEVER inherited): a
            -- follower diffs add-only/idempotent against ITS OWN current keywords.
            local existingNames = readExistingNames(handle)
            entries[#entries + 1] = {
                photoKey      = r.photo,
                photo         = handle,
                response      = r.response,
                existingNames = existingNames,
            }
            identified = identified + 1
        elseif status == 'cancelled' then
            cancelled = cancelled + 1
        elseif status == 'error' then
            errored = errored + 1
        else
            -- 'deferred' (and any unexpected status) -> no entry, retried next run.
            deferred = deferred + 1
        end
    end

    return {
        entries    = entries,
        identified = identified,
        deferred   = deferred,
        cancelled  = cancelled,
        errored    = errored,
    }
end

-- ---------------------------------------------------------------------------
-- runFeatures(deps) — the PURE feature-branch SEQUENCE (BL-06/07/04 dispatch).
-- Composes buildFrames -> optional cluster pre-pass (via injected fetchGrid + similarGrids +
-- group) -> poolRun(anchors) -> resultsBuild -> buildAdapterEntries. EVERY Lr-touching step is
-- INJECTED so the e2e spec drives the REAL sequence (not a model). deps = {
--   prefs, photos, photoKeyOf, timeEpochOf, stackIdOf,   -- framing
--   fetchGrid(photo,i)->grid|nil, similarGrids(a,b)->bool, group(frames,opts)->{anchors,followerToAnchor},
--   poolRun(anchors)->{statusByAnchorKey,responseByAnchorKey},
--   resultsBuild(args)->{ordered=...}, readExistingNames(handle)->{names},
-- } -> { results, identified, deferred, cancelled, errored, anchors, followers, photoByKey, poolOut }.
-- ---------------------------------------------------------------------------
function M.runFeatures(deps)
    deps = type(deps) == 'table' and deps or {}
    local prefs = type(deps.prefs) == 'table' and deps.prefs or {}
    local photos = type(deps.photos) == 'table' and deps.photos or {}
    local photoKeyOf = type(deps.photoKeyOf) == 'function' and deps.photoKeyOf or tostring
    local fetchGrid = type(deps.fetchGrid) == 'function' and deps.fetchGrid or function() return nil end
    local similarGrids = type(deps.similarGrids) == 'function' and deps.similarGrids or function() return false end
    local group = type(deps.group) == 'function' and deps.group or nil
    local poolRun = type(deps.poolRun) == 'function' and deps.poolRun
        or function() return { statusByAnchorKey = {}, responseByAnchorKey = {} } end
    local resultsBuild = type(deps.resultsBuild) == 'function' and deps.resultsBuild
        or function() return { ordered = {} } end
    local readExistingNames = type(deps.readExistingNames) == 'function'
        and deps.readExistingNames or function() return {} end

    local framing = M.buildFrames({
        photos = photos, photoKeyOf = photoKeyOf,
        timeEpochOf = deps.timeEpochOf, stackIdOf = deps.stackIdOf,
    })
    local photoByKey = framing.photoByKey
    local selection = framing.selection

    local anchors, followerToAnchor
    if prefs.clusterBursts == true and group then
        -- Per-photo grid (INJECTED fetchGrid: >=128px thumb -> DC-luma; nil => not-similar => no merge).
        local gridByKey = {}
        for i = 1, #photos do
            local photo = photos[i]
            gridByKey[photoKeyOf(photo)] = fetchGrid(photo, i)
        end
        local sim = function(prevKey, curKey)
            return similarGrids(gridByKey[prevKey], gridByKey[curKey])
        end
        local grp = group(framing.frames, {
            maxGapSeconds = prefs.clusterMaxGapSeconds,
            useStacks     = prefs.clusterUseStacks,
            sim           = sim,
        })
        anchors = (type(grp) == 'table' and type(grp.anchors) == 'table') and grp.anchors or {}
        followerToAnchor = (type(grp) == 'table' and type(grp.followerToAnchor) == 'table')
            and grp.followerToAnchor or {}
    else
        -- Clustering off (another feature on): every photo is its own anchor.
        anchors = {}
        for i = 1, #selection do anchors[#anchors + 1] = selection[i] end
        followerToAnchor = {}
    end

    -- Consume the worker_pool.run RETURN (blocker A): status/response keyed by anchor.
    local poolOut = poolRun(anchors)
    if type(poolOut) ~= 'table' then poolOut = {} end
    local resModel = resultsBuild({
        selection        = selection,
        anchors          = anchors,
        followerToAnchor = followerToAnchor,
        anchorStatus     = type(poolOut.statusByAnchorKey) == 'table' and poolOut.statusByAnchorKey or {},
        anchorResponse   = type(poolOut.responseByAnchorKey) == 'table' and poolOut.responseByAnchorKey or {},
    })
    if type(resModel) ~= 'table' then resModel = { ordered = {} } end

    local adapter = M.buildAdapterEntries({
        ordered           = type(resModel.ordered) == 'table' and resModel.ordered or {},
        photoByKey        = photoByKey,
        readExistingNames = readExistingNames,
    })

    local followers = 0
    for _ in pairs(followerToAnchor) do followers = followers + 1 end

    return {
        results    = adapter.entries,
        identified = adapter.identified,
        deferred   = adapter.deferred,
        cancelled  = adapter.cancelled,
        errored    = adapter.errored,
        anchors    = #anchors,
        followers  = followers,
        photoByKey = photoByKey,
        poolOut    = poolOut,
    }
end

-- ---------------------------------------------------------------------------
-- dispatch(deps) — the HARD default-safe bypass DECISION over two thunks (the REAL branch the
-- entry takes). featuresOff (computed from prefs if not given) ⇒ run the SERIAL thunk and NEVER
-- the feature thunk (so the entry's lazy feature requires never happen at defaults); else run the
-- feature thunk. Returns whatever the chosen thunk returns. deps = {
--   featuresOff = bool | nil (nil ⇒ M.featuresOff(prefs)), prefs, runSerial = fn, runFeatures = fn }.
-- ---------------------------------------------------------------------------
function M.dispatch(deps)
    deps = type(deps) == 'table' and deps or {}
    local off = deps.featuresOff
    if off == nil then off = M.featuresOff(deps.prefs) end
    if off then
        if type(deps.runSerial) == 'function' then return deps.runSerial() end
        return nil
    end
    if type(deps.runFeatures) == 'function' then return deps.runFeatures() end
    return nil
end

return M
