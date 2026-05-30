-- test/metadata_reader_spec.lua (Phase 3 review — metadata_reader pcall guards)
--
-- Exercises BirdAID.lrdevplugin/src/lr/metadata_reader.lua. That file lives in the src/lr/
-- glue tier and MAY touch the Lightroom SDK at CALL time, but it imports NO Lr* module at
-- LOAD time, so it is require-able under stock lua / luajit and its accessor-guarding logic
-- can be exercised with a plain mock photo (no Lr needed) — we do NOT add Lr to it.
--
-- CODEX review item 6: each getRawMetadata call is guarded in pcall so a throwing accessor
-- on one field does not abort read(); the field becomes nil and the others still read.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local reader = require('src.lr.metadata_reader')

assert_true(type(reader) == 'table', "require 'src.lr.metadata_reader' resolves (no Lr at load)")
assert_true(type(reader.read) == 'function', "metadata_reader exposes read")

-- Build a mock photo (a plain table with a getRawMetadata method). responses[key] supplies
-- the value; if a key is listed in throwOn, the accessor RAISES (simulating an SDK that
-- errors on that field for a given file).
local function mockPhoto(responses, throwOn)
    throwOn = throwOn or {}
    return {
        getRawMetadata = function(self, key)
            if throwOn[key] then error("simulated SDK error on " .. key) end
            return responses[key]
        end,
    }
end

-- =====================================================================
-- Happy path: all accessors return values; read() carries them through.
-- =====================================================================
do
    local photo = mockPhoto({
        gps = { latitude = 51.5, longitude = -0.12 },
        dateTimeOriginal = 12345,
        path = "/Users/alice/img.jpg",
    })
    local raw = reader.read(photo)
    assert_true(type(raw) == 'table', "read returns a table")
    assert_eq(raw.gps.latitude, 51.5, "gps carried through")
    assert_eq(raw.dateRaw, 12345, "dateTimeOriginal carried into dateRaw")
    assert_eq(raw.path, "/Users/alice/img.jpg", "path carried through")
end

-- =====================================================================
-- CODEX review item 6: a THROWING accessor on 'dateTimeOriginal' must NOT abort read().
-- read() still returns a table; the throwing field is nil; the others are still read.
-- =====================================================================
do
    local photo = mockPhoto(
        { gps = { latitude = 1, longitude = 2 }, path = "/p/x.jpg",
          dateTimeDigitized = nil, dateTime = nil },
        { dateTimeOriginal = true })   -- this accessor RAISES
    local ok, raw = pcall(reader.read, photo)
    assert_true(ok, "item 6: read() does NOT raise when an accessor throws")
    assert_true(type(raw) == 'table', "item 6: read() still returns a table")
    assert_eq(raw.dateRaw, nil, "item 6: throwing dateTimeOriginal -> dateRaw nil")
    assert_eq(raw.gps.latitude, 1, "item 6: other fields still read when one throws")
    assert_eq(raw.path, "/p/x.jpg", "item 6: path still read when date accessor throws")
end

-- The date fallback chain still works when the primary throws but a fallback succeeds.
do
    local photo = mockPhoto(
        { dateTimeDigitized = 999, gps = nil, path = nil },
        { dateTimeOriginal = true })
    local raw = reader.read(photo)
    assert_eq(raw.dateRaw, 999, "item 6: falls back to dateTimeDigitized when original throws")
end

-- ALL accessors throwing still yields an all-nil table, never a raise.
do
    local photo = mockPhoto({}, {
        gps = true, dateTimeOriginal = true, dateTimeDigitized = true,
        dateTime = true, path = true,
    })
    local ok, raw = pcall(reader.read, photo)
    assert_true(ok, "item 6: every accessor throwing still does not raise")
    assert_true(type(raw) == 'table', "item 6: all-throwing -> still a table")
    assert_eq(raw.gps, nil, "item 6: all-throwing -> gps nil")
    assert_eq(raw.dateRaw, nil, "item 6: all-throwing -> dateRaw nil")
    assert_eq(raw.path, nil, "item 6: all-throwing -> path nil")
end

-- Non-photo input (nil / wrong type) returns an all-nil table, never raises.
do
    local raw = reader.read(nil)
    assert_true(type(raw) == 'table', "read(nil) returns a table")
    assert_eq(raw.gps, nil, "read(nil) gps nil")
    assert_eq(raw.dateRaw, nil, "read(nil) dateRaw nil")
    assert_eq(raw.path, nil, "read(nil) path nil")
end
