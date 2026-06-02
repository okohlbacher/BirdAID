-- test/run_state_store_spec.lua (Phase 12 — RETRY-01 cross-session persistence glue)
--
-- Exercises BirdAID.lrdevplugin/src/lr/run_state_store.lua, the THIN Lr-glue persistence adapter.
-- The file lives in the src/lr/ glue tier and touches the SDK (LrPrefs, photo:getRawMetadata), so
-- it is NOT pure. To exercise it under the stock-lua CLI suite we (a) inject a FAKE 'src.log' into
-- package.loaded BEFORE requiring it (the real src.log imports LrLogger and cannot load offline),
-- then (b) drive save/load/clear/stableIdFor with a STUBBED prefs table + stubbed photos.
--
-- Asserts:
--   * save -> load ROUND-TRIPS the secret-free { photoId, outcome } shape (LrPrefs scope).
--   * a token / path / extra field does NOT survive the round-trip (serialize projects to two keys).
--   * a record with a NIL photoId (NON-RESUMABLE, no uuid) is NOT persisted.
--   * stableIdFor returns the uuid when present; returns nil (NON-RESUMABLE) when uuid is
--     absent/empty OR when getRawMetadata THROWS — and NEVER returns a path.
--   * a THROWING prefs store accessor degrades load (and save) to a safe result without raising.
--   * the persisted value contains NO path / extra field.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

package.path = package.path .. ";./?.lua"

-- (a) Inject a fake 'src.log' BEFORE requiring run_state_store so its top-level require 'src.log'
--     resolves to this capturing stub (no LrLogger needed offline). Also capture every logged
--     fields table so we can assert NO photoId/uuid/path VALUE is ever logged.
local logged = { info = {}, warn = {}, error = {}, trace = {} }
local function resetLog()
    logged.info, logged.warn, logged.error, logged.trace = {}, {}, {}, {}
