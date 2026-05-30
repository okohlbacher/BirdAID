-- test/backoff_quota_spec.lua (quick 260529-s5h — enum-aware classify regression suite)
--
-- Exercises BirdAID.lrdevplugin/src/net/backoff.lua's classify() ENUM-AWARENESS on retryable
-- bodies: a PURE module (no Lr, no LrHttp, no math.random) require-able under stock lua / luajit.
-- Proves (1) OpenAI quota/billing/account-disabled 429 enums RECLASSIFY retry -> fatal with an
-- actionable token-free err; (2) a genuine-transient retryable enum (rate_limit_exceeded) ENRICHES
-- the retry label but stays outcome='retry'; (3) a nil/empty/garbage body falls back to the PLAIN
-- 'rate-limited-429' label and NEVER raises (the guarded json.decode tuple idiom); (4) the no-leak
-- invariant: the returned err reads ONLY the safe enum (error.type/code/status), NEVER error.message
-- or any echoed token/Bearer/data URL; (5) unchanged 200/401/400 paths (regression guard).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

local backoff = require('src.net.backoff')

assert_true(type(backoff) == 'table', "require 'src.net.backoff' resolves")
assert_true(type(backoff.classify) == 'function', "backoff exposes classify")

-- =====================================================================
-- QUOTA-FATAL: an OpenAI insufficient_quota 429 body RECLASSIFIES to fatal so the provider
-- returns (nil, err) and the user sees an actionable error instead of "no bird found".
-- The err mentions billing/quota/credits and carries NONE of the secret needles.
-- =====================================================================
do
    local body =
        '{"error":{"type":"insufficient_quota","code":"insufficient_quota",' ..
        '"message":"You exceeded your current quota, please check your plan and billing details. ' ..
        'Authorization: Bearer sk-SECRET-LEAK-1234 data:image/jpeg;base64,SECRETBYTES"}}'
    local v = backoff.classify(429, body, { status = 429 })
    assert_eq(v.outcome, 'fatal', "insufficient_quota 429 -> fatal (no silent degrade)")
    assert_true(type(v.err) == 'string' and #v.err > 0, "quota-fatal err is a non-empty string")
    local lower = v.err:lower()
    assert_true(lower:find('quota', 1, true) ~= nil or lower:find('billing', 1, true) ~= nil,
        "quota-fatal err mentions quota/billing")
    -- no-leak: the actionable err carries NONE of the echoed secrets / message text.
    assert_true(v.err:find('Bearer', 1, true) == nil, "quota-fatal err carries no 'Bearer'")
    assert_true(v.err:find('sk-SECRET', 1, true) == nil, "quota-fatal err carries no token text")
    assert_true(v.err:find('data:image', 1, true) == nil, "quota-fatal err carries no data URL")
    assert_true(v.err:find('SECRETBYTES', 1, true) == nil, "quota-fatal err carries no base64 marker")
    assert_true(v.err:find('exceeded your current', 1, true) == nil, "quota-fatal err carries no message text")
end

-- One more unambiguous fatal enum: billing_hard_limit_reached -> fatal.
do
    local body = '{"error":{"type":"billing_hard_limit_reached","code":"billing_hard_limit_reached","message":"x"}}'
    local v = backoff.classify(429, body, { status = 429 })
    assert_eq(v.outcome, 'fatal', "billing_hard_limit_reached 429 -> fatal")
end

-- And access_terminated (account disabled) -> fatal.
do
    local body = '{"error":{"type":"access_terminated","code":"access_terminated","message":"x"}}'
    local v = backoff.classify(429, body, { status = 429 })
    assert_eq(v.outcome, 'fatal', "access_terminated 429 -> fatal")
end

-- =====================================================================
-- ENRICH (still retry): a rate_limit_exceeded 429 STAYS retry but the err now names the safe enum.
-- =====================================================================
do
    local body =
        '{"error":{"type":"rate_limit_error","code":"rate_limit_exceeded",' ..
        '"message":"Rate limit reached for gpt-4o. Authorization: Bearer sk-LEAK data:image/jpeg;base64,XYZ"}}'
    local v = backoff.classify(429, body, { status = 429 })
    assert_eq(v.outcome, 'retry', "rate_limit_exceeded 429 stays retry (genuine transient)")
    assert_true(v.err:find('rate-limited-429', 1, true) ~= nil, "enriched err keeps the 'rate-limited-429' prefix")
    assert_true(v.err:find('rate_limit_exceeded', 1, true) ~= nil, "enriched err names the safe enum 'rate_limit_exceeded'")
    -- no-leak on the enrich path.
    assert_true(v.err:find('Bearer', 1, true) == nil, "enriched retry err carries no 'Bearer'")
    assert_true(v.err:find('data:image', 1, true) == nil, "enriched retry err carries no data URL")
    assert_true(v.err:find('sk-LEAK', 1, true) == nil, "enriched retry err carries no token")
    -- the still-retry path preserves Retry-After parsing.
    local v2 = backoff.classify(429, body, { status = 429, { field = 'Retry-After', value = '7' } })
    assert_eq(v2.outcome, 'retry', "enriched retry still retries with Retry-After")
    assert_eq(v2.retryAfter, 7, "enriched retry still parses Retry-After")
end

-- Anthropic rate_limit_error / overloaded_error and Google RESOURCE_EXHAUSTED stay RETRY.
do
    local anth = '{"type":"error","error":{"type":"rate_limit_error","message":"x"}}'
    assert_eq(backoff.classify(429, anth, { status = 429 }).outcome, 'retry', "Anthropic rate_limit_error stays retry")

    local over = '{"type":"error","error":{"type":"overloaded_error","message":"x"}}'
    assert_eq(backoff.classify(529, over, { status = 529 }).outcome, 'retry', "Anthropic overloaded_error stays retry")

    local goog = '{"error":{"status":"RESOURCE_EXHAUSTED","code":429,"message":"x"}}'
    local vg = backoff.classify(429, goog, { status = 429 })
    assert_eq(vg.outcome, 'retry', "Google RESOURCE_EXHAUSTED stays retry")
    assert_true(vg.err:find('RESOURCE_EXHAUSTED', 1, true) ~= nil, "Google enrich names the safe status enum")
end

-- =====================================================================
-- GUARDED FALLBACK: nil / empty / garbage 429 bodies -> retry with the PLAIN 'rate-limited-429'
-- label (no parenthetical enum), and the call DOES NOT RAISE (reaching the next assertion proves it).
-- =====================================================================
do
    local vNil = backoff.classify(429, nil, { status = 429 })
    assert_eq(vNil.outcome, 'retry', "nil body -> retry")
    assert_eq(vNil.err, 'rate-limited-429', "nil body -> plain rate-limited-429 label (no enum)")

    local vEmpty = backoff.classify(429, '', { status = 429 })
    assert_eq(vEmpty.outcome, 'retry', "empty body -> retry")
    assert_eq(vEmpty.err, 'rate-limited-429', "empty body -> plain rate-limited-429 label (no enum)")

    local vGarbage = backoff.classify(429, '{not json', { status = 429 })
    assert_eq(vGarbage.outcome, 'retry', "garbage body -> retry (guarded decode does not raise)")
    assert_eq(vGarbage.err, 'rate-limited-429', "garbage body -> plain rate-limited-429 label (no enum)")

    -- a JSON body with NO error table -> plain label (no enum, no raise).
    local vNoErr = backoff.classify(429, '{"ok":true}', { status = 429 })
    assert_eq(vNoErr.outcome, 'retry', "no-error-table body -> retry")
    assert_eq(vNoErr.err, 'rate-limited-429', "no-error-table body -> plain label")

    -- a JSON body whose error is a NON-table (hostile shape) -> plain label, no raise.
    local vErrStr = backoff.classify(429, '{"error":"a string not a table"}', { status = 429 })
    assert_eq(vErrStr.outcome, 'retry', "non-table error -> retry")
    assert_eq(vErrStr.err, 'rate-limited-429', "non-table error -> plain label (guarded, no raise)")

    -- an unknown enum (clean identifier, but NOT in the ENUM_SAFE_LABEL allowlist) on a retryable
    -- body -> still retry, but the enum is DROPPED (plain label). Proves the allowlist — not a
    -- charset/length check — is the gate. [CODEX no-leak round 2]
    local vUnknown = backoff.classify(429, '{"error":{"code":"some_new_unlisted_code"}}', { status = 429 })
    assert_eq(vUnknown.outcome, 'retry', "unknown enum -> retry")
    assert_eq(vUnknown.err, 'rate-limited-429',
        "unknown-but-clean enum is DROPPED (allowlist-not-charset is the gate)")
    assert_true(vUnknown.err:find('some_new_unlisted_code', 1, true) == nil,
        "unknown enum does NOT enrich (not allowlisted)")
end

-- A retryable SERVER error (500) with a leaky body still behaves: retry, no leak.
do
    local body = '{"error":{"message":"data:image/jpeg;base64,SECRETBYTES Bearer sk-LEAK"}}'
    local v = backoff.classify(500, body, { status = 500 })
    assert_eq(v.outcome, 'retry', "leaky 500 -> retry")
    assert_true(v.err:find('Bearer', 1, true) == nil, "leaky 500 err carries no 'Bearer'")
    assert_true(v.err:find('data:image', 1, true) == nil, "leaky 500 err carries no data URL")
    assert_true(v.err:find('SECRETBYTES', 1, true) == nil, "leaky 500 err carries no base64 marker")
end

-- =====================================================================
-- NO-LEAK: a 429 body whose error.message embeds a fake token + data URL, with a SAFE enum code,
-- yields an err that contains the safe enum but NONE of the secret needles nor the message text.
-- =====================================================================
do
    local body =
        '{"error":{"type":"some_type","code":"rate_limit_exceeded",' ..
        '"message":"Authorization: Bearer sk-SECRET-LEAK-1234 data:image/jpeg;base64,SECRETBYTES failed"}}'
    local v = backoff.classify(429, body, { status = 429 })
    assert_eq(v.outcome, 'retry', "no-leak case stays retry (rate_limit_exceeded)")
    assert_true(v.err:find('rate_limit_exceeded', 1, true) ~= nil, "no-leak err names the safe enum")
    -- needle assertions (plain-text find, no patterns) mirror backoff_spec.lua's MUST-FIX-1 block.
    assert_true(string.find(v.err, 'sk-SECRET', 1, true) == nil, "no-leak err carries no token")
    assert_true(string.find(v.err, 'Bearer', 1, true) == nil, "no-leak err carries no 'Bearer'")
    assert_true(string.find(v.err, 'data:image', 1, true) == nil, "no-leak err carries no data URL")
    assert_true(string.find(v.err, 'SECRETBYTES', 1, true) == nil, "no-leak err carries no base64 marker")
    assert_true(string.find(v.err, 'failed', 1, true) == nil, "no-leak err carries no message substring")
end

-- =====================================================================
-- NO-LEAK (ENUM FIELD): the enum VALUE itself is untrusted. A hostile/malformed body can cram a
-- token / Bearer / base64 data URL directly into error.type, error.code, or error.status. Each
-- such value FAILS the safe-identifier filter (space, hyphen, colon, slash, semicolon, comma) and
-- is DROPPED, so the returned err stays the PLAIN body-free 'rate-limited-429' with NO enum echoed
-- and NONE of the secret needles. [CODEX no-leak round 1]
-- =====================================================================
do
    local hostile = 'Bearer sk-XXXX data:image/jpeg;base64,AAAA'

    -- helper: assert the err equals the plain label and carries no needle.
    local function assertNoEnumLeak(field, body)
        local v = backoff.classify(429, body, { status = 429 })
        assert_eq(v.outcome, 'retry', 'hostile ' .. field .. ' enum -> retry')
        assert_eq(v.err, 'rate-limited-429',
            'hostile ' .. field .. ' enum -> plain rate-limited-429 (no enum echoed)')
        assert_true(string.find(v.err, 'Bearer', 1, true) == nil,
            'hostile ' .. field .. ' err carries no Bearer')
        assert_true(string.find(v.err, 'sk-', 1, true) == nil,
            'hostile ' .. field .. ' err carries no sk- token')
        assert_true(string.find(v.err, 'data:image', 1, true) == nil,
            'hostile ' .. field .. ' err carries no data URL')
        -- NO space beyond the fixed label text: the plain label has none.
        assert_true(string.find(v.err, ' ', 1, true) == nil,
            'hostile ' .. field .. ' err carries no space (no free-text)')
        assert_true(string.find(v.err, hostile, 1, true) == nil,
            'hostile ' .. field .. ' err carries no hostile substring')
    end

    -- error.type carries the hostile value (code/status absent).
    assertNoEnumLeak('type',
        '{"error":{"type":"Bearer sk-XXXX data:image/jpeg;base64,AAAA"}}')
    -- error.code carries the hostile value (type/status absent).
    assertNoEnumLeak('code',
        '{"error":{"code":"Bearer sk-XXXX data:image/jpeg;base64,AAAA"}}')
    -- error.status carries the hostile value (type/code absent).
    assertNoEnumLeak('status',
        '{"error":{"status":"Bearer sk-XXXX data:image/jpeg;base64,AAAA"}}')

    -- MIXED: one hostile field + one SAFE field. The hostile field is dropped; only the safe enum
    -- enriches. Proves the filter is per-candidate, not all-or-nothing.
    do
        local body = '{"error":{"type":"Bearer sk-XXXX data:image/jpeg;base64,AAAA",' ..
            '"code":"rate_limit_exceeded"}}'
        local v = backoff.classify(429, body, { status = 429 })
        assert_eq(v.outcome, 'retry', 'mixed hostile+safe -> retry')
        assert_eq(v.err, 'rate-limited-429 (rate_limit_exceeded)',
            'mixed: hostile type dropped, safe code enriches')
        assert_true(string.find(v.err, 'Bearer', 1, true) == nil, 'mixed err carries no Bearer')
        assert_true(string.find(v.err, 'sk-', 1, true) == nil, 'mixed err carries no token')
        assert_true(string.find(v.err, 'data:image', 1, true) == nil, 'mixed err carries no data URL')
    end
end

-- =====================================================================
-- NO-LEAK (IDENTIFIER-SHAPED SECRET): the regression for CODEX no-leak ROUND 2. A bare
-- identifier-shaped secret (a GitHub PAT `ghp_...`, an AWS access key `AKIA...`, or any pure
-- [A-Za-z0-9_] token <= 64 chars) PASSES a charset/length sanitize but is NOT a member of the
-- ENUM_SAFE_LABEL allowlist, so it is DROPPED. The returned err stays the PLAIN body-free
-- 'rate-limited-429' and does NOT contain the secret substring. This proves the allowlist (set
-- membership) — not a charset check — is the authoritative gate. [CODEX no-leak round 2]
-- =====================================================================
do
    local function assertNoSecretLeak(field, secret, body)
        local v = backoff.classify(429, body, { status = 429 })
        assert_eq(v.outcome, 'retry', 'identifier-shaped secret in ' .. field .. ' -> retry')
        assert_eq(v.err, 'rate-limited-429',
            'identifier-shaped secret in ' .. field .. ' -> plain rate-limited-429 (dropped, not allowlisted)')
        assert_true(string.find(v.err, secret, 1, true) == nil,
            'err carries no ' .. field .. ' secret substring')
    end

    -- A GitHub PAT-shaped token in error.type (pure [A-Za-z0-9_], <= 64) — passes charset, DROPPED by allowlist.
    local ghp = 'ghp_FAKE0000000000000000000000000000000000'
    assertNoSecretLeak('type', ghp, '{"error":{"type":"' .. ghp .. '"}}')

    -- An AWS access-key-shaped token in error.code (pure [A-Za-z0-9], <= 64) — passes charset, DROPPED by allowlist.
    local akia = 'AKIAFAKEFAKEFAKEFAKE'
    assertNoSecretLeak('code', akia, '{"error":{"code":"' .. akia .. '"}}')
end

-- =====================================================================
-- POSITIVE (allowlist is not over-aggressive): the KNOWN provider enums still enrich.
-- =====================================================================
do
    -- OpenAI snake_case lowercase enum enriches (allowlisted).
    local v1 = backoff.classify(429, '{"error":{"code":"rate_limit_exceeded"}}', { status = 429 })
    assert_eq(v1.err, 'rate-limited-429 (rate_limit_exceeded)',
        'allowlisted snake_case enum (rate_limit_exceeded) still enriches the label')

    -- Google UPPER_SNAKE enum enriches (allowlisted).
    local v2 = backoff.classify(429, '{"error":{"status":"RESOURCE_EXHAUSTED"}}', { status = 429 })
    assert_eq(v2.err, 'rate-limited-429 (RESOURCE_EXHAUSTED)',
        'allowlisted UPPER_SNAKE enum (RESOURCE_EXHAUSTED) still enriches the label')

    -- Anthropic overloaded_error enriches (allowlisted).
    local v3 = backoff.classify(429, '{"error":{"type":"overloaded_error"}}', { status = 429 })
    assert_eq(v3.err, 'rate-limited-429 (overloaded_error)',
        'allowlisted Anthropic enum (overloaded_error) still enriches the label')

    -- Anthropic rate_limit_error enriches (allowlisted).
    local v4 = backoff.classify(429, '{"error":{"type":"rate_limit_error"}}', { status = 429 })
    assert_eq(v4.err, 'rate-limited-429 (rate_limit_error)',
        'allowlisted Anthropic enum (rate_limit_error) still enriches the label')

    -- An over-long but otherwise-valid identifier (> 64 chars) is also dropped (not allowlisted).
    local longEnum = string.rep('a', 65)
    local v5 = backoff.classify(429, '{"error":{"code":"' .. longEnum .. '"}}', { status = 429 })
    assert_eq(v5.err, 'rate-limited-429',
        'over-long non-allowlisted identifier is dropped -> plain label')
end

-- =====================================================================
-- UNCHANGED PATHS (regression guard): 200/401/400 classify exactly as before.
-- =====================================================================
do
    -- 200 with a decodable body -> ok, parsed table.
    local vOk = backoff.classify(200, '{"bird_present":false}', nil)
    assert_eq(vOk.outcome, 'ok', "200 decodable -> ok (unchanged)")
    assert_true(type(vOk.parsed) == 'table', "200 ok carries parsed table (unchanged)")

    -- 401 -> fatal, mentions API key, no Bearer (unchanged).
    local v401 = backoff.classify(401, '{"error":{"message":"Incorrect API key Bearer sk-LEAK"}}', { status = 401 })
    assert_eq(v401.outcome, 'fatal', "401 -> fatal (unchanged)")
    assert_true(v401.err:find('API key', 1, true) ~= nil, "401 err mentions API key (unchanged)")
    assert_true(v401.err:find('Bearer', 1, true) == nil, "401 err carries no Bearer (unchanged)")

    -- 400 -> fatal (unchanged).
    local v400 = backoff.classify(400, '{"error":{"message":"bad request"}}', { status = 400 })
    assert_eq(v400.outcome, 'fatal', "400 -> fatal (unchanged)")
    assert_true(type(v400.err) == 'string' and #v400.err > 0, "400 carries a speaking err (unchanged)")
end
