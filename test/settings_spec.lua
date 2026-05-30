-- test/settings_spec.lua (Phase 2 — Settings & Secrets, pure core)
--
-- Exercises BirdAID.lrdevplugin/src/settings.lua: a PURE module (imports NO Lr*),
-- require-able under stock lua / luajit. Covers SET-01 (provider/model catalog +
-- custom-model acceptance), SET-02 (schema/defaults/validation + TYPED normalizedPrefs),
-- the SET-03 pure token classifier (isTokenPresent/tokenStatus) and the defensive
-- tokenKeyFor, plus the SET-04 adversarial path-hint sanitizer invariant.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local S = require('src.settings')

-- =====================================================================
-- SET-02: DEFAULTS (exact eight keys + values)
-- =====================================================================
assert_eq(S.DEFAULTS.provider, "openai", "default provider is openai")
assert_eq(S.DEFAULTS.model, "gpt-4o", "default model is gpt-4o")
assert_eq(S.DEFAULTS.promptAddition, "", "default promptAddition is empty string")
assert_eq(S.DEFAULTS.confidenceThreshold, 0.6, "default confidenceThreshold is 0.6")
assert_eq(S.DEFAULTS.previewSize, 2048, "default previewSize is 2048")
assert_eq(S.DEFAULTS.rateLimit, 1.0, "default rateLimit is 1.0")
assert_eq(S.DEFAULTS.sendGpsDate, true, "default sendGpsDate is true (opt-in DEFAULT ON)")
assert_eq(S.DEFAULTS.usePathHint, false, "default usePathHint is false (opt-in DEFAULT OFF)")
assert_eq(S.DEFAULTS.dryRun, false, "default dryRun is false (WR-04 report-without-write OFF)")
assert_eq(S.DEFAULTS.singleKeywordPerPhoto, false,
    "default singleKeywordPerPhoto is false (per-detection deduped)")

-- =====================================================================
-- 06-01: Phase-6 crop prefs added to DEFAULTS.
--   cropEnabled   -- opt-in crop-for-ID pass, DEFAULT OFF (SPEC §3; fail-closed boolean)
--   imageToolPath -- absolute path to the external crop tool (magick), DEFAULT ""
--   maxCropEdge   -- longest-edge cap for the re-query crop, DEFAULT 2048 (mirrors previewSize)
-- =====================================================================
assert_eq(S.DEFAULTS.cropEnabled, false, "default cropEnabled is false (opt-in DEFAULT OFF)")
assert_eq(S.DEFAULTS.imageToolPath, "", "default imageToolPath is empty string")
assert_eq(S.DEFAULTS.maxCropEdge, 2048, "default maxCropEdge is 2048 (mirrors previewSize)")

-- =====================================================================
-- 04-02: settings.toBool — SHARED fail-closed boolean parser
-- false / nil / numeric 0 / trimmed-lowercased {"false","no","off","0",""} -> false;
-- everything else -> true. Always returns a REAL boolean (never nil/string).
-- =====================================================================
-- the false-set
assert_eq(S.toBool(false), false, "toBool(false) -> false")
assert_eq(S.toBool(nil), false, "toBool(nil) -> false")
assert_eq(S.toBool(0), false, "toBool(0) -> false")
assert_eq(S.toBool("false"), false, "toBool('false') -> false")
assert_eq(S.toBool("no"), false, "toBool('no') -> false")
assert_eq(S.toBool("off"), false, "toBool('off') -> false")
assert_eq(S.toBool("0"), false, "toBool('0') -> false")
assert_eq(S.toBool(""), false, "toBool('') -> false")
-- trim + lowercase
assert_eq(S.toBool("  FALSE  "), false, "toBool('  FALSE  ') -> false (trim + lower)")
assert_eq(S.toBool("Off"), false, "toBool('Off') -> false (lower)")
-- truthy values
assert_eq(S.toBool(true), true, "toBool(true) -> true")
assert_eq(S.toBool(1), true, "toBool(1) -> true")
assert_eq(S.toBool("true"), true, "toBool('true') -> true")
assert_eq(S.toBool("yes"), true, "toBool('yes') -> true")
assert_eq(S.toBool("anything"), true, "toBool('anything') -> true")
-- always a real boolean
assert_eq(type(S.toBool("false")), "boolean", "toBool('false') returns a real boolean")
assert_eq(type(S.toBool("anything")), "boolean", "toBool('anything') returns a real boolean")

