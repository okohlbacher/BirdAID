-- test/openai_provider_spec.lua (Phase 5 — PROV-01/02/04/05/06: the assembled provider object)
--
-- Exercises BirdAID.lrdevplugin/src/providers/openai.lua + the init.lua 'openai' wiring: PURE
-- modules (all Lr is INJECTED) require-able under stock lua / luajit. Drives identify(image,
-- ctx) with an INJECTED fake httpPost returning captured fixtures and asserts:
--   * success -> a contract-valid response (common_name carried through openai_response.map);
--   * refusal/malformed/truncated/content_filter -> a VALID degrade;
--   * 401/400 -> (nil, err) with NO retry (httpPost called EXACTLY once) and NO token in the err;
--   * 429-then-200 -> retries the expected number of times calling the recorder sleep with the
--     deterministic backoff delays, then succeeds;
--   * network-nil-then-200 -> retries then succeeds;
--   * PERMANENT 429 (always 429) -> retry-EXHAUSTED returns the VALIDATED degrade (CODEX MUST-FIX 6),
--     NOT (nil, err);
--   * a fake httpPost that RAISES with the Authorization header VALUE in its message -> a retryable
--     transport error, with the token ABSENT from the returned err AND every recorded log line (MUST-FIX 5);
--   * using SENTINELs, NO recorded log line/field contains 'Authorization', 'Bearer',
--     'data:image/jpeg;base64', or the request JSON body (MUST-FIX 11);
--   * deps.rateLimit is surfaced unchanged (PROV-06).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local openai    = require('src.providers.openai')
local providers = require('src.providers.init')
local contract  = require('src.contract')
local backoff   = require('src.net.backoff')
local json      = require('src.json')
local BODY      = require('test.fixtures.openai.body_fixtures')

assert_true(type(openai) == 'table', "require 'src.providers.openai' resolves")
assert_true(type(openai.new) == 'function', "openai exposes new")

-- A known SENTINEL token + a SENTINEL data URL we feed as the image so the no-leak greps have
-- distinctive needles to search for. Neither may appear in any log line or returned err.
local SENTINEL_TOKEN = 'sk-SENTINEL-TOKEN-do-not-leak-1234567890'
local SENTINEL_DATAURL = 'data:image/jpeg;base64,SENTINELIMAGEBYTESxyz=='

-- An HTTP body STRING wrapping a structured-output content JSON in the choices envelope, exactly
-- as the live API returns (message.content is itself a JSON string). We encode via src.json so
-- the provider's nested-decode path is exercised end-to-end.
local function httpBody(contentStr, finishReason, refusal)
    local msg = { content = contentStr }
    if refusal ~= nil then msg.refusal = refusal end
    return json.encode({
        choices = { { finish_reason = finishReason or 'stop', message = msg } },
    })
end

-- The valid Northern-Cardinal structured-output content as a JSON STRING (mirrors body_fixtures).
local VALID_CONTENT =
    '{"bird_present":true,"detections":[{' ..
    '"bbox":[0.30,0.25,0.70,0.80],' ..
    '"common_name":"Northern Cardinal",' ..
    '"scientific_name":"Cardinalis cardinalis",' ..
    '"confidence":0.82,' ..
    '"identified_rank":"species",' ..
    '"rank_name":"Cardinalis cardinalis",' ..
    '"alternatives":[]}]}'

local SUCCESS_BODY = httpBody(VALID_CONTENT, 'stop')

-- header(field,value) helper matching the LrHttp { field=, value= } array shape.
local function hdr(field, value) return { field = field, value = value } end
local function headers(status, pairs_)
    local h = { status = status }
    pairs_ = pairs_ or {}
    for i = 1, #pairs_ do h[i] = pairs_[i] end
    return h
end

