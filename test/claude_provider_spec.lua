-- test/claude_provider_spec.lua (Phase 7 Plan 02 — PROV2-01: the assembled Claude provider object)
--
-- Exercises BirdAID.lrdevplugin/src/providers/claude.lua + the init.lua 'claude' wiring: PURE
-- modules (all Lr is INJECTED) require-able under stock lua / luajit. Drives identify(image, ctx)
-- with an INJECTED fake httpPost returning captured fixtures and asserts:
--   * success -> a contract-valid response (common_name carried through claude_response.map);
--   * refusal/malformed -> a VALID degrade (no retry — the mapper owns recovery);
--   * 401/400 -> (nil, err) with NO retry (httpPost called EXACTLY once) and NO token in the err;
--   * 429-then-200 -> retries with the deterministic backoff delays, then succeeds;
--   * permanent-529 (Anthropic overloaded) -> retry-EXHAUSTED returns the VALIDATED degrade
--     (CODEX MUST-FIX 6), NOT (nil, err);
--   * a fake httpPost that RAISES with the x-api-key VALUE in its message -> a retryable transport
--     error, token ABSENT from the returned err AND every recorded log line (CODEX MUST-FIX 5);
--   * missing image.b64 -> fail-fast token-free error, NO httpPost call;
--   * [CODEX MUST-FIX 6] HEADER-CAPTURE: the fake httpPost RECORDS its headers; the spec asserts
--     they carry x-api-key (== the SENTINEL token) AND anthropic-version ('2023-06-01');
--   * [CODEX MUST-FIX 7] a deps WITHOUT authHeaders (or not-a-function) -> a CLEAR token-free err
--     and NO post (no inline/default header fallback);
--   * using SENTINELs, NO recorded log line/field/err contains 'x-api-key', the token value, or
--     the request JSON body.
--   * deps.rateLimit is surfaced unchanged (PROV-06).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local claude    = require('src.providers.claude')
local providers = require('src.providers.init')
local contract  = require('src.contract')
local backoff   = require('src.net.backoff')
local F         = require('test.fixtures.claude.status_fixtures')

assert_true(type(claude) == 'table', "require 'src.providers.claude' resolves")
assert_true(type(claude.new) == 'function', "claude exposes new")

-- A known SENTINEL token + a SENTINEL raw base64 we feed as the image so the no-leak greps have
-- distinctive needles. Neither may appear in any log line or returned err.
local SENTINEL_TOKEN = 'sk-ant-SENTINEL-TOKEN-do-not-leak-1234567890'
local SENTINEL_B64 = 'SENTINELRAWBASE64imagebytesNoDataPrefix=='
local ANTHROPIC_VERSION = '2023-06-01'

-- The authHeaders binding the live glue supplies: x-api-key (the token VALUE) + anthropic-version
-- + content-type. The token VALUE materializes ONLY inside this returned table.
local function authHeaders(token)
    return {
        { field = 'x-api-key', value = token },
        { field = 'anthropic-version', value = ANTHROPIC_VERSION },
        { field = 'content-type', value = 'application/json' },
    }
end

