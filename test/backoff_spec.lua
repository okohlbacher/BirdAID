-- test/backoff_spec.lua (Phase 5 — PROV-05 pure classify + deterministic backoff policy)
--
-- Exercises BirdAID.lrdevplugin/src/net/backoff.lua: a PURE module (no Lr, no LrHttp, no
-- math.random) require-able under stock lua / luajit. Proves the status->outcome table, the
-- Retry-After parsing in ALL THREE forms (integer seconds / retry-after-ms / HTTP-date), the
-- deterministic exponential-with-cap backoff, the bounded max-attempts ceiling, and the
-- CODEX MUST-FIX 2 OVER-CAP rule (a server wait greater than the cap => retry=false, NEVER an
-- early retry). Uses the offline status/header fixtures.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local backoff = require('src.net.backoff')
local FX = require('test.fixtures.openai.status_fixtures')

assert_true(type(backoff) == 'table', "require 'src.net.backoff' resolves")
assert_true(type(backoff.classify) == 'function', "backoff exposes classify")
assert_true(type(backoff.next) == 'function', "backoff exposes next")
assert_true(type(backoff.httpDateToSeconds) == 'function', "backoff exposes httpDateToSeconds")

-- Module policy constants the spec reads (so the exact-delay assertions track the policy).
assert_true(type(backoff.BASE) == 'number', "backoff.BASE is a number")
assert_true(type(backoff.CAP) == 'number', "backoff.CAP is a number")
assert_true(type(backoff.MAX_ATTEMPTS) == 'number', "backoff.MAX_ATTEMPTS is a number")
local BASE, CAP, MAX = backoff.BASE, backoff.CAP, backoff.MAX_ATTEMPTS

