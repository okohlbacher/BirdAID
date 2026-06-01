-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/keystore.lua (Plan 11-03 / DKEY-01 — multi-slot secret glue)
--
-- THIN Lr-GLUE for the per-slot Keychain secret store (the multi-key generalization of
-- src/lr/http.lua's readToken). It lives in the src/lr/ glue tier and is one of the few
-- modules ALLOWED to touch the Lightroom SDK (LrPasswords). It is NOT a pure module and is
-- intentionally EXCLUDED from the negative-purity grep gate (which scopes only the pure src/
-- modules). It is loaded only by an entry point AFTER birdaid_bootstrap.lua has installed the
-- require shim. It reuses the EXACT LrPasswords.retrieve/store signatures from http.lua +
-- PluginInfoProvider.lua and the stable per-slot naming from settings.tokenKeyForSlot (Wave 1).
--
-- WHAT IT PROVIDES (the token VALUE materializes ONLY in readTokenForSlot):
--   1. M.PLUGIN_ID = "com.okohlbacher.birdaid"  -- single Keychain scope; MUST match
--        src/lr/http.lua, PluginInfoProvider.lua, and Info.lua's LrToolkitIdentifier.
--   2. M.readTokenForSlot(provider, storageIndex) -> (token) | (nil, status). Mirrors
--        http.readToken EXACTLY, swapping tokenKeyFor -> tokenKeyForSlot. This is the ONLY
--        function that materializes a token VALUE and is used ONLY at actual call time to
--        feed the provider via buildDeps.
--   3. M.statusForSlot(provider, storageIndex) -> 'set'|'absent'|'keychain_error'. VALUE-FREE:
--        it retrieves only to CLASSIFY presence and DISCARDS the value; it NEVER returns,
--        logs, or otherwise exposes the token. Drives migration + the per-row UI status.
--   4. M.storeTokenForSlot(provider, storageIndex, value) -> true | (false, 'no-key'|'keychain_error').
--        On a pcall failure it returns the CONSTANT 'keychain_error' -- NEVER the raw
--        LrPasswords error string (which could reach a log/dialog). Storing "" clears a slot.
--   5. M.migrateIfNeeded(provider, prefs) -> bool. The idempotent silent migration: gated on
--        the PURE settings.needsMigration, decided via the VALUE-FREE statusForSlot(provider, 1)
--        (never the token value), seeds keyOrder/keyCount/keyNextIndex ONCE and NEVER touches a
--        Keychain value (D-09/D-10).
--
-- NO-LEAK (T-11-10/11/12): the token is read ONLY into readTokenForSlot's return value (which
-- flows into buildDeps -> deps.token -> the auth header). statusForSlot is value-free;
-- storeTokenForSlot returns a constant on failure; migration never binds a token value. NO log
-- line in this file references the token value -- only provider/slot/status fields.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; UTF-8 literal bytes.

local LrPasswords = import 'LrPasswords'

local settings = require 'src.settings'
local log      = require 'src.log'                 -- single redacting sink (provider/slot/status only)

local M = {}

-- The plugin id used to SCOPE every Keychain entry. MUST match src/lr/http.lua's PLUGIN_ID,
-- PluginInfoProvider.lua's PLUGIN_ID, and the LrToolkitIdentifier in Info.lua, or the stored
-- token won't be found.
M.PLUGIN_ID = "com.okohlbacher.birdaid"
local PLUGIN_ID = M.PLUGIN_ID

-- ---------------------------------------------------------------------------
-- readTokenForSlot(provider, storageIndex) -> (token) | (nil, status)
-- Mirrors http.readToken EXACTLY, swapping tokenKeyFor -> tokenKeyForSlot. tokenKeyForSlot
-- then pcall-wrapped LrPasswords.retrieve(key, nil, PLUGIN_ID), classified by
-- settings.tokenStatus. nil key -> (nil, 'no-key'); not "set" -> (nil, status). NEVER
-- log/return the token. There is NO env-var fallback. This is the ONLY function that
-- materializes a token VALUE, used ONLY at call time to feed the provider.
-- ---------------------------------------------------------------------------
function M.readTokenForSlot(provider, storageIndex)
    local key = settings.tokenKeyForSlot(provider, storageIndex)
    if key == nil then
        return nil, 'no-key'
    end
    local ok, token = pcall(function()
        return LrPasswords.retrieve(key, nil, PLUGIN_ID)
    end)
    local status = settings.tokenStatus(ok, token)
    if status ~= 'set' then
        return nil, status
    end
    return token
