-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/settings.lua (Phase 2 — Settings & Secrets, PURE core)
--
-- PURE module: it pulls in no Lightroom SDK namespace at load time (no SDK import, no
-- SDK-namespace require), so it is require-able under stock lua / lua5.1 / luajit for
-- offline unit testing (the CODEX-mandated separation invariant). The SDK glue
-- (PluginInfoProvider.lua, the prefs binding + Keychain store/retrieve) is Wave 2 and is
-- the ONLY new SDK toucher.
--
-- Owns the load-bearing, provable half of Settings & Secrets:
--   * SET-01: provider/model catalog (+ custom-model escape hatch via isValidModel)
--   * SET-02: schema/defaults, validate (coerce/clamp, never raise) and the TYPED
--             read-through accessor normalizedPrefs
--   * SET-03 (pure half): isTokenPresent / tokenStatus classification of an undocumented
--             LrPasswords.retrieve result; defensive per-provider tokenKeyFor
--   * SET-04: the strict-allowlist sanitizePathHint (output PROVABLY in {"", curated})
--   * NIT:    DISCLOSURE_TEXT
--
-- Strictly Lua 5.1 common subset: no \u{}, no integer //, no goto, no <close>;
-- `unpack` is global; UTF-8 must be literal bytes, never escapes.

local M = {}