-- [CODEX phase-7 #3] The OpenAI auth header binding the shared glue supplies: Authorization
-- Bearer <token> + Content-Type. The token VALUE materializes ONLY inside this returned table.
-- openai.lua now builds its auth header from deps.authHeaders (NOT an inline 'Bearer ..token').
local function authHeaders(token)
    return {
        { field = 'Authorization', value = 'Bearer ' .. tostring(token) },
        { field = 'Content-Type', value = 'application/json' },
    }
end

-- makeDeps(httpPost[, opts]) -> deps with recorder sleep + recorder log + sentinel token + the
-- OpenAI authHeaders binding. Returns deps PLUS the recorder tables so the spec can assert on them.
local function makeDeps(httpPost, opts)
    opts = opts or {}
    local sleeps = {}
    local logs = {}
    local deps = {
        token = SENTINEL_TOKEN,
        model = 'gpt-4o',
        rateLimit = 1.5,
        httpPost = httpPost,
        sleep = function(s) sleeps[#sleeps + 1] = s end,
        log = {
            event = function(level, msg, fields)
                logs[#logs + 1] = { level = level, msg = msg, fields = fields }
            end,
        },
        prefs = {},
    }
    -- authHeaders is present UNLESS the caller explicitly omits it (the negative cases below).
    if opts.omitAuthHeaders ~= true then
        deps.authHeaders = opts.authHeaders or authHeaders
    end
    return deps, sleeps, logs
end

-- A scripted httpPost: returns successive (status, body, info) tuples from `script`, and counts
-- its calls. Each script entry is { status=, body=, info= }.
local function scriptedPost(script)
    local calls = { n = 0 }
    local function post(url, body, hdrs)
        calls.n = calls.n + 1
        calls.lastUrl = url
        calls.lastBody = body
        calls.lastHeaders = hdrs
        local entry = script[calls.n] or script[#script]
        return entry.status, entry.body, entry.info
    end
    return post, calls
end

-- collectLogText(logs) -> a single string concatenating every msg + every field key/value,
-- so the no-leak assertions can substring-search the WHOLE recorded surface.
local function collectLogText(logs)
    local parts = {}
    for i = 1, #logs do
        local e = logs[i]
        parts[#parts + 1] = tostring(e.level)
        parts[#parts + 1] = tostring(e.msg)
        if type(e.fields) == 'table' then
            for k, v in pairs(e.fields) do
                parts[#parts + 1] = tostring(k)
                parts[#parts + 1] = tostring(v)
            end
        end
    end
    return table.concat(parts, '\1')
end

local IMAGE = { kind = 'bytes', dataUrl = SENTINEL_DATAURL, width = 800, height = 600 }
local CTX = { runId = 'run-xyz' }

-- =====================================================================
-- (1) Wiring: providers.get('openai', deps) returns the provider object.
-- =====================================================================
do
    local post = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps = makeDeps(post)
    local prov, err = providers.get('openai', deps)
    assert_true(type(prov) == 'table', "get('openai', deps) returns a table")
    assert_true(err == nil, "get('openai', deps) returns no error")
    assert_true(type(prov.identify) == 'function', "provider exposes identify (interface parity)")
    assert_eq(prov.rateLimit, 1.5, "provider surfaces deps.rateLimit unchanged (PROV-06)")
    -- fake/claude/gemini paths unchanged.
    local fakeProv = providers.get('fake')
    assert_true(type(fakeProv) == 'table' and type(fakeProv.identify) == 'function',
        "get('fake') still returns the fake provider")
    -- [07-02] claude is now wired: the 07-01 dispatch seam resolves the lazy-required pure
    -- provider object (identify + rateLimit), no longer a 'provider-pending:claude' error.
    local cprov, cerr = providers.get('claude', { rateLimit = 2 })
    assert_true(type(cprov) == 'table' and type(cprov.identify) == 'function',
        "get('claude', deps) resolves the provider object (lands in 07-02)")
    assert_true(cerr == nil, "get('claude', deps) returns no error")
end

-- =====================================================================
-- (2) SUCCESS -> a contract-valid response carrying the common_name.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local prov = openai.new((makeDeps(post)))
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "success: no err")
    assert_true(type(resp) == 'table', "success: returns a table")
    assert_true(contract.validateResponse(resp), "success: response passes validateResponse")
    assert_eq(resp.bird_present, true, "success: bird_present true")
    assert_eq(resp.detections[1].common_name, "Northern Cardinal", "success: common_name carried")
    assert_eq(calls.n, 1, "success: httpPost called exactly once")
    -- The request went to the OpenAI endpoint.
    assert_true(calls.lastUrl:find('api.openai.com', 1, true) ~= nil, "success: posts to OpenAI endpoint")
end

-- =====================================================================
-- (3) REFUSAL / TRUNCATED / CONTENT_FILTER / MALFORMED -> VALID degrade.
-- =====================================================================
do
    local cases = {
        { name = 'refusal',
          body = httpBody(nil, 'stop', "I can't help identify individuals.") },
        { name = 'truncated',
          body = httpBody('{"bird_present":true,"detections":[{"common_name":"Nor', 'length') },
        { name = 'content_filter',
          body = httpBody('', 'content_filter') },
        { name = 'malformed-unrecoverable',
          body = httpBody('{"bird_present":true,"detections":[{"common_name":"North', 'stop') },
    }
    for _, c in ipairs(cases) do
        local post, calls = scriptedPost({ { status = 200, body = c.body, info = headers(200) } })
        local prov = openai.new((makeDeps(post)))
        local resp, err = prov.identify(IMAGE, CTX)
        assert_true(err == nil, c.name .. ": degrade is not an err")
        assert_true(type(resp) == 'table' and contract.validateResponse(resp),
            c.name .. ": degrade is a VALID response")
        assert_eq(resp.bird_present, false, c.name .. ": degrade bird_present=false")
        assert_eq(#resp.detections, 0, c.name .. ": degrade has empty detections")
        assert_eq(calls.n, 1, c.name .. ": one httpPost call (ok outcome, no retry)")
    end
end

-- =====================================================================
-- (3b) [CODEX MUST-FIX 4] A 200 whose HTTP body is itself malformed JSON is NEVER network-
--      retried: exactly ONE httpPost call, then a VALID degrade (mapper owns repair/degrade).
--      And a 200 whose content is recoverable-fenced JSON is salvaged by the mapper (no retry).
-- =====================================================================
do
    -- (a) Whole HTTP body is broken JSON -> classify returns ok(parsed=nil) -> map -> degrade.
    local post, calls = scriptedPost({ { status = 200, body = '{bad json', info = headers(200) } })
    local prov = openai.new((makeDeps(post)))
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "200-badjson: not an err (degrade-then-continue)")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp),
        "200-badjson: returns a VALID degrade")
    assert_eq(resp.bird_present, false, "200-badjson: degrade bird_present=false")
    assert_eq(calls.n, 1, "200-badjson: EXACTLY ONE httpPost call (no network retry on 200)")

    -- (b) content is a fenced ```json block (recoverable): the mapper salvages it (no retry).
    local fenced = "```json\n" .. VALID_CONTENT .. "\n```"
    local post2, calls2 = scriptedPost({ { status = 200, body = httpBody(fenced, 'stop'), info = headers(200) } })
    local prov2 = openai.new((makeDeps(post2)))
    local resp2, err2 = prov2.identify(IMAGE, CTX)
    assert_true(err2 == nil and type(resp2) == 'table', "200-fenced: succeeds")
    assert_eq(resp2.detections[1].common_name, "Northern Cardinal", "200-fenced: mapper salvages the fenced JSON")
    assert_eq(calls2.n, 1, "200-fenced: EXACTLY ONE httpPost call (salvage, no retry)")
end

-- =====================================================================
-- (4) FATAL 401 / 400 -> (nil, err), NO retry (exactly one call), NO token in err.
-- =====================================================================
do
    local cases = {
        { name = '401', status = 401,
          body = '{"error":{"message":"Incorrect API key provided"}}', bodyNeedle = 'Incorrect' },
        { name = '400', status = 400,
          body = '{"error":{"message":"Invalid schema for response_format"}}', bodyNeedle = 'Invalid schema' },
    }
    for _, c in ipairs(cases) do
        local post, calls = scriptedPost({ { status = c.status, body = c.body, info = headers(c.status) } })
        local deps, sleeps, logs = makeDeps(post)
        local prov = openai.new(deps)
        local resp, err = prov.identify(IMAGE, CTX)
        assert_true(resp == nil, c.name .. ": fatal returns nil response")
        assert_true(type(err) == 'string' and #err > 0, c.name .. ": fatal returns a speaking err")
        assert_eq(calls.n, 1, c.name .. ": fatal made exactly ONE httpPost call (no retry)")
        assert_eq(#sleeps, 0, c.name .. ": fatal slept zero times")
        -- token-free err.
        assert_true(err:find(SENTINEL_TOKEN, 1, true) == nil, c.name .. ": err carries no token")
        assert_true(err:find('Bearer', 1, true) == nil, c.name .. ": err carries no 'Bearer'")
        -- [CODEX MUST-FIX 1] status-derived label only -- the server's free-text message is dropped.
        assert_true(err:find(c.bodyNeedle, 1, true) == nil,
            c.name .. ": err does NOT echo the server's free-text error.message")
        assert_true(err:find(tostring(c.status), 1, true) ~= nil,
            c.name .. ": err is status-derived (mentions the status code)")
        -- the leak grep over the recorded logs too.
        local text = collectLogText(logs)
        assert_true(text:find(c.bodyNeedle, 1, true) == nil,
            c.name .. ": server message absent from every log line")
    end
end

-- =====================================================================
-- (5) 429-then-200 -> retries the expected count with deterministic delays, then succeeds.
-- =====================================================================
do
    local post, calls = scriptedPost({
        { status = 429, body = '{"error":{"message":"Rate limit"}}', info = headers(429) },
        { status = 429, body = '{"error":{"message":"Rate limit"}}', info = headers(429) },
        { status = 200, body = SUCCESS_BODY, info = headers(200) },
    })
    local deps, sleeps = makeDeps(post)
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table', "429x2-then-200: succeeds")
    assert_eq(resp.detections[1].common_name, "Northern Cardinal", "429x2-then-200: maps success")
    assert_eq(calls.n, 3, "429x2-then-200: exactly 3 httpPost calls")
    assert_eq(#sleeps, 2, "429x2-then-200: slept exactly twice (between the 2 retries)")
    -- Deterministic delays: attempt 1 -> BASE*2^0, attempt 2 -> BASE*2^1 (no Retry-After header).
    assert_eq(sleeps[1], backoff.next(1, 429, nil).delay, "429: 1st sleep is the policy delay for attempt 1")
    assert_eq(sleeps[2], backoff.next(2, 429, nil).delay, "429: 2nd sleep is the policy delay for attempt 2")
end

-- =====================================================================
-- (6) network-nil-then-200 -> retries then succeeds.
-- =====================================================================
do
    local post, calls = scriptedPost({
        { status = nil, body = nil, info = { error = { errorCode = 'timedOut' } } },
        { status = 200, body = SUCCESS_BODY, info = headers(200) },
    })
    local deps, sleeps = makeDeps(post)
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table', "network-nil-then-200: succeeds")
    assert_eq(calls.n, 2, "network-nil-then-200: exactly 2 httpPost calls")
    assert_eq(#sleeps, 1, "network-nil-then-200: slept exactly once")
end

-- =====================================================================
-- (7) PERMANENT 429 -> retry-EXHAUSTED returns the VALIDATED degrade (NOT nil,err).
-- =====================================================================
do
    local post, calls = scriptedPost({
        { status = 429, body = '{"error":{"message":"Rate limit"}}', info = headers(429) },
    })
    local deps, sleeps, logs = makeDeps(post)
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "permanent-429: NOT an err (degrade-then-continue, MUST-FIX 6)")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp),
        "permanent-429: returns a VALIDATED degrade")
    assert_eq(resp.bird_present, false, "permanent-429: degrade bird_present=false")
    assert_eq(#resp.detections, 0, "permanent-429: degrade empty detections")
    -- [CODEX MUST-FIX 3] total HTTP calls == MAX_ATTEMPTS (NOT MAX_ATTEMPTS+1). The loop posts,
    -- THEN consults the policy; next() returns retry=false once attempt >= MAX_ATTEMPTS, so the
    -- MAX_ATTEMPTS-th post is the LAST call and the run then exhausts -> validated degrade.
    assert_eq(calls.n, backoff.MAX_ATTEMPTS, "permanent-429: attempted EXACTLY MAX_ATTEMPTS times then exhausted")
    -- It slept exactly MAX_ATTEMPTS-1 times (between each of the MAX_ATTEMPTS-1 retries).
    assert_eq(#sleeps, backoff.MAX_ATTEMPTS - 1, "permanent-429: slept MAX_ATTEMPTS-1 times before exhausting")
    -- No leak in the exhaustion logs.
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "permanent-429: no token in logs")
    assert_true(text:find('Bearer', 1, true) == nil, "permanent-429: no 'Bearer' in logs")
end

-- =====================================================================
-- (8) httpPost RAISES (with the Authorization header VALUE embedded) -> retryable transport
--     error; token ABSENT from returned err AND every recorded log line (CODEX MUST-FIX 5).
-- =====================================================================
do
    -- A raising httpPost: the FIRST call raises an error message that EMBEDS the Bearer token
    -- (simulating a client that interpolates headers into its error). The SECOND call succeeds,
    -- proving the raise was treated as RETRYABLE.
    local calls = { n = 0 }
    local function raisingPost(url, body, hdrs)
        calls.n = calls.n + 1
        if calls.n == 1 then
            -- A message that leaks the full Authorization header value if naively propagated.
            error('POST failed with Authorization: Bearer ' .. SENTINEL_TOKEN)
        end
        return 200, SUCCESS_BODY, headers(200)
    end
    local deps, sleeps, logs = makeDeps(raisingPost)
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table', "raising-then-200: treated as retryable, succeeds")
    assert_eq(calls.n, 2, "raising-then-200: retried (exactly 2 calls)")
    -- The token must NOT appear in the returned err (here err is nil, but assert anyway for the
    -- contract) NOR in any recorded log line.
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "raise: token absent from every log line")
    assert_true(text:find('Bearer', 1, true) == nil, "raise: 'Bearer' absent from every log line")
end

-- Same as (8) but the raise PERSISTS so the path exhausts -> degrade with NO leak in err/logs.
do
    local function alwaysRaise(url, body, hdrs)
        error('boom Authorization: Bearer ' .. SENTINEL_TOKEN .. ' body=' .. tostring(body))
    end
    local deps, sleeps, logs = makeDeps(alwaysRaise)
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "always-raise: exhausts to a degrade, not an err")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp),
        "always-raise: returns a VALIDATED degrade")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "always-raise: token absent from every log line")
    assert_true(text:find('Bearer', 1, true) == nil, "always-raise: 'Bearer' absent from every log line")
end

-- =====================================================================
-- (9) NO-LEAK (MUST-FIX 11): using sentinels, NO recorded log line/field contains
--     'Authorization', 'Bearer', the base64 data URL, or the request JSON body.
-- =====================================================================
do
    -- Drive a retry+success so several log lines (retry, success path) are recorded, then grep
    -- the whole recorded surface for every forbidden needle.
    local post = scriptedPost({
        { status = 500, body = '{"error":{"message":"server"}}', info = headers(500) },
        { status = 200, body = SUCCESS_BODY, info = headers(200) },
    })
    local deps, sleeps, logs = makeDeps(post)
    local prov = openai.new(deps)
    local resp = prov.identify(IMAGE, CTX)
    assert_true(type(resp) == 'table', "no-leak: completed")
    local text = collectLogText(logs)
    assert_true(text:find('Authorization', 1, true) == nil, "no-leak: no 'Authorization' in any log line")
    assert_true(text:find('Bearer', 1, true) == nil, "no-leak: no 'Bearer' in any log line")
    assert_true(text:find('data:image/jpeg;base64', 1, true) == nil, "no-leak: no base64 data URL in logs")
    assert_true(text:find(SENTINEL_DATAURL, 1, true) == nil, "no-leak: the SENTINEL data URL absent from logs")
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "no-leak: token absent from logs")
    -- The request JSON body (which embeds the prompt + the data URL) must NOT be logged. We
    -- assert via a body-only needle: the schema name 'bird_identification' is unique to the body.
    assert_true(text:find('bird_identification', 1, true) == nil, "no-leak: request JSON body not logged")
end

-- =====================================================================
-- (9b) [CODEX MUST-FIX 2] Data URL discipline:
--      * the request body carries a NON-EMPTY "data:image/jpeg;base64,..." image_url.url;
--      * a MISSING/empty dataUrl is REJECTED (nil, err) -- never sent as image_url:[] -- and
--        NO httpPost call is made; the err is token/body-free.
-- =====================================================================
do
    -- (a) When a dataUrl is provided, the posted body's image_url.url is that non-empty data URL.
    local post, calls = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local prov = openai.new((makeDeps(post)))
    local resp = prov.identify(IMAGE, CTX)
    assert_true(type(resp) == 'table', "dataUrl present: succeeds")
    -- decode the posted body and inspect the image_url.url it carried.
    local okB, posted = json.decode(calls.lastBody)
    assert_true(okB and type(posted) == 'table', "posted body decodes")
    local imgPart = posted.messages[1].content[2]
    assert_eq(imgPart.type, 'image_url', "posted body has an image_url part")
    assert_true(type(imgPart.image_url.url) == 'string'
        and imgPart.image_url.url:find('data:image/jpeg;base64,', 1, true) == 1
        and #imgPart.image_url.url > #('data:image/jpeg;base64,'),
        "posted image_url.url is a non-empty data:image/jpeg;base64,... string")

    -- (b) A missing dataUrl is REJECTED: (nil, err), NO httpPost call, token/body-free err.
    local post2, calls2 = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps2, sleeps2, logs2 = makeDeps(post2)
    local prov2 = openai.new(deps2)
    local noUrlImage = { kind = 'bytes', width = 800, height = 600 } -- NO dataUrl
    local r2, e2 = prov2.identify(noUrlImage, CTX)
    assert_true(r2 == nil, "missing dataUrl: returns nil response")
    assert_true(type(e2) == 'string' and #e2 > 0, "missing dataUrl: speaking err")
    assert_eq(calls2.n, 0, "missing dataUrl: NO httpPost call (fail fast, not sent)")
    assert_true(e2:find(SENTINEL_TOKEN, 1, true) == nil, "missing dataUrl: err carries no token")
    assert_true(e2:find('Bearer', 1, true) == nil, "missing dataUrl: err carries no 'Bearer'")
    local text2 = collectLogText(logs2)
    assert_true(text2:find(SENTINEL_TOKEN, 1, true) == nil, "missing dataUrl: no token in logs")

    -- (c) An EMPTY-payload data URL (prefix only) is likewise rejected.
    local post3, calls3 = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local prov3 = openai.new((makeDeps(post3)))
    local emptyImage = { kind = 'bytes', dataUrl = 'data:image/jpeg;base64,', width = 1, height = 1 }
    local r3, e3 = prov3.identify(emptyImage, CTX)
    assert_true(r3 == nil and type(e3) == 'string', "empty data URL: rejected (nil, err)")
    assert_eq(calls3.n, 0, "empty data URL: NO httpPost call")
end

-- =====================================================================
-- (10) Breaker integration: an OPEN breaker short-circuits identify to a degrade with no call.
-- =====================================================================
do
    local breaker = require('src.net.breaker')
    local b = breaker.new({ threshold = 1 })
    b.record('exhausted')  -- trips it open immediately.
    assert_eq(b.shouldStop(), true, "breaker is open")
    local post, calls = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps = makeDeps(post)
    deps.breaker = b
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table' and contract.validateResponse(resp),
        "breaker-open: returns a VALIDATED degrade")
    assert_eq(resp.bird_present, false, "breaker-open: degrade")
    assert_eq(calls.n, 0, "breaker-open: NO httpPost call made")
end

-- =====================================================================
-- (11) [CODEX phase-7 #1] authHeaders RAISES (with the token embedded) -> (nil, token-free err),
--      NO httpPost call, token ABSENT from the err AND every recorded log line.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps, sleeps, logs = makeDeps(post, {
        authHeaders = function(t) error('x-api-key ' .. tostring(t)) end,
    })
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(resp == nil, "authHeaders-raise: returns nil response")
    assert_true(type(err) == 'string' and #err > 0, "authHeaders-raise: speaking err")
    assert_eq(calls.n, 0, "authHeaders-raise: NO httpPost call (failed before posting)")
    assert_true(err:find(SENTINEL_TOKEN, 1, true) == nil, "authHeaders-raise: err carries no token")
    assert_true(err:find('Bearer', 1, true) == nil, "authHeaders-raise: err carries no 'Bearer'")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "authHeaders-raise: token absent from logs")
end

-- =====================================================================
-- (12) [CODEX phase-7 #2] authHeaders returns nil (or a non-table) -> FAIL before posting:
--      (nil, clear token-free err), NO httpPost call (never httpPost with headers=nil).
-- =====================================================================
do
    -- (a) returns nil.
    local post, calls = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps = makeDeps(post, { authHeaders = function() return nil end })
    local prov = openai.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(resp == nil and type(err) == 'string', "authHeaders-nil: rejected (nil, err)")
    assert_eq(calls.n, 0, "authHeaders-nil: NO httpPost call (never posts headers=nil)")

    -- (b) returns a non-table.
    local post2, calls2 = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps2 = makeDeps(post2, { authHeaders = function() return 'not-a-table' end })
    local prov2 = openai.new(deps2)
    local r2, e2 = prov2.identify(IMAGE, CTX)
    assert_true(r2 == nil and type(e2) == 'string', "authHeaders-non-table: rejected (nil, err)")
    assert_eq(calls2.n, 0, "authHeaders-non-table: NO httpPost call")

    -- (c) returns an EMPTY table (no header pairs) -> still rejected.
    local post3, calls3 = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps3 = makeDeps(post3, { authHeaders = function() return {} end })
    local prov3 = openai.new(deps3)
    local r3, e3 = prov3.identify(IMAGE, CTX)
    assert_true(r3 == nil and type(e3) == 'string', "authHeaders-empty: rejected (nil, err)")
    assert_eq(calls3.n, 0, "authHeaders-empty: NO httpPost call")

    -- (d) MISSING authHeaders binding entirely -> clear token-free err, NO post.
    local post4, calls4 = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    local deps4 = makeDeps(post4, { omitAuthHeaders = true })
    local prov4 = openai.new(deps4)
    local r4, e4 = prov4.identify(IMAGE, CTX)
    assert_true(r4 == nil and type(e4) == 'string' and #e4 > 0, "authHeaders-missing: rejected (nil, err)")
    assert_eq(calls4.n, 0, "authHeaders-missing: NO httpPost call")
end

-- =====================================================================
-- (13) [CODEX phase-7 #3] OpenAI uses the SHARED deps.authHeaders (NOT inline 'Bearer ..token'):
--      a deps with token=nil + a real authHeaders posts the REAL Authorization header value the
--      binding produced — never 'Bearer nil'. The posted header is what authHeaders returned.
-- =====================================================================
do
    local REAL_HEADER_TOKEN = 'sk-REAL-HEADER-FROM-BINDING-42'
    local post, calls = scriptedPost({ { status = 200, body = SUCCESS_BODY, info = headers(200) } })
    -- token is nil on deps; the binding ignores it and returns a real header value.
    local deps = makeDeps(post, {
        authHeaders = function() return {
            { field = 'Authorization', value = 'Bearer ' .. REAL_HEADER_TOKEN },
            { field = 'Content-Type', value = 'application/json' },
        } end,
    })
    deps.token = nil
    local prov = openai.new(deps)
    local resp = prov.identify(IMAGE, CTX)
    assert_true(type(resp) == 'table', "shared-auth: succeeds with token=nil + real authHeaders")
    assert_eq(calls.n, 1, "shared-auth: exactly one httpPost call")
    -- The posted headers carry the REAL binding-produced Authorization, NOT 'Bearer nil'.
    local function hv(hdrs, field)
        if type(hdrs) ~= 'table' then return nil end
        for i = 1, #hdrs do
            if type(hdrs[i]) == 'table' and hdrs[i].field == field then return hdrs[i].value end
        end
        return nil
    end
    assert_eq(hv(calls.lastHeaders, 'Authorization'), 'Bearer ' .. REAL_HEADER_TOKEN,
        "shared-auth: posted Authorization is the binding's value (NOT inline 'Bearer ..deps.token')")
    assert_true(hv(calls.lastHeaders, 'Authorization'):find('nil', 1, true) == nil,
        "shared-auth: posted Authorization is never 'Bearer nil'")
end