-- =====================================================================
-- 04-02: validate routes ALL FOUR boolean keys through toBool (fail-closed).
-- This RETROACTIVELY hardens sendGpsDate/usePathHint (the old truthy coercion let
-- a string "false" through). For each of the four keys, string/numeric falses -> false.
-- =====================================================================
do
    local boolKeys = { "sendGpsDate", "usePathHint", "dryRun", "singleKeywordPerPhoto" }
    for _, k in ipairs(boolKeys) do
        assert_eq(S.validate(k, "false"), false, "validate(" .. k .. ", 'false') -> false")
        assert_eq(S.validate(k, "no"), false, "validate(" .. k .. ", 'no') -> false")
        assert_eq(S.validate(k, "off"), false, "validate(" .. k .. ", 'off') -> false")
        assert_eq(S.validate(k, ""), false, "validate(" .. k .. ", '') -> false")
        assert_eq(S.validate(k, 0), false, "validate(" .. k .. ", 0) -> false")
        assert_eq(S.validate(k, true), true, "validate(" .. k .. ", true) -> true")
        assert_eq(S.validate(k, "true"), true, "validate(" .. k .. ", 'true') -> true")
        assert_eq(type(S.validate(k, "false")), "boolean",
            "validate(" .. k .. ", 'false') is a real boolean")
    end
end

-- =====================================================================
-- SET-02: validate() coercion / clamping / boolean normalization
-- =====================================================================
-- confidenceThreshold [0,1] default 0.6
assert_eq(S.validate("confidenceThreshold", "0.6"), 0.6, "string '0.6' coerced to number 0.6")
assert_eq(type(S.validate("confidenceThreshold", "0.6")), "number", "coerced value is a number")
assert_eq(S.validate("confidenceThreshold", 5), 1, "confidenceThreshold 5 clamps to 1")
assert_eq(S.validate("confidenceThreshold", -1), 0, "confidenceThreshold -1 clamps to 0")
assert_eq(S.validate("confidenceThreshold", "garbage"), 0.6, "garbage falls back to default 0.6")

-- previewSize [512,8192] default 2048
assert_eq(S.validate("previewSize", "2048"), 2048, "previewSize string coerced to number")
assert_eq(S.validate("previewSize", 100), 512, "previewSize 100 clamps to 512")
assert_eq(S.validate("previewSize", 99999), 8192, "previewSize 99999 clamps to 8192")
assert_eq(S.validate("previewSize", "nope"), 2048, "previewSize garbage falls back to 2048")

-- rateLimit [0,60] default 1.0
assert_eq(S.validate("rateLimit", "1.0"), 1.0, "rateLimit string coerced to number")
assert_eq(S.validate("rateLimit", -5), 0, "rateLimit -5 clamps to 0")
assert_eq(S.validate("rateLimit", 999), 60, "rateLimit 999 clamps to 60")
assert_eq(S.validate("rateLimit", "x"), 1.0, "rateLimit garbage falls back to 1.0")

-- boolean normalization
assert_eq(S.validate("sendGpsDate", true), true, "sendGpsDate true stays true")
assert_eq(S.validate("sendGpsDate", nil), false, "sendGpsDate nil normalizes to false")
assert_eq(S.validate("sendGpsDate", false), false, "sendGpsDate false stays false")
assert_eq(S.validate("usePathHint", 1), true, "usePathHint truthy normalizes to true")
assert_eq(S.validate("usePathHint", nil), false, "usePathHint nil normalizes to false")

-- string coercion for provider/model/promptAddition
assert_eq(S.validate("provider", "openai"), "openai", "provider string passthrough")
assert_eq(S.validate("model", nil), "", "model nil coerces to empty string")
assert_eq(S.validate("promptAddition", 42), "42", "promptAddition number coerces to string")

