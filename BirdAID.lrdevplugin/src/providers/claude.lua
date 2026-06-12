-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/claude.lua (Phase 7 Plan 02 — PROV2-01 PURE provider object)
--
-- PURE module: imports NO Lr* module, NO LrHttp, performs NO base64 encoding (encodeBase64), NO
-- Keychain access (LrPasswords), and NO network/process I/O. EVERYTHING the live call needs is
-- INJECTED via deps (the shared Lr glue src/lr/http.lua from 07-01 supplies real httpPost/sleep/
-- token/model/rateLimit/log AND the per-provider authHeaders binding). It is therefore
-- require-able under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated
-- separation invariant; the purity grep stays clean).
--
-- new(deps) -> { identify, rateLimit } : a provider object exposing the SAME interface as the fake
-- and the OpenAI provider (identify(image, ctx) -> (response) | (nil, err)), wiring the pure halves:
--   prompt.build (src.prompt) + claude_request.build (src.providers.claude_request) +
--   deps.httpPost (pcall-wrapped) + backoff.classify/next (src.net.backoff) +
--   claude_response.map (src.providers.claude_response).
--
-- This mirrors the CODEX-hardened OpenAI attempt-loop EXACTLY, swapping (07-RESEARCH Pattern 2):
--   (a) ENDPOINT  -> the Anthropic Messages endpoint;
--   (b) AUTH      -> headers come ONLY from deps.authHeaders(deps.token). OpenAI builds an inline
--                    Authorization header; claude.lua MUST NOT (CODEX MUST-FIX 7 / T-07-16). If
--                    deps.authHeaders is absent or not a function we FAIL CLEARLY with a token-free
--                    err BEFORE posting — a broken binding can never be masked by a default header;
--   (c) MODULES   -> claude_request / claude_response;
--   (d) IMAGE     -> the missing-image fail-fast checks image.b64 (RAW base64) instead of dataUrl.
-- The LOCKED return contract, the TRANSPORT_ERR constant, the token-free safeLog, the breaker
-- shouldStop/record wiring, and the backoff.classify/next loop are unchanged.
--
-- deps = { token, model, rateLimit, httpPost, sleep, log[, prefs, breaker], authHeaders }
--   authHeaders(token) -> the {field=,value=} array (the API-key header + anthropic-version + content-type).
--                         The token VALUE materializes ONLY inside what authHeaders returns; it is
--                         NEVER logged, NEVER concatenated into an err, NEVER returned. (T-07-04.)
--
-- LOCKED RETURN CONTRACT: identify returns (nil, err) ONLY for a non-retryable FATAL (401/400/
-- other 4xx) OR a fail-fast precondition (missing b64 / missing auth binding). Retry EXHAUSTION
-- (cap reached / permanent 429 / permanent 529 / repeated transport raise) returns a VALIDATED
-- degrade {bird_present=false, detections={}} (degrade-then-continue, FR2).
--
-- NO-LEAK (T-07-04): the request BODY and the request HEADERS are NEVER logged. On a pcall RAISE
-- from httpPost (which may CARRY the API-key header value in its message) we use a CONSTANT
-- transport-failure message — we NEVER include tostring(raisedError).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local prompt   = require 'src.prompt'
local request  = require 'src.providers.claude_request'
local backoff  = require 'src.net.backoff'
local response = require 'src.providers.claude_response'
local json     = require 'src.json'

local M = {}

-- The Anthropic Messages endpoint. Constant; carries no secret.
local ENDPOINT = 'https://api.anthropic.com/v1/messages'

-- A CONSTANT transport-failure message used on the pcall-raise path. We MUST NOT propagate
-- tostring(raisedError) because a fake (or a real client) may embed the API-key header value in
-- its error message (T-07-04). This constant carries zero secret.
local TRANSPORT_ERR = 'transport error'

-- The canonical token-free graceful-degrade response (a VALID contract.validateResponse shape).
local function degrade()
    return { bird_present = false, detections = {} }
end

-- safeLog: route a line through the injected sink with ONLY token-free safe metadata. NEVER pass
-- the body, headers, token, or the API-key header. Tolerant of a sink exposing event(...)/level methods.
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

