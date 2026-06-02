-- test/retry_filter_spec.lua (12-02 Task 1 — PURE selectIncomplete over the terminal-outcome taxonomy)
--
-- Exercises BirdAID.lrdevplugin/src/retry_filter.lua: a PURE module (no Lr, deterministic, no
-- math.random) require-able under stock lua / luajit. selectIncomplete(priorRun) returns the
-- photoIds whose outcome is NOT terminal (retryable OR missing/unknown), de-duped by photoId and
-- dropping malformed ids. It MUST NOT re-select any terminal success / no-bird / no-detection.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local retry_filter = require('src.retry_filter')

assert_true(type(retry_filter) == 'table', "require 'src.retry_filter' resolves")
assert_true(type(retry_filter.selectIncomplete) == 'function', "exposes selectIncomplete")

-- =====================================================================
-- nil / empty input -> {} (never errors).
-- =====================================================================
do
    assert_eq(#retry_filter.selectIncomplete(nil), 0, "selectIncomplete(nil) -> {}")
    assert_eq(#retry_filter.selectIncomplete({}), 0, "selectIncomplete({}) -> {}")
end

-- =====================================================================
-- TERMINAL outcomes are EXCLUDED; RETRYABLE + missing/unknown are INCLUDED. Order preserved.
-- =====================================================================
do
    local prior = {
        { photoId = 'p1', outcome = 'written' },       -- terminal -> excluded
        { photoId = 'p2', outcome = 'existing' },       -- terminal -> excluded
        { photoId = 'p3', outcome = 'no-bird' },        -- terminal -> excluded
        { photoId = 'p4', outcome = 'no-detection' },   -- terminal -> excluded
        { photoId = 'p5', outcome = 'deferred' },       -- retryable -> included
        { photoId = 'p6', outcome = 'timed-out' },      -- retryable -> included
        { photoId = 'p7', outcome = 'errored' },        -- retryable -> included
        { photoId = 'p8', outcome = 'cancelled' },      -- retryable -> included
        { photoId = 'p9', outcome = 'mystery-unknown' },-- unknown -> included (retry safe)
        { photoId = 'p10' },                            -- missing outcome -> included (retry safe)
    }
    local sel = retry_filter.selectIncomplete(prior)
    assert_eq(#sel, 6, "exactly the 6 non-terminal records are selected")
    assert_eq(sel[1], 'p5', "order preserved: deferred first")
    assert_eq(sel[2], 'p6', "timed-out second")
    assert_eq(sel[3], 'p7', "errored third")
    assert_eq(sel[4], 'p8', "cancelled fourth")
    assert_eq(sel[5], 'p9', "unknown-outcome fifth")
    assert_eq(sel[6], 'p10', "missing-outcome sixth")
end

-- =====================================================================
-- DEDUPE by photoId (CODEX MEDIUM-1): two records with the SAME id emit it ONCE (first occurrence
-- position preserved). A record with a nil / empty / non-string photoId is DROPPED.
-- =====================================================================
do
    local prior = {
        { photoId = 'dup', outcome = 'deferred' },     -- first occurrence
        { photoId = 'dup', outcome = 'errored' },       -- duplicate -> not re-emitted
        { photoId = '', outcome = 'deferred' },         -- empty id -> dropped
        { photoId = 42, outcome = 'deferred' },         -- non-string id -> dropped
        { outcome = 'deferred' },                       -- nil id -> dropped
        { photoId = 'keep', outcome = 'cancelled' },    -- emitted
    }
    local sel = retry_filter.selectIncomplete(prior)
    assert_eq(#sel, 2, "dup emitted once, malformed ids dropped -> 2 selected")
    assert_eq(sel[1], 'dup', "first occurrence of dup preserved")
    assert_eq(sel[2], 'keep', "valid trailing id selected")
end

-- =====================================================================
-- A terminal record duplicated with a retryable record under the SAME id: the id is still
-- selected ONCE iff its FIRST-seen-as-retryable occurrence drives inclusion. Here the terminal
-- 'written' for 'x' appears first; since it is terminal it is not emitted, and the later retryable
-- 'deferred' for the SAME id then includes it once (selection is per-id non-terminal presence).
-- =====================================================================
do
    local prior = {
        { photoId = 'x', outcome = 'written' },   -- terminal, not emitted
        { photoId = 'x', outcome = 'deferred' },  -- retryable -> id emitted once
    }
    local sel = retry_filter.selectIncomplete(prior)
    assert_eq(#sel, 1, "id with a mix of terminal+retryable emits once")
    assert_eq(sel[1], 'x', "the id is selected")
end