-- makeDeps(httpPost[, opts]) -> deps with recorder sleep + recorder log + sentinel token +
-- the Claude authHeaders binding. Returns deps PLUS the recorder tables.
local function makeDeps(httpPost, opts)
    opts = opts or {}
    local sleeps = {}
    local logs = {}
    local deps = {
        token = SENTINEL_TOKEN,
        model = 'claude-opus-4-8',
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
    -- authHeaders is present UNLESS the caller explicitly omits it (MUST-FIX 7 negative case).
    if opts.omitAuthHeaders ~= true then
        deps.authHeaders = opts.authHeaders or authHeaders
    end
    return deps, sleeps, logs
end

-- A scripted httpPost: returns successive (status, body, info) tuples and RECORDS (url, body,
-- headers) per call (header-capture for MUST-FIX 6).
local function scriptedPost(script)
    local calls = { n = 0 }
    local function post(url, body, hdrs)
        calls.n = calls.n + 1
        calls.lastUrl = url
        calls.lastBody = body
        calls.lastHeaders = hdrs
        local entry = script[calls.n] or script[#script]
        return entry.status, entry.body, entry.info or entry.headers
    end
    return post, calls
end

-- collectLogText(logs) -> a single string concatenating every msg + field key/value so the
-- no-leak assertions can substring-search the whole recorded surface.
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

-- headerValue(hdrs, field) -> the value of the first matching {field=,value=} pair, or nil.
local function headerValue(hdrs, field)
    if type(hdrs) ~= 'table' then return nil end
    for i = 1, #hdrs do
        if type(hdrs[i]) == 'table' and hdrs[i].field == field then return hdrs[i].value end
    end
    return nil
end

local IMAGE = { kind = 'bytes', b64 = SENTINEL_B64, width = 800, height = 600 }
local CTX = { runId = 'run-claude' }

-- =====================================================================
-- (1) Wiring: providers.get('claude', deps) returns the provider object (07-01 seam resolves).
-- =====================================================================
do
    local post = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps = makeDeps(post)
    local prov, err = providers.get('claude', deps)
    assert_true(type(prov) == 'table', "get('claude', deps) returns a table")
    assert_true(err == nil, "get('claude', deps) returns no error (object lands in 07-02)")
    assert_true(type(prov.identify) == 'function', "provider exposes identify (interface parity)")
    assert_eq(prov.rateLimit, 1.5, "provider surfaces deps.rateLimit unchanged (PROV-06)")
end

-- =====================================================================
-- (2) SUCCESS -> a contract-valid response carrying the common_name; posts to the Claude endpoint.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local prov = claude.new((makeDeps(post)))
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "success: no err")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp),
        "success: response passes validateResponse")
    assert_eq(resp.bird_present, true, "success: bird_present true")
    assert_eq(resp.detections[1].common_name, F.EXPECTED_COMMON_NAME, "success: common_name carried")
    assert_eq(calls.n, 1, "success: httpPost called exactly once")
    assert_true(calls.lastUrl:find('api.anthropic.com/v1/messages', 1, true) ~= nil,
        "success: posts to the Claude Messages endpoint")
end

-- =====================================================================
-- (2b) HEADER-CAPTURE [CODEX MUST-FIX 6]: the recorded request headers carry x-api-key (==
--      SENTINEL token) AND anthropic-version ('2023-06-01'). Presence/shape only; we assert
--      equality against the KNOWN sentinel, never printing the value.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local prov = claude.new((makeDeps(post)))
    prov.identify(IMAGE, CTX)
    assert_eq(headerValue(calls.lastHeaders, 'x-api-key'), SENTINEL_TOKEN,
        "header-capture: x-api-key header == the sentinel token (from deps.authHeaders)")
    assert_eq(headerValue(calls.lastHeaders, 'anthropic-version'), ANTHROPIC_VERSION,
        "header-capture: anthropic-version header == '2023-06-01'")
end

