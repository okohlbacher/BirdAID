-- test/crop_sweep_spec.lua (Phase 6 — Crop-for-ID, PURE per-run-dir sweep policy, CROP-05)
--
-- Exercises BirdAID.lrdevplugin/src/crop/sweep.lua: a PURE module (pulls in NO Lightroom SDK
-- namespace at load time), require-able under stock lua / luajit. Covers the naming + sweep
-- policy that scopes deletion to OUR per-run run-<id>/ directory (the temp dir is shared, so
-- deleting non-ours would be destructive) [CODEX #6/#7/#8/#9 + per-run-dir NIT]:
--   * sanitizeRunId rejects path separators '/' '\\' and '..' and control chars;
--   * runDirName(id) == 'run-' .. sanitizeRunId(id);
--   * isOurs matches ONLY the run-<id> dir naming (not source-photo basenames, not old flat);
--   * isStaleRunDir gates on age (a concurrent run's fresh dir is NOT swept);
--   * tempNames are collision-free basenames inside the run dir.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local SW = require('src.crop.sweep')

-- =====================================================================
-- sanitizeRunId: rejects path separators / .. / control chars; the result NEVER contains
-- '/', '\\', or '..'.
-- =====================================================================
do
    assert_eq(SW.sanitizeRunId('abc'), 'abc', "sanitizeRunId: plain id passes through")
    assert_eq(SW.sanitizeRunId('abc-123_xy'), 'abc-123_xy', "sanitizeRunId: [%w-_] id passes")
    assert_eq(SW.sanitizeRunId('a/b'), nil, "sanitizeRunId: forward-slash -> nil")
    assert_eq(SW.sanitizeRunId('a\\b'), nil, "sanitizeRunId: backslash -> nil")
    assert_eq(SW.sanitizeRunId('..'), nil, "sanitizeRunId: '..' -> nil")
    assert_eq(SW.sanitizeRunId('a..b'), nil, "sanitizeRunId: embedded '..' -> nil")
    assert_eq(SW.sanitizeRunId('x\ny'), nil, "sanitizeRunId: newline (control char) -> nil")
    assert_eq(SW.sanitizeRunId(''), nil, "sanitizeRunId: empty -> nil")
    assert_eq(SW.sanitizeRunId(nil), nil, "sanitizeRunId: nil -> nil")
    assert_eq(SW.sanitizeRunId(42), nil, "sanitizeRunId: non-string -> nil")

    -- INVARIANT: any non-nil result contains none of '/', '\\', '..'.
    local inputs = { 'abc', 'a/b', 'a\\b', '..', 'a..b', 'x\ny', '', 'good_id-9', '/etc/passwd' }
    for i = 1, #inputs do
        local out = SW.sanitizeRunId(inputs[i])
        if out ~= nil then
            assert_eq(out:find('/', 1, true), nil, "sanitizeRunId result has no '/' (input #" .. i .. ")")
            assert_eq(out:find('\\', 1, true), nil, "sanitizeRunId result has no '\\' (input #" .. i .. ")")
            assert_eq(out:find('..', 1, true), nil, "sanitizeRunId result has no '..' (input #" .. i .. ")")
        end
    end
end

-- =====================================================================
-- runDirName(id) == 'run-' .. sanitizeRunId(id); unsafe id -> nil.
-- =====================================================================
assert_eq(SW.runDirName('abc'), 'run-abc', "runDirName: 'abc' -> 'run-abc'")
assert_eq(SW.runDirName('a-1_b'), 'run-a-1_b', "runDirName: composite id")
assert_eq(SW.runDirName('a/b'), nil, "runDirName: unsafe id -> nil")
assert_eq(SW.runDirName('..'), nil, "runDirName: '..' -> nil")
assert_eq(SW.runDirName(nil), nil, "runDirName: nil -> nil")

-- =====================================================================
-- isOurs [CODEX #9]: matches the RUN-DIR naming (run-<id>), NOT source-photo basenames, NOT
-- the old flat birdaid- naming. The export goes INTO our run dir; the DIR is the ownership
-- marker.
-- =====================================================================
assert_eq(SW.isOurs('run-abc'), true, "isOurs: 'run-abc' -> true")
assert_eq(SW.isOurs('run-abc-123'), true, "isOurs: 'run-abc-123' -> true")
assert_eq(SW.isOurs('run-a_1-b'), true, "isOurs: 'run-a_1-b' -> true")
assert_eq(SW.isOurs('vacation.jpg'), false, "isOurs: source-photo basename -> false")
assert_eq(SW.isOurs('run.jpg'), false, "isOurs: 'run.jpg' -> false")
assert_eq(SW.isOurs('birdaid-x.jpg'), false, "isOurs: old flat birdaid- naming -> false")
assert_eq(SW.isOurs('run-'), false, "isOurs: 'run-' with empty id -> false")
assert_eq(SW.isOurs('xrun-abc'), false, "isOurs: must anchor at start -> false")
assert_eq(SW.isOurs('run-abc/evil'), false, "isOurs: a slash in the name -> false")
assert_eq(SW.isOurs(nil), false, "isOurs: nil -> false")
assert_eq(SW.isOurs(42), false, "isOurs: non-string -> false")

-- =====================================================================
-- isStaleRunDir(name, ageSecs, thresholdSecs): true ONLY when isOurs(name) AND
-- ageSecs >= thresholdSecs (age gate so a CONCURRENT run's fresh dir is NOT swept).
-- =====================================================================
assert_eq(SW.isStaleRunDir('run-x', 10, 3600), false, "isStaleRunDir: too fresh -> false")
assert_eq(SW.isStaleRunDir('run-x', 7200, 3600), true, "isStaleRunDir: old enough -> true")
assert_eq(SW.isStaleRunDir('run-x', 3600, 3600), true, "isStaleRunDir: exactly at threshold -> true")
assert_eq(SW.isStaleRunDir('foreign', 99999, 3600), false, "isStaleRunDir: not ours -> false")
assert_eq(SW.isStaleRunDir('vacation.jpg', 99999, 3600), false,
    "isStaleRunDir: foreign basename never swept regardless of age")
assert_eq(SW.isStaleRunDir('run-x', nil, 3600), false, "isStaleRunDir: nil age -> false")
assert_eq(SW.isStaleRunDir('run-x', 7200, nil), false, "isStaleRunDir: nil threshold -> false")
assert_eq(SW.isStaleRunDir(nil, 7200, 3600), false, "isStaleRunDir: nil name -> false")

-- =====================================================================
-- tempNames(idx) -> {export,crop,err} BASENAMES within the run dir; all distinct; idx
-- zero-padded so two different idx never collide.
-- =====================================================================
do
    local n1 = SW.tempNames(1)
    assert_eq(n1.export, 'export-00001.jpg', "tempNames(1).export zero-padded")
    assert_eq(n1.crop, 'crop-00001.jpg', "tempNames(1).crop zero-padded")
    assert_eq(n1.err, 'err-00001', "tempNames(1).err zero-padded")
    -- all three distinct
    assert_true(n1.export ~= n1.crop and n1.crop ~= n1.err and n1.export ~= n1.err,
        "tempNames: the three basenames are distinct")
    -- basenames carry no path separator (they live INSIDE run-<id>/).
    assert_eq(n1.export:find('/', 1, true), nil, "tempNames: export has no path separator")
    assert_eq(n1.crop:find('/', 1, true), nil, "tempNames: crop has no path separator")

    local n2 = SW.tempNames(2)
    assert_true(n1.export ~= n2.export, "tempNames: different idx -> different export name (no collision)")
    assert_true(n1.crop ~= n2.crop, "tempNames: different idx -> different crop name")
    assert_true(n1.err ~= n2.err, "tempNames: different idx -> different err name")

    local n12345 = SW.tempNames(12345)
    assert_eq(n12345.export, 'export-12345.jpg', "tempNames: 5-digit idx preserved")
end

-- =====================================================================
-- NEVER raises (pcall battery).
-- =====================================================================
do
    local ids = { 'abc', 'a/b', '..', nil, 42, '', 'x\ny' }
    for i = 1, #ids do
        assert_true(pcall(SW.sanitizeRunId, ids[i]), "sanitizeRunId never raises (battery " .. i .. ")")
        assert_true(pcall(SW.runDirName, ids[i]), "runDirName never raises (battery " .. i .. ")")
        assert_true(pcall(SW.isOurs, ids[i]), "isOurs never raises (battery " .. i .. ")")
    end
    assert_true(pcall(SW.tempNames, 1), "tempNames never raises")
    assert_true(pcall(SW.isStaleRunDir, 'run-x', 1, 1), "isStaleRunDir never raises")
end
