-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/openai.lua (PROV-01/02/04/05/06 — PURE provider object)
--
-- PURE module: imports NO Lr* module, NO LrHttp, NO LrStringUtils, performs NO base64 encoding
-- (encodeBase64), NO Keychain access (LrPasswords), and NO network/process I/O. EVERYTHING the
-- live call needs is INJECTED via deps (the Lr glue in Plan 05-04 supplies real httpPost/sleep/
-- token/model/rateLimit/log). It is therefore require-able under stock lua / lua5.1 / luajit for
-- offline unit testing (the CODEX-mandated separation invariant; the purity grep stays clean).
--
-- new(deps) -> { identify, rateLimit } : a provider object exposing the SAME interface as the
-- fake (identify(image, ctx) -> (response) | (nil, err)), wiring the upstream pure halves:
--   prompt.build (src.prompt) + openai_request.build (src.providers.openai_request) +
--   deps.httpPost (pcall-wrapped) + backoff.classify/next (src.net.backoff) +
--   openai_response.map (src.providers.openai_response).
--
-- deps = { token, model, rateLimit, httpPost, sleep, log[, prefs, breaker], authHeaders }
--   token     : the API secret. Used ONLY by deps.authHeaders to build the Authorization header
--               VALUE passed to httpPost. It is NEVER logged, NEVER concatenated into an err
--               string, NEVER returned. (T-05-07 / CODEX phase-7 #1/#3.)
--   authHeaders(token) -> the {field=,value=} array (Authorization Bearer + Content-Type). The
--               token VALUE materializes ONLY inside what authHeaders returns. [CODEX phase-7 #3]
--               openai builds its auth header from this shared binding (like claude/gemini), NOT
--               an inline 'Bearer ..deps.token', so a deps with token=nil + a real authHeaders
--               posts the REAL header. The authHeaders CALL is pcall-wrapped and its return is
--               validated as a non-empty header TABLE BEFORE any post (CODEX phase-7 #1/#2); on a
--               raise / nil / non-table return we FAIL token-free and do NOT post.
--   model     : the model id (passed THROUGH to openai_request.build unvalidated).
--   rateLimit : the inter-photo interval (seconds). EXPOSED as self.rateLimit for the
--               orchestrator (PROV-06). The provider does NOT sleep between photos; that is the
--               orchestrator's job — we only surface the interval.
--   httpPost(url, bodyString, headers) -> (status, respBody, info) -- MAY RAISE. We pcall it.
--   sleep(seconds)  -- the inter-ATTEMPT backoff wait (recorder/no-op in tests, LrTasks.sleep in glue).
--   log             -- a log sink exposing event(level, msg, fields) (and/or info/warn/error).
--                      We route ALL logging through it with ONLY token-free safe metadata.
--   prefs           -- optional; passed to prompt.build for the user's promptAddition.
--   breaker         -- optional; if present, identify consults shouldStop() up front and
--                      record('ok'|'exhausted'|'fatal') after, so a run-level outage stops the run.
--
-- LOCKED RETURN CONTRACT (CODEX MUST-FIX 6): identify returns (nil, err) ONLY for a
-- non-retryable FATAL (401/400/other 4xx). Retry EXHAUSTION (cap reached / over-cap Retry-After
-- / permanent 429 / repeated transport raise) returns a VALIDATED degrade
-- {bird_present=false, detections={}} (degrade-then-continue, FR2). NO "or return nil,err"
-- alternative on the exhaustion path.
--
-- NO-LEAK (CODEX MUST-FIX 5/11): the request BODY and the request HEADERS are NEVER logged.
-- Only safe metadata (status, attempt, model, runId, a token-free error string) is logged. On a
-- pcall RAISE from httpPost (which may CARRY the Authorization header value in its message) we
-- use a CONSTANT transport-failure message — we NEVER include tostring(raisedError).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local prompt  = require 'src.prompt'
local request = require 'src.providers.openai_request'
local backoff = require 'src.net.backoff'
local response = require 'src.providers.openai_response'
local json    = require 'src.json'

local M = {}

-- The OpenAI Chat Completions endpoint. Constant; carries no secret.
local ENDPOINT = 'https://api.openai.com/v1/chat/completions'

-- A CONSTANT transport-failure message used on the pcall-raise path. We MUST NOT propagate
-- tostring(raisedError) because a fake (or a real client) may embed the Authorization header
-- value in its error message (CODEX MUST-FIX 5). This constant carries zero secret.
local TRANSPORT_ERR = 'transport error'

-- The canonical token-free graceful-degrade response (a VALID contract.validateResponse shape).
-- Built fresh each call so a caller mutating it can never corrupt a shared constant.
local function degrade()
    return { bird_present = false, detections = {} }
end

-- safeLog(deps, level, msg, fields): route a line through the injected sink with ONLY
-- token-free safe metadata. NEVER pass the body, headers, token, or 'Bearer'. Tolerant of a
-- sink that exposes event(...) or level methods or nothing.
local function safeLog(deps, level, msg, fields)
    local log = deps.log
    if type(log) ~= 'table' then return end
    if type(log.event) == 'function' then
        log.event(level, msg, fields)
    elseif type(log[level]) == 'function' then
        log[level](msg, fields)
    end
end

-- isHeaderTable(h): true iff h is a NON-EMPTY array of {field=,value=} pairs (a usable header
-- set). A nil / non-table / empty return from authHeaders must NEVER reach httpPost.
local function isHeaderTable(h)
    if type(h) ~= 'table' then return false end
    local n = #h
    if n == 0 then return false end
    for i = 1, n do
        if type(h[i]) ~= 'table' then return false end
    end
    return true
end

-- buildAuthHeaders(deps) -> (headers) | (nil, err). [CODEX phase-7 #1/#2/#3] Calls deps.authHeaders
-- INSIDE pcall so a raise (which may CARRY the token in its message) can NEVER reach a log/err/
-- return: on a raise we DISCARD the raised value and return a CONSTANT token-free err. The return
-- is then VALIDATED as a non-empty header TABLE; nil/non-table -> token-free err. The header VALUE
-- (the token) materializes ONLY inside the returned table and is NEVER returned as the err.
local function buildAuthHeaders(deps)
    if type(deps.authHeaders) ~= 'function' then
        return nil, 'missing-auth-headers-binding'
    end
    local pok, headers = pcall(deps.authHeaders, deps.token)
    if not pok then
        -- DISCARD `headers` (the raised value) — it may carry the token. Constant message only.
        return nil, 'auth-headers-error'
    end
    if not isHeaderTable(headers) then
        return nil, 'invalid-auth-headers'
    end
    return headers
end

-- new(deps) -> provider object { identify, rateLimit }.
function M.new(deps)
    deps = type(deps) == 'table' and deps or {}

    local self = {}

    -- PROV-06: surface the inter-photo rate-limit interval for the orchestrator (read-only
    -- value; the provider does not sleep between photos).
    self.rateLimit = deps.rateLimit

    -- identify(image, ctx) -> (response) | (nil, err)
    function self.identify(image, ctx)
        local runId = (type(ctx) == 'table' and ctx.runId) or nil
        local breaker = deps.breaker

        -- Run-level breaker: if a prior outage tripped it, do not call the API; degrade.
        if type(breaker) == 'table' and type(breaker.shouldStop) == 'function'
            and breaker.shouldStop() then
            safeLog(deps, 'warn', 'breaker-open: skipping AI call (run-level cooldown)',
                { runId = runId, model = deps.model })
            return degrade()
        end

        -- [CODEX MUST-FIX 2] FAIL FAST on a missing/empty data URL: never send an image_url with
        -- a nil/empty url (the API would 400, or worse we'd post an empty image_url:[] shape).
        -- The error is token/body-free. The live glue (openai_http) attaches image.dataUrl before
        -- calling identify; if it is somehow absent we refuse rather than send a malformed body.
        local dataUrl = (type(image) == 'table') and image.dataUrl or nil
        if type(dataUrl) ~= 'string'
            or dataUrl:find('data:image/jpeg;base64,', 1, true) ~= 1
            or #dataUrl <= #('data:image/jpeg;base64,') then
            local err = 'missing-image-data-url'
            if type(breaker) == 'table' and type(breaker.record) == 'function' then
                breaker.record('fatal')
            end
            safeLog(deps, 'error', 'openai fatal: image data URL missing/empty (request not sent)',
                { runId = runId, model = deps.model, error = err })
            return nil, err
        end

        -- [CODEX phase-7 #1/#2/#3] Build the auth headers from the SHARED deps.authHeaders binding
        -- (NOT an inline 'Bearer ..deps.token'): pcall-wrapped + return-validated, BEFORE building
        -- the body. A raise / nil / non-table return FAILS token-free and we do NOT post. The token
        -- VALUE materializes ONLY inside the returned table and is NEVER logged/returned.
        local headers, herr = buildAuthHeaders(deps)
        if headers == nil then
            if type(breaker) == 'table' and type(breaker.record) == 'function' then
                breaker.record('fatal')
            end
            safeLog(deps, 'error', 'openai fatal: auth headers unavailable (request not sent)',
                { runId = runId, model = deps.model, error = herr })
            return nil, herr
        end

        -- Build the prompt (user guidance fenced inside prompt.build) and the request body.
        local builtPrompt = prompt.build(ctx, deps.prefs)
        local bodyTable = request.build(builtPrompt, image, deps.model)
        local bodyString = json.encode(bodyTable)

        -- =====================================================================
        -- SINGLE-ATTEMPT MODE (Plan 11-05, DKEY-02): GUARDED + ADDITIVE. When deps.maxAttempts == 1
        -- the failover COORDINATOR (src.net.keyring_runner) owns the retry/sleep/failover decision,
        -- so the provider performs exactly ONE HTTP attempt, does NOT sleep, does NOT loop, and does
        -- NOT record to the run breaker (the coordinator is the SOLE breaker recorder, D-07). It
        -- returns the TOKEN-FREE structured table { outcome, status, retryAfter, response, err } so
        -- the coordinator can split 401/403 (retire) from 400/404/422 (request-error) by the
        -- reliable HTTP STATUS — never by parsing an opaque err string (D-04). The LEGACY path below
        -- (deps.maxAttempts absent or > 1) is UNCHANGED and byte-compatible.
        -- =====================================================================
        if deps.maxAttempts == 1 then
            local protect = (type(deps.pcall) == 'function') and deps.pcall or pcall
            local pok, status, respBody, info = protect(deps.httpPost, ENDPOINT, bodyString, headers)
            -- On a pcall RAISE, `status` is the raised error string (which may carry the auth header
            -- value). Force it to nil so the returned status/err is token-free (CODEX MUST-FIX 5).
            local httpStatus = (pok and status) or nil

            if not pok then
                -- Transport raise -> a retryable transport error with a CONSTANT token-free err.
                safeLog(deps, 'warn', 'openai single-attempt transport error (coordinator decides)',
                    { runId = runId, model = deps.model, error = TRANSPORT_ERR })
                return { outcome = 'retry', status = nil, retryAfter = nil,
                         response = nil, err = TRANSPORT_ERR }
            end

            local classified = backoff.classify(status, respBody, info)
            if classified.outcome == 'ok' then
                -- response.map is TOTAL: a contract-valid table or a validated degrade.
                return { outcome = 'ok', status = httpStatus, retryAfter = nil,
                         response = response.map(classified.parsed), err = nil }
            elseif classified.outcome == 'retry' then
                safeLog(deps, 'info', 'openai single-attempt retryable (coordinator decides failover)',
                    { runId = runId, status = httpStatus, model = deps.model, error = classified.err })
                return { outcome = 'retry', status = httpStatus, retryAfter = classified.retryAfter,
                         response = nil, err = classified.err }
            else
                -- classify 'fatal': split by STATUS — 401/403 -> auth-fatal (retire), else
                -- (400/404/422/other non-auth fatal) -> request-fatal (per-photo error, no failover).
                local label = (httpStatus == 401 or httpStatus == 403) and 'auth-fatal' or 'request-fatal'
                safeLog(deps, 'error', 'openai single-attempt fatal (coordinator maps by status)',
                    { runId = runId, status = httpStatus, model = deps.model, error = classified.err })
                return { outcome = label, status = httpStatus, retryAfter = nil,
                         response = nil, err = classified.err }
            end
        end

        -- The attempt loop. backoff.MAX_ATTEMPTS bounds it; on exhaustion we degrade.
        local attempt = 1
        while true do
            -- pcall-wrap httpPost (CODEX MUST-FIX 5): a RAISE is a retryable transport error.
            -- We deliberately DISCARD the raised value (it may carry the header) and use a
            -- CONSTANT message — never tostring(raisedError). CRITICAL: httpPost YIELDS (LrHttp.post
            -- waits on the network), and the standard C `pcall` forbids yielding across its boundary
            -- ("Yielding is not allowed within a C or metamethod call"). So use the injected yield-
            -- safe deps.pcall (= LrTasks.pcall in production); tests fall back to standard pcall.
            local protect = (type(deps.pcall) == 'function') and deps.pcall or pcall
            local pok, status, respBody, info = protect(deps.httpPost, ENDPOINT, bodyString, headers)

            -- httpStatus is the SAFE status to log: on a pcall RAISE, pcall's 2nd return value
            -- (`status`) is the RAISED ERROR STRING, which may CARRY the Authorization header
            -- value (CODEX MUST-FIX 5). We MUST NOT log or propagate it — force it to nil on the
            -- raise path so no log line ever carries the raised message.
            local httpStatus = (pok and status) or nil

            local result
            if not pok then
                -- Transport raise -> classify as a retryable transport error (status=nil),
                -- with a token/header/body-free message. The raised value is DISCARDED.
                result = { outcome = 'retry', err = TRANSPORT_ERR }
                safeLog(deps, 'warn', 'openai transport error (will retry/exhaust)',
                    { runId = runId, attempt = attempt, model = deps.model, error = TRANSPORT_ERR })
            else
                result = backoff.classify(status, respBody, info)
            end

            if result.outcome == 'ok' then
                -- response.map is TOTAL: a contract-valid table or a validated degrade.
                if type(breaker) == 'table' and type(breaker.record) == 'function' then
                    breaker.record('ok')
                end
                return response.map(result.parsed)
            end

            if result.outcome == 'fatal' then
                -- Non-retryable 401/400/other-4xx. classify's err is already token-free.
                if type(breaker) == 'table' and type(breaker.record) == 'function' then
                    breaker.record('fatal')
                end
                safeLog(deps, 'error', 'openai fatal (non-retryable)',
                    { runId = runId, attempt = attempt, status = httpStatus, model = deps.model,
                      error = result.err })
                return nil, result.err
            end

            -- outcome == 'retry': consult the deterministic backoff policy. For a transport
            -- raise OR a network-nil (httpStatus == nil) backoff.next would treat it as
            -- non-retryable, so we pass 429 to keep the transport retryable up to MAX_ATTEMPTS
            -- while honoring the SAME ceiling.
            local statusForPolicy = httpStatus
            if statusForPolicy == nil then statusForPolicy = 429 end
            local nxt = backoff.next(attempt, statusForPolicy, result.retryAfter)

            if nxt.retry then
                safeLog(deps, 'info', 'openai retrying after backoff',
                    { runId = runId, attempt = attempt, status = httpStatus, model = deps.model,
                      error = result.err })
                if type(deps.sleep) == 'function' then
                    deps.sleep(nxt.delay)
                end
                attempt = attempt + 1
            else
                -- RETRY-EXHAUSTED (cap / over-cap Retry-After / permanent 429). [CODEX MUST-FIX 6,
                -- LOCKED] return the VALIDATED degrade and log a token-free per-photo error.
                -- NO "or return nil,err" branch here.
                if type(breaker) == 'table' and type(breaker.record) == 'function' then
                    breaker.record('exhausted')
                end
                safeLog(deps, 'warn', 'openai retries exhausted -> degrade (continue run)',
                    { runId = runId, attempt = attempt, status = httpStatus, model = deps.model,
                      error = result.err })
                return degrade()
            end
        end
    end

    return self
end

return M