-- =====================================================================
-- 06-01: Phase-6 crop pref validation.
--   cropEnabled routes through the SHARED fail-closed boolean parser (toBool) just like the
--   other booleans (string "false"/numeric 0/nil -> false).
--   imageToolPath is string-coerced ONLY here; absoluteness / leading-dash / existence are
--   ENFORCED IN THE GLUE at exec time (06-02 CROP-02), not in settings (boundary note).
--   maxCropEdge is clamped to the same sane bounds as previewSize (512..8192), default 2048.
-- =====================================================================
-- cropEnabled fail-closed boolean
assert_eq(S.validate("cropEnabled", "false"), false, "validate(cropEnabled,'false') -> false")
assert_eq(S.validate("cropEnabled", "true"), true, "validate(cropEnabled,'true') -> true")
assert_eq(S.validate("cropEnabled", nil), false, "validate(cropEnabled,nil) -> false (toBool nil)")
assert_eq(S.validate("cropEnabled", 0), false, "validate(cropEnabled,0) -> false (fail-closed)")
assert_eq(type(S.validate("cropEnabled", "false")), "boolean",
    "validate(cropEnabled) returns a real boolean")

-- imageToolPath string coercion (NOTE: absoluteness/existence are a GLUE-tier check, 06-02)
assert_eq(S.validate("imageToolPath", "/opt/homebrew/bin/magick"), "/opt/homebrew/bin/magick",
    "validate(imageToolPath, abs) passes through the string")
assert_eq(S.validate("imageToolPath", nil), "", "validate(imageToolPath, nil) -> '' (tostring(value or ''))")
assert_eq(S.validate("imageToolPath", 42), "42", "validate(imageToolPath, number) coerces to string")

-- maxCropEdge clamped number
assert_eq(S.validate("maxCropEdge", "4096"), 4096, "validate(maxCropEdge,'4096') -> number 4096")
assert_eq(type(S.validate("maxCropEdge", "4096")), "number", "maxCropEdge coerced to number")
assert_eq(S.validate("maxCropEdge", "99"), 512, "validate(maxCropEdge,'99') clamps to 512 (min)")
assert_eq(S.validate("maxCropEdge", 99999), 8192, "validate(maxCropEdge,99999) clamps to 8192 (max)")
assert_eq(S.validate("maxCropEdge", nil), 2048, "validate(maxCropEdge,nil) -> default 2048")
assert_eq(S.validate("maxCropEdge", "garbage"), 2048, "validate(maxCropEdge garbage) -> default 2048")

-- validate NEVER raises (pcall battery)
do
    local inputs = { nil, 0, -1, 5, "0.6", "garbage", true, false, {}, 1/0, -1/0 }
    local keys = { "confidenceThreshold", "previewSize", "rateLimit",
                   "sendGpsDate", "usePathHint", "provider", "model", "promptAddition",
                   "unknownKey" }
    for _, k in ipairs(keys) do
        for i = 1, #inputs do
            local ok = pcall(S.validate, k, inputs[i])
            assert_true(ok, "validate never raises for key " .. tostring(k))
        end
        -- explicit nil-value case (table holes drop nils)
        local okn = pcall(S.validate, k, nil)
        assert_true(okn, "validate never raises for nil value on key " .. tostring(k))
    end
end

