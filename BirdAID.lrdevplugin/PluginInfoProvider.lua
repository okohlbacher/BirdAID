-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/PluginInfoProvider.lua (Phase 2 — Settings & Secrets, Lr glue)
--
-- The SINGLE new Lr-importing surface this phase adds. Like IdentifyBirds.lua it is a
-- top-level SDK-loaded file, so it MAY import Lr* namespaces -- the negative-purity gate
-- scans src/ only, and this file is NOT under src/. All decision logic it relies on lives
-- in the Wave-1 PURE src/settings.lua (defaults, catalog, validate, normalizedPrefs,
-- tokenKeyFor, tokenStatus, isValidModel, sanitizePathHint, DISCLOSURE_TEXT); this file is
-- thin wiring.
--
-- Responsibilities:
--   * SET-01: render the Plug-in Manager settings section via LrView.osFactory().
--   * SET-02: bind every NON-secret control EXPLICITLY to the observable LrPrefs table via
--             bind_to_object = prefs, so values actually persist. A bare `bind 'key'` inside
--             an InfoProvider binds to the InfoProvider property table (transient), NOT to
--             prefs -- so non-secret controls MUST use bind_to_object = prefs.
--   * SET-03: route the API token EXCLUSIVELY through LrPasswords (macOS Keychain). The
--             password_field binds to a TRANSIENT propertyTable (NEVER prefs, NEVER a log
--             line). Save is pcall-wrapped; tokenStatus flips to "set" ONLY on a successful
--             store; a failed store shows a non-secret LrDialogs error and never reports
--             success. tokenKeyFor(nil)/unknown provider disables Save.
--   * SET-04: GPS/date checkbox (default ON) + path-hint checkbox (default OFF) + the
--             disclosure paragraph (settings.DISCLOSURE_TEXT).
--   * SET-05: the one diagnostic line ("api token saved") goes through src/log.lua and
--             carries the provider only -- the token value is never constructed into a line.
--
-- A provider-change observer (on the PREFS provider key, which is the observable that
-- actually holds provider) recomputes the model popup, resets an invalid model to the new
-- provider's first model, clears the transient token entry, and recomputes tokenStatus for
-- the new provider's key.
--
-- Strictly Lua 5.1 common subset: no \u{}, no integer //, no goto, no <close>;
-- UTF-8 must be literal bytes, never escapes.

local LrView      = import 'LrView'
local LrPrefs     = import 'LrPrefs'
local LrPasswords = import 'LrPasswords'
local LrDialogs   = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'

-- Install the src.* module loader shim BEFORE any require of our modules: LrC's built-in
-- require cannot resolve dotted/subdirectory names. dofile is the documented escape hatch.
dofile(LrPathUtils.child(_PLUGIN.path, 'birdaid_bootstrap.lua'))

local settings = require 'src.settings'
local log      = require 'src.log'

local PLUGIN_ID = "com.okohlbacher.birdaid"

-- Persist-on-assignment defaults: set a DEFAULTS key ONLY when the pref is absent, so user
-- values are never clobbered. settings.DEFAULTS is a PLAIN table (safe with pairs); do NOT
-- iterate the prefs observable with bare pairs (it is an LrObservableTable).
local function ensureDefaults(prefs)
    for k, v in pairs(settings.DEFAULTS) do
        if prefs[k] == nil then
            prefs[k] = v
        end
    end
end

-- Derive the human-readable indicator label from a tokenStatus string. NEVER includes the
-- secret value -- only the classification.
local function labelForStatus(status)
    if status == "set" then
        return "Token: set"
    elseif status == "keychain_error" then
        return "Keychain locked or unavailable -- reopen after unlocking"
    else
        return "Token: not set"
    end
end

