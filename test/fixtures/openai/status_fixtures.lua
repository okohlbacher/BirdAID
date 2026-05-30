-- test/fixtures/openai/status_fixtures.lua (Phase 5 — PROV-05 status/header fixtures)
--
-- Self-contained, OFFLINE (status, headers, body, info) tuples mirroring the LrHttp return
-- contract, returned as a plain Lua table so test/backoff_spec.lua can require it (no Lr, no
-- network). Mirrors test/fixtures/jpeg_fixtures.lua style (offline plain data tables).
--
-- LrHttp return contract (05-RESEARCH Pitfall 4/5):
--   * On an HTTP response: body string + a headers table whose `status` key is the integer
--     status and whose ARRAY part is a list of { field=, value= } header pairs.
--   * On a transport/network failure: (nil, info) where info.error = {errorCode,name,...} and
--     there is NO status. We model that as { status = nil, info = { error = {...} } }.
--
-- 'retry-after-ms' is OpenAI's calibrated millisecond wait (429 only). 'Retry-After' is EITHER
-- integer seconds OR an RFC1123 HTTP-date. classify must honor all three (CODEX MUST-FIX 2).
--
-- Strictly Lua 5.1 common subset.

-- header(field, value) -> a { field=, value= } pair (the LrHttp array-element shape).
local function header(field, value)
    return { field = field, value = value }
end

-- A headers table = a status key PLUS the array of header pairs.
local function headers(status, pairs_)
    local h = { status = status }
    pairs_ = pairs_ or {}
    for i = 1, #pairs_ do h[i] = pairs_[i] end
    return h
end

local F = {}

-- (a) 429 with retry-after-ms (milliseconds -> seconds). 2500 ms => 2.5 s.
F.rateLimit_ms = {
    status = 429,
    body = '{"error":{"message":"Rate limit reached","type":"requests"}}',
    headers = headers(429, {
        header('Content-Type', 'application/json'),
        header('retry-after-ms', '2500'),
    }),
    expectRetryAfter = 2.5,
    label = '429 with retry-after-ms=2500 (=> 2.5s)',
}

-- (b) 429 with Retry-After as INTEGER SECONDS. "12" => 12 s.
F.rateLimit_seconds = {
    status = 429,
    body = '{"error":{"message":"Rate limit reached"}}',
    headers = headers(429, {
        header('Retry-After', '12'),
    }),
    expectRetryAfter = 12,
    label = '429 with Retry-After=12 (seconds)',
}

-- (c) 429 with Retry-After as an HTTP-date (RFC1123). The spec computes the expected delta by
-- passing a FIXED nowEpoch to httpDateToSeconds, so the assertion is deterministic.
-- The date below is "Wed, 21 Oct 2026 07:28:00 GMT".
F.rateLimit_httpDate = {
    status = 429,
    body = '{"error":{"message":"Rate limit reached"}}',
    headers = headers(429, {
        header('Retry-After', 'Wed, 21 Oct 2026 07:28:00 GMT'),
    }),
    dateString = 'Wed, 21 Oct 2026 07:28:00 GMT',
    label = '429 with Retry-After as an HTTP-date',
}

-- (d) 400 bad request (schema/request error). Carries an error object to surface. Non-retryable.
F.badRequest = {
    status = 400,
    body = '{"error":{"message":"Invalid schema for response_format","type":"invalid_request_error"}}',
    headers = headers(400, {
        header('Content-Type', 'application/json'),
    }),
    label = '400 bad request (schema/request error) -- fatal',
}

-- (e) 401 invalid auth. Non-retryable; err must name "check API key" and carry NO token.
F.unauthorized = {
    status = 401,
    body = '{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}',
    headers = headers(401, {
        header('Content-Type', 'application/json'),
    }),
    label = '401 invalid auth -- fatal',
}

-- (f) 500 server error -- retryable, no Retry-After header.
F.serverError = {
    status = 500,
    body = '{"error":{"message":"The server had an error"}}',
    headers = headers(500, {
        header('Content-Type', 'application/json'),
    }),
    label = '500 server error -- retry',
}

-- (g) Network/transport failure: nil status + info.error. Retryable.
F.networkNil = {
    status = nil,
    body = nil,
    info = { error = { errorCode = 'timedOut', name = 'NetworkError', nativeCode = -1001 } },
    label = 'network-nil transport error -- retry',
}

-- (h) 200 OK with a valid JSON body (for the classify happy-path).
F.ok = {
    status = 200,
    body = '{"choices":[{"finish_reason":"stop","message":{"content":"{}"}}]}',
    headers = headers(200, {
        header('Content-Type', 'application/json'),
    }),
    label = '200 OK with decodable JSON body',
}

-- (i) 200 OK with a MALFORMED JSON body (decode fails -> retry, never crash).
F.okBadJson = {
    status = 200,
    body = '{not valid json',
    headers = headers(200, {
        header('Content-Type', 'application/json'),
    }),
    label = '200 OK with undecodable body -- retry',
}

-- Expose the builders so the spec can craft adversarial header arrays inline if needed.
F.helpers = { header = header, headers = headers }

return F
