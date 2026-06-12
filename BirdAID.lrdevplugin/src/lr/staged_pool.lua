-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/staged_pool.lua (Phase 9 — BL-06 preview-decoupling fix)
--
-- THIN Lr glue. Fixes the stress-test bug: when the worker pool issued N concurrent
-- photo:requestJpegThumbnail renders (one per worker coroutine), every preview timed out under
-- load (LrC serializes preview RENDERING internally; N cold 2048px renders each exceed the 8s
-- timeout) -> 100% skips, 0 identifies. The serial path always worked.
--
-- THE FIX (staged producer/consumer): the PRODUCER runs on the CALLING (orchestrator) task and
-- fetches previews SERIALLY -- one render at a time, the reliable path. As each preview becomes
-- ready it DISPATCHES a CONSUMER (LrTasks.startAsyncTask) that does ONLY the gated provider call
-- (LrHttp.post overlaps cleanly). In-flight consumers are BOUNDED to maxConcurrency (backpressure),
-- so we hold ~maxConcurrency previews in memory, never all N. The token bucket now gates ONLY the
-- provider call (inside identifyJob's worker_gate), not the preview fetch.
--
-- run(opts) -> { statusByAnchorKey = { [key]=status }, responseByAnchorKey = { [key]=response } }
--   opts = {
--     items          = { <key>, ... },               -- anchor keys, in order
--     maxConcurrency = <int>=1>,                      -- max in-flight CONSUMERS (floored, NaN/inf->1)
--     fetchJob       = function(key) -> job | (nil, reason),  -- MAIN-TASK serial preview fetch
--     identifyJob    = function(job) -> (status, response),   -- CONSUMER: gated AI call; status one
--                       --   of 'identified'(+response) | 'fatal' | 'deferred' | 'cancelled'
--     isCanceled     = function() -> bool,            -- cooperative cancel (opt)
--     breaker        = { shouldStop = function() -> bool } (opt, READ-ONLY here),
--     spawn          = function(fn[, name]) (opt; default LrTasks.startAsyncTask),
--     sleep          = function(secs)       (opt; default LrTasks.sleep),
--     yield          = function()           (opt; default LrTasks.yield),
--     progress       = <LrProgressScope>    (opt),
--   }
--
-- TERMINAL STATUS for EVERY item: a dispatched anchor gets its consumer's status; a preview
-- fetch failure -> 'error' (isolated, no response); once cancelled/breaker-open the producer stops
-- and the REMAINING (undispatched) anchors are marked 'cancelled'/'deferred'. The pure
-- src.results.build + adapter then turn these into per-photo write entries (identified only).
--
-- CONCURRENCY: LrC tasks are single-threaded COOPERATIVE -- counters (inFlight/done) mutate only
-- at yield points, so the producer's ++ and a consumer's -- never race. The consumer body is
-- wrapped in the yield-safe LrTasks.pcall so a throwing identify ALWAYS decrements inFlight (the
-- drain can never hang) and maps to 'fatal'. Strictly Lua 5.1 common subset.

-- Guarded import so the module LOADS under stock lua/luajit for offline tests (where `import` is
-- absent): then spawn/sleep/yield/pcall are INJECTED by the spec. Under LrC `import` resolves.
local ok_, LrTasks = pcall(function() return import 'LrTasks' end)
if not ok_ then LrTasks = nil end

local M = {}

local function safeBool(fn)
    if type(fn) ~= 'function' then return false end
    local ok, v = pcall(fn)
    return (ok and v) and true or false
end

function M.run(opts)
    opts = type(opts) == 'table' and opts or {}
    local items = type(opts.items) == 'table' and opts.items or {}
    local maxC = math.floor(tonumber(opts.maxConcurrency) or 1)
    if maxC ~= maxC or maxC == math.huge or maxC == -math.huge or maxC < 1 then maxC = 1 end
    local fetchJob = type(opts.fetchJob) == 'function' and opts.fetchJob or function() return nil, 'no-fetch' end
    local identifyJob = type(opts.identifyJob) == 'function' and opts.identifyJob or function() return 'fatal' end
    local isCanceled = type(opts.isCanceled) == 'function' and opts.isCanceled or function() return false end
    local breaker = opts.breaker
    local spawn = type(opts.spawn) == 'function' and opts.spawn or (LrTasks and LrTasks.startAsyncTask)
    local sleep = type(opts.sleep) == 'function' and opts.sleep or (LrTasks and LrTasks.sleep)
    local yield = type(opts.yield) == 'function' and opts.yield or (LrTasks and LrTasks.yield)
    -- yield-safe protector for the consumer body (identifyJob YIELDS): injected for tests, else
    -- LrTasks.pcall in LrC, else stock pcall (tests use non-yielding fakes).
    local protect = type(opts.pcall) == 'function' and opts.pcall or (LrTasks and LrTasks.pcall) or pcall
    local progress = opts.progress

    local statusByAnchorKey = {}
    local responseByAnchorKey = {}
    local total = #items
    local inFlight = 0
    local peakInFlight = 0   -- max simultaneous in-flight AI consumers (observed concurrency)
    local done = 0

    local function breakerOpen()
        if type(breaker) == 'table' then return safeBool(breaker.shouldStop) end
        return false
    end

    local function bumpProgress()
        if type(progress) ~= 'table' then return end
        -- non-yielding UI updates; guard each so a bad scope can never break accounting.
        if type(progress.setPortionComplete) == 'function' then
            protect(function() progress:setPortionComplete(done, total) end)
        end
        -- BL-12: X-of-Y caption. The parallel path completes out of order, so a running
        -- "Processed N of M" count is the meaningful signal (the bar alone has no number).
        if type(progress.setCaption) == 'function' then
            protect(function() progress:setCaption(string.format("Processed %d of %d", done, total)) end)
        end
    end

    -- Mark all still-unresolved items from index `fromIdx` with `status` (cancel/breaker stop).
    local function markRemaining(fromIdx, status)
        for j = fromIdx, total do
            local k = items[j]
            if statusByAnchorKey[k] == nil then statusByAnchorKey[k] = status end
        end
    end

    local i = 1
    while i <= total do
        local key = items[i]

        if isCanceled() then markRemaining(i, 'cancelled'); break end
        if breakerOpen() then markRemaining(i, 'deferred'); break end

        -- BACKPRESSURE: wait while at capacity so we never hold more than ~maxC previews/consumers.
        while inFlight >= maxC do
            if isCanceled() then break end
            sleep(0.05)
        end
        -- Re-check BOTH cancel and breaker AFTER the capacity wait (either may flip during it) so we
        -- never fetch/dispatch one extra anchor past a cancel or a breaker-open mid-wait.
        if isCanceled() then markRemaining(i, 'cancelled'); break end
        if breakerOpen() then markRemaining(i, 'deferred'); break end

        -- PRODUCER: MAIN-TASK serial preview fetch (the reliable path — one render at a time).
        local job = fetchJob(key)
        if job == nil then
            -- preview timeout/fail: isolated; this anchor gets no response (surfaced as 'error',
            -- which the adapter drops from the write — retried on a later run).
            statusByAnchorKey[key] = 'error'
            done = done + 1
            bumpProgress()
        else
            -- CONSUMER: gated provider call ONLY, in its own cooperative task (parallel up to maxC).
            inFlight = inFlight + 1
            if inFlight > peakInFlight then peakInFlight = inFlight end   -- observed concurrency
            spawn(function()
                local st = 'fatal'
                local resp = nil
                -- identifyJob YIELDS (LrHttp.post) -> MUST be the yield-safe LrTasks.pcall. A throw
                -- maps to 'fatal'; the decrement below ALWAYS runs so the drain can never hang.
                local ok, a, b = protect(identifyJob, job)
                if ok then st = a or 'fatal'; resp = b end
                statusByAnchorKey[key] = st
                if st == 'identified' then responseByAnchorKey[key] = resp end
                inFlight = inFlight - 1
                done = done + 1
                bumpProgress()
            end, 'BirdAID.aiConsumer')
        end

        i = i + 1
        yield()   -- cooperative: let dispatched consumers run + the preview callback fire.
    end

    -- DRAIN: wait for all in-flight consumers to finish before returning the terminal maps.
    -- D6 (M7): completion semantics are spec-pinned (in-flight work MUST complete) — the sleeps stay
    -- as-is. We only improve the UX: set the caption ONCE at drain start to "Finishing N in-flight…"
    -- via the SAME injected progress/caption seam used by bumpProgress, so the user sees why the run
    -- is still busy after the last anchor dispatched (the bar would otherwise sit silent). Guarded
    -- and non-yielding; never blocks the drain.
    if inFlight > 0 and type(progress) == 'table' and type(progress.setCaption) == 'function' then
        local remaining = inFlight
        protect(function()
            progress:setCaption(string.format("Finishing %d in-flight\226\128\166", remaining))
        end)
    end
    while inFlight > 0 do
        sleep(0.05)
    end

    return {
        statusByAnchorKey = statusByAnchorKey,
        responseByAnchorKey = responseByAnchorKey,
        peakConcurrency = peakInFlight,   -- max in-flight observed; compare to maxConcurrency
    }
end

return M
