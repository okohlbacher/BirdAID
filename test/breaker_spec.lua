-- test/breaker_spec.lua (Phase 5 — run-level circuit breaker, CODEX MUST-FIX 8)
--
-- Exercises BirdAID.lrdevplugin/src/net/breaker.lua: a PURE module (no Lr, no os.time/date/
-- clock, no math.random) require-able under stock lua / luajit. Proves the run-level circuit
-- breaker that stops further AI calls after N CONSECUTIVE retryable exhaustions so a quota
-- outage does not burn 500 photos x maxAttempts.
--
-- Behaviors asserted:
--   * threshold-1 consecutive exhaustions -> shouldStop()==false; the Nth -> true.
--   * an 'ok' in the middle RESETS the consecutive count (the count must restart).
--   * a 'fatal' RESETS the count (a config error is not a run-wide outage).
--   * once OPEN the breaker LATCHES open for the run (stays true).
--   * state() reports {consecutive, open} (token-free counts only).
--   * default threshold when opts is absent / non-number.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local breaker = require('src.net.breaker')

assert_true(type(breaker) == 'table', "require 'src.net.breaker' resolves")
assert_true(type(breaker.new) == 'function', "breaker exposes new")

-- =====================================================================
-- new(opts) returns the {record, shouldStop, state} object.
-- =====================================================================
do
    local b = breaker.new({ threshold = 3 })
    assert_true(type(b) == 'table', "new returns a table")
    assert_true(type(b.record) == 'function', "object exposes record")
    assert_true(type(b.shouldStop) == 'function', "object exposes shouldStop")
    assert_true(type(b.state) == 'function', "object exposes state")
end

-- =====================================================================
-- Opens after N CONSECUTIVE exhaustions; threshold-1 does not open.
-- =====================================================================
do
    local b = breaker.new({ threshold = 3 })
    assert_eq(b.shouldStop(), false, "fresh breaker is not open")

    b.record('exhausted')
    assert_eq(b.shouldStop(), false, "1 exhaustion (< 3) -> not open")
    assert_eq(b.state().consecutive, 1, "state reports 1 consecutive")

    b.record('exhausted')
    assert_eq(b.shouldStop(), false, "2 exhaustions (< 3) -> not open")
    assert_eq(b.state().consecutive, 2, "state reports 2 consecutive")

    b.record('exhausted')
    assert_eq(b.shouldStop(), true, "3rd consecutive exhaustion -> OPEN")
    assert_eq(b.state().open, true, "state.open is true at threshold")
    assert_eq(b.state().consecutive, 3, "state reports 3 consecutive")
end

-- =====================================================================
-- An 'ok' in the middle RESETS the consecutive count (must restart).
-- =====================================================================
do
    local b = breaker.new({ threshold = 3 })
    b.record('exhausted')
    b.record('exhausted')
    assert_eq(b.state().consecutive, 2, "2 before reset")
    b.record('ok')
    assert_eq(b.state().consecutive, 0, "ok resets consecutive to 0")
    assert_eq(b.shouldStop(), false, "still closed after reset")
    -- restart: it now takes a full 3 again to open.
    b.record('exhausted')
    b.record('exhausted')
    assert_eq(b.shouldStop(), false, "2 after reset (< 3) -> not open")
    b.record('exhausted')
    assert_eq(b.shouldStop(), true, "3 after reset -> open")
end

-- =====================================================================
-- A 'fatal' RESETS the count (config error, not a run-wide outage).
-- =====================================================================
do
    local b = breaker.new({ threshold = 2 })
    b.record('exhausted')
    assert_eq(b.state().consecutive, 1, "1 exhaustion before fatal")
    b.record('fatal')
    assert_eq(b.state().consecutive, 0, "fatal resets consecutive to 0")
    assert_eq(b.shouldStop(), false, "still closed after fatal reset")
end

-- =====================================================================
-- LATCHING: once open it stays open for the run (even an 'ok' after).
-- =====================================================================
do
    local b = breaker.new({ threshold = 2 })
    b.record('exhausted')
    b.record('exhausted')
    assert_eq(b.shouldStop(), true, "open at threshold")
    -- A subsequent ok must NOT re-close a latched-open breaker (run-level cooldown).
    b.record('ok')
    assert_eq(b.shouldStop(), true, "latched OPEN: stays open even after an ok")
    assert_eq(b.state().open, true, "state.open stays true once latched")
end

-- =====================================================================
-- Default threshold when opts is absent / non-number.
-- =====================================================================
do
    local b = breaker.new()
    assert_true(type(b) == 'table', "new() with no opts returns an object")
    assert_eq(b.shouldStop(), false, "default-threshold breaker starts closed")
    -- a non-number threshold falls back to the default (a small constant >= 2).
    local b2 = breaker.new({ threshold = 'lots' })
    assert_eq(b2.shouldStop(), false, "non-number threshold falls back to default, starts closed")
    -- one exhaustion must NOT open under the default (default is > 1).
    b2.record('exhausted')
    assert_eq(b2.shouldStop(), false, "one exhaustion does not open under the default threshold")
end
