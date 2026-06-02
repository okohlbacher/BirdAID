-- test/run_state_spec.lua (12-02 Task 1 — PURE run-state OUTCOME shape)
--
-- Exercises BirdAID.lrdevplugin/src/run_state.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. It owns the per-photo TERMINAL-OUTCOME
-- taxonomy (the split between do-not-retry and retryable outcomes), a secret-free serialize /
-- deserialize of the { photoId, outcome } shape, and the SINGLE source-of-truth classifier
-- M.outcomeFor that maps (status, birdPresent, detectionCount, wroteCount) -> outcome.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local run_state = require('src.run_state')

assert_true(type(run_state) == 'table', "require 'src.run_state' resolves")
assert_true(type(run_state.OUTCOMES) == 'table', "exposes OUTCOMES table")
assert_true(type(run_state.isTerminal) == 'function', "exposes isTerminal")
assert_true(type(run_state.isRetryable) == 'function', "exposes isRetryable")
assert_true(type(run_state.serialize) == 'function', "exposes serialize")
assert_true(type(run_state.deserialize) == 'function', "exposes deserialize")
assert_true(type(run_state.outcomeFor) == 'function', "exposes outcomeFor")

-- =====================================================================
-- The TERMINAL / RETRYABLE split (CODEX HIGH-3): done-ness is the OUTCOME, not a `wrote` boolean.
-- =====================================================================
do
    -- TERMINAL (do not retry).
    assert_true(run_state.isTerminal('written') == true, "written is terminal")
    assert_true(run_state.isTerminal('existing') == true, "existing is terminal")
    assert_true(run_state.isTerminal('no-bird') == true, "no-bird is terminal")
    assert_true(run_state.isTerminal('no-detection') == true, "no-detection is terminal")

    -- RETRYABLE.
    assert_true(run_state.isTerminal('deferred') == false, "deferred is NOT terminal")
    assert_true(run_state.isTerminal('timed-out') == false, "timed-out is NOT terminal")
    assert_true(run_state.isTerminal('errored') == false, "errored is NOT terminal")
    assert_true(run_state.isTerminal('cancelled') == false, "cancelled is NOT terminal")

    -- isRetryable is the mirror for KNOWN outcomes.
    assert_true(run_state.isRetryable('deferred') == true, "deferred is retryable")
    assert_true(run_state.isRetryable('written') == false, "written is NOT retryable")

    -- An UNKNOWN / nil outcome is NOT terminal (so it is retried — safe).
    assert_true(run_state.isTerminal('bogus') == false, "unknown outcome is NOT terminal (retry safe)")
    assert_true(run_state.isTerminal(nil) == false, "nil outcome is NOT terminal (retry safe)")
end

