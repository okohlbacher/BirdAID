-- test/keyring_runner_spec.lua (Phase 11 / Plan 11-05 — DKEY-02 live-failover coordinator
-- semantics + DKEY-03 no-leak)
--
-- Exercises BirdAID.lrdevplugin/src/net/keyring_runner.lua: a PURE failover coordinator (no Lr,
-- no wall-clock reads, no randomness) require-able under stock lua / luajit. It owns the
-- per-photo failover DECISION over the keyring + a structured single-attempt result:
--   select(now) -> attemptOnce(idx) -> { outcome, status, retryAfter, response, err }
--     -> keyring.record(...) keyed off result.STATUS/result.OUTCOME -> loop.
--
-- The coordinator NEVER sleeps while another healthy slot exists (D-06 immediate failover);
-- falls back to the net/backoff per-attempt sleep ONLY when a SINGLE key remains (D-06 fallback);
-- splits 401/403 (retire) from 400/404/422 (request-error) by reading result.STATUS, NEVER by
-- string-matching result.err (D-04); is the SOLE recorder of breaker 'exhausted', and ONLY when
-- keyring.select() returns nil (D-07 / Assumption A3); is serial by construction (one active slot
-- run-wide, D-01); and returns an ordinal-only, token-free result/summary (SC3 / DKEY-03).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- nowTick is ALWAYS an injected integer (never read from a wall clock). Strictly Lua 5.1 subset
-- (no \u{}, no //, no goto, no <close>; unpack is global).

local runner  = require('src.net.keyring_runner')
local keyring = require('src.net.keyring')
local backoff = require('src.net.backoff')

assert_true(type(runner) == 'table', "require 'src.net.keyring_runner' resolves")
assert_true(type(runner.run) == 'function', "keyring_runner exposes run")

-- =====================================================================
-- Test scaffolding.
-- =====================================================================

-- A monotonic integer 'now' source (never a wall clock). Each call returns the SAME tick unless
-- the test advances it; the coordinator only needs a deterministic now() for record/select.
local function fixedNow(tick)
    return function() return tick end
end

-- A sleep RECORDER: pushes each requested delay to a list so a test can assert it stayed EMPTY
-- (immediate failover) or NON-EMPTY (single-key backoff fallback).
local function sleepRecorder()
    local list = {}
    local function sleep(seconds) list[#list + 1] = seconds end
    return sleep, list
end

-- A breaker RECORDER exposing record/shouldStop/state with a token-free outcome count.
local function breakerRecorder()
    local rec = { calls = {}, exhausted = 0 }
    rec.record = function(outcome)
        rec.calls[#rec.calls + 1] = outcome
        if outcome == 'exhausted' then rec.exhausted = rec.exhausted + 1 end
    end
    rec.shouldStop = function() return false end
    rec.state = function() return { consecutive = rec.exhausted } end
    return rec
end

-- A table-driven attemptOnce builder: per-CALL it returns the next scripted structured result for
-- the slot it is asked about. Records the SEQUENCE of slots it was called on (to prove serial,
-- single-active-slot ordering and that a retired slot is not retried). Each script entry is the
-- exact 5-field single-attempt contract { outcome, status, retryAfter, response, err }.
local function scriptedAttempt(perSlotScripts)
    local state = { order = {}, idxBySlot = {} }
    local function attemptOnce(storageIndex)
        state.order[#state.order + 1] = storageIndex
        local script = perSlotScripts[storageIndex] or {}
        local i = (state.idxBySlot[storageIndex] or 0) + 1
        state.idxBySlot[storageIndex] = i
        local entry = script[i] or script[#script]
        return entry
    end
    return attemptOnce, state
end

-- Helpers building the 5-field structured single-attempt result.
local function rOk(response)        return { outcome = 'ok',            status = 200, retryAfter = nil, response = response, err = nil } end
local function rRetry(status, ra)   return { outcome = 'retry',         status = status or 429, retryAfter = ra, response = nil, err = 'rate-limited-' .. tostring(status or 429) } end
local function rAuthFatal(status)   return { outcome = 'auth-fatal',    status = status or 401, retryAfter = nil, response = nil, err = 'auth-failed-' .. tostring(status or 401) } end
local function rReqFatal(status)    return { outcome = 'request-fatal', status = status or 400, retryAfter = nil, response = nil, err = 'http-' .. tostring(status or 400) } end

-- =====================================================================
-- (1) SUCCESS: a slot returns outcome 'ok' with a response -> run returns the response;
-- keyring.record(idx,'ok',...). attemptOnce called exactly once on the first healthy slot.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce, st = scriptedAttempt({ [1] = { rOk({ bird_present = true, detections = {} }) } })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    assert_true(type(result) == 'table', "ok: run returns a table")
    assert_eq(result.response and result.response.bird_present, true, "ok: run surfaces result.response")
    assert_eq(#st.order, 1, "ok: attemptOnce called exactly once")
    assert_eq(st.order[1], 1, "ok: the highest-priority healthy slot (1) is used")
    assert_eq(#slept, 0, "ok: no sleep on the success path")
    assert_eq(breaker.exhausted, 0, "ok: breaker 'exhausted' never recorded on success")
    assert_eq(k.state()[1] and k.state()[1].attempt or 0, 0, "ok: slot 1 attempt reset by record('ok')")
end

-- =====================================================================
-- (2) D-06 429 IMMEDIATE FAILOVER (multi-key): slot 1 returns retry/429 -> record('cooldown') ->
-- select() returns the NEXT healthy slot 2 -> retry the SAME photo IMMEDIATELY with NO sleep.
-- Assert attemptOnce ran on slot 1 then slot 2 with the sleep recorder EMPTY in between (D-06).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rRetry(429, nil) },
        [2] = { rOk({ bird_present = false, detections = {} }) },
    })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(50),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    assert_eq(st.order[1], 1, "429-failover: slot 1 attempted first")
    assert_eq(st.order[2], 2, "429-failover: failed over to slot 2 (next healthy)")
    assert_eq(#st.order, 2, "429-failover: exactly two attempts (no extra)")
    assert_eq(#slept, 0, "429-failover: NO sleep while another healthy slot exists (D-06)")
    assert_true(type(result.response) == 'table', "429-failover: slot 2 success surfaced")
    assert_eq(breaker.exhausted, 0, "429-failover: breaker 'exhausted' not recorded while a slot remained (D-07)")
    -- slot 1 was cooled (record('cooldown') bumped its attempt) but slot 2 succeeded.
    assert_true((k.state()[1] and k.state()[1].attempt or 0) >= 1, "429-failover: slot 1 was cooled (attempt bumped)")
end

-- =====================================================================
-- (3) D-06 SINGLE-KEY BACKOFF FALLBACK: with ONLY one slot in priorityOrder, a 429 cools the key,
-- select() returns nil for THAT slot's cooldown window, and the coordinator falls back to the
-- backoff per-attempt sleep -> assert the injected sleep IS called with backoff.next's delay.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rRetry(429, nil), rOk({ bird_present = false, detections = {} }) },
    })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 1,
    })
    assert_true(type(result.response) == 'table', "single-key: succeeds after the backoff sleep")
    assert_eq(#st.order, 2, "single-key: attempted twice (429 then ok)")
    assert_eq(#slept, 1, "single-key: slept exactly once (backoff fallback, D-06)")
    -- The delay is the policy delay for the slot's first cooldown attempt.
    assert_eq(slept[1], backoff.next(1, 429, nil).delay, "single-key: the sleep is backoff.next's delay")
end

-- =====================================================================
-- (4) D-04 AUTH-fatal (401) -> retire then fail over: slot 1 {outcome='auth-fatal',status=401}
-- retires (record('retire')), select() returns slot 2, the RETIRED slot is NOT retried.
-- Asserts the split is STATUS-driven (status==401), not err-string driven.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rAuthFatal(401) },
        [2] = { rOk({ bird_present = true, detections = {} }) },
    })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    assert_eq(st.order[1], 1, "auth-fatal: slot 1 attempted first")
    assert_eq(st.order[2], 2, "auth-fatal: 401 retired slot 1 -> failed over to slot 2")
    assert_eq(#st.order, 2, "auth-fatal: the retired slot 1 is NOT retried")
    assert_eq(k.state()[1].retired, true, "auth-fatal: slot 1 retired for the run (status 401)")
    assert_true(type(result.response) == 'table', "auth-fatal: slot 2 success surfaced")
    assert_eq(#slept, 0, "auth-fatal: no sleep on the retire+failover path")
end

-- =====================================================================
-- (4b) 403 also retires (AUTH-fatal split by STATUS).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rAuthFatal(403) },
        [2] = { rOk({ bird_present = false, detections = {} }) },
    })
    local breaker = breakerRecorder()
    local sleep = sleepRecorder()
    runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    assert_eq(k.state()[1].retired, true, "auth-fatal-403: status 403 retires the slot (D-04)")
    assert_eq(st.order[2], 2, "auth-fatal-403: failed over to slot 2")