-- buildAuthHeaders(deps) -> (headers) | (nil, err). [CODEX phase-7 #1/#2] Calls deps.authHeaders
-- INSIDE pcall so a raise (which may CARRY the API-key in its message) can NEVER reach a log/err/
-- return: on a raise we DISCARD the raised value and return a CONSTANT token-free err. The return
-- is then VALIDATED as a non-empty header TABLE; nil/non-table -> token-free err. The token VALUE
-- materializes ONLY inside the returned table and is NEVER returned as the err.
local function buildAuthHeaders(deps)
    if type(deps.authHeaders) ~= 'function' then
        return nil, 'missing-auth-headers-binding'
    end
    local pok, headers = pcall(deps.authHeaders, deps.token)
    if not pok then
        return nil, 'auth-headers-error'   -- DISCARD the raised value (may carry the token).
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

    -- PROV-06: surface the inter-photo rate-limit interval for the orchestrator (read-only).
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

        -- [CODEX MUST-FIX 7 / T-07-16, CODEX phase-7 #1/#2] AUTH headers come ONLY from
        -- deps.authHeaders, built via the pcall-wrapped + return-validated buildAuthHeaders BEFORE
        -- posting (a raise must NEVER leak the token into a log/err; nil/non-table must NEVER reach
        -- httpPost). A missing binding / raise / invalid return FAILS CLEARLY with a token-free err
        -- BEFORE the image so a misconfigured provider never even builds a body.
        local headers, herr = buildAuthHeaders(deps)
        if headers == nil then
            if type(breaker) == 'table' and type(breaker.record) == 'function' then
                breaker.record('fatal')
            end
            safeLog(deps, 'error', 'claude fatal: auth headers unavailable (request not sent)',
                { runId = runId, model = deps.model, error = herr })
            return nil, herr
        end

        -- [missing-image fail-fast] Claude needs EITHER inline RAW base64 in image.b64 (SHALLOW) OR a
        -- Files-API handle in image.fileId (DEEP — claude_request.lua emits source.type='file' for it).
        -- Accept either; fail fast only when BOTH are absent (the API would 400 on an empty source).
        -- The error is token/body-free.
        local b64 = (type(image) == 'table') and image.b64 or nil
        local fileId = (type(image) == 'table') and image.fileId or nil
        local hasB64 = type(b64) == 'string' and b64 ~= ''
        local hasFileId = type(fileId) == 'string' and fileId ~= ''
        if not hasB64 and not hasFileId then
            local err = 'missing-image-source'
            if type(breaker) == 'table' and type(breaker.record) == 'function' then
                breaker.record('fatal')
            end
            safeLog(deps, 'error', 'claude fatal: no image source (b64/fileId both missing; request not sent)',
                { runId = runId, model = deps.model, error = err })
            return nil, err
        end

        -- Build the prompt (Claude uses the default [0,1] bbox directive — no box-format opt) and
        -- the request body.
        local builtPrompt = prompt.build(ctx, deps.prefs)
        local bodyTable = request.build(builtPrompt, image, deps.model)
        local bodyString = json.encode(bodyTable)

        -- `headers` (carrying the API-key token VALUE) was built above via buildAuthHeaders and is
        -- NEVER passed to any log call.

        -- The attempt loop. backoff.MAX_ATTEMPTS bounds it; on exhaustion we degrade.
        local attempt = 1
        while true do
            -- pcall-wrap httpPost: a RAISE is a retryable transport error. We DISCARD the raised
            -- value (it may carry the header) and use a CONSTANT message — never tostring(raised).
            -- CRITICAL: httpPost YIELDS (LrHttp.post); the standard C `pcall` forbids yielding across
            -- its boundary, so use the injected yield-safe deps.pcall (= LrTasks.pcall); tests fall
            -- back to standard pcall (their fakes do not yield).
            local protect = (type(deps.pcall) == 'function') and deps.pcall or pcall
            local pok, status, respBody, info = protect(deps.httpPost, ENDPOINT, bodyString, headers)

            -- On a pcall RAISE, pcall's 2nd return (`status`) is the RAISED ERROR STRING, which may
            -- CARRY the API-key header value. Force it to nil on the raise path so no log line
            -- ever carries the raised message.
            local httpStatus = (pok and status) or nil

            local result
            if not pok then
                result = { outcome = 'retry', err = TRANSPORT_ERR }
                safeLog(deps, 'warn', 'claude transport error (will retry/exhaust)',
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
                safeLog(deps, 'error', 'claude fatal (non-retryable)',
                    { runId = runId, attempt = attempt, status = httpStatus, model = deps.model,
                      error = result.err })
                return nil, result.err
            end

            -- outcome == 'retry': consult the deterministic backoff policy. For a transport raise OR
            -- a network-nil (httpStatus == nil) we pass 429 to keep the transport retryable up to
            -- MAX_ATTEMPTS while honoring the SAME ceiling.
            local statusForPolicy = httpStatus
            if statusForPolicy == nil then statusForPolicy = 429 end
            local nxt = backoff.next(attempt, statusForPolicy, result.retryAfter)

            if nxt.retry then
                safeLog(deps, 'info', 'claude retrying after backoff',
                    { runId = runId, attempt = attempt, status = httpStatus, model = deps.model,
                      error = result.err })
                if type(deps.sleep) == 'function' then
                    deps.sleep(nxt.delay)
                end
                attempt = attempt + 1
            else
                -- RETRY-EXHAUSTED (cap / over-cap Retry-After / permanent 429/529). [LOCKED] return
                -- the VALIDATED degrade and log a token-free per-photo error. NO (nil,err) here.
                if type(breaker) == 'table' and type(breaker.record) == 'function' then
                    breaker.record('exhausted')
                end
                safeLog(deps, 'warn', 'claude retries exhausted -> degrade (continue run)',
                    { runId = runId, attempt = attempt, status = httpStatus, model = deps.model,
                      error = result.err })
                return degrade()
            end
        end
    end

    return self
end

return M
