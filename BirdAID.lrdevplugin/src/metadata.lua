-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/metadata.lua (META-01, META-02 — PURE core)
--
-- PURE module: pulls in NO Lightroom SDK namespace at load time (the only require is the
-- pure src.settings), so it is require-able under stock lua / lua5.1 / luajit for offline
-- unit testing (the CODEX-mandated separation invariant). The thin metadata READER
-- (photo:getRawMetadata('gps'/'dateTimeOriginal'/'path')) is Lr-glue and lives in the
-- entry/pipeline tier — NOT here.
--
-- shape(raw, prefs) -> ctx, the privacy-gated context the prompt builder consumes:
--   * META-01: ctx.gps / ctx.date emitted ONLY when sendGpsDate is truly ON AND the raw
--              values are present and finite (non-NaN/inf).
--   * META-02: ctx.locationHint via settings.sanitizePathHint ONLY when usePathHint is ON,
--              no gps was emitted (gps precedence), and the sanitized hint is non-empty.
--
-- CODEX hardening folded in:
--   * MUST-FIX 11: normalize prefs INTERNALLY via settings.normalizedPrefs so a RAW pref
--     like {sendGpsDate="false"} (a TRUTHY Lua string from edit_field/LrPrefs) cannot leak
--     GPS/date — after normalization the toggles are REAL booleans.
--   * MUST-FIX 10: reject NaN AND +/-inf for every numeric (gps lat/lon, dateRaw).
--   * MUST-FIX 12: dateRaw is the Cocoa epoch (seconds since 2001-01-01 00:00:00 GMT);
--     convert to a STABLE UTC "YYYY-MM-DD" by adding 978307200 (Cocoa->Unix) and formatting
--     with os.date('!%Y-%m-%d', unix). Pure + deterministic; 0 -> "2001-01-01".
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local settings = require 'src.settings'

local M = {}

-- Cocoa->Unix epoch offset: seconds between 1970-01-01 and 2001-01-01 (both UTC).
local COCOA_EPOCH_OFFSET = 978307200

-- Numeric guard (CODEX MUST-FIX 10): valid only when a number, not NaN (x==x false for
-- NaN), and neither +inf nor -inf.
local INF = 1 / 0
local function isFinite(x)
    return type(x) == 'number' and x == x and x ~= INF and x ~= -INF
end

-- Privacy-toggle boolean reader (CODEX MUST-FIX 11). A privacy toggle must FAIL CLOSED:
-- LrPrefs/edit_field yield STRINGS and every non-empty string is truthy in Lua, so a raw
-- {sendGpsDate="false"} must NOT leak GPS/date. 04-02 hoisted this fail-closed rule into
-- the SHARED settings.toBool (which fail-closes {false,nil,0,"false","no","off","0",""}
-- after trim+lower, treats a real false / numeric 0 as OFF, and is what validate now
-- routes ALL boolean keys through). toggleOn delegates to it so the rule lives in ONE
-- place; behavior is unchanged. (normalizedValue is now redundant — normalizedPrefs is
-- itself fail-closed — but kept in the signature for callers; the raw value is decisive.)
local function toggleOn(rawValue, normalizedValue)
    return settings.toBool(rawValue)
end

-- shape(raw, prefs) -> ctx
--   raw   = { gps = {latitude=N, longitude=N} | nil,
--             dateRaw = <number Cocoa-epoch> | nil,
--             path = <string> | nil }
--   prefs = a raw or already-normalized prefs table; normalized INTERNALLY (MUST-FIX 11).
-- Returns a ctx with fields present ONLY when their toggle is on and inputs are valid.
-- Never raises.
function M.shape(raw, prefs)
    raw = type(raw) == 'table' and raw or {}
    local rawPrefs = type(prefs) == 'table' and prefs or {}
    -- CODEX MUST-FIX 11: gate on REAL booleans, not raw truthy strings. normalizedPrefs
    -- types the numerics + non-toggle fields; the two privacy toggles are read FAIL-CLOSED
    -- via toggleOn so a raw "false" string can never leak.
    local normalized = settings.normalizedPrefs(prefs)
    local sendGpsDate = toggleOn(rawPrefs.sendGpsDate, normalized.sendGpsDate)
    local usePathHint = toggleOn(rawPrefs.usePathHint, normalized.usePathHint)

    local ctx = {}

    if sendGpsDate then
        local g = raw.gps
        if type(g) == 'table' and isFinite(g.latitude) and isFinite(g.longitude) then
            ctx.gps = { latitude = g.latitude, longitude = g.longitude }
        end
        if isFinite(raw.dateRaw) then
            -- CODEX MUST-FIX 12: Cocoa epoch -> UTC YYYY-MM-DD (deterministic, locale-free).
            -- CODEX review item 5: os.date can RAISE for out-of-range values on some
            -- platforms (e.g. a dateRaw so large the resulting time_t overflows). Guard it
            -- in pcall and OMIT date on failure rather than letting shape() raise. A valid
            -- conversion sets ctx.date; any failure (or a non-string result) leaves it nil.
            local unix = raw.dateRaw + COCOA_EPOCH_OFFSET
            local ok, formatted = pcall(os.date, '!%Y-%m-%d', unix)
            if ok and type(formatted) == 'string' then
                ctx.date = formatted
            end
        end
    end

    -- META-02: hint ONLY when usePathHint AND no GPS was emitted (gps precedence) AND the
    -- sanitized hint is non-empty. sanitizePathHint output is provably "" or a curated
    -- GEO_ALLOWLIST constant — never a raw path/username/drive.
    if usePathHint and not ctx.gps and type(raw.path) == 'string' then
        local hint = settings.sanitizePathHint(raw.path)
        if hint ~= '' then ctx.locationHint = hint end
    end

    return ctx
end

return M
