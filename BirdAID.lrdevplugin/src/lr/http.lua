-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/http.lua (Plan 07-01 — shared Lr HTTP glue for ALL providers)
--
-- THIN Lr-GLUE adapter (the generalization of the proven Phase-5 openai_http.lua). This file
-- lives in the src/lr/ glue tier and is one of the few modules ALLOWED to touch the Lightroom
-- SDK (LrHttp, LrStringUtils, LrPasswords, LrTasks). It is NOT a pure module and is
-- intentionally EXCLUDED from the negative-purity grep gate (which scopes only the pure src/
-- modules). It is loaded only by an entry point AFTER birdaid_bootstrap.lua has installed the
-- require shim. (The former openai_http.lua thin wrapper was retired in Wave-D D3; openai/claude/
-- gemini all share THIS one Lr surface directly.)
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

-- LrPathUtils is used only to compute the multipart fileName leaf (DEEP-03 uploadFile). Import it
-- defensively so a stock-lua module-load (offline) does not hard-fail; uploadFile guards on nil.
local LrPathUtils
pcall(function() LrPathUtils = import 'LrPathUtils' end)

local settings = require 'src.settings'
local keystore = require 'src.lr.keystore'         -- slot-aware Keychain glue (the failover seam)
local log      = require 'src.log'                 -- single redacting sink (for transport diagnostics)
local redact   = require('src.redact').redact      -- backstop redaction of any raised message
local json     = require 'src.json'                -- non-raising decode of the UNTRUSTED Files-API body

local M = {}

-- The plugin id used to SCOPE the Keychain entry. MUST match PluginInfoProvider.lua's PLUGIN_ID
-- and the LrToolkitIdentifier in Info.lua, or the stored token won't be found.
M.PLUGIN_ID = "com.okohlbacher.birdaid"
local PLUGIN_ID = M.PLUGIN_ID

-- Default LrHttp timeout (seconds). Generous enough for a vision call; the pure backoff policy
-- bounds retries on top of this.
local HTTP_TIMEOUT = 60

