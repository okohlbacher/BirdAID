-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/http.lua (Plan 07-01 — shared Lr HTTP glue for ALL providers)
--
-- THIN Lr-GLUE adapter (the generalization of the proven Phase-5 openai_http.lua). This file
-- lives in the src/lr/ glue tier and is one of the few modules ALLOWED to touch the Lightroom
-- SDK (LrHttp, LrStringUtils, LrPasswords, LrTasks). It is NOT a pure module and is
-- intentionally EXCLUDED from the negative-purity grep gate (which scopes only the pure src/
-- modules). It is loaded only by an entry point AFTER birdaid_bootstrap.lua has installed the
-- require shim. openai_http.lua now delegates here so openai/claude/gemini share ONE Lr surface.
--
-- WHAT IT PROVIDES (per-provider, the token VALUE materializes ONLY in this file):
--   1. M.PLUGIN_ID = "com.okohlbacher.birdaid"  -- single source of truth for the Keychain scope.
--   2. M.makeHttpPost([timeout]) -> httpPost(url, bodyString, headers) returning the LOCKED
--        3-value contract: HTTP response -> (status:number, body:string, headers:array);
--        transport error -> (nil, nil, info). Identical semantics to openai_http today.
--   3. M.encodeBase64(bytes) -> RAW base64 string (NO data: prefix) — what Claude/Gemini want.
--   4. M.dataUrl(bytes) -> "data:image/jpeg;base64," .. encodeBase64(bytes) — what OpenAI wants.
--   5. M.attachImage(image) -> image. Sets BOTH image.dataUrl (OpenAI) AND image.b64 (RAW,
--        Claude/Gemini) in place from image.data (kind='bytes') OR by reading image.path off
--        disk (kind='file', the Phase-6 crop re-query branch, size-capped). Missing/unreadable
--        source leaves BOTH nil (the provider degrades token-free).
--   6. M.authHeaders(provider, token) -> the per-provider {field=,value=} array. The token VALUE
--        materializes ONLY here. NEVER log the returned table. Unknown provider -> nil.
--   7. M.readToken(provider) -> (token) | (nil, status). tokenKeyFor(provider) + pcall-wrapped
--        LrPasswords.retrieve(key, nil, PLUGIN_ID), classified by settings.tokenStatus.
--   8. M.buildDeps(provider, prefs[, opts]) -> (deps) | (nil, err). RECONCILES the model to the
--        EXPLICIT provider arg (CODEX MUST-FIX 5) so forcing 'claude' never sends a stale gpt-4o.
--
-- NO-LEAK (T-07-01): the token is read ONLY into deps.token and the authHeaders value. This glue
-- NEVER logs the token, the request body, the headers, the raw crop path, or the data URL. NO
-- env-var read anywhere (no os.getenv); an unknown provider returns nil (never an auth-less set).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; UTF-8 literal bytes.

local LrHttp        = import 'LrHttp'
local LrStringUtils = import 'LrStringUtils'
local LrPasswords   = import 'LrPasswords'
local LrTasks       = import 'LrTasks'

local settings = require 'src.settings'
local log      = require 'src.log'                 -- single redacting sink (for transport diagnostics)
local redact   = require('src.redact').redact      -- backstop redaction of any raised message

local M = {}

-- The plugin id used to SCOPE the Keychain entry. MUST match PluginInfoProvider.lua's PLUGIN_ID
-- and the LrToolkitIdentifier in Info.lua, or the stored token won't be found.
M.PLUGIN_ID = "com.okohlbacher.birdaid"
local PLUGIN_ID = M.PLUGIN_ID

-- Default LrHttp timeout (seconds). Generous enough for a vision call; the pure backoff policy
-- bounds retries on top of this.
local HTTP_TIMEOUT = 60

