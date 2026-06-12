-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/crop/sweep.lua (Phase 6 — Crop-for-ID, CROP-05 policy half)
--
-- PURE module: it pulls in no Lightroom SDK namespace at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant). Run under stock lua/luajit; negative-purity grep clean. (The bare SDK-load
-- token is NEVER written here, even in comments, because the purity grep false-positives on
-- it.)
--
-- The temp scratch dir <temp>/BirdAID/ is SHARED, so the sweep policy must scope deletion to
-- OUR own per-run directory: every run owns a run-<id>/ subdir, and ONLY entries whose name
-- matches that run-<id> naming are eligible for deletion [CODEX #9]. sanitizeRunId rejects
-- path separators and '..' so a malicious/odd runId can never escape the dir [CODEX #6/#7/#8].
-- isStaleRunDir adds an age gate so a CONCURRENT run's fresh dir is NOT swept. The per-photo
-- temp files (export/crop/err) live INSIDE the run dir, so they need no prefix of their own —
-- the run DIR is the ownership marker.
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; unpack is global.

local M = {}

-- sanitizeRunId(s) -> a safe id (only [%w-_]) | nil. Rejects non-strings, empty, anything
-- containing a path separator ('/' or '\\'), '..', or a control character (so the run dir
-- can never traverse out of <temp>/BirdAID/). A safe id PROVABLY contains no '/', '\\', '..'.
function M.sanitizeRunId(s)
    if type(s) ~= 'string' or s == '' then return nil end
    -- reject path separators and parent-dir traversal outright.
    if s:find('/', 1, true) then return nil end
    if s:find('\\', 1, true) then return nil end
    if s:find('..', 1, true) then return nil end
    -- the id must consist ENTIRELY of word chars, '-' and '_' (this also rejects control
    -- chars, spaces, '.', and any shell/path metacharacter).
    if s:find('[^%w%-_]') then return nil end
    return s
end

-- runDirName(id) -> 'run-' .. sanitizeRunId(id) | nil for an unsafe id.
function M.runDirName(id)
    local safe = M.sanitizeRunId(id)
    if not safe then return nil end
    return 'run-' .. safe
end

-- isOurs(name) -> true ONLY for a name shaped like our run-<id> directory (run- followed by
-- one or more [%w-_] chars, anchored at both ends). Rejects source-photo basenames, the old
-- flat birdaid- naming, empty ids, and any name containing a separator [CODEX #9].
function M.isOurs(name)
    if type(name) ~= 'string' then return false end
    return name:match('^run%-[%w%-_]+$') ~= nil
end

-- isStaleRunDir(name, ageSecs, thresholdSecs) -> true ONLY when isOurs(name) AND the dir is
-- old enough (ageSecs >= thresholdSecs). The age gate prevents sweeping a concurrent run's
-- still-active fresh dir.
function M.isStaleRunDir(name, ageSecs, thresholdSecs)
    if not M.isOurs(name) then return false end
    if type(ageSecs) ~= 'number' or type(thresholdSecs) ~= 'number' then return false end
    return ageSecs >= thresholdSecs
end

-- UNIX_TO_COCOA_OFFSET: seconds between the Unix epoch (1970-01-01) and the Cocoa/LrDate epoch
-- (2001-01-01). os.time() is Unix-epoch; LrFileUtils.fileAttributes().fileModificationDate and
-- LrDate.currentTime() are Cocoa-epoch. (L8: this constant lived inline in viz_report.sweepOrphans;
-- it now has a single home so the two dir-staleness sites share one convention.)
M.UNIX_TO_COCOA_OFFSET = 978307200

-- ageSecsFrom(nowCocoa, modCocoa) -> ageSeconds | nil. PURE staleness helper: both args MUST be in
-- the SAME (Cocoa/LrDate) epoch — a Unix os.time() caller converts first via UNIX_TO_COCOA_OFFSET.
-- Returns nil for non-number inputs or a NaN result (caller then treats the dir as NOT stale).
function M.ageSecsFrom(nowCocoa, modCocoa)
    if type(nowCocoa) ~= 'number' or type(modCocoa) ~= 'number' then return nil end
    local age = nowCocoa - modCocoa
    if age ~= age then return nil end          -- NaN guard
    return age
end

-- tempNames(idx) -> { export=, crop=, err= } collision-safe BASENAMES inside the run dir.
-- idx is zero-padded to 5 digits so two different indices never collide. NEW-3: coerce idx to a
-- non-negative INTEGER first (math.floor(tonumber(idx) or 0)) so string.format('%05d', ...) behaves
-- IDENTICALLY under LuaJIT and Lua 5.4 on a non-integer/float/non-number idx (5.4's '%d' RAISES on a
-- float; LuaJIT truncates — the floor makes both deterministic and never raises).
function M.tempNames(idx)
    local n = string.format('%05d', math.floor(tonumber(idx) or 0))
    return {
        export = 'export-' .. n .. '.jpg',
        crop   = 'crop-' .. n .. '.jpg',
        err    = 'err-' .. n,
    }
end

return M
