-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/PluginInfoProvider.lua (Phase 2 — Settings & Secrets, Lr glue)
--
-- The SINGLE new Lr-importing surface this phase adds. Like IdentifyBirds.lua it is a
-- top-level SDK-loaded file, so it MAY import Lr* namespaces -- the negative-purity gate
-- scans src/ only, and this file is NOT under src/. All decision logic it relies on lives
-- in the Wave-1 PURE src/settings.lua (defaults, catalog, validate, normalizedPrefs,
-- key-status classification, isValidModel, sanitizePathHint, DISCLOSURE_TEXT); this file is
-- thin wiring.
--
-- Responsibilities:
--   * SET-01: render the Plug-in Manager settings section via LrView.osFactory().
--   * SET-02: bind every NON-secret control EXPLICITLY to the observable LrPrefs table via
--             bind_to_object = prefs, so values actually persist. A bare `bind 'key'` inside
--             an InfoProvider binds to the InfoProvider property table (transient), NOT to
--             prefs -- so non-secret controls MUST use bind_to_object = prefs.
--   * SET-03: route API keys EXCLUSIVELY through the Keychain (via src/lr/keystore, which
--             wraps LrPasswords). Every key entry binds to a TRANSIENT propertyTable (NEVER
--             prefs, NEVER a log line) and is write-only; the secret is never read back into
--             a visible field. The canonical credential UI is the per-provider "API keys
--             (priority order)" list below -- the original single-token field it subsumed was
--             retired (slot 1 already reuses the legacy <provider>_api_token Keychain id, so
--             existing single keys are never orphaned).
--   * SET-04: GPS/date checkbox (default ON) + path-hint checkbox (default OFF) + the
--             disclosure paragraph (settings.DISCLOSURE_TEXT).
--   * SET-05: the one diagnostic line ("api key saved") goes through src/log.lua and
--             carries the provider + non-secret storage ordinal only -- the value is never
--             constructed into a line.
--
-- A provider-change observer (on the PREFS provider key, which is the observable that
-- actually holds provider) recomputes the model popup, resets an invalid model to the new
-- provider's first model, and rebinds/refreshes the per-provider key list.
--
-- Strictly Lua 5.1 common subset: no \u{}, no integer //, no goto, no <close>;
-- UTF-8 must be literal bytes, never escapes.

local LrView      = import 'LrView'
local LrPrefs     = import 'LrPrefs'
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

-- Derive the human-readable indicator label from a key-status string ("set" |
-- "keychain_error" | other => "not set"). NEVER includes the secret value -- only the
-- classification.
local function labelForStatus(status)
    if status == "set" then
        return "Key: set"
    elseif status == "keychain_error" then
        return "Keychain locked or unavailable -- reopen after unlocking"
    else
        return "Key: not set"
    end
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

-- M3: clear ALL transient per-POSITION key-entry fields. ANY structural change to keyOrder
-- (Remove compacts the list; Up/Down swap positions; a provider switch swaps the whole list)
-- shifts which storage ordinal a position maps to. Unsaved typed text in a password_field is
-- bound to apiTokenEntry_<position>, NOT to a storage ordinal, so after a shift that text would
-- "stick" to the wrong position and a later Save would write it to the wrong Keychain slot.
-- Clearing every entry on every restructure makes that impossible. (The fields are write-only
-- transients -- clearing them never touches a stored secret; the Keychain is keyed by the
-- STABLE storage ordinal, untouched here.)
local function clearKeyEntries(propertyTable)
    for p = 1, MAX_KEYS do
        propertyTable['apiTokenEntry_' .. p] = ""
    end
end

-- M5 + L3: build a standard NUMERIC settings row (label + bounded edit_field). The hand-built
-- numeric rows previously had no min/max/precision and so let junk persist raw, clamping only
-- silently at run time inside settings.normalizedPrefs. numRow attaches the SDK edit_field's
-- numeric guard rails (min/max/precision) so the UI rejects/clamps at entry, and pins ONE label
-- width (180) -- fixing the L3 140/180 drift between sections.
--
-- The UI bounds passed here MUST mirror the matching settings.validate clamp EXACTLY (the field
-- and the read-through accessor must agree); each call site names the settings.lua clamp it
-- mirrors. Numeric edit_field properties (min, max, precision) are the documented LrView numeric
-- guards; immediate=false is KEPT (commit on focus-out, matching every existing field) so a
-- partially-typed value is not clamped on each keystroke.
--   opts.min, opts.max  -- numeric bounds (REQUIRED; mirror the settings.lua clamp)
--   opts.precision      -- decimal places (default 0 = integer; e.g. 2 for confidenceThreshold)
local NUM_LABEL_WIDTH = 180
local function numRow(f, prefs, labelText, prefKey, opts)
    local bind = LrView.bind
    return f:row {
        f:static_text { title = labelText, width = NUM_LABEL_WIDTH },
        f:edit_field {
            value     = bind { key = prefKey, bind_to_object = prefs },
            min       = opts.min,
            max       = opts.max,
            precision = opts.precision or 0,
            width_in_chars = 6,
            immediate = false,
        },
    }
end

