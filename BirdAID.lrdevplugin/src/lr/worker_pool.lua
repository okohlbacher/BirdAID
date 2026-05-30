-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/worker_pool.lua (Phase 9 — BL-06 cooperative worker-pool driver)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the Lightroom SDK
-- (LrTasks, LrDate). It is NOT a pure module and is intentionally EXCLUDED from the negative-purity
-- grep gate (which scopes only the pure src/ modules). It is loaded only by an entry point AFTER
-- birdaid_bootstrap.lua has installed the require shim. ALL the dispatch/drain/cancel/deferred
-- LOGIC is PURE and proven in src.net.pool (pool_spec); this layer is a thin cooperative DRIVER
-- over that controller — N startAsyncTask workers pulling dispatchable items, a per-provider-call
-- token take, an after-token breaker gate, and the provider HTTP call.
--
-- *** YIELD-SAFE BODY PINNING (CRITICAL — resolves the yield-in-pcall blocker) ***
-- The ENTIRE per-item worker body (the per-call token take's LrTasks.sleep on a deny, the provider
-- HTTP call via identify -> LrHttp.post, the provider's own backoff sleeps, and the optional crop
-- re-query) runs INSIDE the injected yield-safe LrTasks.pcall — NEVER a standard C pcall, because
-- those calls YIELD across a C-frame and Lua 5.1 forbids yielding across a standard pcall boundary.
-- The pool's OWN LrTasks.sleep / LrTasks.yield / LrProgressScope updates run on the task ITSELF,
-- NOT wrapped in any pcall. NO yielding Lr call is ever inside a standard pcall.
--
-- *** BREAKER OWNERSHIP (resolves the double-ownership blocker) ***
-- identify IS the PROVIDER call; the PROVIDER already records deps.breaker.record('ok'|'fatal'|
-- 'exhausted') internally and, on exhaustion, returns a VALIDATED degrade (response, nil) — NOT an
-- error. Therefore worker_pool and pool MUST NOT call breaker.record AT ALL. The pool READS
-- breaker.shouldStop() to halt NEW dispatch; the worker READS shouldStop() once MORE — AFTER token
-- acquisition, immediately before EACH provider call — and DEFERS (never identifies) when open.
--
-- *** PER-PROVIDER-CALL ORDERING (BLOCKER D + C — TOKEN FIRST, THEN shouldStop, THEN call) ***
-- The breaker can latch DURING the token wait (bucket.take may LrTasks.sleep up to 1/rate), so the
-- worker's exact per-provider-call sequence (for the preview identify AND for EVERY crop re-query) is:
--   (1) TAKE A TOKEN: loop { ok,wait = bucket.take(now()); if ok break else LrTasks.sleep(wait) }
--       — acquire ONE token first (capacity=1, no bursting) so each provider call costs one token
--       and the AGGREGATE provider-call rate (incl. crop re-queries) honors rateLimit.
--   (2) THEN RE-READ breaker.shouldStop() immediately before identify. If OPEN -> do NOT call;
--       this is a DEFERRED provider call (the body raises a sentinel so the worker classifies the
--       whole item 'deferred'). A token already taken is harmless (it just paces the next call).
--   (3) ONLY when shouldStop() is CLOSED at this after-token point does the worker call identify.
-- This places the gate AFTER token acquisition, immediately before each provider call, so a breaker
-- that latches WHILE a worker sleeps in the token wait still defers that worker (never reaches the
-- provider). A breaker-induced degrade is NEVER classified 'identified'.
--
-- *** RETURN CONTRACT (BLOCKER A — the orchestrator consumes this VALUE) ***
-- M.run(opts) RETURNS { statusByAnchorKey = pool.terminalStatus(),
--                       responseByAnchorKey = <table built from each 'identified' anchor's response> }.
-- responseByAnchorKey holds an entry ONLY for an item whose terminal status is 'identified' (a
-- (response,nil) observed AFTER a CLOSED pre-call breaker gate). The pool instance is LOCAL to run()
-- — there is NO pool-handle method exposed to the orchestrator; the structured table is the entire
-- contract. The orchestrator feeds both maps into results.build.
--
-- *** THUNDERING-HERD BOUND (accepted + bounded) ***
-- in-flight is capped at maxConcurrency, and because the bucket (capacity=1) is consumed PER
-- PROVIDER CALL, even the initial fan-out is paced at 1 call per 1/rate sec when rateLimit>0. Once
-- the provider records a fatal/exhausted and the breaker latches, the after-token shouldStop gate
-- fires ZERO further provider calls (in-flight workers that have not yet reached their gate defer
-- instead of calling) — so the dead-provider burst is bounded by maxConcurrency, then zero.
--
-- *** LIVE-UNVERIFIED ASSUMPTION (A-PARALLEL) ***
-- That N startAsyncTask workers each calling LrHttp.post truly OVERLAP on the network under LrC's
-- cooperative scheduler (BL-06 spike question) AND that the LrTasks.execute serialization noted in
-- the BL-04 spike does NOT apply to LrHttp.post — confirmed live in Task 12.
--
-- PII / NO-LEAK: token-free logging only; NEVER the token/body/data-URI/path/gps/date.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global. MUST run
-- inside an LrTasks-capable context (it spawns startAsyncTask workers).

local LrTasks = import 'LrTasks'

-- LrDate is the preferred wall-clock source for the token bucket (real time during LrTasks.sleep).
-- Import defensively; fall back to os.time() if unavailable. NEVER os.clock (CPU time).
local LrDate
pcall(function() LrDate = import 'LrDate' end)

local poolMod = require 'src.net.pool'
local log     = require 'src.log'

local M = {}

-- A sentinel error value that the worker body raises when the after-token breaker gate finds the
-- breaker OPEN. It is a TABLE (not a string) so it can never collide with a real provider error
-- string, and the worker classifies it as 'deferred' (NEVER 'fatal'/'identified').
local DEFERRED_SENTINEL = { deferred = true }

-- A sentinel the worker body raises when, AFTER the token wait, cooperative cancel is observed
-- immediately before the provider call. It is a TABLE so it can never collide with a real provider
-- error string. The worker classifies it as 'cancelled' (the provider is NEVER called); the pool
-- controller resolves the item 'cancelled' and its cluster-followers cancel via the results join.
local CANCELLED_SENTINEL = { cancelled = true }

-- wallClockSeconds() -> a monotonically-advancing real-time seconds value (NOT CPU time).
local function wallClockSeconds()
    if LrDate and LrDate.currentTime then
        local ok, t = pcall(LrDate.currentTime)
        if ok and type(t) == 'number' and t == t then return t end
    end
    return os.time()
end

-- safeCanceled(isCanceled) -> bool. An absent/throwing isCanceled() must never crash a worker.
local function safeCanceled(isCanceled)
    if type(isCanceled) ~= 'function' then return false end
    local ok, c = pcall(isCanceled)
    return (ok and c) or false
end

-- acquireToken(bucket, sleep): take ONE token, sleeping (on the TASK, not in a pcall) until granted.
-- A nil bucket (no rate limiter) is treated as unlimited. Returns nothing; it blocks the worker
-- cooperatively until a token is in hand. The CALLER invokes this INSIDE the yield-safe pcall body
-- (LrTasks.sleep yields), so the sleep is pinned correctly.
local function acquireToken(bucket, sleep)
    if type(bucket) ~= 'table' or type(bucket.take) ~= 'function' then
        return                                   -- no bucket -> unlimited, no token cost.
    end
    while true do
        local ok, wait = bucket.take(wallClockSeconds())
        if ok then return end
        -- Not enough tokens: sleep the reported wait (>=0). Guard a bad/absent wait with a small
        -- floor so we always yield and re-check (never a busy spin).
        local w = tonumber(wait)
        if type(w) ~= 'number' or w ~= w or w < 0 then w = 0 end
        if w < 0.001 then w = 0.001 end
        sleep(w)
    end
end

-- breakerOpen(breaker) -> bool. READ-ONLY shouldStop; never records.
local function breakerOpen(breaker)
    return type(breaker) == 'table'
        and type(breaker.shouldStop) == 'function'
        and breaker.shouldStop() == true
end

-- M.run(opts) — see the RETURN CONTRACT in the header.
-- opts = {
--   items          = { <anchorKey>, ... },          -- the work items (anchors) to dispatch.
--   maxConcurrency = <int>,                          -- N cooperative workers.
--   bucket         = <token_bucket, capacity=1>,     -- shared GLOBAL rate limiter (per-call).
--   breaker        = <breaker, READ-ONLY here>,      -- provider records; pool+worker READ shouldStop.
--   identifyFn     = function(item) -> (response|nil, err),  -- the PROVIDER call for this item
--                     -- (the orchestrator closes over the preview fetch + provider.identify + the
--                     -- optional crop re-query; EACH provider call inside it is itself token+gated
--                     -- by the orchestrator's identify closure OR — for the single-call case — by
--                     -- this driver's per-call token+gate around identifyFn). See note below.
--   onCollect      = function(item, response, err) end,      -- stores OUTSIDE any write gate (opt).
--   progress       = <LrProgressScope|nil>,          -- advanced once per resolved item (opt).
--   isCanceled     = function() -> bool,             -- cooperative cancel (opt).
--   pcall          = <LrTasks.pcall>,                -- the YIELD-SAFE protected call (REQUIRED for
--                     -- a yielding identifyFn; defaults to LrTasks.pcall).
--   log fields...                                    -- runId etc. for token-free logging.
-- }
--
-- NOTE ON THE PER-CALL TOKEN+GATE: this driver applies the (1)->(3) token+gate sequence around the
-- identifyFn call IT makes. When identifyFn internally makes MULTIPLE provider calls (the preview
-- identify + crop re-queries), the orchestrator MUST thread the SAME bucket+breaker into identifyFn
-- so each inner provider call also takes a token + re-checks shouldStop before it (the orchestrator
-- builds identifyFn to do exactly that). The driver guarantees the gate for the FIRST/outermost
-- provider call; the orchestrator's identifyFn guarantees it for each subsequent crop call. Both
-- honor the SAME shared bucket+breaker so the aggregate rate + the pre-call defer hold end to end.
function M.run(opts)
    opts = type(opts) == 'table' and opts or {}
    local items          = type(opts.items) == 'table' and opts.items or {}
    local maxConcurrency = opts.maxConcurrency
    local bucket         = opts.bucket
    local breaker        = opts.breaker
    local identifyFn     = type(opts.identifyFn) == 'function' and opts.identifyFn or function() return nil, 'no-identify' end
    local onCollect      = type(opts.onCollect) == 'function' and opts.onCollect or function() end
    local progress       = opts.progress
    local isCanceled     = opts.isCanceled
    -- YIELD-SAFE protected call (REQUIRED for a yielding identifyFn). Defaults to LrTasks.pcall.
    local ypcall         = type(opts.pcall) == 'function' and opts.pcall or LrTasks.pcall
    local runId          = opts.runId

    local pool = poolMod.new({
        items          = items,
        maxConcurrency = maxConcurrency,
        bucket         = bucket,
        breaker        = breaker,
    })

    -- responseByAnchorKey is built from each 'identified' anchor's collected response. Keyed by item.
    local responseByAnchorKey = {}

    -- advance the shared progress scope once per resolved item (single-threaded cooperative; no lock).
    -- POOL-OWNED Lr CALL: setPortionComplete runs DIRECTLY on the worker's task (NOT inside a standard
    -- pcall — that would be the yield-across-C-pcall hazard for a pool-owned Lr call). It does not yield,
    -- but we wrap it in the INJECTED yield-safe pcall (ypcall) as a defensive guard so an absent/throwing
    -- method can never crash the worker (NEVER a standard pcall for a pool-owned Lr call).
    local total = #items
    local resolved = 0
    local function advanceProgress()
        resolved = resolved + 1
        if progress and progress.setPortionComplete then
            ypcall(function() progress:setPortionComplete(resolved, total) end)
        end
    end

    -- ---- one worker's per-item body (runs INSIDE the yield-safe pcall) -------------------------
    -- Returns (response, err); RAISES CANCELLED_SENTINEL when cancel is observed after the token wait,
    -- or DEFERRED_SENTINEL when the after-token breaker gate is open. ORDER (BLOCKER C + B):
    --   acquireToken -> (isCanceled? -> cancelled) -> (shouldStop? -> deferred) -> else identifyFn.
    local function workerBody(item)
        -- (1) TAKE A TOKEN (per-provider-call cost). LrTasks.sleep yields — pinned inside ypcall.
        --     bucket.take itself may LrTasks.sleep up to 1/rate, so cancel/breaker may flip DURING it.
        acquireToken(bucket, LrTasks.sleep)
        -- (2a) AFTER-TOKEN CANCEL GATE (BLOCKER B): re-check cooperative cancel IMMEDIATELY before the
        -- provider call. A worker can sleep waiting for a token while cancel happens mid-wait; without
        -- this re-check it would pass the breaker gate and still call the provider. If cancelled now,
        -- do NOT call the provider — raise the cancelled sentinel so the worker classifies the item
        -- 'cancelled' (its followers cancel via the results join). A token already taken just paces.
        if safeCanceled(isCanceled) then
            error(CANCELLED_SENTINEL)
        end
        -- (2b) AFTER-TOKEN BREAKER GATE: re-read shouldStop immediately before the provider call. If
        -- open, do NOT call the provider — raise the deferred sentinel so the worker classifies the
        -- item 'deferred' (NEVER 'identified', even though the provider would return a valid degrade).
        if breakerOpen(breaker) then
            error(DEFERRED_SENTINEL)
        end
        -- (3) CALL THE PROVIDER. identifyFn closes over the preview fetch + provider.identify (+ any
        -- crop re-query, each of which takes its OWN token + re-checks cancel + shouldStop via the
        -- shared isCanceled/bucket/breaker the orchestrator threaded in).
        return identifyFn(item)
    end

    -- classify a worker body's outcome into a pool terminal status + the collected (response,err).
    -- ok=false + err==CANCELLED_SENTINEL -> 'cancelled' (cancel observed after the token wait, before
    -- the provider call); ok=false + err==DEFERRED_SENTINEL -> 'deferred'; ok=false (any other err) ->
    -- 'fatal' (an isolated per-item failure, never aborts the run); ok=true + response -> 'identified';
    -- ok=true + (nil,err) -> 'fatal'. Only 'identified' carries a response into responseByAnchorKey.
    local function classify(item, ok, a, b)
        if not ok then
            -- a is the raised error (a sentinel table OR an error string/object).
            if a == CANCELLED_SENTINEL then
                return 'cancelled', nil, nil
            end
            if a == DEFERRED_SENTINEL then
                return 'deferred', nil, nil
            end
            log.warn("worker body failed (isolated; item deferred-as-fatal; run continues)", {
                runId = runId, error = tostring(a),
            })
            return 'fatal', nil, tostring(a)
        end
        -- ok: a = response|nil, b = err.
        local response, err = a, b
        if response ~= nil and err == nil then
            return 'identified', response, nil
        end
        return 'fatal', nil, (err ~= nil and tostring(err) or 'identify-failed')
    end

    -- ---- spawn up to maxConcurrency cooperative workers ---------------------------------------
    -- A worker LOOPS: pool.nextDispatch -> dispatch (run the yield-safe body) | wait | idle | done.
    -- The pool's own sleep/yield/progress run on the TASK, never inside a pcall.
    local activeWorkers = 0
    local allDone = false

    local function spawnWorker()
        activeWorkers = activeWorkers + 1
        LrTasks.startAsyncTask(function()
            while true do
                -- Cancel check (cooperative): flip the pool to cancel so new dispatch stops + drains.
                if safeCanceled(isCanceled) then
                    pool.cancel()
                end

                local d = pool.nextDispatch(wallClockSeconds())
                local action = d.action

                if action == 'dispatch' then
                    local item = d.key
                    -- RUN THE ENTIRE YIELDING BODY INSIDE THE YIELD-SAFE pcall (never a bare pcall).
                    local ok, a, b = ypcall(function() return workerBody(item) end)
                    local status, response = classify(item, ok, a, b)
                    -- Record the terminal outcome into the PURE controller (frees the slot).
                    pool.onResult(item, status)
                    if status == 'identified' and response ~= nil then
                        responseByAnchorKey[item] = response
                    end
                    -- Collect OUTSIDE any write gate (the orchestrator writes once at the end).
                    pcall(function()
                        if status == 'identified' then
                            onCollect(item, response, nil)
                        elseif status == 'fatal' then
                            onCollect(item, nil, b)
                        else
                            onCollect(item, nil, nil)   -- deferred/cancelled: no response, no error.
                        end
                    end)
                    advanceProgress()
                    -- loop immediately (pull the next dispatchable item).

                elseif action == 'wait' then
                    -- a token/slot is not free per the pure controller (production paces at the
                    -- provider call, but honor a 'wait' for completeness). Sleep on the task.
                    local secs = tonumber(d.seconds) or 0.01
                    if secs < 0 or secs ~= secs then secs = 0.01 end
                    LrTasks.sleep(secs)

                elseif action == 'idle' then
                    -- no free slot but items remain in flight -> yield to other workers.
                    LrTasks.yield()

                else  -- 'done': all items terminal. Exit this worker.
                    break
                end
            end

            activeWorkers = activeWorkers - 1
            if activeWorkers <= 0 then
                allDone = true
            end
        end)
    end

    -- How many workers to spawn: min(maxConcurrency, #items), at least 1 (so an empty item list
    -- still spawns one worker that immediately sees 'done'). The pool itself floors/clamps the
    -- concurrency cap defensively.
    local nWorkers = math.floor(tonumber(maxConcurrency) or 1)
    if nWorkers ~= nWorkers or nWorkers < 1 then nWorkers = 1 end   -- NaN/sub-1 guard.
    if nWorkers > total and total > 0 then nWorkers = total end
    if total == 0 then nWorkers = 1 end

    for _ = 1, nWorkers do
        spawnWorker()
    end

    -- M.run blocks (cooperatively) until ALL workers reach 'done'. This call runs on its own task
    -- (the orchestrator invokes M.run inside an async task), so yielding here is correct + safe.
    while not allDone do
        LrTasks.yield()
    end

    return {
        statusByAnchorKey   = pool.terminalStatus(),
        responseByAnchorKey = responseByAnchorKey,
    }
end

return M