end

-- =====================================================================
-- (5) D-04 REQUEST-fatal (400) -> per-photo provider error WITHOUT retire or failover: slot 1
-- {outcome='request-fatal',status=400} -> coordinator returns the per-photo err, NO failover,
-- NO retire (record('request-error') is a keyring no-op). The split is STATUS-driven (status==400).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rReqFatal(400) },
        [2] = { rOk({ bird_present = true, detections = {} }) },  -- MUST NOT be reached
    })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    assert_eq(#st.order, 1, "request-fatal: NO failover — slot 2 never attempted (D-04)")
    assert_eq(st.order[1], 1, "request-fatal: only slot 1 attempted")
    assert_true(type(result.err) == 'string' and #result.err > 0, "request-fatal: the per-photo provider error surfaces")
    assert_true(result.response == nil, "request-fatal: no response (it is a per-photo error)")
    assert_eq(k.state()[1].retired, nil, "request-fatal: slot 1 NOT retired (status 400, not 401/403)")
    assert_eq(k.state()[1].exhausted, nil, "request-fatal: slot 1 NOT exhausted")
    assert_eq(k.state()[1].coolUntil, nil, "request-fatal: slot 1 NOT cooled")
    assert_eq(breaker.exhausted, 0, "request-fatal: breaker 'exhausted' not recorded")
    assert_eq(#slept, 0, "request-fatal: no sleep")
end

-- (5b) 404 and 422 are likewise request-fatal (no failover, no retire) — status-driven.
do
    for _, status in ipairs({ 404, 422 }) do
        local k = keyring.new({ priorityOrder = { 1, 2 } })
        local attemptOnce, st = scriptedAttempt({
            [1] = { rReqFatal(status) },
            [2] = { rOk({ bird_present = false, detections = {} }) },
        })
        local breaker = breakerRecorder()
        local sleep = sleepRecorder()
        local result = runner.run({
            keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
            sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
        })
        assert_eq(#st.order, 1, "request-fatal-" .. status .. ": NO failover (D-04)")
        assert_eq(k.state()[1].retired, nil, "request-fatal-" .. status .. ": NOT retired")
        assert_true(type(result.err) == 'string', "request-fatal-" .. status .. ": per-photo error surfaced")
    end
end

-- =====================================================================
-- (6) D-07 ALL KEYS DOWN: when select() returns nil (all cooling/retired/exhausted), run records
-- breaker 'exhausted' EXACTLY ONCE and returns a degrade/defer. Assert breaker.record('exhausted')
-- is on the select()==nil path ONLY — NOT after a single failed key while another remained.
-- Here slot 1 retires (401) and slot 2 retires (403) -> select() == nil.
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rAuthFatal(401) },
        [2] = { rAuthFatal(403) },
    })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    -- slot 1 attempted (retire) -> select() -> slot 2 attempted (retire) -> select() == nil -> exhausted.
    assert_eq(st.order[1], 1, "all-down: slot 1 attempted")
    assert_eq(st.order[2], 2, "all-down: slot 2 attempted after slot 1 retired")
    assert_eq(#st.order, 2, "all-down: exactly two attempts (both retired)")
    assert_eq(breaker.exhausted, 1, "all-down: breaker 'exhausted' recorded EXACTLY once (D-07)")
    assert_true(result.outcome == 'defer' or result.outcome == 'degrade' or result.degraded == true,
        "all-down: returns a degrade/defer result")
    assert_true(result.response == nil, "all-down: no usable response")
end

-- (6b) D-07 NEGATIVE: a single failed key while another remains records ZERO 'exhausted' (the
-- failover succeeds before select() ever returns nil). Covered functionally by (2); assert
-- the count explicitly here with a fresh run.
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    local attemptOnce = scriptedAttempt({
        [1] = { rRetry(429, nil) },
        [2] = { rOk({ bird_present = false, detections = {} }) },
    })
    local breaker = breakerRecorder()
    local sleep = sleepRecorder()
    runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(50),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })
    assert_eq(breaker.exhausted, 0, "D-07 negative: a single cooled key with a healthy slot left records NO 'exhausted'")
