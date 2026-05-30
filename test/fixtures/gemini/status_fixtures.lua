-- test/fixtures/gemini/status_fixtures.lua (Phase 7 Plan 03 — PROV2-02 status/header fixtures)
--
-- Self-contained, OFFLINE (status, headers, body, info) tuples mirroring the LrHttp return
-- contract, returned as a plain Lua table so test/gemini_provider_spec.lua can require it (no Lr,
-- no network). Mirrors test/fixtures/claude/status_fixtures.lua style.
--
-- LrHttp return contract:
--   * HTTP response: body string + a headers table whose `status` key is the integer status and
--     whose ARRAY part is a list of { field=, value= } header pairs.
--   * transport/network failure: status == nil + info.error = {errorCode,...}.
--
-- The Gemini success body is a generateContent envelope: candidates[1].content.parts[1].text is a
-- JSON STRING per the responseSchema, each detection carrying box_2d [ymin,xmin,ymax,xmax] 0-1000.
--
-- Error bodies carry the Google RPC error envelope { error:{code,status,message,details[]} } — the
-- provider NEVER reads error.message (backoff.statusLabel is status-only). Gemini delivers its
-- retry wait in the BODY (error.details[].retryDelay 'Ns' with @type ...google.rpc.RetryInfo), NOT
-- a header — the 429 fixture below carries a header Retry-After:1 AND a body retryDelay '30s' so the
-- spec can prove the BODY wins (CODEX MUST-FIX 9). 503 (UNAVAILABLE) is retryable.
--
-- Strictly Lua 5.1 common subset.

local function header(field, value)
    return { field = field, value = value }
end

local function headers(status, pairs_)
    local h = { status = status }
    pairs_ = pairs_ or {}
    for i = 1, #pairs_ do h[i] = pairs_[i] end
    return h
end

local F = {}

-- A valid Gemini success HTTP body STRING (the wire shape). The text part carries the structured
-- JSON object with a box_2d {200,300,700,800} -> bbox {0.3,0.2,0.8,0.7} after the mapper. The text
-- JSON is embedded inside the envelope as a JSON STRING (so its quotes are escaped).
F.SUCCESS_TEXT_JSON =
    '{\\"bird_present\\":true,\\"detections\\":[{' ..
    '\\"box_2d\\":[200,300,700,800],' ..
    '\\"common_name\\":\\"Northern Cardinal\\",' ..
    '\\"scientific_name\\":\\"Cardinalis cardinalis\\",' ..
    '\\"confidence\\":0.82,' ..
    '\\"identified_rank\\":\\"species\\",' ..
    '\\"rank_name\\":\\"Cardinalis cardinalis\\",' ..
    '\\"alternatives\\":[]}]}'

F.SUCCESS_BODY =
    '{"candidates":[{"content":{"parts":[{"text":"' .. F.SUCCESS_TEXT_JSON .. '"}]},' ..
    '"finishReason":"STOP"}]}'

F.EXPECTED_COMMON_NAME = 'Northern Cardinal'
F.EXPECTED_BBOX = { 0.3, 0.2, 0.8, 0.7 }

-- A SAFETY-blocked body (HTTP 200, finishReason='SAFETY') -> the mapper degrades.
F.REFUSAL_BODY =
    '{"candidates":[{"content":{"parts":[{"text":"{}"}]},"finishReason":"SAFETY"}]}'

-- A malformed (truncated) HTTP body that json.decode cannot parse -> the mapper degrades (no retry).
F.MALFORMED_BODY = '{"candidates":[{"content":{"parts":[{"text":"{\\"bird_present'

-- (a) 200 OK with the valid box_2d body.
F.success = {
    status = 200,
    body = F.SUCCESS_BODY,
    headers = headers(200, { header('content-type', 'application/json') }),
    label = '200 OK with a valid box_2d detection body',
}

-- (b) 400 INVALID_ARGUMENT -> fatal (non-retryable).
F.badRequest = {
    status = 400,
    body = '{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"bad request"}}',
    headers = headers(400, { header('content-type', 'application/json') }),
    label = '400 INVALID_ARGUMENT -- fatal',
}

-- (c) 401 PERMISSION_DENIED (bad/missing key) -> fatal. Carries a body needle that must NOT leak.
F.unauthorized = {
    status = 401,
    body = '{"error":{"code":401,"status":"PERMISSION_DENIED","message":"API key not valid SECRET-LEAK"}}',
    headers = headers(401, { header('content-type', 'application/json') }),
    label = '401 PERMISSION_DENIED -- fatal',
    bodyNeedle = 'SECRET-LEAK',
}

-- (d) 403 PERMISSION_DENIED -> fatal.
F.forbidden = {
    status = 403,
    body = '{"error":{"code":403,"status":"PERMISSION_DENIED","message":"forbidden"}}',
    headers = headers(403, { header('content-type', 'application/json') }),
    label = '403 PERMISSION_DENIED -- fatal',
}

-- (e) 429 RESOURCE_EXHAUSTED with a HEADER Retry-After:1 AND a BODY retryDelay '30s'. The BODY
--     30s must WIN over the header 1s (CODEX MUST-FIX 9). The 30 is at the CAP so it is the delay.
F.RATE_LIMIT_BODY =
    '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"quota",' ..
    '"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"30s"},' ..
    '{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[]}]}}'
F.rateLimit = {
    status = 429,
    body = F.RATE_LIMIT_BODY,
    headers = headers(429, { header('content-type', 'application/json'), header('Retry-After', '1') }),
    label = '429 RESOURCE_EXHAUSTED -- retry; header 1s but body retryDelay 30s WINS',
}

-- (f) 503 UNAVAILABLE (overloaded) -> retryable.
F.unavailable = {
    status = 503,
    body = '{"error":{"code":503,"status":"UNAVAILABLE","message":"overloaded"}}',
    headers = headers(503, { header('content-type', 'application/json') }),
    label = '503 UNAVAILABLE -- retry',
}

F.helpers = { header = header, headers = headers }

return F