end
package.loaded['src.log'] = {
    event = function(level, msg, fields) (logged[level] or {})[#(logged[level] or {}) + 1] = { msg = msg, fields = fields } end,
    info  = function(msg, fields) logged.info[#logged.info + 1]   = { msg = msg, fields = fields } end,
    warn  = function(msg, fields) logged.warn[#logged.warn + 1]   = { msg = msg, fields = fields } end,
    error = function(msg, fields) logged.error[#logged.error + 1] = { msg = msg, fields = fields } end,
    trace = function(msg, fields) logged.trace[#logged.trace + 1] = { msg = msg, fields = fields } end,
    logFilePath = function() return "/dev/null" end,
}

local S = require('src.lr.run_state_store')

assert_true(type(S) == 'table', "require 'src.lr.run_state_store' resolves with fake src.log")
assert_true(type(S.save) == 'function', "run_state_store exposes save")
assert_true(type(S.load) == 'function', "run_state_store exposes load")
assert_true(type(S.clear) == 'function', "run_state_store exposes clear")
assert_true(type(S.stableIdFor) == 'function', "run_state_store exposes stableIdFor")

-- A stub prefs table that behaves like LrPrefs.prefsForPlugin (plain key/value).
local function stubPrefs()
    return {}
end

-- A stub photo whose getRawMetadata('uuid') returns `uuid` (or raises when `throws`).
local function stubPhoto(uuid, throws)
    return {
        getRawMetadata = function(self, key)
            if throws then error("simulated getRawMetadata failure") end
            if key == 'uuid' then return uuid end
            return nil
        end,
    }
end

-- =====================================================================
-- stableIdFor: uuid present -> the uuid; absent/empty/throwing -> nil; NEVER a path.
-- =====================================================================
do
    assert_eq(S.stableIdFor(stubPhoto("UUID-ABC")), "UUID-ABC", "stableIdFor: returns the uuid when present")
    assert_eq(S.stableIdFor(stubPhoto(nil)), nil, "stableIdFor: nil uuid -> nil (NON-RESUMABLE)")
    assert_eq(S.stableIdFor(stubPhoto("")), nil, "stableIdFor: empty uuid -> nil (NON-RESUMABLE)")
    assert_eq(S.stableIdFor(stubPhoto(nil, true)), nil, "stableIdFor: throwing getRawMetadata -> nil (never raises)")
    assert_eq(S.stableIdFor(nil), nil, "stableIdFor: nil photo -> nil")
    assert_eq(S.stableIdFor("not-a-photo"), nil, "stableIdFor: non-photo -> nil")
end

-- =====================================================================
-- save -> load round-trips the secret-free { photoId, outcome } shape (LrPrefs scope).
-- =====================================================================
do
    resetLog()
    local prefs = stubPrefs()
    local records = {
        { photoId = "UUID-1", outcome = "written" },
        { photoId = "UUID-2", outcome = "deferred" },
    }
    assert_true(S.save("run-1", records, { prefs = prefs }), "save: returns true on a healthy store")
    local loaded = S.load({ prefs = prefs })
    assert_eq(#loaded, 2, "load: round-trips both records")
    assert_eq(loaded[1].photoId, "UUID-1", "load: record 1 photoId preserved")
    assert_eq(loaded[1].outcome, "written", "load: record 1 outcome preserved")
    assert_eq(loaded[2].photoId, "UUID-2", "load: record 2 photoId preserved")
    assert_eq(loaded[2].outcome, "deferred", "load: record 2 outcome preserved")
end

-- =====================================================================
-- A token / path / extra field does NOT survive the round-trip.
-- =====================================================================
do
    local prefs = stubPrefs()
    local records = {
        { photoId = "UUID-3", outcome = "errored",
          token = "sk-SECRET", path = "/Users/x/photo.jpg", response = { big = true }, status = 200 },
    }
    S.save("run-2", records, { prefs = prefs })
    local loaded = S.load({ prefs = prefs })
    assert_eq(#loaded, 1, "load: the single record survives")
    assert_eq(loaded[1].photoId, "UUID-3", "load: photoId survives")
    assert_eq(loaded[1].outcome, "errored", "load: outcome survives")
    assert_eq(loaded[1].token, nil, "load: a token field does NOT survive")
    assert_eq(loaded[1].path, nil, "load: a path field does NOT survive")
    assert_eq(loaded[1].response, nil, "load: a response field does NOT survive")
    assert_eq(loaded[1].status, nil, "load: a raw status field does NOT survive")
    -- The PERSISTED value itself must also be path-free / extra-free.
    local raw = prefs['retryRunState']
    assert_true(type(raw) == 'table', "persisted value is a plain-data array")
    assert_eq(raw[1].token, nil, "persisted: no token field")
    assert_eq(raw[1].path, nil, "persisted: no path field")
end

-- =====================================================================
-- A record with a NIL photoId (NON-RESUMABLE, no uuid) is NOT persisted.
-- =====================================================================
do
    local prefs = stubPrefs()
    local records = {
        { photoId = "UUID-A", outcome = "written" },
        { photoId = nil, outcome = "deferred" },   -- NON-RESUMABLE: no uuid -> dropped
        { photoId = "UUID-B", outcome = "deferred" },
    }
    S.save("run-3", records, { prefs = prefs })
    local loaded = S.load({ prefs = prefs })
    assert_eq(#loaded, 2, "load: the NON-RESUMABLE (nil photoId) record is dropped")
    assert_eq(loaded[1].photoId, "UUID-A", "load: first resumable record kept")
    assert_eq(loaded[2].photoId, "UUID-B", "load: second resumable record kept")
end

-- =====================================================================
-- A THROWING prefs store accessor degrades save->false and load->{} without raising.
-- =====================================================================
do
    -- A prefs proxy whose __newindex / __index raise on the state key.
    local throwingPrefs = setmetatable({}, {
        __newindex = function() error("simulated prefs write failure") end,
        __index = function() error("simulated prefs read failure") end,
    })
    local okSave = S.save("run-4", { { photoId = "UUID-X", outcome = "written" } }, { prefs = throwingPrefs })
    assert_eq(okSave, false, "save: a throwing store accessor degrades to false (never raises)")
    local loaded = S.load({ prefs = throwingPrefs })
    assert_true(type(loaded) == 'table', "load: a throwing store accessor degrades to a table")
    assert_eq(#loaded, 0, "load: degrades to an empty array on a throwing read")
end

-- =====================================================================
-- clear drops the state; subsequent load -> {}.
-- =====================================================================
do
    local prefs = stubPrefs()
    S.save("run-5", { { photoId = "UUID-C", outcome = "written" } }, { prefs = prefs })
    assert_eq(#S.load({ prefs = prefs }), 1, "load: present before clear")
    assert_true(S.clear({ prefs = prefs }), "clear: returns true")
    assert_eq(#S.load({ prefs = prefs }), 0, "load: empty after clear")
end

-- =====================================================================
-- No log line carries a photoId / uuid / path VALUE (ids are map keys/returns only).
-- =====================================================================
do
    resetLog()
    local prefs = stubPrefs()
    S.save("run-6", { { photoId = "UUID-SECRET-VAL", outcome = "written" } }, { prefs = prefs })
    S.load({ prefs = prefs })
    S.clear({ prefs = prefs })
    local function scan(bucket)
        for i = 1, #bucket do
            local f = bucket[i].fields or {}
            for k, v in pairs(f) do
                if type(v) == 'string' then
                    assert_true(v ~= "UUID-SECRET-VAL", "log: no photoId/uuid VALUE in field " .. tostring(k))
                end
            end
        end
    end
    scan(logged.info); scan(logged.warn); scan(logged.error); scan(logged.trace)
end