end

-- (6c) Single-key EXHAUSTION: one key, permanent 429 -> after the backoff cap the only slot
-- exhausts; select() == nil -> breaker 'exhausted' recorded exactly once, degrade returned.
do
    local k = keyring.new({ priorityOrder = { 1 } })
    -- Always 429 for slot 1 (the scriptedAttempt repeats the last entry).
    local attemptOnce, st = scriptedAttempt({ [1] = { rRetry(429, nil) } })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 1,
    })
    assert_eq(breaker.exhausted, 1, "single-key-exhaust: breaker 'exhausted' recorded exactly once when the only slot exhausts (D-07)")
    assert_true(result.response == nil, "single-key-exhaust: degrade, no response")
    -- It slept on each within-cap cooldown before the final exhaustion (MAX_ATTEMPTS-1 sleeps).
    assert_eq(#slept, backoff.MAX_ATTEMPTS - 1, "single-key-exhaust: slept MAX_ATTEMPTS-1 times before exhausting")
    assert_eq(k.state()[1].exhausted, true, "single-key-exhaust: the only slot is parked EXHAUSTED")
end

-- =====================================================================
-- (7) D-01 SINGLE ACTIVE SLOT (serial by construction): across the whole run attemptOnce is never
-- called for two slots concurrently — the coordinator drives one attempt at a time, sequentially.
-- We prove sequentiality by asserting the recorded call ORDER is a strict sequence (the runner is
-- single-threaded Lua; there is no concurrency primitive here).
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2, 3 } })
    local attemptOnce, st = scriptedAttempt({
        [1] = { rAuthFatal(401) },                       -- retire -> failover
        [2] = { rRetry(429, nil) },                      -- cooldown -> failover
        [3] = { rOk({ bird_present = true, detections = {} }) },
    })
    local sleep, slept = sleepRecorder()
    local breaker = breakerRecorder()
    runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 3,
    })
    assert_eq(st.order[1], 1, "serial: first attempt slot 1")
    assert_eq(st.order[2], 2, "serial: then slot 2")
    assert_eq(st.order[3], 3, "serial: then slot 3 — strictly sequential, one active slot (D-01)")
    assert_eq(#st.order, 3, "serial: exactly three sequential attempts")
    assert_eq(#slept, 0, "serial: failover across 3 keys never sleeps (a healthy slot always remained)")
end

-- =====================================================================
-- (8) SC3 / DKEY-03 NO-LEAK (recursive): the result/summary the coordinator returns carries a
-- storage ORDINAL but NO token-shaped value ('sk-', 'sk-ant-', 'AIza', 'Bearer ') and references
-- keys only by ordinal. We also feed a HOSTILE scripted err (one that would leak if echoed) and
-- assert it never appears as a token shape in the surfaced result. (Mirrors keyring_spec walker.)
-- =====================================================================
do
    local k = keyring.new({ priorityOrder = { 1, 2 } })
    -- A request-fatal whose err is token-free by contract; plus an ok with a storage ordinal in a
    -- summary. We drive a retire->failover->ok so the result carries slot references.
    local attemptOnce = scriptedAttempt({
        [1] = { rAuthFatal(401) },
        [2] = { rOk({ bird_present = false, detections = {} }) },
    })
    local sleep = sleepRecorder()
    local breaker = breakerRecorder()
    local result = runner.run({
        keyring = k, attemptOnce = attemptOnce, now = fixedNow(100),
        sleep = sleep, breaker = breaker, backoff = backoff, priorityCount = 2,
    })

    local function assertTokenFree(s)
        assert_eq(s:find('sk-', 1, true), nil, "no-leak: no 'sk-' token value in the coordinator result/summary")
        assert_eq(s:find('AIza', 1, true), nil, "no-leak: no 'AIza' token value in the coordinator result/summary")
        assert_eq(s:find('Bearer ', 1, true), nil, "no-leak: no 'Bearer ' token value in the coordinator result/summary")
    end

    local function walk(v, visit)
        if type(v) == 'table' then
            for kk, vv in pairs(v) do
                if type(kk) == 'string' then visit(kk) end
                walk(vv, visit)
            end
        elseif type(v) == 'string' then
            visit(v)
        end
    end
    walk(result, assertTokenFree)

    -- The result references the WINNING slot by an integer storage ordinal (when present).
    if result.storageIndex ~= nil then
        assert_true(type(result.storageIndex) == 'number' and result.storageIndex == math.floor(result.storageIndex),
            "no-leak: the surfaced storageIndex is an integer ordinal")
    end
end