-- =====================================================================
-- classify: the status -> outcome table.
-- =====================================================================
do
    -- 200 with decodable body -> ok, parsed table returned.
    local v = backoff.classify(FX.ok.status, FX.ok.body, nil)
    assert_eq(v.outcome, 'ok', "200 decodable -> ok")
    assert_true(type(v.parsed) == 'table', "200 ok carries parsed table")

    -- [CODEX MUST-FIX 4] 200 with UNdecodable body -> outcome 'ok' (NEVER a network retry); the
    -- response mapper owns repair-once/degrade. parsed is nil so the mapper sees no table.
    local vb = backoff.classify(FX.okBadJson.status, FX.okBadJson.body, nil)
    assert_eq(vb.outcome, 'ok', "200 undecodable -> ok (mapper owns repair/degrade, no retry)")
    assert_eq(vb.parsed, nil, "200 bad-json -> parsed nil (handed to mapper, not retried)")

    -- 401 -> fatal; err names "API key"; carries NO token text.
    local v401 = backoff.classify(FX.unauthorized.status, FX.unauthorized.body, FX.unauthorized.headers)
    assert_eq(v401.outcome, 'fatal', "401 -> fatal")
    assert_true(string.find(v401.err, 'API key', 1, true) ~= nil, "401 err mentions API key")
    assert_true(string.find(v401.err, 'Bearer') == nil, "401 err carries no Bearer token")

    -- 400 -> fatal (non-retryable), speaking message.
    local v400 = backoff.classify(FX.badRequest.status, FX.badRequest.body, FX.badRequest.headers)
    assert_eq(v400.outcome, 'fatal', "400 -> fatal")
    assert_true(type(v400.err) == 'string' and #v400.err > 0, "400 carries a speaking err")

    -- 500 -> retry.
    local v500 = backoff.classify(FX.serverError.status, FX.serverError.body, FX.serverError.headers)
    assert_eq(v500.outcome, 'retry', "500 -> retry")

    -- 408 -> retry.
    local v408 = backoff.classify(408, '', { status = 408 })
    assert_eq(v408.outcome, 'retry', "408 -> retry")

    -- network nil -> retry.
    local vnil = backoff.classify(FX.networkNil.status, FX.networkNil.body, FX.networkNil.info)
    assert_eq(vnil.outcome, 'retry', "network-nil -> retry")

    -- an unexpected 4xx (e.g. 404) -> fatal.
    local v404 = backoff.classify(404, '', { status = 404 })
    assert_eq(v404.outcome, 'fatal', "404 (other 4xx) -> fatal")
end

-- =====================================================================
-- [CODEX MUST-FIX 1] classify NEVER propagates the server's free-text error.message into err.
-- A body that EMBEDS the data URL + Authorization Bearer token must yield a STATUS-DERIVED
-- label only -- none of the secret needles may appear.
-- =====================================================================
do
    local leakyBody =
        '{"error":{"message":"failed processing data:image/jpeg;base64,SECRETBYTES with ' ..
        'Authorization: Bearer sk-LEAK-TOKEN-1234"}}'

    -- 400: fatal, status-derived label, NONE of the secret needles.
    local v = backoff.classify(400, leakyBody, { status = 400 })
    assert_eq(v.outcome, 'fatal', "leaky 400 -> fatal")
    assert_true(type(v.err) == 'string', "leaky 400 err is a string")
    assert_true(v.err:find('400', 1, true) ~= nil, "leaky 400 err is status-derived (mentions 400)")
    assert_true(v.err:find('SECRET', 1, true) == nil, "leaky 400 err carries no body 'SECRET'")
    assert_true(v.err:find('base64', 1, true) == nil, "leaky 400 err carries no 'base64'")
    assert_true(v.err:find('Bearer', 1, true) == nil, "leaky 400 err carries no 'Bearer'")
    assert_true(v.err:find('sk-LEAK', 1, true) == nil, "leaky 400 err carries no token text")
    assert_true(v.err:find('data:image/jpeg;base64', 1, true) == nil, "leaky 400 err carries no data URL")

    -- 500 (retryable) with the same leaky body: status-derived retry label, no secret.
    local v5 = backoff.classify(500, leakyBody, { status = 500 })
    assert_eq(v5.outcome, 'retry', "leaky 500 -> retry")
    assert_true(v5.err:find('SECRET', 1, true) == nil, "leaky 500 retry err carries no body 'SECRET'")
    assert_true(v5.err:find('Bearer', 1, true) == nil, "leaky 500 retry err carries no 'Bearer'")
    assert_true(v5.err:find('base64', 1, true) == nil, "leaky 500 retry err carries no 'base64'")

    -- transport-error (nil status) is a fixed, body-free label.
    local vt = backoff.classify(nil, leakyBody, { error = { name = 'x' } })
    assert_eq(vt.outcome, 'retry', "nil status -> retry")
    assert_eq(vt.err, 'transport-error', "nil status err is the fixed body-free 'transport-error'")
end

-- =====================================================================
-- classify: Retry-After parsing -- all three forms.
-- =====================================================================
do
    -- (a) retry-after-ms (429 only): 2500 ms -> 2.5 s.
    local vms = backoff.classify(FX.rateLimit_ms.status, FX.rateLimit_ms.body, FX.rateLimit_ms.headers)
    assert_eq(vms.outcome, 'retry', "429 retry-after-ms -> retry")
    assert_eq(vms.retryAfter, FX.rateLimit_ms.expectRetryAfter, "retry-after-ms parsed to 2.5 s")

    -- (b) Retry-After integer seconds: "12" -> 12.
    local vsec = backoff.classify(FX.rateLimit_seconds.status, FX.rateLimit_seconds.body, FX.rateLimit_seconds.headers)
    assert_eq(vsec.outcome, 'retry', "429 Retry-After seconds -> retry")
    assert_eq(vsec.retryAfter, FX.rateLimit_seconds.expectRetryAfter, "Retry-After seconds parsed to 12")

    -- (c) Retry-After as HTTP-date: classify uses os.time(now); we cannot fix `now` inside
    -- classify, so we assert the pure helper directly with a fixed nowEpoch, and separately
    -- assert classify returns a NON-NEGATIVE numeric retryAfter for the date form.
    local target = backoff.httpDateToSeconds(FX.rateLimit_httpDate.dateString, 0) -- absolute epoch
    assert_true(type(target) == 'number' and target > 0, "httpDateToSeconds yields a positive epoch")

    -- a fixed nowEpoch exactly 30 s BEFORE the target -> delta == 30.
    local delta = backoff.httpDateToSeconds(FX.rateLimit_httpDate.dateString, target - 30)
    assert_eq(delta, 30, "httpDateToSeconds(date, target-30) == 30 (deterministic delta)")

    -- a fixed nowEpoch AFTER the target -> clamped to 0 (never negative).
    local past = backoff.httpDateToSeconds(FX.rateLimit_httpDate.dateString, target + 100)
    assert_eq(past, 0, "httpDateToSeconds clamps a past target to 0")

    -- classify with the HTTP-date header returns a numeric, non-negative retryAfter.
    local vdate = backoff.classify(FX.rateLimit_httpDate.status, FX.rateLimit_httpDate.body, FX.rateLimit_httpDate.headers)
    assert_eq(vdate.outcome, 'retry', "429 Retry-After HTTP-date -> retry")
    assert_true(type(vdate.retryAfter) == 'number' and vdate.retryAfter >= 0,
        "429 HTTP-date retryAfter is a non-negative number")

    -- header lookup is CASE-INSENSITIVE: an upper-case RETRY-AFTER still parses.
    local upHeaders = { status = 429, { field = 'RETRY-AFTER', value = '7' } }
    local vup = backoff.classify(429, '', upHeaders)
    assert_eq(vup.retryAfter, 7, "Retry-After header matched case-insensitively")

    -- retry-after-ms is PREFERRED over Retry-After when both present (calibrated wait).
    local both = { status = 429,
        { field = 'Retry-After', value = '60' },
        { field = 'retry-after-ms', value = '1500' } }
    local vboth = backoff.classify(429, '', both)
    assert_eq(vboth.retryAfter, 1.5, "retry-after-ms preferred over Retry-After when both present")

    -- neither header present -> retryAfter is nil.
    local vnone = backoff.classify(429, '', { status = 429 })
    assert_eq(vnone.retryAfter, nil, "no Retry-After header -> retryAfter nil")
end

-- =====================================================================
-- [CODEX MUST-FIX 5] Retry-After hardening: strict HTTP-date validation + non-negative clamp.
-- =====================================================================
do
    -- A non-GMT zone (PST) is REJECTED -> nil.
    assert_eq(backoff.httpDateToSeconds("Wed, 21 Oct 2026 07:28:00 PST", 0), nil,
        "non-GMT zone (PST) -> nil")
    -- Missing the leading day-name / GMT zone -> nil.
    assert_eq(backoff.httpDateToSeconds("21 Oct 2026 07:28:00", 0), nil,
        "no day-name/GMT -> nil")
    -- Out-of-range / normalized-impossible day -> nil (NOT silently rolled over by os.time).
    assert_eq(backoff.httpDateToSeconds("Wed, 99 Jan 2026 07:28:00 GMT", 0), nil,
        "impossible day (99 Jan) -> nil")
    -- Out-of-range hour -> nil.
    assert_eq(backoff.httpDateToSeconds("Wed, 21 Oct 2026 25:00:00 GMT", 0), nil,
        "impossible hour (25) -> nil")
    -- A bad month abbreviation -> nil.
    assert_eq(backoff.httpDateToSeconds("Wed, 21 Xyz 2026 07:28:00 GMT", 0), nil,
        "bad month abbreviation -> nil")
    -- A WELL-FORMED GMT date still parses (positive epoch with nowEpoch=0).
    local good = backoff.httpDateToSeconds("Wed, 21 Oct 2026 07:28:00 GMT", 0)
    assert_true(type(good) == 'number' and good > 0, "well-formed GMT date still parses")
    -- UTC zone is also accepted.
    local utc = backoff.httpDateToSeconds("Wed, 21 Oct 2026 07:28:00 UTC", 0)
    assert_true(type(utc) == 'number' and utc > 0, "UTC zone accepted")

    -- Numeric Retry-After "-5" is IGNORED (return nil from parse) so next() falls back to the
    -- computed exponential backoff -> the resulting delay is >= 0 (never negative).
    local neg = backoff.classify(429, '', { status = 429, { field = 'Retry-After', value = '-5' } })
    assert_eq(neg.retryAfter, nil, "negative Retry-After ignored (parsed to nil)")
    local d = backoff.next(1, 429, neg.retryAfter)
    assert_eq(d.retry, true, "negative Retry-After -> still retries via computed backoff")
    assert_true(type(d.delay) == 'number' and d.delay >= 0, "computed delay is >= 0 (never negative)")

    -- A negative retry-after-ms is likewise ignored.
    local negms = backoff.classify(429, '', { status = 429, { field = 'retry-after-ms', value = '-1000' } })
    assert_eq(negms.retryAfter, nil, "negative retry-after-ms ignored (parsed to nil)")
end

-- =====================================================================
-- backoff.next: deterministic exponential-with-cap delays.
-- delay = min(CAP, BASE * 2^(attempt-1)).
-- =====================================================================
do
    -- attempt 1 -> BASE; attempt 2 -> BASE*2; attempt 3 -> BASE*4 (each clamped to CAP).
    local function expected(attempt)
        local d = BASE * (2 ^ (attempt - 1))
        if d > CAP then d = CAP end
        return d
    end

    local b1 = backoff.next(1, 429, nil)
    assert_eq(b1.retry, true, "attempt 1 on 429 retries")
    assert_eq(b1.delay, expected(1), "attempt 1 delay == BASE")

    local b2 = backoff.next(2, 429, nil)
    assert_eq(b2.retry, true, "attempt 2 on 429 retries")
    assert_eq(b2.delay, expected(2), "attempt 2 delay == BASE*2")

    -- a high attempt index (still within MAX) -> delay clamped to CAP.
    if MAX >= 3 then
        local b3 = backoff.next(3, 500, nil)
        assert_eq(b3.delay, expected(3), "attempt 3 delay follows the capped exponential rule")
    end

    -- determinism: identical args -> identical delay (no jitter / no math.random).
    local r1 = backoff.next(2, 429, nil)
    local r2 = backoff.next(2, 429, nil)
    assert_eq(r1.delay, r2.delay, "backoff.next is deterministic (same args -> same delay)")
end

-- =====================================================================
-- backoff.next: max-attempts cap and non-retryable statuses.
-- =====================================================================
do
    -- once attempt EXCEEDS the cap -> retry=false even on a retryable status.
    local over = backoff.next(MAX + 1, 429, nil)
    assert_eq(over.retry, false, "attempt > MAX_ATTEMPTS -> retry=false (exhausted)")

    -- [CODEX MUST-FIX 3] `attempt` is the POST just made; after the MAX_ATTEMPTS-th post there
    -- is NO further retry (so total calls == MAX_ATTEMPTS, not MAX_ATTEMPTS+1).
    local atMax = backoff.next(MAX, 429, nil)
    assert_eq(atMax.retry, false, "attempt == MAX_ATTEMPTS -> retry=false (no MAX+1-th call)")

    -- the LAST RETRYING attempt is MAX_ATTEMPTS-1 (it still retries -> the MAX-th call).
    if MAX >= 2 then
        local last = backoff.next(MAX - 1, 429, nil)
        assert_eq(last.retry, true, "attempt == MAX_ATTEMPTS-1 on 429 still retries (yields the MAX-th call)")
    end

    -- 400 / 401 / other 4xx never retry, regardless of attempt.
    assert_eq(backoff.next(1, 400, nil).retry, false, "400 never retries")
    assert_eq(backoff.next(1, 401, nil).retry, false, "401 never retries")
    assert_eq(backoff.next(1, 404, nil).retry, false, "404 (other 4xx) never retries")
end

-- =====================================================================
-- backoff.next: Retry-After interaction (within-cap used; OVER-CAP => retry=false).
-- =====================================================================
do
    -- within-cap Retry-After is PREFERRED as the delay (with retry=true, attempt in cap).
    local withinSecs = CAP - 1
    local b = backoff.next(1, 429, withinSecs)
    assert_eq(b.retry, true, "within-cap Retry-After retries")
    assert_eq(b.delay, withinSecs, "within-cap Retry-After is used as the delay")

    -- a Retry-After EXACTLY at the cap is still usable (<= cap).
    local atCap = backoff.next(1, 429, CAP)
    assert_eq(atCap.retry, true, "Retry-After == CAP still retries")
    assert_eq(atCap.delay, CAP, "Retry-After == CAP used as the delay")

    -- OVER-CAP rule (CODEX MUST-FIX 2): a server wait GREATER than the cap => retry=false,
    -- NOT a clamped early retry.
    local overCap = backoff.next(1, 429, CAP + 1)
    assert_eq(overCap.retry, false, "over-cap Retry-After -> retry=false (defer/degrade, no early retry)")
end

-- =====================================================================
-- Plan 07-01 — Multi-provider retryable statuses: 529 (Anthropic overloaded) + 503 (Gemini
-- unavailable) are BOTH retryable (CODEX MUST-FIX from Phase 7).
-- =====================================================================
do
    -- 529 (Anthropic overloaded_error) -> retry, both via classify and next.
    local v529 = backoff.classify(529, '', { status = 529 })
    assert_eq(v529.outcome, 'retry', "529 (Anthropic overloaded) -> retry")
    assert_eq(backoff.next(1, 529, nil).retry, true, "529 is retryable in next()")

    -- 503 (Gemini UNAVAILABLE) stays retryable.
    local v503 = backoff.classify(503, '', { status = 503 })
    assert_eq(v503.outcome, 'retry', "503 (Gemini unavailable) -> retry")
    assert_eq(backoff.next(1, 503, nil).retry, true, "503 is retryable in next()")
end

-- =====================================================================
-- Plan 07-01 — parseGoogleRetryDelay: read Gemini's body-borne retry wait. PURE + TOTAL.
-- The wait is error.details[i].retryDelay (a duration STRING "30s") where @type ENDS WITH
-- "google.rpc.RetryInfo". Missing/garbage/non-table -> nil. NEVER raises.
-- =====================================================================
do
    assert_true(type(backoff.parseGoogleRetryDelay) == 'function', "backoff exposes parseGoogleRetryDelay")

    local function geminiBody(retryDelay)
        return {
            error = {
                code = 429,
                status = 'RESOURCE_EXHAUSTED',
                details = {
                    { ['@type'] = 'type.googleapis.com/google.rpc.RetryInfo', retryDelay = retryDelay },
                    { ['@type'] = 'type.googleapis.com/google.rpc.QuotaFailure', violations = {} },
                },
            },
        }
    end

    assert_eq(backoff.parseGoogleRetryDelay(geminiBody('30s')), 30, "retryDelay '30s' -> 30")
    assert_eq(backoff.parseGoogleRetryDelay(geminiBody('1.5s')), 1.5, "retryDelay '1.5s' -> 1.5")
    assert_eq(backoff.parseGoogleRetryDelay(geminiBody('0s')), 0, "retryDelay '0s' -> 0")

    -- QuotaFailure-only body (no RetryInfo) -> nil.
    local quotaOnly = { error = { details = {
        { ['@type'] = 'type.googleapis.com/google.rpc.QuotaFailure', violations = {} },
    } } }
    assert_eq(backoff.parseGoogleRetryDelay(quotaOnly), nil, "QuotaFailure-only body -> nil")

    -- Missing details / garbage / non-table -> nil; never raises.
    assert_eq(backoff.parseGoogleRetryDelay({ error = {} }), nil, "no details -> nil")
    assert_eq(backoff.parseGoogleRetryDelay({}), nil, "empty body -> nil")
    assert_eq(backoff.parseGoogleRetryDelay(nil), nil, "nil body -> nil")
    assert_eq(backoff.parseGoogleRetryDelay("not a table"), nil, "non-table body -> nil")
    assert_eq(backoff.parseGoogleRetryDelay(geminiBody('garbage')), nil, "non-duration string -> nil")
    assert_eq(backoff.parseGoogleRetryDelay(geminiBody('-5s')), nil, "negative duration -> nil")

    -- never raises even on a hostile shape.
    local ok = pcall(backoff.parseGoogleRetryDelay, { error = { details = 'wrong-type' } })
    assert_true(ok, "parseGoogleRetryDelay never raises on a hostile details type")
end

-- =====================================================================
-- Plan 07-01 — BODY-over-HEADER precedence (CODEX MUST-FIX 9): when BOTH a header Retry-After
-- AND a body retryDelay are present, the BODY retryDelay WINS. This mirrors how the Gemini
-- caller resolves the wait: bodyWait = parseGoogleRetryDelay(decoded); if non-nil it wins over
-- classify's header retryAfter. Then next() applies the OVER-CAP clamp.
-- =====================================================================
do
    -- A 429 carrying a header Retry-After of 1 second.
    local v = backoff.classify(429, '', { status = 429, { field = 'Retry-After', value = '1' } })
    assert_eq(v.retryAfter, 1, "classify reads the header Retry-After (1s)")

    -- The Gemini body says 30s. The body WINS over the header's 1s.
    local geminiBody = {
        error = { details = {
            { ['@type'] = 'type.googleapis.com/google.rpc.RetryInfo', retryDelay = '30s' },
        } },
    }
    local bodyWait = backoff.parseGoogleRetryDelay(geminiBody)
    assert_eq(bodyWait, 30, "body retryDelay parsed to 30")

    -- The resolved wait the gemini caller uses: body wins over header.
    local resolved = (bodyWait ~= nil) and bodyWait or v.retryAfter
    assert_eq(resolved, 30, "body retryDelay (30) WINS over header Retry-After (1)")

    -- next() then applies the OVER-CAP clamp: 30 > CAP? With CAP=30 it is exactly at the cap.
    local n = backoff.next(1, 429, resolved)
    if resolved <= CAP then
        assert_eq(n.retry, true, "resolved within cap -> retries")
        assert_eq(n.delay, resolved, "resolved within cap used as the delay")
    else
        assert_eq(n.retry, false, "resolved over cap -> retry=false (defer/degrade)")
    end

    -- And confirm a body wait that EXCEEDS the cap is deferred (not the header's small value).
    local bigBody = { error = { details = {
        { ['@type'] = 'type.googleapis.com/google.rpc.RetryInfo', retryDelay = (CAP + 5) .. 's' },
    } } }
    local bigWait = backoff.parseGoogleRetryDelay(bigBody)
    assert_eq(bigWait, CAP + 5, "big body wait parsed")
    local nBig = backoff.next(1, 429, (bigWait ~= nil) and bigWait or v.retryAfter)
    assert_eq(nBig.retry, false, "an over-cap BODY wait -> retry=false (NOT the small header value)")
end

-- =====================================================================
-- Plan 07-01 — PROVIDER-NEUTRAL status labels (CODEX MUST-FIX 8). statusLabel must never emit
-- the literal 'openai-http' so a Claude/Gemini error is not mislabeled "openai". Labels are
-- status-only and body/token-free. We observe statusLabel via classify's err.
-- =====================================================================
do
    -- a 403 (other 4xx, fatal) -> neutral 'http-403' (NOT 'openai-http-403').
    local v403 = backoff.classify(403, '', { status = 403 })
    assert_eq(v403.outcome, 'fatal', "403 -> fatal")
    assert_true(v403.err:find('http-403', 1, true) ~= nil, "403 err is the neutral 'http-403'")
    assert_true(v403.err:find('openai-http', 1, true) == nil, "403 err carries NO 'openai-http'")

    -- a 503 (retryable server error) -> neutral 'server-error-503'.
    local v503 = backoff.classify(503, '', { status = 503 })
    assert_true(v503.err:find('server-error-503', 1, true) ~= nil, "503 err is 'server-error-503'")
    assert_true(v503.err:find('openai', 1, true) == nil, "503 err carries NO 'openai'")

    -- a 529 retryable label is neutral too.
    local v529 = backoff.classify(529, '', { status = 529 })
    assert_true(v529.err:find('server-error-529', 1, true) ~= nil, "529 err is 'server-error-529'")
    assert_true(v529.err:find('openai', 1, true) == nil, "529 err carries NO 'openai'")

    -- 401 stays the token-free 'auth-failed-401 (check API key)' (no provider name).
    local v401 = backoff.classify(401, '', { status = 401 })
    assert_true(v401.err:find('auth-failed-401', 1, true) ~= nil, "401 err is the neutral auth label")
    assert_true(v401.err:find('openai', 1, true) == nil, "401 err carries NO 'openai'")
end