-- Defensively classify the stored token for a given Keychain key. tokenKey may be nil
-- (unknown/corrupt provider) -> never build a key from raw prefs; report "absent". When
-- non-nil, wrap LrPasswords.retrieve in pcall (a locked keychain may raise) and classify
-- with the pure settings.tokenStatus -> "set" | "absent" | "keychain_error".
local function computeTokenStatus(tokenKey)
    if tokenKey == nil then
        return "absent"
    end
    local ok, val = pcall(function()
        return LrPasswords.retrieve(tokenKey, nil, PLUGIN_ID)
    end)
    return settings.tokenStatus(ok, val)
end

-- Refresh the transient token UI state on propertyTable for the CURRENT provider:
-- recompute the active key, status, label, and whether Save is enabled (a nil key disables
-- Save). NEVER reads or stores the secret value.
local function refreshTokenState(propertyTable, prefs)
    local tokenKey = settings.tokenKeyFor(prefs.provider)
    local status   = computeTokenStatus(tokenKey)
    propertyTable.tokenStatus   = status
    propertyTable.tokenLabel    = labelForStatus(status)
    propertyTable.saveEnabled   = (tokenKey ~= nil)
end

local function sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    ensureDefaults(prefs)

    -- Transient (NON-persisted) token entry box: bound to propertyTable, NEVER to prefs.
    propertyTable.apiTokenEntry = ""
    -- [CODEX MUST-FIX 3] The model popup's items must be REACTIVE to provider changes, so
    -- bind them to this transient property (updated by the observer) rather than computing a
    -- static list once at render. Seed it for the current provider.
    propertyTable.modelItems = settings.modelItemsFor(prefs.provider)
    refreshTokenState(propertyTable, prefs)

    -- Provider-change observer. provider lives on the OBSERVABLE prefs table (a bare
    -- propertyTable observer would watch the wrong object), so observe prefs directly --
    -- LrPrefs tables are observable. On a provider switch: rebuild the model popup items,
    -- reset a STALE cross-provider model to the new provider's default, clear the transient
    -- token entry, and recompute token state for the new provider's key (nil key => "not set"
    -- + Save disabled). This guarantees no stale model/token survives a switch (Pitfall 4).
    prefs:addObserver('provider', function()
        -- [CODEX MUST-FIX 3] rebuild the popup item list for the new provider.
        propertyTable.modelItems = settings.modelItemsFor(prefs.provider)
        -- [CODEX MUST-FIX 2] isValidModel is too lenient (accepts any non-empty string), so a
        -- stale catalog model like "gpt-4o" would survive a switch to "claude". Use
        -- isCatalogModel: if the current model is NOT in the new provider's catalog, reset to
        -- that provider's default. (Custom-model entry is not exposed in the UI yet; when it
        -- is, this reset will be gated on a custom-model flag.)
        if not settings.isCatalogModel(prefs.provider, prefs.model) then
            local def = settings.defaultModelFor(prefs.provider)
            if def ~= nil then
                prefs.model = def
            end
        end
        propertyTable.apiTokenEntry = ""
        refreshTokenState(propertyTable, prefs)
    end)

    local bind = LrView.bind

    return {
        {
            title    = "BirdAID - Provider & Privacy",
            synopsis = "Configure the vision-AI provider, model, and privacy options.",

            f:row {
                f:static_text { title = "Provider:", width = 140 },
                f:popup_menu {
                    value = bind { key = 'provider', bind_to_object = prefs },
                    items = settings.providerItems(),
                },
            },

            f:row {
                f:static_text { title = "Model:", width = 140 },
                f:popup_menu {
                    value = bind { key = 'model', bind_to_object = prefs },
                    -- [CODEX MUST-FIX 3] reactive: rebuilt by the provider observer.
                    items = bind { key = 'modelItems', bind_to_object = propertyTable },
                },
            },

            f:row {
                f:static_text { title = "Prompt addition:", width = 140 },
                f:edit_field {
                    value = bind { key = 'promptAddition', bind_to_object = prefs },
                    width_in_chars = 40,
                    immediate = false,
                },
            },

            f:row {
                f:static_text { title = "Confidence threshold:", width = 140 },
                f:edit_field {
                    value = bind { key = 'confidenceThreshold', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },

            f:row {
                f:static_text { title = "Preview size (px):", width = 140 },
                f:edit_field {
                    value = bind { key = 'previewSize', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },

            f:row {
                f:static_text { title = "Rate limit (sec):", width = 140 },
                f:edit_field {
                    value = bind { key = 'rateLimit', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },

            f:row {
                f:checkbox {
                    title = "Send GPS + capture date to the AI (improves accuracy)",
                    value = bind { key = 'sendGpsDate', bind_to_object = prefs },
                },
            },

            f:row {
                f:checkbox {
                    title = "Use a sanitized location hint derived from the file path",
                    value = bind { key = 'usePathHint', bind_to_object = prefs },
                },
            },

            f:row {
                f:static_text {
                    title = settings.DISCLOSURE_TEXT,
                    width_in_chars = 60,
                    height_in_lines = 4,
                },
            },

            -- 06-02 (Phase 6 — Crop-for-ID): the opt-in crop pass + its external tool path.
            -- DEFAULTS alone leaves these keys HIDDEN, so they MUST be surfaced here (CODEX #15).
            -- Both bind EXPLICITLY to prefs so the values persist.
            f:row {
                f:checkbox {
                    title = "Enable crop-for-ID refinement pass (sends a tighter crop for a second look)",
                    value = bind { key = 'cropEnabled', bind_to_object = prefs },
                },
            },

            f:row {
                f:static_text { title = "Image tool path:", width = 140 },
                f:edit_field {
                    value = bind { key = 'imageToolPath', bind_to_object = prefs },
                    width_in_chars = 40,
                    immediate = false,
                },
            },

            f:row {
                f:static_text {
                    title = "Absolute path to the ImageMagick 'magick' binary " ..
                            "(e.g. /opt/homebrew/bin/magick). Required only when the crop " ..
                            "pass is enabled; macOS-only in v1.",
                    width_in_chars = 60,
                    height_in_lines = 2,
                },
            },

            -- TOKEN: bound to the TRANSIENT propertyTable (NEVER prefs). The entry is
            -- write-only; the secret is never read back into a visible field.
            f:row {
                f:static_text { title = "API token:", width = 140 },
                f:password_field {
                    value = bind { key = 'apiTokenEntry', bind_to_object = propertyTable },
                    width_in_chars = 40,
                },
            },

            f:row {
                f:static_text {
                    title = bind { key = 'tokenLabel', bind_to_object = propertyTable },
                    width_in_chars = 60,
                },
            },

            f:row {
                f:push_button {
                    title   = "Save token to Keychain",
                    enabled = bind { key = 'saveEnabled', bind_to_object = propertyTable },
                    action  = function()
                        local entry = propertyTable.apiTokenEntry or ""
                        if entry == "" then
                            return
                        end

                        -- Recompute the key at action time (provider may have changed). A nil
                        -- key (unknown provider) must NEVER yield an arbitrary Keychain key.
                        local key = settings.tokenKeyFor(prefs.provider)
                        if key == nil then
                            LrDialogs.message(
                                "Cannot save token",
                                "Unknown provider -- pick a valid provider first.",
                                "warning")
                            return
                        end

                        -- pcall-wrap the store: a locked keychain may raise. Flip status to
                        -- "set" ONLY inside the success branch -- never falsely report success.
                        local ok = pcall(function()
                            LrPasswords.store(key, entry, nil, PLUGIN_ID)
                        end)

                        if ok then
                            propertyTable.apiTokenEntry = ""
                            propertyTable.tokenStatus = "set"
                            propertyTable.tokenLabel  = labelForStatus("set")
                            -- The token VALUE never enters this line; provider is non-secret.
                            log.info("api token saved", { provider = prefs.provider })
                        else
                            -- The error message MUST NOT contain the token value.
                            LrDialogs.message(
                                "Could not save token",
                                "The macOS Keychain rejected the save (it may be locked). " ..
                                "Try again after unlocking.",
                                "critical")
                        end
                    end,
                },
            },
        },
    }
end

return { sectionsForTopOfDialog = sectionsForTopOfDialog }