-- =====================================================================
-- (2c) NO-INLINE-AUTH [CODEX MUST-FIX 7]: a deps WITHOUT authHeaders fails CLEARLY (token-free
--      err) and does NOT post a default/empty header set (the fake is never called).
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps, sleeps, logs = makeDeps(post, { omitAuthHeaders = true })
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(resp == nil, "missing authHeaders: returns nil response")
    assert_true(type(err) == 'string' and #err > 0, "missing authHeaders: speaking err")
    assert_eq(calls.n, 0, "missing authHeaders: NO httpPost call (no default-header fallback)")
    assert_true(err:find(SENTINEL_TOKEN, 1, true) == nil, "missing authHeaders: err carries no token")

    -- authHeaders present but NOT a function -> same clear failure, no post.
    local post2, calls2 = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps2 = makeDeps(post2, { authHeaders = 'not-a-function' })
    local prov2 = claude.new(deps2)
    local r2, e2 = prov2.identify(IMAGE, CTX)
    assert_true(r2 == nil and type(e2) == 'string', "authHeaders not-a-function: rejected (nil, err)")
    assert_eq(calls2.n, 0, "authHeaders not-a-function: NO httpPost call")
end

-- =====================================================================
-- (2d) [CODEX phase-7 #1] authHeaders RAISES (with the token embedded) -> (nil, token-free err),
--      NO httpPost call, token ABSENT from the err AND every recorded log line.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps, sleeps, logs = makeDeps(post, {
        authHeaders = function(t) error('x-api-key ' .. tostring(t)) end,
    })
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(resp == nil, "authHeaders-raise: returns nil response")
    assert_true(type(err) == 'string' and #err > 0, "authHeaders-raise: speaking err")
    assert_eq(calls.n, 0, "authHeaders-raise: NO httpPost call (failed before posting)")
    assert_true(err:find(SENTINEL_TOKEN, 1, true) == nil, "authHeaders-raise: err carries no token")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "authHeaders-raise: token absent from logs")
    assert_true(text:find('x-api-key', 1, true) == nil, "authHeaders-raise: 'x-api-key' absent from logs")
end

-- =====================================================================
-- (2e) [CODEX phase-7 #2] authHeaders returns nil / non-table / empty -> FAIL before posting:
--      (nil, clear token-free err), NO httpPost call (never httpPost with headers=nil).
-- =====================================================================
do
    local bad = {
        { name = 'nil',       fn = function() return nil end },
        { name = 'non-table', fn = function() return 'nope' end },
        { name = 'empty',     fn = function() return {} end },
    }
    for _, c in ipairs(bad) do
        local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
        local deps = makeDeps(post, { authHeaders = c.fn })
        local prov = claude.new(deps)
        local resp, err = prov.identify(IMAGE, CTX)
        assert_true(resp == nil and type(err) == 'string',
            "authHeaders-" .. c.name .. ": rejected (nil, err)")
        assert_eq(calls.n, 0, "authHeaders-" .. c.name .. ": NO httpPost call (never headers=nil)")
    end
end

-- =====================================================================
-- (3) REFUSAL / MALFORMED -> a VALID degrade (the mapper owns recovery; exactly ONE call).
-- =====================================================================
do
    local cases = {
        { name = 'refusal', body = F.REFUSAL_BODY },
        { name = 'malformed', body = F.MALFORMED_BODY },
    }
    for _, c in ipairs(cases) do
        local post, calls = scriptedPost({ { status = 200, body = c.body, headers = F.success.headers } })
        local prov = claude.new((makeDeps(post)))
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
-- (4) FATAL 401 / 400 -> (nil, err), NO retry (exactly one call), NO token / no server text in err.
-- =====================================================================
do
    local cases = {
        { name = '401', fx = F.unauthorized },
        { name = '400', fx = F.badRequest },
    }
    for _, c in ipairs(cases) do
        local post, calls = scriptedPost({ { status = c.fx.status, body = c.fx.body, headers = c.fx.headers } })
        local deps, sleeps, logs = makeDeps(post)
        local prov = claude.new(deps)
        local resp, err = prov.identify(IMAGE, CTX)
        assert_true(resp == nil, c.name .. ": fatal returns nil response")
        assert_true(type(err) == 'string' and #err > 0, c.name .. ": fatal returns a speaking err")
        assert_eq(calls.n, 1, c.name .. ": fatal made exactly ONE httpPost call (no retry)")
        assert_eq(#sleeps, 0, c.name .. ": fatal slept zero times")
        assert_true(err:find(SENTINEL_TOKEN, 1, true) == nil, c.name .. ": err carries no token")
        assert_true(err:find(tostring(c.fx.status), 1, true) ~= nil,
            c.name .. ": err is status-derived (mentions the status code)")
        -- the 401 body carries a needle that must never leak.
        if c.fx.bodyNeedle then
            assert_true(err:find(c.fx.bodyNeedle, 1, true) == nil,
                c.name .. ": err does NOT echo the server's error.message")
            local text = collectLogText(logs)
            assert_true(text:find(c.fx.bodyNeedle, 1, true) == nil,
                c.name .. ": server message absent from every log line")
        end
    end
end

-- =====================================================================
-- (5) 429-then-200 -> retries with deterministic delays, then succeeds.
-- =====================================================================
do
    local post, calls = scriptedPost({
        { status = 429, body = F.rateLimit.body, headers = F.rateLimit.headers },
        { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers },
    })
    local deps, sleeps = makeDeps(post)
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table', "429-then-200: succeeds")
    assert_eq(resp.detections[1].common_name, F.EXPECTED_COMMON_NAME, "429-then-200: maps success")
    assert_eq(calls.n, 2, "429-then-200: exactly 2 httpPost calls")
    assert_eq(#sleeps, 1, "429-then-200: slept exactly once")
    assert_eq(sleeps[1], backoff.next(1, 429, nil).delay, "429: sleep is the policy delay for attempt 1")
end

-- =====================================================================
-- (6) PERMANENT 529 (Anthropic overloaded) -> retry-EXHAUSTED returns the VALIDATED degrade
--     (NOT nil,err) — proving 529 is retryable and exhaustion degrades.
-- =====================================================================
do
    local post, calls = scriptedPost({
        { status = 529, body = F.overloaded.body, headers = F.overloaded.headers },
    })
    local deps, sleeps, logs = makeDeps(post)
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "permanent-529: NOT an err (degrade-then-continue, MUST-FIX 6)")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp),
        "permanent-529: returns a VALIDATED degrade")
    assert_eq(resp.bird_present, false, "permanent-529: degrade bird_present=false")
    assert_eq(#resp.detections, 0, "permanent-529: degrade empty detections")
    assert_eq(calls.n, backoff.MAX_ATTEMPTS, "permanent-529: attempted EXACTLY MAX_ATTEMPTS times")
    assert_eq(#sleeps, backoff.MAX_ATTEMPTS - 1, "permanent-529: slept MAX_ATTEMPTS-1 times")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "permanent-529: no token in logs")
end

-- =====================================================================
-- (7) httpPost RAISES (with the x-api-key VALUE embedded) -> retryable transport error; token
--     ABSENT from returned err AND every recorded log line (CODEX MUST-FIX 5).
-- =====================================================================
do
    local calls = { n = 0 }
    local function raisingPost(url, body, hdrs)
        calls.n = calls.n + 1
        if calls.n == 1 then
            -- A message that leaks the full x-api-key header value if naively propagated.
            error('POST failed with x-api-key: ' .. SENTINEL_TOKEN)
        end
        return 200, F.SUCCESS_BODY, F.success.headers
    end
    local deps, sleeps, logs = makeDeps(raisingPost)
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table', "raising-then-200: treated as retryable, succeeds")
    assert_eq(calls.n, 2, "raising-then-200: retried (exactly 2 calls)")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "raise: token absent from every log line")
    assert_true(text:find('x-api-key', 1, true) == nil, "raise: 'x-api-key' absent from every log line")
end

-- Persisting raise -> exhausts to a degrade with NO leak in err/logs.
do
    local function alwaysRaise(url, body, hdrs)
        error('boom x-api-key: ' .. SENTINEL_TOKEN .. ' body=' .. tostring(body))
    end
    local deps, sleeps, logs = makeDeps(alwaysRaise)
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil, "always-raise: exhausts to a degrade, not an err")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp),
        "always-raise: returns a VALIDATED degrade")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "always-raise: token absent from logs")
    assert_true(text:find('x-api-key', 1, true) == nil, "always-raise: 'x-api-key' absent from logs")
