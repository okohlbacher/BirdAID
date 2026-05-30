-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/openai_http.lua (Plan 05-04; THIN wrapper since 07-01)
--
-- THIN Lr-GLUE adapter for the OpenAI provider. Since Plan 07-01 this file DELEGATES to the
-- shared src/lr/http.lua (the generalized POST + base64 + Keychain-by-key + per-provider auth +
-- model-reconciling buildDeps), keeping its EXISTING public surface byte-for-byte compatible so
-- the live in-Lightroom entry points and the per-photo pipeline continue to work unchanged. It
-- lives in the src/lr/ glue tier (Lr allowed) and is EXCLUDED from the purity grep.
--
-- PUBLIC SURFACE (preserved):
--   * M.makeHttpPost()            -> delegates to http.makeHttpPost().
--   * M.dataUrl(bytes)            -> delegates to http.dataUrl(bytes) (keeps the data: prefix).
--   * M.attachDataUrl(image)      -> delegates to http.attachImage(image): the OpenAI {kind=bytes}
--        path STILL sets image.dataUrl (the live-path regression CODEX MUST-FIX 4 guards), and the
--        kind='file' crop branch + size cap are preserved in the shared helper.
--   * M.buildDeps(prefs)          -> http.buildDeps('openai', prefs) (model reconciled to openai).
--   * M.identify(image, ctx, prefs[, breaker]) -> per-photo entry helper (unchanged behavior).
--   * M.newProvider(prefs[, breaker])          -> resolve once + wrap identify to attach first.
--
-- NO-LEAK: the token is read ONLY into deps.token (-> the Authorization header value, built in
-- the shared http.authHeaders). This file NEVER logs the token, body, headers, or data URL. NO
-- env-var read anywhere.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; UTF-8 literal bytes.

local http      = require 'src.lr.http'
local providers = require 'src.providers.init'

local M = {}

-- The plugin id used to SCOPE the Keychain entry. Re-exported (sourced from the shared http
-- module) so any caller historically reading openai_http's scope still gets the canonical value.
local PLUGIN_ID = http.PLUGIN_ID

-- makeHttpPost() -> httpPost(url, bodyString, headers). Delegates to the shared helper.
function M.makeHttpPost()
    return http.makeHttpPost()
end

-- dataUrl(bytes) -> "data:image/jpeg;base64,<...>" | nil. Delegates (keeps the exact prefix).
function M.dataUrl(bytes)
    return http.dataUrl(bytes)
end

-- attachDataUrl(image) -> image. Delegates to http.attachImage, which sets image.dataUrl (for
-- the OpenAI request body — the live-path regression guard) AND image.b64 (raw, harmless here).
function M.attachDataUrl(image)
    return http.attachImage(image)
end

-- buildDeps(prefs) -> (deps) | (nil, err). Delegates to the shared, model-reconciling buildDeps
-- forced to the 'openai' provider (so the OpenAI Keychain token + openai default model are used).
function M.buildDeps(prefs)
    return http.buildDeps('openai', prefs)
end

-- identify(image, ctx, prefs[, breaker]) -> (response) | (nil, err). Attaches the data URL,
-- builds the openai deps (Keychain token), wires an optional run-level breaker, resolves the pure
-- 'openai' provider and returns identify(image, ctx). (nil, err) if deps can't be built.
function M.identify(image, ctx, prefs, breaker)
    M.attachDataUrl(image)
    local deps, err = M.buildDeps(prefs)
    if not deps then
        return nil, err
    end
    if breaker ~= nil then
        deps.breaker = breaker
    end
    local provider, perr = providers.get('openai', deps)
    if not provider then
        return nil, tostring(perr)
    end
    return provider.identify(image, ctx)
end

-- newProvider(prefs[, breaker]) -> (provider) | (nil, err). Builds the deps ONCE and returns the
-- resolved pure 'openai' provider wrapped so every per-photo identify attaches the data URL first
-- (the pure provider does not base64-encode). rateLimit is forwarded unchanged.
function M.newProvider(prefs, breaker)
    local deps, err = M.buildDeps(prefs)
    if not deps then
        return nil, err
    end
    if breaker ~= nil then
        deps.breaker = breaker
    end
    local provider, perr = providers.get('openai', deps)
    if not provider then
        return nil, perr
    end

    local rawIdentify = provider.identify
    return {
        rateLimit = provider.rateLimit,
        identify = function(image, ctx)
            M.attachDataUrl(image)          -- LIVE: encode preview bytes -> data URL first.
            return rawIdentify(image, ctx)
        end,
    }
end

return M
