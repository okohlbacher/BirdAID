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
local keystore = require 'src.lr.keystore'
local log      = require 'src.log'

local PLUGIN_ID = "com.okohlbacher.birdaid"

-- The soft cap (D-11) is on LIVE keys, so #keyOrder <= MAX_KEYS ALWAYS. We pre-render EXACTLY
-- this many fixed POSITION-keyed row widgets up front (LrView sections are static once returned
-- -- Pitfall 4: a table.insert into a built section silently no-ops), then toggle visibility by
-- `p <= #keyOrder`. Rows are keyed by PRIORITY POSITION p (1..MAX_KEYS), NOT by storage ordinal;
-- the storage ordinal is resolved from keyOrder[p] at ACTION TIME (round-2 BLOCKER-A fix), so a
-- post-churn storage ordinal (e.g. 6) is fully renderable/saveable in whatever POSITION it holds.
local MAX_KEYS = 5

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

-- Human display name for a provider value (catalog title minus the " (default)" suffix), so the
-- token field can name WHICH provider's key is being set. Falls back to the raw value.
local function providerDisplay(provider)
    for _, it in ipairs(settings.providerItems()) do
        if it.value == provider then
            return (it.title:gsub("%s*%(default%)%s*$", ""))
        end
    end
    return tostring(provider or "")
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
    -- Make the field name WHICH provider's key it sets, so it is obvious the key is per-provider.
    propertyTable.tokenFieldTitle = "API token (" .. providerDisplay(prefs.provider) .. "):"
end

-- ---------------------------------------------------------------------------
-- Dynamic per-provider key list (D-08). Rows are KEYED BY PRIORITY POSITION.
-- ---------------------------------------------------------------------------