-- [CODEX #7] BACKSTOP cap (bytes) on a kind='file' crop before we read+base64 it on the main
-- thread. Crops are already size-capped (maxCropEdge, 06-01); this is defence-in-depth so a
-- pathological/oversized file can never be slurped into memory. On exceed we leave both
-- image.dataUrl and image.b64 nil and the pure provider fail-fasts token-free.
local MAX_FILE_BYTES = 8 * 1024 * 1024

-- ---------------------------------------------------------------------------
-- makeHttpPost([timeout]) -> httpPost(url, bodyString, headers)
-- LOCKED contract: HTTP response -> (status, body, headers-array); transport -> (nil, nil, info).
-- ---------------------------------------------------------------------------
function M.makeHttpPost(timeout)
    local t = timeout or HTTP_TIMEOUT
    return function(url, bodyString, headers)
        -- CRITICAL: call LrHttp.post DIRECTLY (NO surrounding pcall). LrHttp.post YIELDS the
        -- cooperative task while it waits on the network, and Lua 5.1 forbids yielding across a
        -- C-call boundary ("Yielding is not allowed within a C or metamethod call"). The provider
        -- protects this call with deps.pcall = LrTasks.pcall (yield-safe), NOT the standard pcall.
        local body, respHeaders = LrHttp.post(url, bodyString, headers, "POST", t)

        -- Transport failure: LrHttp.post returns a nil body and an info table whose `error` field
        -- carries {errorCode,name,nativeCode}. These are NETWORK diagnostics (not the token) -- log
        -- them (redacted backstop) so a transport failure speaks, then hand back (nil, nil, info).
        if body == nil then
            local info = respHeaders
            if type(info) ~= 'table' then info = { error = info } end
            local e = info.error
            if type(e) == 'table' then
                pcall(function()
                    log.warn('LrHttp.post transport failure', {
                        url = url, name = redact(tostring(e.name)),
                        nativeCode = tostring(e.nativeCode), errorCode = tostring(e.errorCode),
                    })
                end)
            end
            return nil, nil, info
        end

        -- HTTP response: status lives on respHeaders.status; respHeaders is also the response
        -- header ARRAY (+ a status key); forward it so classify can read Retry-After.
        local status = (type(respHeaders) == 'table') and respHeaders.status or nil
        return status, body, respHeaders
    end
end

-- ---------------------------------------------------------------------------
-- encodeBase64(bytes) -> RAW base64 string (NO data: prefix) | nil
-- Base64-encode MODEST preview bytes INSIDE the async task (encodeBase64 blocks the main
-- thread — keep previews modest). nil/empty -> nil. This is what Claude/Gemini consume.
-- ---------------------------------------------------------------------------
function M.encodeBase64(bytes)
    if type(bytes) ~= 'string' or bytes == '' then
        return nil
    end
    return LrStringUtils.encodeBase64(bytes)
end

-- ---------------------------------------------------------------------------
-- dataUrl(bytes) -> "data:image/jpeg;base64,<...>" | nil  (kept for OpenAI; MUST keep the prefix)
-- ---------------------------------------------------------------------------
function M.dataUrl(bytes)
    local b64 = M.encodeBase64(bytes)
    if b64 == nil then return nil end
    return "data:image/jpeg;base64," .. b64
end

-- ---------------------------------------------------------------------------
-- readImageBytes(image) -> rawBytes | nil. The two sources, in order:
--   * kind='bytes' (image.data) — the Phase-5 preview path.
--   * kind='file'  (image.path) — the Phase-6 crop re-query path: read the (small, size-capped)
--     crop file off disk. A missing/unreadable/over-cap source -> nil. The raw path is NEVER logged.
-- ---------------------------------------------------------------------------
local function readImageBytes(image)
    if type(image.data) == 'string' and image.data ~= '' then
        return image.data
    end
    if image.kind == 'file' and type(image.path) == 'string' and image.path ~= '' then
        local f = io.open(image.path, 'rb')
        if not f then return nil end
        -- [CODEX #7] SIZE CAP backstop: learn the size via seek WITHOUT reading, reject over-cap.
        local size = nil
        local okSeek = pcall(function() size = f:seek('end') end)
        local withinCap = (not okSeek)
            or (type(size) == 'number' and size <= MAX_FILE_BYTES)
        if okSeek then pcall(function() f:seek('set', 0) end) end
        if not withinCap then
            f:close()
            return nil
        end
        -- Bounded read: never read more than the cap + 1 byte (detect an over-running stream).
        local bytes = f:read(MAX_FILE_BYTES + 1)
        f:close()
        if type(bytes) == 'string' and bytes ~= '' and #bytes <= MAX_FILE_BYTES then
            return bytes
        end
        return nil
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- attachImage(image) -> image. Sets BOTH image.dataUrl (OpenAI) AND image.b64 (RAW, Claude/Gemini)
-- in place from the resolved image bytes. Returns the same image for chaining. Idempotent: if
-- image.dataUrl is already set we leave it (mirrors openai_http.attachDataUrl), but we still
-- backfill image.b64 from the same source so the raw-base64 consumers also work after a re-attach.
-- A missing/unreadable source leaves both nil (the provider degrades token-free). NEVER log the
-- token/body/headers, the raw crop path (PII), or the data URL.
-- ---------------------------------------------------------------------------
function M.attachImage(image)
    if type(image) ~= 'table' then
        return image
    end
    if image.dataUrl ~= nil and image.b64 ~= nil then
        return image                       -- both already attached: nothing to do.
    end
    local bytes = readImageBytes(image)
    if type(bytes) ~= 'string' or bytes == '' then
        return image                       -- leave both nil; provider degrades token-free.
    end
    local b64 = M.encodeBase64(bytes)      -- ONE encode, reused for both shapes.
    if b64 == nil then
        return image
    end
    if image.b64 == nil then
        image.b64 = b64                    -- RAW base64 for Claude/Gemini.
    end
    if image.dataUrl == nil then
        image.dataUrl = "data:image/jpeg;base64," .. b64   -- data URL for OpenAI.
    end
    return image
end

-- ---------------------------------------------------------------------------
-- authHeaders(provider, token) -> per-provider {field=,value=} array | nil
-- The token VALUE materializes ONLY here. NEVER log the returned table. Unknown provider -> nil
-- (the caller errors clearly — never an empty/auth-less header set).
--   openai = Authorization Bearer + Content-Type
--   claude = x-api-key + anthropic-version "2023-06-01" + content-type
--   gemini = x-goog-api-key + Content-Type  (header form; NEVER the ?key= query param)
-- ---------------------------------------------------------------------------
function M.authHeaders(provider, token)
    if provider == 'openai' then
        return {
            { field = 'Authorization', value = 'Bearer ' .. tostring(token) },
            { field = 'Content-Type',  value = 'application/json' },
        }
    elseif provider == 'claude' then
        return {
            { field = 'x-api-key',         value = tostring(token) },
            { field = 'anthropic-version', value = '2023-06-01' },
            { field = 'content-type',      value = 'application/json' },
        }
    elseif provider == 'gemini' then
        return {
            { field = 'x-goog-api-key', value = tostring(token) },
            { field = 'Content-Type',   value = 'application/json' },
        }
    end
    return nil                              -- unknown provider: never an auth-less default.
end

-- ---------------------------------------------------------------------------
-- readToken(provider) -> (token) | (nil, status)
-- tokenKeyFor(provider) then pcall-wrapped LrPasswords.retrieve(key, nil, PLUGIN_ID), classified
-- by settings.tokenStatus. nil key -> (nil, 'no-key'); not "set" -> (nil, status). NEVER
-- log/return the token. There is NO env-var fallback (no os.getenv).
-- ---------------------------------------------------------------------------
function M.readToken(provider)
    local key = settings.tokenKeyFor(provider)
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
-- buildDeps(provider, prefs[, opts]) -> (deps) | (nil, err)
--
-- [CODEX MUST-FIX 5 / CODEX phase-7 N2] RECONCILE the model to the EXPLICIT `provider` arg via the
-- PURE settings.reconcileModel: reset to settings.defaultModelFor(provider) ONLY when prefs.model is
-- a catalog model of a DIFFERENT provider (stale cross-provider — e.g. buildDeps('claude',
-- {model='gpt-4o'}) yields the claude default, never a stale gpt-4o). A catalog model of THIS
-- provider is KEPT, and a non-empty CUSTOM string (not in ANY provider's catalog) is KEPT (the
-- custom-model escape hatch — buildDeps('gemini', {model='gemini-custom-xyz'}) keeps that string).
--
-- Reads the token from the Keychain via readToken (the EXACT LrPasswords.retrieve signature).
-- A nil key / locked keychain / absent token yields a SPEAKING, token-free error (nil, err) and
-- NEVER an env-var fallback. The token value NEVER enters a log line or an error string here.
-- ---------------------------------------------------------------------------
function M.buildDeps(provider, prefs, opts)
    local typed = settings.normalizedPrefs(prefs)

    -- Reconcile the model to the EXPLICIT provider arg (CODEX MUST-FIX 5 / T-07-15 / phase-7 N2):
    -- keep this provider's catalog model AND a custom string; reset only a stale cross-provider model.
    local model = settings.reconcileModel(provider, typed.model)

    local token, status = M.readToken(provider)
    if token == nil then
        local why
        if status == 'no-key' then
            why = "no Keychain key for provider '" .. tostring(provider) .. "'"
        elseif status == 'keychain_error' then
            why = "Keychain is locked or unavailable -- unlock it and try again"
        else
            why = "no API token is stored for '" .. tostring(provider) ..
                  "' -- set it in Plug-in Manager > BirdAID settings"
        end
        return nil, why
    end

    local deps = {
        token       = token,               -- ONLY ever flows into the auth header value.
        model       = model,
        rateLimit   = typed.rateLimit,
        httpPost    = M.makeHttpPost(opts and opts.timeout or nil),
        sleep       = LrTasks.sleep,
        -- YIELD-SAFE protected call: the provider wraps httpPost (which yields inside LrHttp.post)
        -- with deps.pcall. MUST be LrTasks.pcall, NOT the standard C pcall (which forbids yielding
        -- across its boundary). Tests inject nothing and fall back to the standard pcall (their
        -- fake httpPost does not yield), so the no-leak guarantee still holds in both worlds.
        pcall       = LrTasks.pcall,
        log         = require 'src.log',   -- single sink; provider logs only safe metadata.
        prefs       = typed,               -- for prompt.build (the user's promptAddition).
        authHeaders = function(t) return M.authHeaders(provider, t) end,
    }
    return deps
end

return M