end

-- ---------------------------------------------------------------------------
-- statusForSlot(provider, storageIndex) -> 'set' | 'absent' | 'keychain_error'
-- VALUE-FREE presence check for migration + the per-row UI status (MEDIUM fix: migration/UI
-- must NOT read the token value). Computes the slot key; a nil key -> 'absent'; else
-- pcall-wrapped LrPasswords.retrieve and returns ONLY settings.tokenStatus(ok, token). The
-- retrieved value is used SOLELY to classify presence and is then discarded -- it is NEVER
-- returned, logged, or otherwise exposed.
-- ---------------------------------------------------------------------------
function M.statusForSlot(provider, storageIndex)
    local key = settings.tokenKeyForSlot(provider, storageIndex)
    if key == nil then
        return 'absent'
    end
    local ok, token = pcall(function()
        return LrPasswords.retrieve(key, nil, PLUGIN_ID)
    end)
    -- The token value is consumed ONLY by the pure classifier here and never escapes.
    return settings.tokenStatus(ok, token)
end

-- ---------------------------------------------------------------------------
-- storeTokenForSlot(provider, storageIndex, value) -> true | (false, status)
-- Computes the slot key (nil -> (false, 'no-key')); pcall-wrapped
-- LrPasswords.store(key, value, nil, PLUGIN_ID) (the exact PluginInfoProvider signature).
-- On success returns true; on a pcall failure returns the CONSTANT (false, 'keychain_error')
-- (MEDIUM fix: NEVER the raw LrPasswords error string -- it could carry context into a
-- log/dialog). Storing "" clears a slot (per-row remove -- Assumption A1).
-- ---------------------------------------------------------------------------
function M.storeTokenForSlot(provider, storageIndex, value)
    local key = settings.tokenKeyForSlot(provider, storageIndex)
    if key == nil then
        return false, 'no-key'
    end
    local ok = pcall(function()
        LrPasswords.store(key, value, nil, PLUGIN_ID)
    end)
    if ok then
        return true
    end
    -- CONSTANT error code -- never the raw pcall error string.
    return false, 'keychain_error'
end

-- ---------------------------------------------------------------------------
-- migrateIfNeeded(provider, prefs) -> bool (whether a migration was performed)
-- The idempotent silent migration. Reads slot-1 presence via the VALUE-FREE statusForSlot
-- (NOT readTokenForSlot -- MEDIUM fix: never bind the token value just to decide migration),
-- then gates on the PURE settings.needsMigration. When true it seeds ONLY the non-secret
-- ordinal prefs: keyOrder_<provider> = {1}, keyCount_<provider> = 1, and
-- keyNextIndex_<provider> = 1 (the monotonic high-water mark, Assumption A4 / D-09) and logs a
-- provider-only (token-free) note. It NEVER calls LrPasswords on slot 1's value (D-10).
-- Idempotent: once keyOrder_<provider> exists, needsMigration is false and this is a no-op.
-- ---------------------------------------------------------------------------
function M.migrateIfNeeded(provider, prefs)
    local orderKey = 'keyOrder_' .. tostring(provider)
    -- VALUE-FREE slot-1 presence check (never readTokenForSlot here).
    local slot1Status = M.statusForSlot(provider, 1)
    if not settings.needsMigration(prefs[orderKey], slot1Status) then
        return false
    end
    -- Seed only the non-secret ordinal prefs. NEVER touch the Keychain value (D-09/D-10).
    prefs[orderKey] = { 1 }
    prefs['keyCount_' .. tostring(provider)] = 1
    prefs['keyNextIndex_' .. tostring(provider)] = 1   -- monotonic high-water mark (A4)
    -- Provider-only, token-free migration note (no token/value/key string in this line).
    log.info('multi-key migration seeded slot 1', { provider = provider, keyCount = 1 })
    return true
end

return M
