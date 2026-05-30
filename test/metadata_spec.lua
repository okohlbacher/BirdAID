-- test/metadata_spec.lua (Phase 3 — Metadata shaper, pure core: META-01/02)
--
-- Exercises BirdAID.lrdevplugin/src/metadata.lua: a PURE module (imports only the pure
-- src.settings), require-able under stock lua / luajit. Covers GPS/date present + absent,
-- the sendGpsDate privacy off-state, the CODEX MUST-FIX 11 raw-truthy-string regression,
-- the CODEX MUST-FIX 12 Cocoa-epoch date contract (0 -> "2001-01-01"), CODEX MUST-FIX 10
-- NaN/inf rejection, and META-02 path-hint gating (on-with-no-gps / on-with-gps / off).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local meta = require('src.metadata')

local NAN = 0 / 0
local INF = 1 / 0

-- =====================================================================
-- META-01: GPS + date PRESENT when sendGpsDate ON and inputs valid
-- =====================================================================
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 0 },
        { sendGpsDate = true, usePathHint = false })
    assert_true(ctx.gps ~= nil, "gps emitted when sendGpsDate on")
    assert_eq(ctx.gps.latitude, 51.5, "gps latitude carried")
    assert_eq(ctx.gps.longitude, -0.12, "gps longitude carried")
    -- CODEX MUST-FIX 12: dateRaw=0 (Cocoa epoch) -> 2001-01-01 UTC, NOT a 1970 Unix value.
    assert_eq(ctx.date, "2001-01-01", "Cocoa-epoch 0 -> 2001-01-01 (UTC)")
    assert_eq(ctx.locationHint, nil, "no locationHint when usePathHint off")
end

-- A second date value: one full day after Cocoa epoch -> 2001-01-02.
do
    local ctx = meta.shape({ dateRaw = 86400 }, { sendGpsDate = true })
    assert_eq(ctx.date, "2001-01-02", "Cocoa-epoch +1 day -> 2001-01-02 (UTC)")
end

-- =====================================================================
-- Privacy off-state: sendGpsDate OFF -> NO gps and NO date
-- =====================================================================
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 12345 },
        { sendGpsDate = false, usePathHint = false })
    assert_eq(ctx.gps, nil, "sendGpsDate off -> ctx.gps nil")
    assert_eq(ctx.date, nil, "sendGpsDate off -> ctx.date nil")
end

-- =====================================================================
-- CODEX MUST-FIX 11: a RAW {sendGpsDate="false"} string pref (TRUTHY in Lua) must NOT leak
-- gps/date — shape normalizes prefs internally before gating.
-- =====================================================================
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 12345 },
        { sendGpsDate = "false", usePathHint = "false" })
    assert_eq(ctx.gps, nil, "raw string sendGpsDate='false' does NOT leak gps")
    assert_eq(ctx.date, nil, "raw string sendGpsDate='false' does NOT leak date")
    assert_eq(ctx.locationHint, nil, "raw string usePathHint='false' does NOT leak hint")
end

-- A raw {sendGpsDate=true} (real bool) still works (normalization is transparent).
do
    local ctx = meta.shape({ gps = { latitude = 1, longitude = 2 } }, { sendGpsDate = true })
    assert_true(ctx.gps ~= nil, "real-bool sendGpsDate true emits gps after normalization")
end

-- =====================================================================
-- CODEX review item 4: fail-closed for numeric 0, real boolean false, and
-- whitespace/case-variant false strings; only a genuinely truthy value enables.
-- =====================================================================
-- numeric 0 / 0.0 -> OFF (a 0 pref must NOT enable an opt-in privacy toggle).
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 0 },
        { sendGpsDate = 0 })
    assert_eq(ctx.gps, nil, "item 4: sendGpsDate=0 -> no gps")
    assert_eq(ctx.date, nil, "item 4: sendGpsDate=0 -> no date")
end
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 0 },
        { sendGpsDate = 0.0 })
    assert_eq(ctx.gps, nil, "item 4: sendGpsDate=0.0 -> no gps")
    assert_eq(ctx.date, nil, "item 4: sendGpsDate=0.0 -> no date")
end
-- whitespace + case variant false string " FALSE " -> OFF.
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 0 },
        { sendGpsDate = " FALSE " })
    assert_eq(ctx.gps, nil, "item 4: sendGpsDate=' FALSE ' -> no gps")
    assert_eq(ctx.date, nil, "item 4: sendGpsDate=' FALSE ' -> no date")
end
-- other whitespace/case false variants.
do
    local ctx = meta.shape({ gps = { latitude = 1, longitude = 2 } }, { sendGpsDate = "Off" })
    assert_eq(ctx.gps, nil, "item 4: sendGpsDate='Off' -> no gps")
end
do
    local ctx = meta.shape({ gps = { latitude = 1, longitude = 2 } }, { sendGpsDate = " no " })
    assert_eq(ctx.gps, nil, "item 4: sendGpsDate=' no ' -> no gps")
end
-- real boolean false -> OFF.
do
    local ctx = meta.shape({ gps = { latitude = 1, longitude = 2 }, dateRaw = 0 }, { sendGpsDate = false })
    assert_eq(ctx.gps, nil, "item 4: real-bool false -> no gps")
    assert_eq(ctx.date, nil, "item 4: real-bool false -> no date")
