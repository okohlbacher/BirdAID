-- test/settings_deep_prefs_spec.lua (Phase 13 Plan 01 — D-03 deepExportConcurrency clamp)
-- (L12: renamed from settings_deep_export_spec.lua — it tests deep PREFS normalization, not export.)
--
-- Exercises BirdAID.lrdevplugin/src/settings.lua: the SEPARATE export concurrency cap
-- deepExportConcurrency (D-03). It MUST NOT reuse / alias the AI maxConcurrency — it is a
-- distinct key with default 2, clamp [1,4], floored (never fractional), NaN/inf/non-number
-- routed to the default, and surfaced through normalizedPrefs (the typed read-through).
--
-- settings.lua is PURE (imports no Lr*); this spec runs under stock lua / luajit.
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no //, no goto, no <close>; unpack global).

local S = require('src.settings')

-- =====================================================================
-- DEFAULT: deepExportConcurrency default is 2 (D-03), and it is a SEPARATE key.
-- =====================================================================
assert_eq(S.DEFAULTS.deepExportConcurrency, 2, "default deepExportConcurrency is 2 (D-03)")
assert_true(S.DEFAULTS.maxConcurrency ~= nil, "maxConcurrency still exists (not removed)")
assert_true(S.DEFAULTS.deepExportConcurrency ~= S.DEFAULTS.maxConcurrency
    or (S.DEFAULTS.maxConcurrency == 2),
    "deepExportConcurrency is its own key (default 2 != maxConcurrency default 1)")

-- =====================================================================
-- validate: integer clamp [1,4], default 2 (mirrors the maxConcurrency clampInt branch).
-- =====================================================================
assert_eq(S.validate("deepExportConcurrency", 2), 2, "deepExportConcurrency 2 kept")
assert_eq(type(S.validate("deepExportConcurrency", 2)), "number", "deepExportConcurrency is a number")
assert_eq(S.validate("deepExportConcurrency", 0), 1, "deepExportConcurrency 0 clamps up to 1 (low)")
assert_eq(S.validate("deepExportConcurrency", -5), 1, "deepExportConcurrency -5 clamps up to 1")
assert_eq(S.validate("deepExportConcurrency", 1), 1, "deepExportConcurrency 1 kept (lo bound)")
assert_eq(S.validate("deepExportConcurrency", 4), 4, "deepExportConcurrency 4 kept (hi bound)")
assert_eq(S.validate("deepExportConcurrency", 9), 4, "deepExportConcurrency 9 clamps to 4 (high)")
assert_eq(S.validate("deepExportConcurrency", 2.7), 2, "deepExportConcurrency 2.7 floored to 2")
assert_eq(S.validate("deepExportConcurrency", "3"), 3, "deepExportConcurrency '3' coerced to 3")
assert_eq(S.validate("deepExportConcurrency", "x"), 2, "deepExportConcurrency garbage -> default 2")
assert_eq(S.validate("deepExportConcurrency", 0 / 0), 2, "deepExportConcurrency NaN -> default 2")
assert_eq(S.validate("deepExportConcurrency", 1 / 0), 2, "deepExportConcurrency +inf -> default 2")
assert_eq(S.validate("deepExportConcurrency", -1 / 0), 2, "deepExportConcurrency -inf -> default 2")
assert_eq(S.validate("deepExportConcurrency", nil), 2, "deepExportConcurrency nil -> default 2")

-- =====================================================================
-- normalizedPrefs read-through: the default surfaces, and a provided value is clamped through.
-- =====================================================================
assert_eq(S.normalizedPrefs({}).deepExportConcurrency, 2,
    "normalizedPrefs({}) surfaces the default 2")
assert_eq(S.normalizedPrefs({ deepExportConcurrency = 3 }).deepExportConcurrency, 3,
    "normalizedPrefs read-through keeps a valid 3")
assert_eq(S.normalizedPrefs({ deepExportConcurrency = 99 }).deepExportConcurrency, 4,
    "normalizedPrefs clamps an out-of-range 99 to 4")
assert_eq(S.normalizedPrefs(nil).deepExportConcurrency, 2,
    "normalizedPrefs(nil) returns a typed DEFAULTS copy with deepExportConcurrency 2")

-- =====================================================================
-- NEVER raises (pcall battery over hostile inputs).
-- =====================================================================
do
    local vals = { 2, 0, -5, 4, 9, 2.7, "3", "x", 0 / 0, 1 / 0, nil, {}, true }
    for i = 1, #vals do
        assert_true(pcall(S.validate, "deepExportConcurrency", vals[i]),
            "validate(deepExportConcurrency) never raises (battery " .. i .. ")")
    end
end