-- =====================================================================
-- SET-01: Provider / model catalog
--
-- Seeded per SPEC default = OpenAI; Claude + Gemini configurable. [CODEX #12] These
-- model IDs are EDITABLE PLACEHOLDERS, not a hard contract — model IDs churn monthly;
-- a custom non-empty model string must remain selectable (see isValidModel) so users
-- are never stranded when a seeded ID is retired. Provider *calls* are Phase 5/7.
-- [07-01 / CODEX MUST-FIX 11] Model IDs are VOLATILE; NEVER hard-fail on an unknown model —
-- the custom-model escape hatch (isValidModel accepts any non-empty string) covers retired/new
-- IDs. The claude/gemini IDs below were refreshed to current 2026 values (07-RESEARCH State of
-- the Art); the prior 2024-era placeholders are retired in favor of the current Opus/Sonnet/Haiku
-- and Gemini 3.x families.
-- =====================================================================
M.PROVIDERS = {
    { value = "openai", title = "OpenAI (default)",
      models = { "gpt-4o", "gpt-4o-mini", "gpt-5" } },
    { value = "claude", title = "Claude (Anthropic)",
      models = { "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5" } },
    { value = "gemini", title = "Gemini (Google)",
      models = { "gemini-3.5-flash", "gemini-3.1-pro", "gemini-3-flash" } },
}

-- providerItems() -> { {title=,value=}, ... } ; FIRST value is "openai" (default per SPEC).
function M.providerItems()
    local out = {}
    for _, p in ipairs(M.PROVIDERS) do
        out[#out + 1] = { title = p.title, value = p.value }
    end
    return out
end

-- providerByValue(value) -> the catalog entry table, or nil. Internal helper.
local function providerByValue(value)
    if type(value) ~= "string" then return nil end
    for _, p in ipairs(M.PROVIDERS) do
        if p.value == value then return p end
    end
    return nil
end

-- modelItemsFor(providerValue) -> { {title=,value=}, ... } ; EMPTY table (never nil)
-- for an unknown provider.
function M.modelItemsFor(providerValue)
    local p = providerByValue(providerValue)
    local out = {}
    if p then
        for _, m in ipairs(p.models) do
            out[#out + 1] = { title = m, value = m }
        end
    end
    return out
end

-- isValidModel(provider, model) [CODEX #12] -> true for a catalog model OR a non-empty
-- custom string (model IDs churn); false for empty/nil/non-string model, or unknown
-- provider. A custom non-empty model must not strand users; an unknown provider rejects.
-- NOTE: this is intentionally lenient (it accepts a custom string). Do NOT use it to
-- decide whether a model belongs to a provider on provider-switch — use isCatalogModel.
function M.isValidModel(provider, model)
    local p = providerByValue(provider)
    if not p then return false end
    if type(model) ~= "string" or model == "" then return false end
    return true
end

-- isCatalogModel(provider, model) [CODEX MUST-FIX 2] -> true ONLY when `model` is one of
-- the provider's seeded catalog models. Used by the provider-change observer to detect a
-- STALE cross-provider model (e.g. "gpt-4o" left selected after switching to "claude"):
-- isValidModel is too lenient for that decision because it green-lights any non-empty
-- string. A custom model is NOT a catalog model, so the observer falls back to the
-- provider default unless the user has explicitly entered a custom model.
function M.isCatalogModel(provider, model)
    local p = providerByValue(provider)
    if not p or type(model) ~= "string" then return false end
    for _, m in ipairs(p.models) do
        if m == model then return true end
    end
    return false
end

-- defaultModelFor(provider) -> the provider's FIRST catalog model, or nil for an unknown
-- provider. The observer resets to this when the current model is not a catalog model.
function M.defaultModelFor(provider)
    local p = providerByValue(provider)
    if not p or not p.models[1] then return nil end
    return p.models[1]
end

-- isAnyCatalogModel(model) -> true iff `model` is a catalog model of ANY known provider. Used to
-- distinguish a STALE cross-provider catalog model (must reset) from a genuine CUSTOM string (the
-- escape hatch — must be KEPT). A custom non-empty string belongs to no provider's catalog.
local function isAnyCatalogModel(model)
    if type(model) ~= "string" then return false end
    for _, p in ipairs(M.PROVIDERS) do
        for _, m in ipairs(p.models) do
            if m == model then return true end
        end
    end
    return false
end

-- reconcileModel(provider, model) [CODEX phase-7 N2] -> the model to use for `provider`.
-- PURE; no Lr. The ONLY case we reset to defaultModelFor(provider) is a STALE CROSS-PROVIDER
-- catalog model: `model` is a catalog model of a DIFFERENT provider (e.g. provider='claude' with
-- model='gpt-4o'). Otherwise we KEEP `model`:
--   * a catalog model of THIS provider -> keep;
--   * a non-empty CUSTOM string (not in ANY provider's catalog) -> keep (custom-model escape hatch);
-- An empty/nil/non-string model falls back to the provider default.
function M.reconcileModel(provider, model)
    if type(model) ~= "string" or model == "" then
        return M.defaultModelFor(provider)
    end
    if M.isCatalogModel(provider, model) then
        return model                       -- this provider's catalog model: keep.
    end
    if isAnyCatalogModel(model) then
        return M.defaultModelFor(provider) -- stale cross-provider catalog model: reset.
    end
    return model                           -- custom non-catalog string: keep (escape hatch).
end

-- =====================================================================
-- SET-02: Defaults (the exact eight pref keys)
-- =====================================================================
M.DEFAULTS = {
    provider            = "openai",
    model               = "gpt-4o",
    promptAddition      = "",
    confidenceThreshold = 0.6,    -- [0,1]; the "sortable hint" gate (CLAUDE.md bird-ID reality)
    previewSize         = 2048,   -- px max edge requested from requestJpegThumbnail
    rateLimit           = 1.0,    -- seconds between AI calls (LrTasks.sleep, Phase 5)
    sendGpsDate         = true,   -- opt-in, DEFAULT ON  (SPEC §3, FR4)
    usePathHint         = false,  -- opt-in, DEFAULT OFF (SPEC §3, SET-04, R8)
    dryRun              = false,  -- WR-04: report the plan, write NOTHING; DEFAULT OFF
    singleKeywordPerPhoto = false,-- false = per-detection (deduped); true = keep only the single best keyword/photo
    -- 06-01 (Phase 6 — Crop-for-ID): the opt-in crop pass + its external tool + size cap.
    cropEnabled         = false,  -- CROP: opt-in crop-for-ID refinement, DEFAULT OFF (SPEC §3)
    imageToolPath       = "",     -- absolute path to the external crop tool (magick); "" = unset.
                                  -- Absoluteness/leading-dash/existence are enforced in the GLUE
                                  -- at exec time (06-02 CROP-02), NOT here — settings only coerces.
    maxCropEdge         = 2048,   -- longest-edge cap for the re-query crop (mirrors previewSize)
}

-- =====================================================================
-- 04-02: settings.toBool — the SINGLE shared FAIL-CLOSED boolean parser.
--
-- LrPrefs/edit_field yield STRINGS, and every non-empty string is truthy in Lua, so the
-- old `value and true or false` coercion let a string "false" become true (a privacy
-- toggle could silently flip ON). toBool is the one rule routed by validate for ALL
-- boolean keys: it returns a REAL boolean (never nil/string), failing CLOSED for
--   * real boolean false
--   * nil
--   * numeric 0
--   * a string that, after trim + lowercase, is one of {"false","no","off","0",""}
-- and returning true for everything else (real true, any other string, any non-zero number).
-- This is the shared extraction of metadata.lua's local toggleOn/FALSE_STRINGS intent.
-- =====================================================================
local FALSE_STRINGS = {
    ["false"] = true, ["no"] = true, ["off"] = true, ["0"] = true, [""] = true,
}
-- trim leading/trailing whitespace (Lua 5.1 subset; gsub returns 2 values, parenthesize).
local function trimWs(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
function M.toBool(v)
    if v == false or v == nil then return false end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then
        return not FALSE_STRINGS[trimWs(v):lower()]
    end
    return true
end

-- =====================================================================
-- SET-02: Validation — coerce/clamp/normalize; NEVER raises.
-- =====================================================================
-- clampNumber: tonumber the value, fall back to default on non-number (incl. NaN/inf
-- handling: NaN fails the comparisons so we route it to the default; inf clamps to hi).
local function clampNumber(v, lo, hi, default)
    local n = tonumber(v)
    if type(n) ~= "number" then return default end
    if n ~= n then return default end   -- NaN guard (NaN ~= NaN)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

function M.validate(key, value)
    if key == "confidenceThreshold" then return clampNumber(value, 0, 1, 0.6) end
    if key == "previewSize" then return clampNumber(value, 512, 8192, 2048) end
    if key == "rateLimit" then return clampNumber(value, 0, 60, 1.0) end
    -- 06-01: maxCropEdge clamps to the same sane bounds as previewSize (512..8192), default 2048.
    if key == "maxCropEdge" then return clampNumber(value, 512, 8192, 2048) end
    if key == "sendGpsDate" or key == "usePathHint"
        or key == "dryRun" or key == "singleKeywordPerPhoto"
        or key == "cropEnabled" then
        -- 04-02: ALL boolean keys go through the shared fail-closed parser. (Retroactively
        -- fixes sendGpsDate/usePathHint: the old `value and true or false` let a string
        -- "false" through, because every non-empty string is truthy in Lua.)
        return M.toBool(value)
    end
    if key == "provider" or key == "model" or key == "promptAddition"
        or key == "imageToolPath" then
        -- 06-01: imageToolPath is string-coerced ONLY here; absoluteness/leading-dash/existence
        -- are enforced in the GLUE at exec time (06-02 CROP-02), not in settings.
        return tostring(value or "")
    end
    -- Unknown key: passthrough (never raise).
    return value
end

-- =====================================================================
-- SET-02: normalizedPrefs — the TYPED read-through accessor (CODEX #2)
--
-- CONTRACT: Downstream phases (3/5/6/7) MUST read numeric prefs through this accessor.
-- LrPrefs + edit_field produce STRING values for numeric fields; reading
-- confidenceThreshold/previewSize/rateLimit straight off the prefs table yields strings
-- and breaks numeric comparisons. normalizedPrefs returns a NEW table where each
-- DEFAULTS key has been passed through M.validate, so numerics are NUMBERS and booleans
-- are real booleans. Accepts a nil rawPrefs (returns a typed DEFAULTS copy). NEVER raises.
-- =====================================================================
function M.normalizedPrefs(rawPrefs)
    if type(rawPrefs) ~= "table" then rawPrefs = {} end
    local out = {}
    for k in pairs(M.DEFAULTS) do
        local v = rawPrefs[k]
        if v == nil then v = M.DEFAULTS[k] end
        out[k] = M.validate(k, v)
    end
    return out
end

-- =====================================================================
-- NIT: Disclosure text (SET-04). Plain UTF-8 literal bytes only.
-- MUST state GPS/date is ON by default and the path-hint is OFF by default — never any
-- "both off" phrasing (the GPS/date toggle defaults ON).
-- =====================================================================
M.DISCLOSURE_TEXT =
    "Privacy: when enabled, your photo's GPS coordinates and capture date are sent to " ..
    "the third-party AI provider you selected to improve identification accuracy. The " ..
    "optional location hint is a coarse region label only -- never your file path, " ..
    "username, or drive. GPS/date sharing is ON by default; the path-hint is OFF by " ..
    "default. You can change either at any time in Plug-in Manager."

-- =====================================================================
-- SET-04: Path-hint sanitizer (security-critical) [CODEX #7/#8]
--
-- STRICT ALLOWLIST. The output is PROVABLY "" or a curated GEO_ALLOWLIST constant for
-- ALL inputs. The /Users/<username> and /Volumes/<drive> POSITIONAL segments are
-- DROPPED before any matching, so an allowlisted-country username/drive
-- (/Users/Canada, /Volumes/Germany, /Users/Japan) can NEVER leak. UNC //server/...
-- paths are not supported (return ""). Countries-only allowlist to start (Open Q4).
-- =====================================================================
-- [CODEX SHOULD-FIX] Short ambiguous aliases ("us", "uk") are intentionally OMITTED: a
-- folder literally named "us"/"uk" is far more likely a project/client/initials label than
-- a country, so matching them would infer geography from non-geographic private folders.
-- Only unambiguous full country names (and well-known long aliases) are emittable.
M.GEO_ALLOWLIST = {            -- values are the ONLY emittable strings
    ["usa"] = "United States", ["united states"] = "United States",
    ["united kingdom"] = "United Kingdom",
    ["germany"] = "Germany", ["deutschland"] = "Germany",
    ["canada"] = "Canada", ["australia"] = "Australia", ["france"] = "France",
    ["spain"] = "Spain", ["italy"] = "Italy", ["japan"] = "Japan",
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.sanitizePathHint(path)
    if type(path) ~= "string" or path == "" then return "" end

    -- UNC paths ("//server/share/..." or "\\server\share\...") are NOT supported:
    -- the leading double separator means the first real segment is a host/share name
    -- (structural, not a region), so reject the whole path up front.
    if path:match("^//") or path:match("^\\\\") then return "" end

    -- Split into structural segments on / and \ (collapses repeated separators).
    local segs = {}
    for segment in path:gmatch("[^/\\]+") do
        segs[#segs + 1] = segment
    end
    if #segs == 0 then return "" end

    -- Drop the structural-PII segments BEFORE any matching. [CODEX MUST-FIX 1] The
    -- "Users"/"Volumes" anchor can appear at ANY position, not just segment 1
    -- (e.g. "/System/Volumes/Data/Users/Canada/...", "C:\\Users\\Canada\\...",
    -- "foo/Users/Germany/..."). So whenever a segment is the "users" or "volumes"
    -- anchor, skip BOTH it and the immediately-following PII segment (username/drive)
    -- so an allowlisted-country username/drive can NEVER leak. A drive letter like
    -- "C:" is not an anchor and is harmless (never in the allowlist).
    local skipNext = false
    for i = 1, #segs do
        local lower = segs[i]:lower()
        if skipNext then
            skipNext = false                 -- this is a username/drive: never matched
        elseif lower == "users" or lower == "volumes" then
            skipNext = true                  -- skip the anchor AND the next segment
        else
            local mapped = M.GEO_ALLOWLIST[trim(lower)]
            if mapped then return mapped end -- a CURATED constant, never raw input
        end
    end
    return ""                              -- safe default: no hint
end

-- =====================================================================
-- SET-03 (pure half): token-result classification + defensive key naming
-- =====================================================================

-- isTokenPresent(ok, val) [CODEX #4] -> true ONLY when ok==true AND val is a non-empty
-- string. Any other shape (ok false, nil, empty, non-string) is "no token".
function M.isTokenPresent(ok, val)
    return ok == true and type(val) == "string" and val ~= ""
end

-- tokenStatus(ok, val) [CODEX #4] -> one of:
--   "keychain_error" when ok==false (a raised/locked LrPasswords.retrieve)
--   "set"            when ok==true and val is a non-empty string
--   "absent"         when ok==true but val is non-string/empty
-- This is the SET-03 classification, made pure so the Lr glue carries no logic and can
-- distinguish a locked/error keychain from a genuinely-absent token.
function M.tokenStatus(ok, val)
    if ok ~= true then return "keychain_error" end
    if M.isTokenPresent(ok, val) then return "set" end
    return "absent"
end

-- tokenKeyFor(provider) [CODEX #6] -> a STABLE, distinct per-provider Keychain key
-- string, but ONLY for providers present in M.PROVIDERS. For any value not in the
-- catalog (unknown, nil, non-string, or injection-shaped like "\n" or "../") return
-- NIL so the glue disables token save and never builds an arbitrary Keychain key from
-- raw prefs. These names are STABLE (renaming orphans stored tokens). One key per
-- provider (Open Q1) so switching providers does not lose the other token.
function M.tokenKeyFor(provider)
    -- Only catalog providers are eligible. providerByValue already rejects non-strings.
    -- Catalog values are simple lowercase identifiers, so an injection-shaped input
    -- (containing "\n", "/", "..", etc.) can never equal a catalog value and returns nil.
    local p = providerByValue(provider)
    if not p then return nil end
    return p.value .. "_api_token"
end

return M
