-- test/fixtures/claude/status_fixtures.lua (Phase 7 Plan 02 — PROV2-01 status/header fixtures)
--
-- Self-contained, OFFLINE (status, headers, body, info) tuples mirroring the LrHttp return
-- contract, returned as a plain Lua table so test/claude_provider_spec.lua can require it (no Lr,
-- no network). Mirrors test/fixtures/openai/status_fixtures.lua style.
--
-- LrHttp return contract:
--   * HTTP response: body string + a headers table whose `status` key is the integer status and
--     whose ARRAY part is a list of { field=, value= } header pairs.
--   * transport/network failure: status == nil + info.error = {errorCode,...}.
--
-- The Claude success body is an Anthropic Messages-API envelope: stop_reason='tool_use' + a
-- content array carrying a tool_use block whose `input` is the (already-parsed) structured object.
-- Because the body crosses the wire as a JSON STRING, the success body here is a JSON STRING the
-- provider's json.decode turns back into a table with a parsed `input` object (NOT a nested
-- JSON-string), exactly as the live API delivers it.
--
-- Error bodies carry the Anthropic error envelope { type:'error', error:{type,message} } — the
-- provider NEVER reads error.message (backoff.statusLabel is status-only). 529 is Anthropic's
-- overloaded_error (retryable).
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

-- A valid Claude success HTTP body STRING (the wire shape). content[1] is a tool_use block whose
-- `input` is a JSON OBJECT (it decodes to a Lua table — NOT a nested JSON string).
F.SUCCESS_BODY =
    '{"id":"msg_1","model":"claude-opus-4-8","role":"assistant","stop_reason":"tool_use",' ..
    '"content":[{"type":"tool_use","id":"toolu_1","name":"report_bird_identification",' ..
    '"input":{"bird_present":true,"detections":[{' ..
    '"bbox":[0.30,0.25,0.70,0.80],' ..
    '"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis",' ..
    '"confidence":0.82,' ..
    '"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis",' ..
    '"alternatives":[]}]}}]}'

F.EXPECTED_COMMON_NAME = 'Northern Cardinal'

-- A refusal-shaped success body (HTTP 200, stop_reason='refusal') -> the mapper degrades.
F.REFUSAL_BODY =
    '{"id":"msg_2","stop_reason":"refusal","content":[{"type":"text","text":"I cannot help."}]}'

-- A malformed (truncated) HTTP body that json.decode cannot parse -> the mapper degrades (no retry).
F.MALFORMED_BODY = '{"id":"msg_3","stop_reason":"tool_use","content":[{"type":"tool_use'

-- (a) 200 OK with the valid tool_use body.
F.success = {
    status = 200,
    body = F.SUCCESS_BODY,
    headers = headers(200, { header('content-type', 'application/json') }),
    label = '200 OK with a valid tool_use body',
}

-- (b) 400 invalid_request_error -> fatal (non-retryable).
F.badRequest = {
    status = 400,
    body = '{"type":"error","error":{"type":"invalid_request_error","message":"bad schema"}}',
    headers = headers(400, { header('content-type', 'application/json') }),
    label = '400 invalid_request_error -- fatal',
}

-- (c) 401 authentication_error -> fatal.
F.unauthorized = {
    status = 401,
    body = '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
    headers = headers(401, { header('content-type', 'application/json') }),
    label = '401 authentication_error -- fatal',
    -- a needle from the body that must NEVER appear in err/logs (status-only labels).
    bodyNeedle = 'invalid x-api-key',
}

-- (d) 429 rate_limit_error -> retryable (honor retry-after if present; none here so exp fallback).
F.rateLimit = {
    status = 429,
    body = '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}',
    headers = headers(429, { header('content-type', 'application/json') }),
    label = '429 rate_limit_error -- retry',
}

-- (e) 529 overloaded_error (Anthropic) -> retryable.
F.overloaded = {
    status = 529,
    body = '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}',
    headers = headers(529, { header('content-type', 'application/json') }),
    label = '529 overloaded_error -- retry',
}

F.helpers = { header = header, headers = headers }

return F