-- =====================================================================
-- SET-02: normalizedPrefs — TYPED read-through (CODEX #2)
-- =====================================================================
do
    local raw = { confidenceThreshold = "0.6", previewSize = "2048", rateLimit = "1.0",
                  sendGpsDate = true, usePathHint = false,
                  provider = "openai", model = "gpt-4o", promptAddition = "" }
    local n = S.normalizedPrefs(raw)
    assert_eq(type(n.confidenceThreshold), "number", "normalizedPrefs confidenceThreshold is number")
    assert_eq(n.confidenceThreshold, 0.6, "normalizedPrefs confidenceThreshold value 0.6")
    assert_eq(type(n.previewSize), "number", "normalizedPrefs previewSize is number")
    assert_eq(n.previewSize, 2048, "normalizedPrefs previewSize value 2048")
    assert_eq(type(n.rateLimit), "number", "normalizedPrefs rateLimit is number")
    assert_eq(n.rateLimit, 1.0, "normalizedPrefs rateLimit value 1.0")
    assert_eq(type(n.sendGpsDate), "boolean", "normalizedPrefs sendGpsDate is boolean")
    assert_eq(n.provider, "openai", "normalizedPrefs provider preserved")
    assert_eq(n.model, "gpt-4o", "normalizedPrefs model preserved")
end

-- =====================================================================
-- Phase-4 code review CONFIRMED NON-ISSUE (CODEX #4): normalizedPrefs nil->default is
-- CORRECT and is NOT a fail-open bug. nil means ABSENT -> use the configured DEFAULT, and
-- sendGpsDate defaults ON per the locked SPEC. The fail-CLOSED rule applies only to a
-- PRESENT false-ish value ("false"->false), which toBool already enforces. No behavioral
-- change was made; these assertions pin the intended semantics.
-- =====================================================================
do
    assert_eq(S.normalizedPrefs({ sendGpsDate = nil }).sendGpsDate, true,
        "#4 non-issue: absent sendGpsDate -> DEFAULT ON (nil = use default, not fail-closed)")
    assert_eq(S.normalizedPrefs({}).sendGpsDate, true,
        "#4 non-issue: empty prefs -> sendGpsDate DEFAULT ON")
    assert_eq(S.normalizedPrefs({ sendGpsDate = "false" }).sendGpsDate, false,
        "#4 non-issue: a PRESENT false-ish string IS fail-closed to false (toBool)")
    assert_eq(S.normalizedPrefs({ sendGpsDate = false }).sendGpsDate, false,
        "#4 non-issue: a PRESENT boolean false stays false")
end

-- normalizedPrefs(nil) returns typed DEFAULTS copy
do
    local n = S.normalizedPrefs(nil)
    assert_eq(n.confidenceThreshold, 0.6, "normalizedPrefs(nil) confidenceThreshold default")
    assert_eq(type(n.confidenceThreshold), "number", "normalizedPrefs(nil) confidenceThreshold typed")
    assert_eq(n.previewSize, 2048, "normalizedPrefs(nil) previewSize default")
    assert_eq(n.sendGpsDate, true, "normalizedPrefs(nil) sendGpsDate default ON")
    assert_eq(n.usePathHint, false, "normalizedPrefs(nil) usePathHint default OFF")
    assert_eq(n.provider, "openai", "normalizedPrefs(nil) provider default")
end

-- =====================================================================
-- 04-02: normalizedPrefs round-trip for the new keys + retroactive boolean fix.
-- =====================================================================
do
    local n = S.normalizedPrefs(nil)
    assert_eq(n.dryRun, false, "normalizedPrefs(nil).dryRun default false")
    assert_eq(n.singleKeywordPerPhoto, false,
        "normalizedPrefs(nil).singleKeywordPerPhoto default false")
    assert_eq(type(n.dryRun), "boolean", "normalizedPrefs(nil).dryRun is a real boolean")
    assert_eq(type(n.singleKeywordPerPhoto), "boolean",
        "normalizedPrefs(nil).singleKeywordPerPhoto is a real boolean")
    assert_eq(type(n.sendGpsDate), "boolean", "normalizedPrefs(nil).sendGpsDate is a real boolean")
    assert_eq(type(n.usePathHint), "boolean", "normalizedPrefs(nil).usePathHint is a real boolean")
end
do
    assert_eq(S.normalizedPrefs({ dryRun = true }).dryRun, true,
        "normalizedPrefs({dryRun=true}).dryRun -> true")
    assert_eq(S.normalizedPrefs({ singleKeywordPerPhoto = true }).singleKeywordPerPhoto, true,
        "normalizedPrefs({singleKeywordPerPhoto=true}).singleKeywordPerPhoto -> true")
    -- THE RETROACTIVE FIX: a string "false" was previously truthy -> true; now fail-closed.
    assert_eq(S.normalizedPrefs({ sendGpsDate = "false" }).sendGpsDate, false,
        "normalizedPrefs({sendGpsDate='false'}).sendGpsDate -> false (retroactive fix)")
    assert_eq(S.normalizedPrefs({ usePathHint = "false" }).usePathHint, false,
        "normalizedPrefs({usePathHint='false'}).usePathHint -> false (retroactive fix)")
    assert_eq(S.normalizedPrefs({ dryRun = "off" }).dryRun, false,
        "normalizedPrefs({dryRun='off'}).dryRun -> false (fail-closed string)")
    assert_eq(S.normalizedPrefs({ singleKeywordPerPhoto = "0" }).singleKeywordPerPhoto, false,
        "normalizedPrefs({singleKeywordPerPhoto='0'}).singleKeywordPerPhoto -> false")
end

-- missing keys fall back to default
do
    local n = S.normalizedPrefs({ provider = "claude" })
    assert_eq(n.provider, "claude", "normalizedPrefs keeps provided provider")
    assert_eq(n.confidenceThreshold, 0.6, "normalizedPrefs missing confidenceThreshold uses default")
    assert_eq(type(n.confidenceThreshold), "number", "normalizedPrefs default still typed number")
end

-- =====================================================================
-- 06-01: normalizedPrefs surfaces the Phase-6 crop keys, typed.
-- =====================================================================
do
    local n = S.normalizedPrefs({})
    assert_eq(n.cropEnabled, false, "normalizedPrefs({}).cropEnabled default false")
    assert_eq(type(n.cropEnabled), "boolean", "normalizedPrefs({}).cropEnabled is a real boolean")
    assert_eq(n.imageToolPath, "", "normalizedPrefs({}).imageToolPath default empty string")
    assert_eq(type(n.imageToolPath), "string", "normalizedPrefs({}).imageToolPath is a string")
    assert_eq(n.maxCropEdge, 2048, "normalizedPrefs({}).maxCropEdge default 2048")
    assert_eq(type(n.maxCropEdge), "number", "normalizedPrefs({}).maxCropEdge is a number")
end
do
    assert_eq(S.normalizedPrefs({ cropEnabled = "true" }).cropEnabled, true,
        "normalizedPrefs({cropEnabled='true'}).cropEnabled -> true")
    assert_eq(S.normalizedPrefs({ cropEnabled = "false" }).cropEnabled, false,
        "normalizedPrefs({cropEnabled='false'}).cropEnabled -> false (fail-closed string)")
    assert_eq(S.normalizedPrefs({ imageToolPath = "/opt/homebrew/bin/magick" }).imageToolPath,
        "/opt/homebrew/bin/magick", "normalizedPrefs surfaces a configured imageToolPath")
    assert_eq(S.normalizedPrefs({ maxCropEdge = "4096" }).maxCropEdge, 4096,
        "normalizedPrefs({maxCropEdge='4096'}).maxCropEdge -> number 4096")
end

-- normalizedPrefs NEVER raises (pcall battery)
do
    local batteries = { nil, {}, { confidenceThreshold = "x" }, { previewSize = {} },
                        { rateLimit = true }, { provider = 1, model = 2 },
                        { confidenceThreshold = 1/0 } }
    for i = 1, #batteries do
        local ok = pcall(S.normalizedPrefs, batteries[i])
        assert_true(ok, "normalizedPrefs never raises (battery item " .. i .. ")")
    end
    assert_true(pcall(S.normalizedPrefs, nil), "normalizedPrefs(nil) never raises")
end

-- =====================================================================
-- SET-01: provider / model catalog
-- =====================================================================
do
    local items = S.providerItems()
    assert_true(type(items) == "table" and #items >= 1, "providerItems returns a non-empty list")
    assert_eq(items[1].value, "openai", "providerItems first value is openai (default)")
    assert_true(type(items[1].title) == "string" and items[1].title ~= "",
        "providerItems first has a non-empty title")
end

do
    local models = S.modelItemsFor("openai")
    assert_true(type(models) == "table" and #models >= 1, "modelItemsFor(openai) non-empty")
    assert_true(type(models[1].title) == "string" and type(models[1].value) == "string",
        "modelItemsFor entries are {title,value}")
    local none = S.modelItemsFor("nonexistent")
    assert_true(type(none) == "table" and #none == 0, "modelItemsFor(nonexistent) is empty table")
end

-- isValidModel (CODEX #12): catalog OR non-empty custom string; unknown provider rejects
assert_eq(S.isValidModel("openai", "gpt-4o"), true, "isValidModel catalog model true")
assert_eq(S.isValidModel("openai", "my-future-model"), true, "isValidModel non-empty custom true")
assert_eq(S.isValidModel("openai", ""), false, "isValidModel empty string false")
assert_eq(S.isValidModel("openai", nil), false, "isValidModel nil model false")
assert_eq(S.isValidModel("nonexistent-provider", "anything"), false, "isValidModel unknown provider false")

-- =====================================================================
-- SET-03 (pure half): isTokenPresent / tokenStatus
-- =====================================================================
assert_eq(S.isTokenPresent(true, "abc"), true, "isTokenPresent true+non-empty-string -> true")
assert_eq(S.isTokenPresent(false, "abc"), false, "isTokenPresent ok=false -> false")
assert_eq(S.isTokenPresent(true, nil), false, "isTokenPresent true+nil -> false")
assert_eq(S.isTokenPresent(true, ""), false, "isTokenPresent true+empty -> false")
assert_eq(S.isTokenPresent(true, 123), false, "isTokenPresent true+number -> false")

assert_eq(S.tokenStatus(false, "anything"), "keychain_error", "tokenStatus ok=false -> keychain_error")
assert_eq(S.tokenStatus(false, nil), "keychain_error", "tokenStatus ok=false nil -> keychain_error")
assert_eq(S.tokenStatus(true, "abc"), "set", "tokenStatus true+non-empty-string -> set")
assert_eq(S.tokenStatus(true, nil), "absent", "tokenStatus true+nil -> absent")
assert_eq(S.tokenStatus(true, ""), "absent", "tokenStatus true+empty -> absent")
assert_eq(S.tokenStatus(true, 5), "absent", "tokenStatus true+number -> absent")

-- =====================================================================
-- SET-03 (defensive): tokenKeyFor (CODEX #6)
-- =====================================================================
do
    local ko = S.tokenKeyFor("openai")
    local kc = S.tokenKeyFor("claude")
    local kg = S.tokenKeyFor("gemini")
    assert_true(type(ko) == "string" and ko ~= "", "tokenKeyFor(openai) non-nil string")
    assert_true(type(kc) == "string" and kc ~= "", "tokenKeyFor(claude) non-nil string")
    assert_true(type(kg) == "string" and kg ~= "", "tokenKeyFor(gemini) non-nil string")
    assert_true(ko ~= kc and kc ~= kg and ko ~= kg, "tokenKeyFor keys are distinct per provider")
    assert_eq(S.tokenKeyFor("openai"), ko, "tokenKeyFor stable across calls (same input same output)")
end
assert_eq(S.tokenKeyFor("nope"), nil, "tokenKeyFor unknown provider -> nil")
assert_eq(S.tokenKeyFor(nil), nil, "tokenKeyFor nil -> nil")
assert_eq(S.tokenKeyFor(123), nil, "tokenKeyFor number -> nil")
assert_eq(S.tokenKeyFor("openai\nx"), nil, "tokenKeyFor newline-injected -> nil")
assert_eq(S.tokenKeyFor("../x"), nil, "tokenKeyFor path-traversal-shaped -> nil")

-- =====================================================================
-- NIT: DISCLOSURE_TEXT
-- =====================================================================
assert_true(type(S.DISCLOSURE_TEXT) == "string" and S.DISCLOSURE_TEXT ~= "",
    "DISCLOSURE_TEXT is a non-empty string")

-- =====================================================================
-- SET-04: path-hint sanitizer (positive mappings + structural-PII drop
-- + adversarial battery + provable membership invariant)  [CODEX #7/#8]
-- =====================================================================

-- positive mappings via a NON-structural segment
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/2024/Germany/birds/x.cr2"), "Germany",
    "matches an allowlisted non-structural segment -> Germany")
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/usa/x.cr2"), "United States",
    "case-insensitive allowlist map -> United States")
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/secret-project/x.cr2"), "",
    "no allowlist match -> empty hint")

-- [CODEX #7] structural-PII segments (the /Users/<username> and /Volumes/<drive>
-- positional segments) NEVER participate in matching:
assert_eq(S.sanitizePathHint("/Users/Japan/Pictures/x"), "",
    "username 'Japan' is the /Users anchor follower -> dropped, not matched")
assert_eq(S.sanitizePathHint("/Volumes/United States/x"), "",
    "drive 'United States' is the /Volumes anchor follower -> dropped")
assert_eq(S.sanitizePathHint("/Users/Canada/x"), "",
    "username 'Canada' dropped, not matched")
assert_eq(S.sanitizePathHint("/Volumes/Germany/x"), "",
    "drive 'Germany' dropped, not matched")

-- [CODEX #8] adversarial battery
assert_eq(S.sanitizePathHint("//server/Canada/file"), "",
    "UNC //server/... not supported -> empty (Canada not matched)")
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/Deutschland /x"), "Germany",
    "trailing-space segment trimmed -> Germany")
-- the UTF-8 bytes for the two CJK chars meaning 'Japan' (literal bytes, never \u escapes)
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/\230\151\165\230\156\172/x"), "",
    "unicode segment with no allowlist match -> empty (no crash)")
assert_eq(S.sanitizePathHint("C:\\Users\\name\\Pictures\\secret\\x"), "",
    "Windows-style private-only path -> empty (anchor-relative; no match)")
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/private/family/2024/x.cr2"), "",
    "deeply-nested private-only path -> empty")

-- non-string / empty input
assert_eq(S.sanitizePathHint(nil), "", "sanitizePathHint(nil) -> empty (no raise)")
assert_eq(S.sanitizePathHint(""), "", "sanitizePathHint('') -> empty")
assert_eq(S.sanitizePathHint(123), "", "sanitizePathHint(number) -> empty (no raise)")
assert_true(pcall(S.sanitizePathHint, {}), "sanitizePathHint(table) never raises")

-- THE INVARIANT (SET-04 guarantee): output is ALWAYS "" or an allowlisted constant.
do
    local allowed = { [""] = true }
    for _, v in pairs(S.GEO_ALLOWLIST) do allowed[v] = true end
    local battery = {
        "/Users/jane/Pictures/2024/Germany/birds/x.cr2",
        "/Users/jane/Pictures/usa/x.cr2",
        "/Users/jane/Pictures/secret-project/x.cr2",
        "/Users/Japan/Pictures/x",
        "/Volumes/United States/x",
        "/Users/Canada/x",
        "/Volumes/Germany/x",
        "//server/Canada/file",
        "/Users/jane/Pictures/Deutschland /x",
        "/Users/jane/Pictures/\230\151\165\230\156\172/x",
        "C:\\Users\\name\\Pictures\\secret\\x",
        "/Users/jane/Pictures/private/family/2024/x.cr2",
        "", "/", "////", "/Users", "/Volumes",
    }
    for i = 1, #battery do
        local out = S.sanitizePathHint(battery[i])
        assert_true(allowed[out],
            "sanitizePathHint output is '' or an allowlist constant for input #" .. i)
    end
end

-- ADDITIONALLY: no raw private fragment ever appears in the output.
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/secret-project/x"):find("jane"), nil,
    "output never contains username 'jane'")
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/secret-project/x"):find("secret"), nil,
    "output never contains private folder 'secret'")
assert_eq(S.sanitizePathHint("/Users/Japan/Pictures/x"):find("Japan"), nil,
    "structural username 'Japan' never echoed")
assert_eq(S.sanitizePathHint("/Volumes/United States/x"):find("United"), nil,
    "structural drive 'United States' never echoed")

-- =====================================================================
-- [CODEX Phase-2 code-review MUST-FIX 1] anchor-anywhere structural-PII drop:
-- "Users"/"Volumes" can appear at ANY position (symlink/canonical/Windows/relative),
-- and the country-shaped username/drive that follows must NEVER leak.
-- =====================================================================
assert_eq(S.sanitizePathHint("/System/Volumes/Data/Users/Canada/Pictures/x.cr2"), "",
    "Users anchor mid-path: 'Canada' username dropped")
assert_eq(S.sanitizePathHint("/private/var/Users/Japan/Pictures/x.cr2"), "",
    "Users anchor mid-path: 'Japan' username dropped")
assert_eq(S.sanitizePathHint("C:\\Users\\Canada\\Pictures\\x.cr2"), "",
    "Windows Users anchor (seg 2): 'Canada' username dropped")
assert_eq(S.sanitizePathHint("foo/Users/Germany/Pictures/x.cr2"), "",
    "relative Users anchor: 'Germany' username dropped")
assert_eq(S.sanitizePathHint("/System/Volumes/Data/Volumes/Germany/x.cr2"), "",
    "Volumes anchor mid-path: 'Germany' drive dropped")
-- a real country FOLDER deeper than the structural anchor still maps (deliberate label)
assert_eq(S.sanitizePathHint("/System/Volumes/Data/Users/jane/Trips/France/x.cr2"), "France",
    "non-structural 'France' folder still maps after mid-path anchors")

-- [CODEX SHOULD-FIX] ambiguous short aliases 'us'/'uk' are NOT emittable (folder labels)
assert_eq(S.sanitizePathHint("/Users/jane/Clients/us/x.cr2"), "",
    "'us' folder no longer leaks 'United States' (ambiguous alias removed)")
assert_eq(S.sanitizePathHint("/Users/jane/Clients/uk/x.cr2"), "",
    "'uk' folder no longer leaks 'United Kingdom' (ambiguous alias removed)")
-- full names still work
assert_eq(S.sanitizePathHint("/Users/jane/Pictures/united states/x.cr2"), "United States",
    "full 'united states' still maps")

-- =====================================================================
-- [CODEX Phase-2 code-review MUST-FIX 2] isCatalogModel / defaultModelFor
-- (used by the provider-switch observer to detect a STALE cross-provider model)
-- =====================================================================
assert_eq(S.isCatalogModel("openai", "gpt-4o"), true,  "isCatalogModel openai catalog true")
assert_eq(S.isCatalogModel("claude", "gpt-4o"), false, "isCatalogModel rejects cross-provider model")
assert_eq(S.isCatalogModel("openai", "my-custom"), false, "isCatalogModel rejects custom string")
assert_eq(S.isCatalogModel("nope", "x"), false, "isCatalogModel unknown provider false")
assert_eq(S.defaultModelFor("openai"), "gpt-4o", "defaultModelFor openai -> first catalog model")
-- [07-01] claude/gemini catalog refreshed to current 2026 IDs; defaultModelFor tracks the new first entry.
assert_eq(S.defaultModelFor("claude"), "claude-opus-4-8", "defaultModelFor claude -> first catalog model (refreshed)")
assert_eq(S.defaultModelFor("gemini"), "gemini-3.5-flash", "defaultModelFor gemini -> first catalog model (refreshed)")
assert_eq(S.defaultModelFor("nope"), nil, "defaultModelFor unknown -> nil")

-- =====================================================================
-- [CODEX phase-7 N2] reconcileModel: the PURE model-reconcile decision behind http.buildDeps.
-- Reset to the provider default ONLY for a STALE cross-provider catalog model; KEEP this
-- provider's catalog model AND a custom non-catalog string (the escape hatch).
-- =====================================================================
assert_true(type(S.reconcileModel) == "function", "settings exposes reconcileModel")
-- stale cross-provider catalog model -> reset to the provider default.
assert_eq(S.reconcileModel("claude", "gpt-4o"), "claude-opus-4-8",
    "reconcileModel('claude','gpt-4o') -> claude default (stale cross-provider reset)")
assert_eq(S.reconcileModel("gemini", "gpt-4o"), "gemini-3.5-flash",
    "reconcileModel('gemini','gpt-4o') -> gemini default (stale cross-provider reset)")
assert_eq(S.reconcileModel("openai", "claude-opus-4-8"), "gpt-4o",
    "reconcileModel('openai','claude-opus-4-8') -> openai default (stale cross-provider reset)")
-- this provider's catalog model -> KEEP.
assert_eq(S.reconcileModel("claude", "claude-opus-4-8"), "claude-opus-4-8",
    "reconcileModel keeps this provider's catalog model")
assert_eq(S.reconcileModel("openai", "gpt-5"), "gpt-5",
    "reconcileModel keeps this provider's other catalog model")
-- a non-empty CUSTOM string (not in ANY provider catalog) -> KEEP (escape hatch).
assert_eq(S.reconcileModel("gemini", "gemini-custom-xyz"), "gemini-custom-xyz",
    "reconcileModel('gemini','gemini-custom-xyz') -> keeps the custom model (escape hatch)")
assert_eq(S.reconcileModel("claude", "some-brand-new-model"), "some-brand-new-model",
    "reconcileModel keeps an arbitrary custom string")
-- empty / nil model -> provider default.
assert_eq(S.reconcileModel("claude", ""), "claude-opus-4-8",
    "reconcileModel('claude','') -> claude default (empty model)")
assert_eq(S.reconcileModel("openai", nil), "gpt-4o",
    "reconcileModel('openai',nil) -> openai default (nil model)")
