-- test/deep_reaper_spec.lua (Phase 13 Plan 01 — DEEP-03 reaper age-gate decision, Wave 1)
--
-- Proves OFFLINE the startup-reaper decision the 13-04 reaper relies on, WITHOUT touching the
-- filesystem, by exercising the REUSED PURE module BirdAID.lrdevplugin/src/crop/sweep.lua
-- (require'd AS-IS — this spec does NOT fork or modify sweep). It lands in Wave 1 so the
-- decision spec PRE-EXISTS the 13-04 reaper code that consumes it (Nyquist: test ships before
-- the consumer).
--
-- The reaper sweeps stale leftover per-run temp dirs (orphans from a prior crash) but MUST NEVER
-- delete an actively-running sibling run's fresh dir, and MUST NEVER traverse out of the shared
-- <temp>/BirdAID/ dir. The age gate uses the DeepIdentify threshold A4 = 6h (6 * 3600 = 21600s):
--   * isStaleRunDir(name, age, 6h) == true  ONLY for a run-<id> dir at/past 6h;
--   * a fresh sibling (age < 6h) is NEVER swept (concurrent-run protection);
--   * a non-ours name (not run-<id>) is NEVER swept regardless of age;
--   * sanitizeRunId rejects path traversal / separators (a malicious runId can't escape);
--   * runDirName of a newRunId-style '[%w-_]' id is a sweep-safe non-nil 'run-...' string.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local SW = require('src.crop.sweep')

-- The DeepIdentify reaper threshold (A4): a conservative 6-hour age gate.
local THRESHOLD = 6 * 3600   -- 21600 seconds

-- =====================================================================
-- Age gate: true ONLY for OUR run-<id> dir at/past the 6h threshold.
-- =====================================================================
assert_eq(SW.isStaleRunDir('run-abc', 7 * 3600, THRESHOLD), true,
    "reaper: our dir 7h old (past 6h) -> stale, swept")
assert_eq(SW.isStaleRunDir('run-abc', THRESHOLD, THRESHOLD), true,
    "reaper: our dir EXACTLY at 6h -> stale, swept (>= boundary)")
assert_eq(SW.isStaleRunDir('run-abc', 21600, 21600), true,
    "reaper: 6h expressed as 21600s -> stale (A4 threshold literal)")

-- =====================================================================
-- Concurrent-run protection: a FRESH sibling (age < 6h) is NEVER swept.
-- =====================================================================
assert_eq(SW.isStaleRunDir('run-abc', 60, THRESHOLD), false,
    "reaper: our dir 60s old (fresh sibling) -> NOT swept (concurrent run protection)")
assert_eq(SW.isStaleRunDir('run-abc', 6 * 3600 - 1, THRESHOLD), false,
    "reaper: just under 6h -> NOT swept")

-- =====================================================================
-- Ownership gate: a non-ours name is NEVER swept regardless of age.
-- =====================================================================
assert_eq(SW.isStaleRunDir('notrun', 99999, THRESHOLD), false,
    "reaper: non-run-<id> name never swept (not isOurs)")
assert_eq(SW.isStaleRunDir('vacation.jpg', 999999, THRESHOLD), false,
    "reaper: a source-photo basename never swept regardless of age")
assert_eq(SW.isStaleRunDir('run-', 999999, THRESHOLD), false,
    "reaper: 'run-' with empty id never swept")

-- =====================================================================
-- Traversal safety: a malicious/odd runId can never escape <temp>/BirdAID/.
-- =====================================================================
assert_eq(SW.sanitizeRunId('../escape'), nil, "reaper: '../escape' runId rejected (traversal)")
assert_eq(SW.sanitizeRunId('a/b'), nil, "reaper: 'a/b' runId rejected (separator)")
assert_eq(SW.sanitizeRunId('a\\b'), nil, "reaper: 'a\\b' runId rejected (backslash)")
assert_eq(SW.sanitizeRunId('a..b'), nil, "reaper: embedded '..' runId rejected")

-- =====================================================================
-- A newRunId-style '[%w-_]' deep id is sweep-safe: runDirName yields a non-nil 'run-...' name
-- that isOurs/isStaleRunDir then recognize. (The deep run id flows cleanly through the gate.)
-- =====================================================================
do
    local deepId = 'deep-1717300000-9'   -- digits, '-' only: within [%w-_]
    local dir = SW.runDirName(deepId)
    assert_true(type(dir) == 'string', "reaper: a [%w-_] deep id -> a non-nil run dir name")
    assert_eq(dir, 'run-deep-1717300000-9', "reaper: runDirName composes 'run-' + the deep id")
    assert_eq(SW.isOurs(dir), true, "reaper: the composed deep run dir isOurs")
    assert_eq(SW.isStaleRunDir(dir, 7 * 3600, THRESHOLD), true,
        "reaper: a stale deep run dir is correctly swept past 6h")
    assert_eq(SW.isStaleRunDir(dir, 60, THRESHOLD), false,
        "reaper: a fresh deep run dir is NOT swept")
end

-- =====================================================================
-- NEVER raises (the reaper decision must be infallible offline).
-- =====================================================================
assert_true(pcall(SW.isStaleRunDir, 'run-x', 1, THRESHOLD), "isStaleRunDir never raises")
assert_true(pcall(SW.sanitizeRunId, '../escape'), "sanitizeRunId never raises on traversal input")
assert_true(pcall(SW.runDirName, 'deep-1-2'), "runDirName never raises")