end

-- =====================================================================
-- (8) MISSING image.b64 -> fail-fast (nil, err), NO httpPost call, token-free err.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps, sleeps, logs = makeDeps(post)
    local prov = claude.new(deps)
    local noB64Image = { kind = 'bytes', width = 800, height = 600 } -- NO b64
    local r, e = prov.identify(noB64Image, CTX)
    assert_true(r == nil, "missing b64: returns nil response")
    assert_true(type(e) == 'string' and #e > 0, "missing b64: speaking err")
    assert_eq(calls.n, 0, "missing b64: NO httpPost call (fail fast, not sent)")
    assert_true(e:find(SENTINEL_TOKEN, 1, true) == nil, "missing b64: err carries no token")
    local text = collectLogText(logs)
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "missing b64: no token in logs")
end

-- =====================================================================
-- (8b) [CODEX review] DEEP Files-API handle: image carries fileId (NO b64) -> the guard must NOT
--      fail-fast; identify reaches the request builder and the posted body carries the file source
--      (type='file' + file_id). Proves the deep pass no longer dies with missing-image-b64.
-- =====================================================================
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps = makeDeps(post)
    local prov = claude.new(deps)
    local fileImage = { kind = 'fileId', fileId = 'file_abc', width = 800, height = 600 } -- NO b64
    local resp, err = prov.identify(fileImage, CTX)
    assert_true(err == nil, "fileId: no err (guard accepts the Files-API handle)")
    assert_true(type(resp) == 'table' and contract.validateResponse(resp), "fileId: valid response")
    assert_eq(calls.n, 1, "fileId: reached the request builder + posted (one call)")
    assert_true(type(calls.lastBody) == 'string', "fileId: a body was posted")
    local body = type(calls.lastBody) == 'string' and calls.lastBody or ''
    assert_true(body:find('"type":"file"', 1, true) ~= nil
        or body:find('"type": "file"', 1, true) ~= nil,
        "fileId: posted body carries source.type='file'")
    assert_true(body:find('file_abc', 1, true) ~= nil,
        "fileId: posted body carries the file_id handle")