local function sectionsForTopOfDialog(f, propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    ensureDefaults(prefs)

    -- ON OPEN: silently migrate a pre-existing single key to storage ordinal 1 at priority
    -- position 1 (D-10). Idempotent (gated on the pure settings.needsMigration via the VALUE-FREE
    -- keystore.statusForSlot); never touches a Keychain value, never re-runs once keyOrder exists.
    keystore.migrateIfNeeded(prefs.provider, prefs)

    -- [CODEX MUST-FIX 3] The model popup's items must be REACTIVE to provider changes, so
    -- bind them to this transient property (updated by the observer) rather than computing a
    -- static list once at render. Seed it for the current provider.
    propertyTable.modelItems = settings.modelItemsFor(prefs.provider)

    -- Per-POSITION TRANSIENT, WRITE-ONLY secret entries. apiTokenEntry_<p> binds to propertyTable
    -- (NEVER prefs) and NEVER holds the stored secret: a password_field shows nothing on open and
    -- is cleared after Save, so rebinding a position to a different storage ordinal across
    -- reorder/remove can NEVER orphan or leak the stored secret -- the secret lives ONLY in the
    -- Keychain keyed by the STABLE storage ordinal keyOrder[p] (round-2 BLOCKER-A discipline).
    clearKeyEntries(propertyTable)
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
        -- A provider switch also changes which keyOrder list is live: migrate the new provider's
        -- single key if needed (idempotent), clear all transient per-row entries, observe the new
        -- provider's keyOrder pref, and recompute the per-row list. (Observing the new key is
        -- additive -- an extra no-op observer on the prior provider's key is harmless since that
        -- list is no longer displayed; refreshKeyList always reads prefs.provider's current order.)
        keystore.migrateIfNeeded(prefs.provider, prefs)
        clearKeyEntries(propertyTable)
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
            -- H5 + L1: the value-free per-row key status the section header promises
            -- ("the status line tells you which rows have a key"). keyRowStatus_<pos> is
            -- recomputed by refreshKeyList from keystore.statusForSlot (VALUE-FREE -- it is
            -- "Key: set"/"Key: not set"/keychain-error wording, NEVER the secret).
            f:static_text {
                title = bind { key = 'keyRowStatus_' .. pos, bind_to_object = propertyTable },
                width = 110,
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
                        -- M3: a swap shifts which ordinal each position maps to; drop ALL
                        -- unsaved typed text so it can never be Saved to the wrong slot.
                        clearKeyEntries(propertyTable)
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
                        -- M3: see Up -- clear all transient entries after a position swap.
                        clearKeyEntries(propertyTable)
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
                    -- M3: table.remove COMPACTS the list, so every position at/after `pos`
                    -- now maps to a different storage ordinal. Clearing only apiTokenEntry_<pos>
                    -- left unsaved text on the shifted positions stuck to the WRONG ordinal.
                    -- Clear ALL transient entries instead.
                    clearKeyEntries(propertyTable)
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

            -- mirrors settings.validate confidenceThreshold: clampNumber 0..1 default 0.6
            numRow(f, prefs, "Confidence threshold:", 'confidenceThreshold',
                { min = 0, max = 1, precision = 2 }),

            -- mirrors settings.validate previewSize: clampNumber 512..8192 default 2048
            numRow(f, prefs, "Preview size (px):", 'previewSize',
                { min = 512, max = 8192, precision = 0 }),

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
        },

        -- 11-04 (DKEY): the dynamic per-provider add/remove/reorder key list (built above).
        keySection,

        -- 09-01 (Phase 9 — Throughput / Cluster / Viz): the three greenlit v1.0 features, all OFF/
        -- serial by default so today's behavior is unchanged. Each control binds EXPLICITLY to prefs
        -- (bind_to_object = prefs) so the value persists. NO secrets in this section.
        {
            title    = "BirdAID - Throughput & clustering",
            synopsis = "Parallel requests and burst/stack clustering (all OFF/serial by default).",

            -- mirrors settings.validate maxConcurrency: clampInt 1..50 default 1
            numRow(f, prefs, "Number of parallel requests:", 'maxConcurrency',
                { min = 1, max = 50, precision = 0 }),
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
            -- mirrors settings.validate deepExportConcurrency: clampInt 1..4 default 2
            numRow(f, prefs, "Deep export parallelism:", 'deepExportConcurrency',
                { min = 1, max = 4, precision = 0 }),
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

            -- M4: the Phase-12 WBATCH pref (BL-14) is validated + consumed by writeplan but had
            -- no UI. mirrors settings.validate writeBatchSize: clampInt 0..100000 default 0.
            numRow(f, prefs, "Keyword write batch size:", 'writeBatchSize',
                { min = 0, max = 100000, precision = 0 }),
            f:row {
                f:static_text {
                    title = "0 = single write at end of run; 1+ = flush incrementally during " ..
                            "long runs.",
                    width_in_chars = 60,
                    height_in_lines = 2,
                },
            },

            f:row {
                f:checkbox {
                    title = "Cluster bursts (identify one anchor per near-duplicate group)",
                    value = bind { key = 'clusterBursts', bind_to_object = prefs },
                },
            },
            -- mirrors settings.validate clusterMaxGapSeconds: clampNumber 0..30 default 1.0
            numRow(f, prefs, "Max gap (seconds):", 'clusterMaxGapSeconds',
                { min = 0, max = 30, precision = 1 }),
            f:row {
                f:checkbox {
                    title = "Also cluster photos in the same Lightroom stack",
                    value = bind { key = 'clusterUseStacks', bind_to_object = prefs },
                },
            },
            -- mirrors settings.validate clusterSimilarityThreshold: clampInt 0..64 default 10
            numRow(f, prefs, "Similarity threshold:", 'clusterSimilarityThreshold',
                { min = 0, max = 64, precision = 0 }),
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