-- BACKSTOP cap (bytes) on a kind='file' image before we read+base64 it on the main thread. The
-- live kind='file' consumer today is the DEEP path's exported full-res frame inlined for OpenAI
-- (DeepIdentify, detail='high') — the original Phase-6 crop pass is gone. The deep export is
-- already size-bounded (deep export edge cap), so this is defence-in-depth: a pathological /
-- oversized frame can never be slurped into memory + base64-encoded on the main thread. On exceed
-- we leave both image.dataUrl and image.b64 nil (and log an 'image-over-inline-cap' warning, byte
-- counts only) so the pure provider fail-fasts token-free and the skipped deep frame is diagnosable.
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
--   * kind='bytes' (image.data) — the cheap preview path (preview JPEG bytes already in memory).
--   * kind='file'  (image.path) — the DEEP inline path: read the exported (size-bounded) full-res
--     frame off disk for OpenAI inline (DeepIdentify, detail='high'). A missing/unreadable source
--     -> nil; an OVER-cap source -> nil PLUS an 'image-over-inline-cap' warning (byte counts only).
--     The raw path is NEVER logged.
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
            -- SPECIFIC, token/path-free over-cap warning so a skipped deep frame is diagnosable
            -- (byte counts only — never the path, which may be PII).
            log.warn('image-over-inline-cap', { bytes = size, capBytes = MAX_FILE_BYTES })
            return nil
        end
        -- Bounded read: never read more than the cap + 1 byte (detect an over-running stream).
        local bytes = f:read(MAX_FILE_BYTES + 1)
        f:close()
        if type(bytes) == 'string' and bytes ~= '' and #bytes <= MAX_FILE_BYTES then
            return bytes
        end
        -- A stream that over-ran the seek-reported size (or read past the cap): also diagnosable.
        if type(bytes) == 'string' and #bytes > MAX_FILE_BYTES then
            log.warn('image-over-inline-cap', { bytes = #bytes, capBytes = MAX_FILE_BYTES })
        end
        return nil
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- attachImage(image) -> image. Sets BOTH image.dataUrl (OpenAI) AND image.b64 (RAW, Claude/Gemini)
-- in place from the resolved image bytes. Returns the same image for chaining. Idempotent: if
-- image.dataUrl is already set we leave it, but we still
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
-- Reads the token from the Keychain. The DEFAULT (legacy single-key) path uses readToken (the
-- EXACT LrPasswords.retrieve signature). When opts.storageIndex is a number this is the FAILOVER
-- seam (DKEY-02): the orchestrator (Plan 11-05) asks the keyring for a storageIndex and passes it
-- here, so the chosen slot's token (via keystore.readTokenForSlot) flows into deps.token --- one
-- active key at a time (per-worker key distribution is DEFERRED, D-01). When opts.storageIndex is
-- absent this is BYTE-COMPATIBLE with the legacy path. Either way a nil key / locked keychain /
-- absent token yields a SPEAKING, token-free error (nil, err) and NEVER an env-var fallback. The
-- token value NEVER enters a log line or an error string here.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- DEEP-03 (Plan 13-03) — Files-API upload/delete glue (D-01a / D-01b)
--
-- The deep pass exports a true-full-res JPEG to a temp file (src/lr/fullres_export.lua) and must
-- get its bytes to the provider WITHOUT base64-ing a full frame on the main thread (D-01a). The
-- transport is LrHttp.postMultipart STREAMING the file BY PATH — never encodeBase64 of a full
-- frame. uploadFile returns the provider's Files-API handle (Anthropic file_id / Gemini file_uri),
-- which the PURE per-provider request builder (13-02) turns into the image source.
--
-- D-01b (privacy): the provider-side copy is a copy of the user's photo in a third-party store.
-- deleteFile issues the Anthropic DELETE /v1/files/{id} so it does not linger; the 13-04 loop calls
-- it in a guaranteed-teardown branch (success AND error). Gemini auto-expires in 48h -> no-op.
--
-- YIELD DISCIPLINE (Pitfall 4): postMultipart and the DELETE both YIELD on the network. We call
-- the SDK fn DIRECTLY (no surrounding STANDARD pcall — Lua 5.1 forbids yielding across a C-frame).
-- The caller isolates with deps.pcall = LrTasks.pcall (yield-safe), mirroring makeHttpPost. Tests
-- inject a fake (non-yielding) deps.postMultipart/deps.deleteRaw so offline runs need no LrHttp.
--
-- NO-LEAK (lines 29-31): NEVER log the filePath, the token, the request body, the headers, or the
-- returned handle VALUE (a file_id/file_uri is provider state we keep out of logs). Log runId +
-- provider + a boolean outcome only.

-- The Anthropic Files API requires a beta opt-in header (a CONSTANT, not a secret).
local ANTHROPIC_FILES_BETA = 'files-api-2025-04-14'

-- filesUploadUrl(provider) -> the per-provider Files-API upload endpoint | nil (no upload target).
-- OpenAI is intentionally absent (D-01-OPENAI): chat-completions has no file slot; it sends the
-- 2048-equiv frame inline the existing way, so it is never an uploadFile target.
local function filesUploadUrl(provider)
    if provider == 'claude' then
        return 'https://api.anthropic.com/v1/files'
    elseif provider == 'gemini' then
        return 'https://generativelanguage.googleapis.com/upload/v1beta/files'
    end
    return nil
end

-- filesHeaders(provider, token) -> the auth-header array EXTENDED with the provider's Files-API
-- headers. Reuses M.authHeaders (the one place the token VALUE materializes); for Anthropic it
-- ADDS the constant anthropic-beta opt-in (authHeaders already supplies anthropic-version). The
-- returned array carries the token value -> NEVER log it.
local function filesHeaders(provider, token)
    local headers = M.authHeaders(provider, token)
    if headers == nil then
        return nil
    end
    if provider == 'claude' then
        headers[#headers + 1] = { field = 'anthropic-beta', value = ANTHROPIC_FILES_BETA }
    end
    return headers
end

-- ---------------------------------------------------------------------------
-- uploadFile(provider, filePath, deps) -> handle | (nil, reason)
--   handle = { fileId = '<id>' }   (Anthropic)  |  { fileUri = '<uri>' }   (Gemini)
--   reason = 'unsupported-provider' | 'bad-args' | 'no-token' | 'transport' | 'http-<status>'
--          | 'bad-response'
--
-- Streams the temp file BY PATH via LrHttp.postMultipart (NO full-frame encodeBase64 — D-01a) to
-- the provider's Files API, then parses the returned handle. deps carries:
--   deps.token        -- the Keychain token (buildDeps); flows ONLY into the auth header value.
--   deps.pcall        -- LrTasks.pcall (yield-safe). The caller MUST supply it; we fall back to the
--                        standard pcall ONLY for tests (whose fake postMultipart does not yield).
--   deps.postMultipart-- optional test seam: function(url, chunks, headers) -> (body, respHeaders).
--                        Absent at runtime -> LrHttp.postMultipart (which yields; isolated by pcall).
--   deps.log          -- optional sink override (defaults to the module log). Token/path-free fields.
-- The token value, the filePath, the body, and the headers NEVER enter a log line.
-- ---------------------------------------------------------------------------
function M.uploadFile(provider, filePath, deps)
    deps = deps or {}
    local sink   = deps.log or log
    local runId  = deps.runId
    local pc     = deps.pcall or pcall   -- runtime: LrTasks.pcall via deps; tests: standard pcall.

    local url = filesUploadUrl(provider)
    if url == nil then
        return nil, 'unsupported-provider'
    end
    if type(filePath) ~= 'string' or filePath == '' then
        return nil, 'bad-args'
    end
    if type(deps.token) ~= 'string' or deps.token == '' then
        -- A speaking, token-free failure: the caller surfaces it and skips this photo.
        pcall(function()
            sink.warn('deep upload skipped: no token', { runId = runId, provider = provider })
        end)
        return nil, 'no-token'
    end

    local headers = filesHeaders(provider, deps.token)
    if headers == nil then
        return nil, 'unsupported-provider'
    end

    -- The multipart chunk streams the file from disk by filePath (no base64). fileName is the leaf
    -- basename; if LrPathUtils is unavailable (offline) fall back to a constant — the leaf is NOT
    -- logged either way.
    local leaf = 'export.jpg'
    pcall(function()
        if LrPathUtils and LrPathUtils.leafName then
            leaf = LrPathUtils.leafName(filePath) or leaf
        end
    end)
    local chunks = {
        { name = 'file', fileName = leaf, filePath = filePath, contentType = 'image/jpeg' },
    }

    -- The SDK call YIELDS on the network -> call it DIRECTLY, isolate with deps.pcall (yield-safe).
    local doPost = deps.postMultipart or function(u, c, h)
        return LrHttp.postMultipart(u, c, h)
    end
    local okCall, body, respHeaders = pc(function()
        return doPost(url, chunks, headers)
    end)
    if not okCall then
        pcall(function()
            sink.warn('deep upload transport failure', { runId = runId, provider = provider })
        end)
        return nil, 'transport'
    end
    if body == nil then
        -- LrHttp.postMultipart transport failure: nil body. respHeaders carries network diagnostics
        -- (NOT the token); we do not log them verbatim here (provider/runId only).
        pcall(function()
            sink.warn('deep upload no body', { runId = runId, provider = provider })
        end)
        return nil, 'transport'
    end

    -- A non-2xx status is a Files-API rejection. Status lives on respHeaders.status.
    local status = (type(respHeaders) == 'table') and respHeaders.status or nil
    if type(status) == 'number' and (status < 200 or status >= 300) then
        pcall(function()
            sink.warn('deep upload http error', {
                runId = runId, provider = provider, status = tostring(status),
            })
        end)
        return nil, 'http-' .. tostring(status)
    end

    -- Parse the UNTRUSTED JSON body for the provider handle. json.decode never raises (tuple idiom).
    local ok, parsed = json.decode(body)
    if not ok or type(parsed) ~= 'table' then
        return nil, 'bad-response'
    end
    if provider == 'claude' then
        local id = parsed.id
        if type(id) == 'string' and id ~= '' then
            pcall(function()
                sink.info('deep upload ok', { runId = runId, provider = provider, uploaded = true })
            end)
            return { fileId = id }
        end
        return nil, 'bad-response'
    elseif provider == 'gemini' then
        -- Gemini returns { file = { uri = '...' } }.
        local uri = (type(parsed.file) == 'table') and parsed.file.uri or nil
        if type(uri) == 'string' and uri ~= '' then
            pcall(function()
                sink.info('deep upload ok', { runId = runId, provider = provider, uploaded = true })
            end)
            return { fileUri = uri }
        end
        return nil, 'bad-response'
    end
    return nil, 'unsupported-provider'
end

-- ---------------------------------------------------------------------------
-- deleteFile(provider, handle, deps) -> true | (nil, reason)   (D-01b privacy teardown)
--   handle = { fileId = '<id>' }   (Anthropic)  |  anything (Gemini no-op)
--   reason = 'bad-args' | 'no-token' | 'transport' | 'http-<status>'
--
-- For Anthropic: DELETE https://api.anthropic.com/v1/files/{id} with the same auth + beta headers
-- so the provider-side photo copy does not linger (the 13-04 loop calls this on success AND error).
-- For Gemini: a NO-OP (the Files copy auto-expires in 48h, D-01b) -> returns true.
-- deps.deleteRaw is a test seam: function(url, headers) -> (body, respHeaders); absent at runtime
-- -> LrHttp.post(url, '', headers, 'DELETE') (yields; isolated by deps.pcall). The {id} is provider
-- state; it is interpolated into the URL but NEVER logged.
-- ---------------------------------------------------------------------------
function M.deleteFile(provider, handle, deps)
    deps = deps or {}
    local sink  = deps.log or log
    local runId = deps.runId
    local pc    = deps.pcall or pcall

    if provider == 'gemini' then
        return true                         -- Gemini Files auto-expire (48h); nothing to delete.
    end
    if provider ~= 'claude' then
        return nil, 'bad-args'              -- OpenAI never uploads; no other provider to clean.
    end

    local fileId = (type(handle) == 'table') and handle.fileId or nil
    if type(fileId) ~= 'string' or fileId == '' then
        return nil, 'bad-args'
    end
    if type(deps.token) ~= 'string' or deps.token == '' then
        return nil, 'no-token'
    end

    local headers = filesHeaders('claude', deps.token)
    if headers == nil then
        return nil, 'bad-args'
    end

    -- The id is provider state, NOT a secret/path — it goes into the URL but is NEVER logged.
    local url = 'https://api.anthropic.com/v1/files/' .. fileId

    -- LrHttp.post with an explicit DELETE method (yields on the network -> call directly, isolate
    -- with deps.pcall). An empty body is correct for a DELETE.
    local doDelete = deps.deleteRaw or function(u, h)
        return LrHttp.post(u, '', h, 'DELETE')
    end
    local okCall, body, respHeaders = pc(function()
        return doDelete(url, headers)
    end)
    if not okCall then
        pcall(function()
            sink.warn('deep delete transport failure', { runId = runId, provider = provider })
        end)
        return nil, 'transport'
    end

    local status = (type(respHeaders) == 'table') and respHeaders.status or nil
    if type(status) == 'number' and (status < 200 or status >= 300) then
        pcall(function()
            sink.warn('deep delete http error', {
                runId = runId, provider = provider, status = tostring(status),
            })
        end)
        return nil, 'http-' .. tostring(status)
    end

    pcall(function()
        sink.info('deep delete ok', { runId = runId, provider = provider, deleted = true })
    end)
    return true
end

-- ---------------------------------------------------------------------------
function M.buildDeps(provider, prefs, opts)
    local typed = settings.normalizedPrefs(prefs)

    -- Reconcile the model to the EXPLICIT provider arg (CODEX MUST-FIX 5 / T-07-15 / phase-7 N2):
    -- keep this provider's catalog model AND a custom string; reset only a stale cross-provider model.
    local model = settings.reconcileModel(provider, typed.model)

    -- FAILOVER seam (DKEY-02): a numeric opts.storageIndex resolves the keyring-selected slot via
    -- keystore.readTokenForSlot; otherwise fall back to the legacy single-key readToken (byte-compat).
    local token, status
    if opts and type(opts.storageIndex) == 'number' then
        token, status = keystore.readTokenForSlot(provider, opts.storageIndex)
    else
        token, status = M.readToken(provider)
    end
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