end
-- genuine truthy (real true) still enables gps AND date.
do
    local ctx = meta.shape(
        { gps = { latitude = 51.5, longitude = -0.12 }, dateRaw = 0 },
        { sendGpsDate = true })
    assert_true(ctx.gps ~= nil, "item 4: sendGpsDate=true -> gps present")
    assert_eq(ctx.date, "2001-01-01", "item 4: sendGpsDate=true -> date present")
end

-- =====================================================================
-- CODEX review item 5: os.date is guarded in pcall; a value that would overflow/raise
-- omits date and NEVER raises. A non-number dateRaw omits date. dateRaw=0 -> 2001-01-01.
-- =====================================================================
do
    -- 1e20 added to the Cocoa offset can overflow time_t on some platforms; shape must
    -- not raise — it either omits date or yields a valid string.
    local ok, ctx = pcall(meta.shape, { dateRaw = 1e20 }, { sendGpsDate = true })
    assert_true(ok, "item 5: shape({dateRaw=1e20}) never raises")
    assert_true(ctx.date == nil or type(ctx.date) == 'string',
        "item 5: dateRaw=1e20 omits date or yields a valid string")
end
do
    local ctx = meta.shape({ dateRaw = "not-a-number" }, { sendGpsDate = true })
    assert_eq(ctx.date, nil, "item 5: non-number dateRaw omits date")
end
do
    local ctx = meta.shape({ dateRaw = 0 }, { sendGpsDate = true })
    assert_eq(ctx.date, "2001-01-01", "item 5: dateRaw=0 -> 2001-01-01")
end

-- =====================================================================
-- CODEX MUST-FIX 10: NaN / inf gps lat/lon and dateRaw are REJECTED
-- =====================================================================
do
    local ctx = meta.shape({ gps = { latitude = NAN, longitude = 2 } }, { sendGpsDate = true })
    assert_eq(ctx.gps, nil, "NaN latitude -> no gps")
end
do
    local ctx = meta.shape({ gps = { latitude = 1, longitude = INF } }, { sendGpsDate = true })
    assert_eq(ctx.gps, nil, "inf longitude -> no gps")
end
do
    local ctx = meta.shape({ dateRaw = NAN }, { sendGpsDate = true })
    assert_eq(ctx.date, nil, "NaN dateRaw -> no date")
end
do
    local ctx = meta.shape({ dateRaw = INF }, { sendGpsDate = true })
    assert_eq(ctx.date, nil, "inf dateRaw -> no date")
end
do
    local ctx = meta.shape({ dateRaw = -INF }, { sendGpsDate = true })
    assert_eq(ctx.date, nil, "-inf dateRaw -> no date")
end

-- gps as a non-table is ignored (no raise).
do
    local ctx = meta.shape({ gps = "nope", dateRaw = "nope" }, { sendGpsDate = true })
    assert_eq(ctx.gps, nil, "non-table gps ignored")
    assert_eq(ctx.date, nil, "non-number dateRaw ignored")
end

-- =====================================================================
-- META-02: locationHint via sanitizePathHint — gated on usePathHint AND gps absent
-- =====================================================================
-- usePathHint ON, gps absent, allowlisted-country path -> curated hint emitted.
do
    local ctx = meta.shape(
        { path = "/Users/alice/Photos/Germany/2024/img.jpg" },
        { sendGpsDate = false, usePathHint = true })
    assert_eq(ctx.gps, nil, "no gps in this case")
    assert_eq(ctx.locationHint, "Germany", "sanitized hint maps allowlisted country")
end

-- usePathHint ON but gps PRESENT -> NO hint (gps precedence, META-02).
do
    local ctx = meta.shape(
        { gps = { latitude = 1, longitude = 2 }, path = "/Users/alice/Germany/img.jpg" },
        { sendGpsDate = true, usePathHint = true })
    assert_true(ctx.gps ~= nil, "gps present")
    assert_eq(ctx.locationHint, nil, "gps present -> no locationHint (precedence)")
end

-- usePathHint OFF -> NO hint even with an allowlisted path.
do
    local ctx = meta.shape(
        { path = "/Users/alice/Germany/img.jpg" },
        { sendGpsDate = false, usePathHint = false })
    assert_eq(ctx.locationHint, nil, "usePathHint off -> no locationHint")
end

-- usePathHint ON, gps absent, but path sanitizes to "" (no allowlist match) -> NO hint.
do
    local ctx = meta.shape(
        { path = "/Users/alice/Projects/secret/img.jpg" },
        { sendGpsDate = false, usePathHint = true })
    assert_eq(ctx.locationHint, nil, "non-allowlisted path -> no hint (empty sanitized)")
end

-- The sanitizer must never leak a username that happens to match a country.
do
    local ctx = meta.shape(
        { path = "/Users/Canada/Photos/img.jpg" },
        { sendGpsDate = false, usePathHint = true })
    assert_eq(ctx.locationHint, nil, "username 'Canada' dropped, not leaked as hint")
end

-- =====================================================================
-- Robustness: non-table raw / nil prefs never raise
-- =====================================================================
do
    assert_true(pcall(meta.shape, nil, nil), "shape(nil,nil) never raises")
    assert_true(pcall(meta.shape, "x", 42), "shape(non-table, non-table) never raises")
    local ctx = meta.shape(nil, nil)
    assert_true(type(ctx) == 'table', "shape returns a table even for nil raw")
    -- DEFAULTS: sendGpsDate ON, usePathHint OFF -> empty raw yields empty-ish ctx.
    assert_eq(ctx.gps, nil, "empty raw -> no gps")
    assert_eq(ctx.date, nil, "empty raw -> no date")
    assert_eq(ctx.locationHint, nil, "empty raw -> no hint")
end