-- =====================================================================
-- serialize projects each record to EXACTLY { photoId, outcome } — no secret/PII/extra field
-- (token / response / raw status / gps / path) survives. (T-12-05)
-- =====================================================================
do
    local records = {
        { photoId = 'p1', outcome = 'written', response = { detections = {} },
          token = 'sk-SECRET', status = 'identified', gps = { latitude = 1 }, path = '/Users/x/a.jpg' },
        { photoId = 'p2', outcome = 'deferred' },
    }
    local ser = run_state.serialize(records)
    assert_true(type(ser) == 'table', "serialize returns a table")
    assert_eq(#ser, 2, "serialize keeps both records")
    assert_eq(ser[1].photoId, 'p1', "photoId preserved")
    assert_eq(ser[1].outcome, 'written', "outcome preserved")
    -- secret / extra fields must NOT survive.
    assert_true(ser[1].response == nil, "response dropped")
    assert_true(ser[1].token == nil, "token dropped (no secret leak)")
    assert_true(ser[1].status == nil, "raw status dropped")
    assert_true(ser[1].gps == nil, "gps dropped (no PII)")
    assert_true(ser[1].path == nil, "path dropped (no PII)")
    -- count keys on the serialized record: exactly photoId + outcome.
    local nkeys = 0
    for _ in pairs(ser[1]) do nkeys = nkeys + 1 end
    assert_eq(nkeys, 2, "serialized record has EXACTLY 2 fields (photoId, outcome)")
end

-- =====================================================================
-- round-trip: deserialize(serialize(x)) is field-equivalent for valid input.
-- =====================================================================
do
    local records = {
        { photoId = 'a', outcome = 'existing' },
        { photoId = 'b', outcome = 'no-bird' },
        { photoId = 'c', outcome = 'errored' },
    }
    local round = run_state.deserialize(run_state.serialize(records))
    assert_eq(#round, 3, "round-trip preserves count")
    for i = 1, 3 do
        assert_eq(round[i].photoId, records[i].photoId, "round-trip photoId[" .. i .. "]")
        assert_eq(round[i].outcome, records[i].outcome, "round-trip outcome[" .. i .. "]")
    end
end

-- =====================================================================
-- deserialize defensively drops malformed records (unknown outcome / non-string photoId)
-- and degrades nil / non-table input to {} without raising.
-- =====================================================================
do
    assert_eq(#run_state.deserialize(nil), 0, "deserialize(nil) -> {}")
    assert_eq(#run_state.deserialize('garbage'), 0, "deserialize(non-table) -> {}")
    assert_eq(#run_state.deserialize({}), 0, "deserialize({}) -> {}")

    local mixed = {
        { photoId = 'ok', outcome = 'written' },     -- kept
        { photoId = '', outcome = 'written' },        -- dropped (empty id)
        { photoId = 12, outcome = 'written' },        -- dropped (non-string id)
        { photoId = 'bad', outcome = 'totally-unknown' }, -- dropped (unknown outcome)
        { outcome = 'deferred' },                     -- dropped (missing id)
        { photoId = 'ok2', outcome = 'deferred' },    -- kept
    }
    local out = run_state.deserialize(mixed)
    assert_eq(#out, 2, "deserialize keeps only the 2 valid records")
    assert_eq(out[1].photoId, 'ok', "first kept id")
    assert_eq(out[2].photoId, 'ok2', "second kept id")
end

-- =====================================================================
-- serialize also drops malformed records (defensive on the way in).
-- =====================================================================
do
    local out = run_state.serialize({
        { photoId = 'good', outcome = 'written' },
        { photoId = '', outcome = 'written' },
        { photoId = 'bad', outcome = 'nope' },
    })
    assert_eq(#out, 1, "serialize drops empty-id and unknown-outcome records")
    assert_eq(out[1].photoId, 'good', "kept the valid record")
end

-- =====================================================================
-- outcomeFor: the SINGLE source-of-truth classifier (CODEX HIGH-3 / warning-5). Table-driven.
-- Every returned non-nil value is a known OUTCOME.
-- =====================================================================
do
    local cases = {
        -- status, birdPresent, detectionCount, wroteCount  ->  expected
        { { status = 'identified', birdPresent = true, detectionCount = 2, wroteCount = 1 }, 'written' },
        { { status = 'identified', birdPresent = true, detectionCount = 2, wroteCount = 0 }, 'existing' },
        { { status = 'identified', birdPresent = false, detectionCount = 0, wroteCount = 0 }, 'no-bird' },
        { { status = 'identified', birdPresent = true, detectionCount = 0, wroteCount = 0 }, 'no-detection' },
        { { status = 'deferred' }, 'deferred' },
        { { status = 'cancelled' }, 'cancelled' },
        { { status = 'errored' }, 'errored' },
        { { status = 'timed-out' }, 'timed-out' },
        { { status = 'mystery' }, nil },
        { { status = nil }, nil },
        { {}, nil },
    }
    for i = 1, #cases do
        local args, want = cases[i][1], cases[i][2]
        local got = run_state.outcomeFor(args)
        assert_eq(got, want, "outcomeFor case " .. i)
        if got ~= nil then
            assert_true(run_state.OUTCOMES[got] ~= nil, "outcomeFor non-nil result is a known OUTCOME (case " .. i .. ")")
        end
    end

    -- birdPresent=false takes precedence: even with detections present, no-bird wins.
    assert_eq(run_state.outcomeFor({ status = 'identified', birdPresent = false, detectionCount = 3, wroteCount = 0 }),
        'no-bird', "birdPresent=false -> no-bird even with detections")
end