-- Read the keyOrder list (a plain array of STABLE storage ordinals in user priority order) for
-- a provider. Returns a fresh PLAIN Lua array (safe to iterate with ipairs / table.remove). An
-- LrObservableTable / nil pref yields an empty list; non-number entries are skipped defensively.
local function keyOrderFor(prefs, provider)
    local order = prefs['keyOrder_' .. tostring(provider)]
    local out = {}
    if type(order) == 'table' then
        for _, v in ipairs(order) do
            if type(v) == 'number' then
                out[#out + 1] = v
            end
        end
    end
    return out
end

-- Persist a plain keyOrder array back to prefs (assignment of a fresh table makes the change
-- observable). keyCount is DERIVED (= #order) for display/visibility only -- it is NEVER an
-- allocator. keyNextIndex is the monotonic high-water mark and is NOT touched here.
local function setKeyOrder(prefs, provider, order)
    prefs['keyOrder_' .. tostring(provider)] = order
    prefs['keyCount_' .. tostring(provider)] = #order
end

-- Recompute the per-POSITION row UI state on propertyTable for the CURRENT provider, driven by
-- keyOrder POSITIONS (p = 1..#keyOrder), NEVER by a 1..keyNextIndex loop. For each position p:
--   * keyRowVisible_<p>  = (p <= #keyOrder)   -- 5 positions always cover every live key
--   * keyRowOrdinal_<p>  = "key #<keyOrder[p]>" -- the STABLE storage ordinal as a NON-SECRET
--                          label (logs/labels reference the storage ordinal, NEVER position p)
--   * keyRowStatus_<p>   = labelForStatus(keystore.statusForSlot(provider, keyOrder[p]))  (VALUE-FREE)
--   * keyRowUpEnabled/keyRowDownEnabled gate the reorder buttons at the ends.
-- Also recompute keyAddEnabled = (#keyOrder < MAX_KEYS) -- the LIVE cap (D-11).
local function refreshKeyList(propertyTable, prefs)
    local provider = prefs.provider
    local order = keyOrderFor(prefs, provider)
    local n = #order
    for p = 1, MAX_KEYS do
        local visible = (p <= n)
        propertyTable['keyRowVisible_' .. p] = visible
        if visible then
            local storageIndex = order[p]
            -- NON-SECRET label: the STABLE storage ordinal (NOT the position number p).
            propertyTable['keyRowOrdinal_' .. p] = "key #" .. tostring(storageIndex)
            local status = keystore.statusForSlot(provider, storageIndex)
            propertyTable['keyRowStatus_' .. p] = labelForStatus(status)
            propertyTable['keyRowUpEnabled_' .. p]   = (p > 1)
            propertyTable['keyRowDownEnabled_' .. p] = (p < n)
        else
            propertyTable['keyRowOrdinal_' .. p] = ""
            propertyTable['keyRowStatus_' .. p]  = ""
            propertyTable['keyRowUpEnabled_' .. p]   = false
            propertyTable['keyRowDownEnabled_' .. p] = false
        end
    end
    propertyTable.keyAddEnabled = (n < MAX_KEYS)
    propertyTable.keyCountLabel = "Keys for this provider: " .. tostring(n) .. " of " .. tostring(MAX_KEYS)
end

local function sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    ensureDefaults(prefs)

    -- ON OPEN: silently migrate a pre-existing single key to storage ordinal 1 at priority
    -- position 1 (D-10). Idempotent (gated on the pure settings.needsMigration via the VALUE-FREE
    -- keystore.statusForSlot); never touches a Keychain value, never re-runs once keyOrder exists.
    keystore.migrateIfNeeded(prefs.provider, prefs)

    -- Transient (NON-persisted) token entry box: bound to propertyTable, NEVER to prefs.
    propertyTable.apiTokenEntry = ""
    -- [CODEX MUST-FIX 3] The model popup's items must be REACTIVE to provider changes, so
    -- bind them to this transient property (updated by the observer) rather than computing a
    -- static list once at render. Seed it for the current provider.
    propertyTable.modelItems = settings.modelItemsFor(prefs.provider)
    refreshTokenState(propertyTable, prefs)

    -- Per-POSITION TRANSIENT, WRITE-ONLY secret entries. apiTokenEntry_<p> binds to propertyTable
    -- (NEVER prefs) and NEVER holds the stored secret: a password_field shows nothing on open and
    -- is cleared after Save, so rebinding a position to a different storage ordinal across
    -- reorder/remove can NEVER orphan or leak the stored secret -- the secret lives ONLY in the
    -- Keychain keyed by the STABLE storage ordinal keyOrder[p] (round-2 BLOCKER-A discipline).
    for p = 1, MAX_KEYS do
        propertyTable['apiTokenEntry_' .. p] = ""
    end
    refreshKeyList(propertyTable, prefs)

    -- Observe the keyOrder list for the CURRENT provider so add/remove/reorder reactively recompute
    -- per-row visibility/labels/status (the D-08 landmine: NEVER table.insert a new row into a built
    -- section -- toggle visibility on the pre-rendered MAX_KEYS rows instead).
    prefs:addObserver('keyOrder_' .. tostring(prefs.provider), function()
        refreshKeyList(propertyTable, prefs)
    end)

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
        -- A provider switch also changes which keyOrder list is live: migrate the new provider's
        -- single key if needed (idempotent), clear all transient per-row entries, observe the new
        -- provider's keyOrder pref, and recompute the per-row list. (Observing the new key is
        -- additive -- an extra no-op observer on the prior provider's key is harmless since that
        -- list is no longer displayed; refreshKeyList always reads prefs.provider's current order.)
        keystore.migrateIfNeeded(prefs.provider, prefs)
        for p = 1, MAX_KEYS do
            propertyTable['apiTokenEntry_' .. p] = ""
        end
        prefs:addObserver('keyOrder_' .. tostring(prefs.provider), function()
            refreshKeyList(propertyTable, prefs)
        end)
        refreshKeyList(propertyTable, prefs)
    end)

    local bind = LrView.bind

    -- Build the MAX_KEYS pre-rendered POSITION rows UP FRONT (Pattern 3). Each row p owns a
    -- transient write-only password_field (apiTokenEntry_<p>), a NON-SECRET storage-ordinal label
    -- (keyRowOrdinal_<p> = keyOrder[p]), a value-free status label, and Save/Remove/Up/Down
    -- buttons. SAVE/REMOVE/REORDER all resolve storageIndex = keyOrder[p] AT ACTION TIME.
    local keyRows = {}
    for p = 1, MAX_KEYS do
        local pos = p   -- capture the POSITION for the closures below
        keyRows[#keyRows + 1] = f:row {
            visible = bind { key = 'keyRowVisible_' .. pos, bind_to_object = propertyTable },
            f:static_text {
                -- NON-SECRET label: the STABLE storage ordinal (keyOrder[pos]), never position pos.
                title = bind { key = 'keyRowOrdinal_' .. pos, bind_to_object = propertyTable },
                width = 90,
            },
            f:password_field {
                value = bind { key = 'apiTokenEntry_' .. pos, bind_to_object = propertyTable },
                width_in_chars = 30,
            },
            f:push_button {
                title  = "Save",
                action = function()
                    local entry = propertyTable['apiTokenEntry_' .. pos] or ""
                    if entry == "" then
                        return
                    end
                    -- Resolve the STABLE storage ordinal from keyOrder AT ACTION TIME (the position
                    -- may now map to a different ordinal after a reorder/remove).
                    local order = keyOrderFor(prefs, prefs.provider)
                    local storageIndex = order[pos]
                    if storageIndex == nil then
                        return  -- row no longer live (visibility should already hide it)
                    end
                    -- A nil slot key (unknown provider / bad index) disables the save.
                    local key = settings.tokenKeyForSlot(prefs.provider, storageIndex)
                    if key == nil then
                        LrDialogs.message(
                            "Cannot save key",
                            "Unknown provider -- pick a valid provider first.",
                            "warning")
                        return
                    end
                    -- Store ONLY via keystore (LrPasswords under the hood); the token VALUE never
                    -- enters a pref or a log line.
                    local ok = keystore.storeTokenForSlot(prefs.provider, storageIndex, entry)
                    if ok then
                        propertyTable['apiTokenEntry_' .. pos] = ""
                        propertyTable['keyRowStatus_' .. pos] = labelForStatus("set")
                        -- Log provider + STABLE STORAGE ORDINAL only -- NEVER the value, NEVER pos.
                        log.info("api key saved", { provider = prefs.provider, storageIndex = storageIndex })
                    else
                        LrDialogs.message(
                            "Could not save key",
                            "The system keychain rejected the save (it may be locked). " ..
                            "Try again after unlocking.",
                            "critical")
                    end
                end,
            },
            f:push_button {
                title   = "Up",
                enabled = bind { key = 'keyRowUpEnabled_' .. pos, bind_to_object = propertyTable },
                action  = function()
                    -- REORDER: swap ONLY keyOrder entries -- NEVER rename/rewrite a Keychain entry,
                    -- NEVER move a stored secret. Re-Save is not required for values to survive.
                    local order = keyOrderFor(prefs, prefs.provider)
                    if pos > 1 and order[pos] ~= nil then
                        order[pos], order[pos - 1] = order[pos - 1], order[pos]
                        setKeyOrder(prefs, prefs.provider, order)
                    end
                end,
            },
            f:push_button {
                title   = "Down",
                enabled = bind { key = 'keyRowDownEnabled_' .. pos, bind_to_object = propertyTable },
                action  = function()
                    local order = keyOrderFor(prefs, prefs.provider)
                    if order[pos] ~= nil and order[pos + 1] ~= nil then
                        order[pos], order[pos + 1] = order[pos + 1], order[pos]
                        setKeyOrder(prefs, prefs.provider, order)
                    end
                end,
            },
            f:push_button {
                title  = "Remove",
                action = function()
                    -- REMOVE: resolve the storage ordinal from keyOrder AT ACTION TIME, clear that
                    -- ordinal's Keychain entry (store ""), and drop the position from keyOrder.
                    -- NEVER decrement keyNextIndex (high-water only) -- so add->remove->add yields a
                    -- NEW higher ordinal, never reusing a freed one.
                    local order = keyOrderFor(prefs, prefs.provider)
                    local storageIndex = order[pos]
                    if storageIndex == nil then
                        return
                    end
                    -- Clear the slot's secret (Assumption A1). keyNextIndex is left untouched.
                    keystore.storeTokenForSlot(prefs.provider, storageIndex, "")
                    table.remove(order, pos)
                    setKeyOrder(prefs, prefs.provider, order)
                    -- Clear the transient entry on the now-shifted position set.
                    propertyTable['apiTokenEntry_' .. pos] = ""
                    log.info("api key removed", { provider = prefs.provider, storageIndex = storageIndex })
                end,
            },
        }
    end

    -- Assemble the dynamic key-list section by appending the pre-rendered POSITION rows to a
    -- header + count label + ADD button. Building the section table here (rather than table.insert
    -- into a RETURNED section) is the safe form -- nothing is mutated after the view is returned.
    local keySection = {
        title    = "BirdAID - API keys (priority order)",
        synopsis = "Add up to 5 keys per provider; they are tried in priority order (drag with Up/Down).",

        f:row {
            f:static_text {
                title = "Each row is a key in PRIORITY ORDER (top = tried first). Keys are stored "
                    .. "separately in the OS keychain by a STABLE storage number shown on each row; "
                    .. "reorder with Up/Down (no re-Save needed). The entry box is write-only and "
                    .. "clears after Save -- a saved key is never shown back; the status line tells "
                    .. "you which rows have a key.",
                width_in_chars = 60,
                height_in_lines = 4,
            },
        },
        f:row {
            f:static_text {
                title = bind { key = 'keyCountLabel', bind_to_object = propertyTable },
                width_in_chars = 40,
            },
            f:push_button {
                title   = "Add a key",
                enabled = bind { key = 'keyAddEnabled', bind_to_object = propertyTable },
                action  = function()
                    -- ADD only while #keyOrder < MAX_KEYS (the LIVE cap, D-11). Allocate the new
                    -- storage ordinal from the MONOTONIC keyNextIndex high-water pref (default 1),
                    -- append it to keyOrder, then bump keyNextIndex. The new ordinal is NEVER derived
                    -- from keyCount (BLOCKER fix) -- a freed ordinal is never reused.
                    local order = keyOrderFor(prefs, prefs.provider)
                    if #order >= MAX_KEYS then
                        return
                    end
                    local nextKey = 'keyNextIndex_' .. tostring(prefs.provider)
                    local newIdx = prefs[nextKey]
                    if type(newIdx) ~= 'number' or newIdx < 1 then
                        newIdx = 1
                    end
                    order[#order + 1] = newIdx
                    setKeyOrder(prefs, prefs.provider, order)
                    prefs[nextKey] = newIdx + 1   -- monotonic high-water: only ever increments
                    log.info("api key slot added", { provider = prefs.provider, storageIndex = newIdx })
                end,
            },
        },
    }
    for _, rowWidget in ipairs(keyRows) do
        keySection[#keySection + 1] = rowWidget
    end

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

            -- TOKEN: bound to the TRANSIENT propertyTable (NEVER prefs). The entry is
            -- write-only; the secret is never read back into a visible field. The label names the
            -- CURRENT provider (reactive) so it is clear the key is stored PER provider.
            f:row {
                f:static_text {
                    title = bind { key = 'tokenFieldTitle', bind_to_object = propertyTable },
                    width = 140,
                },
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

            -- Make the per-provider key model discoverable (users expected one global key).
            f:row {
                f:static_text {
                    title = "Each provider keeps its OWN key. To use more than one, switch "
                        .. "\"Provider\" above, enter that provider's key, and Save again. Keys are "
                        .. "stored separately in the OS keychain; this field clears on switch (the "
                        .. "saved key is never shown) — the status line above tells you if the "
                        .. "selected provider has a key.",
                    width_in_chars = 60,
                    height_in_lines = 4,
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
                                "The system keychain rejected the save (it may be locked). " ..
                                "Try again after unlocking.",
                                "critical")
                        end
                    end,
                },
            },
        },

        -- 11-04 (DKEY): the dynamic per-provider add/remove/reorder key list (built above).
        keySection,

        -- 09-01 (Phase 9 — Throughput / Cluster / Viz): the three greenlit v1.0 features, all OFF/
        -- serial by default so today's behavior is unchanged. Each control binds EXPLICITLY to prefs
        -- (bind_to_object = prefs) so the value persists. NO secrets in this section.
        {
            title    = "BirdAID - Throughput & clustering",
            synopsis = "Parallel requests and burst/stack clustering (all OFF/serial by default).",

            f:row {
                f:static_text { title = "Number of parallel requests:", width = 180 },
                f:edit_field {
                    value = bind { key = 'maxConcurrency', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },
            f:row {
                f:static_text {
                    title = "How many photos are sent to the AI at the same time (1-50). " ..
                            "1 = one at a time (default). Higher = faster on large selections. " ..
                            "If your AI provider rejects requests for being too fast, BirdAID " ..
                            "automatically backs off and retries -- so just lower this number a bit. " ..
                            "Try 4-8 to start.",
                    width_in_chars = 60,
                    height_in_lines = 4,
                },
            },

            -- 13-04 (DEEP-03 / D-03): the SEPARATE full-res EXPORT parallelism cap for the
            -- "Deep identify…" command. It is NOT the AI request concurrency above — concurrent
            -- full-res exports are the exact risk class v1's preview-timeout cliff guarded, so
            -- this is its own knob (clamped 1-4, default 2; the spike-tuned escape hatch). Binds
            -- EXPLICITLY to prefs (bind_to_object = prefs) so it persists; NO secret here.
            f:row {
                f:static_text { title = "Deep export parallelism:", width = 180 },
                f:edit_field {
                    value = bind { key = 'deepExportConcurrency', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },
            f:row {
                f:static_text {
                    title = "Full-res export parallelism for \"Deep identify…\": 1-4, default 2; " ..
                            "the spike-tuned escape hatch -- separate from AI request concurrency. " ..
                            "Higher renders more full-res frames at once but risks the export " ..
                            "timeout cliff; lower it if deep runs stall.",
                    width_in_chars = 60,
                    height_in_lines = 3,
                },
            },

            f:row {
                f:checkbox {
                    title = "Cluster bursts (identify one anchor per near-duplicate group)",
                    value = bind { key = 'clusterBursts', bind_to_object = prefs },
                },
            },
            f:row {
                f:static_text { title = "Max gap (seconds):", width = 180 },
                f:edit_field {
                    value = bind { key = 'clusterMaxGapSeconds', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },
            f:row {
                f:checkbox {
                    title = "Also cluster photos in the same Lightroom stack",
                    value = bind { key = 'clusterUseStacks', bind_to_object = prefs },
                },
            },
            f:row {
                f:static_text { title = "Similarity threshold:", width = 180 },
                f:edit_field {
                    value = bind { key = 'clusterSimilarityThreshold', bind_to_object = prefs },
                    width_in_chars = 6,
                    immediate = false,
                },
            },
            f:row {
                f:static_text {
                    title = "Hamming distance 0..64 over an 8x8 average-hash; LOWER = stricter " ..
                            "(fewer merges). Clustering transfers ONE identification across " ..
                            "near-duplicate frames (a cost/correctness tradeoff, OFF by default). " ..
                            "If the anchor fails OR a sustained outage trips the breaker, the WHOLE " ..
                            "burst is deferred and retried on the next run (no keywords are written).",
                    width_in_chars = 60,
                    height_in_lines = 5,
                },
            },
        },

        {
            title    = "BirdAID - Detection report",
            synopsis = "Optionally open a per-photo detection report in your browser (OFF by default).",

            f:row {
                f:checkbox {
                    title = "Open a detection report in your browser after the run",
                    value = bind { key = 'showDetectionReport', bind_to_object = prefs },
                },
            },
            f:row {
                f:static_text {
                    title = "When on, BirdAID writes a self-contained SVG (the preview with blue " ..
                            "detection boxes, labels, and a per-box hover tooltip) to a temporary " ..
                            "file and opens it in your default browser. The image stays on your " ..
                            "machine; nothing extra is sent to the AI. OFF by default.",
                    width_in_chars = 60,
                    height_in_lines = 4,
                },
            },
        },
    }
end

return { sectionsForTopOfDialog = sectionsForTopOfDialog }