end

-- (8c) [CODEX review] BOTH missing (no b64, no fileId) -> still fail-fast (nil, err), NO post.
do
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local prov = claude.new((makeDeps(post)))
    local r, e = prov.identify({ kind = 'bytes', width = 800, height = 600 }, CTX)
    assert_true(r == nil and type(e) == 'string' and #e > 0, "no source: fail-fast (nil, err)")
    assert_eq(calls.n, 0, "no source: NO httpPost call")
end

-- =====================================================================
-- (9) NO-LEAK: drive a retry+success and grep the whole recorded surface for forbidden needles —
--     no 'x-api-key', no token, no raw base64, no request-body needle in any log line.
-- =====================================================================
do
    local post = scriptedPost({
        { status = 500, body = '{"type":"error","error":{"type":"api_error"}}', headers = F.helpers.headers(500) },
        { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers },
    })
    local deps, sleeps, logs = makeDeps(post)
    local prov = claude.new(deps)
    local resp = prov.identify(IMAGE, CTX)
    assert_true(type(resp) == 'table', "no-leak: completed")
    local text = collectLogText(logs)
    assert_true(text:find('x-api-key', 1, true) == nil, "no-leak: no 'x-api-key' in any log line")
    assert_true(text:find(SENTINEL_TOKEN, 1, true) == nil, "no-leak: token absent from logs")
    assert_true(text:find(SENTINEL_B64, 1, true) == nil, "no-leak: the raw base64 absent from logs")
    -- The request JSON body embeds the unique tool name; it must NOT be logged.
    assert_true(text:find('report_bird_identification', 1, true) == nil,
        "no-leak: request JSON body not logged")
end

-- =====================================================================
-- (10) Breaker integration: an OPEN breaker short-circuits identify to a degrade with no call.
-- =====================================================================
do
    local breaker = require('src.net.breaker')
    local b = breaker.new({ threshold = 1 })
    b.record('exhausted')
    assert_eq(b.shouldStop(), true, "breaker is open")
    local post, calls = scriptedPost({ { status = 200, body = F.SUCCESS_BODY, headers = F.success.headers } })
    local deps = makeDeps(post)
    deps.breaker = b
    local prov = claude.new(deps)
    local resp, err = prov.identify(IMAGE, CTX)
    assert_true(err == nil and type(resp) == 'table' and contract.validateResponse(resp),
        "breaker-open: returns a VALIDATED degrade")
    assert_eq(resp.bird_present, false, "breaker-open: degrade")
    assert_eq(calls.n, 0, "breaker-open: NO httpPost call made")
end
