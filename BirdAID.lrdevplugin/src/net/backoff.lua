-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/net/backoff.lua (PROV-05 — PURE classify + retry/backoff policy)
--
-- PURE module: imports NO Lr* module, NO LrHttp, and uses NO math.random. The only require is
-- the pure src.json (dkjson wrapper). It is require-able under stock lua / lua5.1 / luajit for
-- offline unit testing (the CODEX-mandated separation invariant). It CONSUMES the LrHttp
-- return shape (status, body, info-or-headers) the Lr glue hands it; it never performs I/O.
--
-- Responsibilities:
--   * classify(status, body, info) -> { outcome, parsed?, retryAfter?, err? }: the
--     status -> outcome decision (the untrusted HTTP boundary), including Retry-After parsing
--     in seconds / retry-after-ms / HTTP-date.
--   * httpDateToSeconds(dateStr, nowEpoch) -> delay seconds: a PURE RFC1123 HTTP-date parser
--     (takes an explicit nowEpoch so tests are deterministic).
--   * next(attempt, status, retryAfter) -> { retry, delay }: the deterministic
--     exponential-with-cap + max-attempts policy, including the OVER-CAP rule.
--
-- DETERMINISM (A1, CODEX MUST-FIX 2): backoff is exponential with NO jitter and NO
-- math.random (unavailable in LrC and breaks determinism). delay = min(CAP, BASE*2^(att-1)).
-- A single-user desktop plugin making serialized per-photo calls has no thundering-herd
-- problem, so jitter buys nothing and would break exact-value unit tests.
--
-- OVER-CAP rule (CODEX MUST-FIX 2): when the server's Retry-After wait EXCEEDS the local CAP,
-- next() returns retry=false (retryable-exhausted: the caller defers/degrades and continues
-- the run per FR2) -- it NEVER retries before the server is ready. A within-cap Retry-After is
-- PREFERRED as the delay.
--
-- SECRETS (T-05-01): no token is in scope here; err strings are speaking but token-free.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local json = require 'src.json'

local M = {}

-- ---------------------------------------------------------------------------
-- Policy constants (exported so the spec's exact-delay assertions track the policy).
-- ---------------------------------------------------------------------------
M.BASE = 1          -- base delay in seconds (attempt 1)
M.CAP = 30          -- maximum single-wait delay in seconds
M.MAX_ATTEMPTS = 4  -- bounded total attempts (after this, no more retries)

-- Retryable HTTP statuses (transient). 400/401/other-4xx are NON-retryable (fatal).
-- [07-01] 529 (Anthropic overloaded_error) and 503 (Gemini UNAVAILABLE) are BOTH retryable so
-- the shared policy serves openai/claude/gemini. 503 was already present; 529 is added here.
local RETRYABLE = {
    [408] = true, [429] = true,
    [500] = true, [502] = true, [503] = true, [504] = true,
    [529] = true,
}

-- ---------------------------------------------------------------------------
-- Header helpers. LrHttp response headers are an ARRAY of { field=, value= } plus a
-- `status` key. Read a header case-insensitively by iterating the array part.
-- ---------------------------------------------------------------------------
local function headerValue(headers, name)
    if type(headers) ~= 'table' then return nil end
    local want = name:lower()
    for _, pair in ipairs(headers) do
        if type(pair) == 'table' and type(pair.field) == 'string'
            and pair.field:lower() == want then
            return pair.value
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- httpDateToSeconds(dateStr, nowEpoch) -> seconds-from-now (>= 0) until the RFC1123 date.
-- Parses "Wed, 21 Oct 2026 07:28:00 GMT" into a UTC epoch via os.time, then returns
-- max(0, target - nowEpoch). nowEpoch is passed explicitly so the result is deterministic
-- in tests. Returns nil if the string cannot be parsed.
--
-- [CODEX MUST-FIX 5] STRICT validation: the string MUST be RFC1123-shaped
-- ("Wdy, DD Mon YYYY HH:MM:SS GMT") with a leading day-NAME, a recognized GMT/UTC zone, a
-- valid month abbreviation, and in-range day/hour/min/sec fields. A missing day-name, a
-- non-GMT zone (e.g. PST/EST/+0000), an out-of-range or normalized-impossible date (e.g.
-- "99 Jan") -> nil (the caller then falls back to the computed exponential backoff). We do
-- NOT accept os.time's silent normalization of impossible dates.
--
-- NOTE: os.time interprets its table as LOCAL time, but Retry-After dates are GMT/UTC. We
-- correct for the local offset by computing the difference between os.time(os.date('!*t'))
-- (UTC fields fed back as if local) and os.time(os.date('*t')) at the same instant -- the
-- standard pure-Lua "treat this table as UTC" trick. Both stock Lua and LrC expose os.time
-- and os.date.
-- ---------------------------------------------------------------------------
local MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

-- Days-in-month for the in-range day check (Feb handled by leap rule below).
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local function utcOffset()
    -- seconds that os.time adds when interpreting a UTC-valued table as local time.
    local t = os.time()
    local utc = os.date('!*t', t)
    local loc = os.date('*t', t)
    -- both describe the SAME instant t; os.time(utc) - os.time(loc) is the local->UTC offset.
    return os.difftime(os.time(utc), os.time(loc))
end

function M.httpDateToSeconds(dateStr, nowEpoch)
    if type(dateStr) ~= 'string' then return nil end
    -- RFC1123: "Wdy, DD Mon YYYY HH:MM:SS GMT". Require the leading day-NAME (3 letters + comma)
    -- and a trailing GMT/UTC zone -- reject bare dates and non-GMT zones (CODEX MUST-FIX 5).
    local wdy, d, mon, y, hh, mm, ss, zone =
        dateStr:match('^%s*(%a%a%a),%s+(%d%d?)%s+(%a%a%a)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s+(%a+)%s*$')
    if not wdy then return nil end
    -- Zone MUST be GMT or UTC; any other zone (PST, EST, ...) is rejected.
    local uz = zone:upper()
    if uz ~= 'GMT' and uz ~= 'UTC' then return nil end
    local month = MONTHS[mon]
    if not month then return nil end
    local dn = tonumber(d)
    local yn = tonumber(y)
    local hn, mn, sn = tonumber(hh), tonumber(mm), tonumber(ss)
    -- Strict range checks (reject normalized-impossible dates os.time would silently roll over).
    local maxDay = DAYS_IN_MONTH[month]
    if month == 2 and isLeap(yn) then maxDay = 29 end
    if dn < 1 or dn > maxDay then return nil end
    if hn > 23 or mn > 59 or sn > 59 then return nil end
    local utcTable = {
        year = yn, month = month, day = dn,
        hour = hn, min = mn, sec = sn,
        isdst = false,
    }
    -- os.time treats the table as local; add the offset to land on the true UTC epoch.
    local target = os.time(utcTable)
    if target == nil then return nil end
    target = target + utcOffset()
    local now = nowEpoch or os.time()
    local delta = target - now
    if delta < 0 then delta = 0 end
    return delta
end

-- ---------------------------------------------------------------------------
-- parseRetryAfter(headers) -> seconds (number) or nil.
-- Prefers 'retry-after-ms' (OpenAI's calibrated millisecond wait on 429) -> /1000 seconds;
-- else 'Retry-After' which is EITHER integer seconds OR an HTTP-date.
-- ---------------------------------------------------------------------------
local function parseRetryAfter(headers)
    -- [CODEX MUST-FIX 5] A negative/nonsensical numeric Retry-After is IGNORED (return nil) so
    -- next() falls back to the computed exponential backoff -- never a negative delay.
    local ms = headerValue(headers, 'retry-after-ms')
    if ms ~= nil then
        local n = tonumber(ms)
        if n ~= nil then
            if n < 0 then return nil end       -- ignore a negative ms wait
            return n / 1000
        end
    end
    local ra = headerValue(headers, 'Retry-After')
    if ra ~= nil then
        local n = tonumber(ra)
        if n ~= nil then
            if n < 0 then return nil end       -- ignore a negative seconds wait
            return n                            -- integer seconds (>= 0)
        end
        local fromDate = M.httpDateToSeconds(ra) -- strict HTTP-date (defaults to os.time())
        if fromDate ~= nil then return fromDate end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- statusLabel(status) -> a STATUS-DERIVED, BODY-FREE classification string. [CODEX MUST-FIX 1]
-- The returned `err` (which the provider may log AND return) is built ONLY from the status
-- code and a fixed category. The server's free-text error.message is NEVER read, decoded, or
-- propagated -- it can carry the token, the Authorization header, or the base64 data URL the
-- server echoed back. We drop it entirely (the safest fix). For 401 we keep a fixed, token-free
-- hint ("check API key") that contains no server text.
--
-- [07-01 / CODEX MUST-FIX 8] Labels are PROVIDER-NEUTRAL: the generic 4xx branch emits
-- 'http-NNN' (the former provider-prefixed form is gone) so a Claude/Gemini error is never
-- mislabeled with a provider name. The shared backoff serves all three providers.
-- (auth-failed/rate-limited/request-timeout/server-error/transport-error already carry no name.)
-- ---------------------------------------------------------------------------
local function statusLabel(status)
    if status == 401 then return 'auth-failed-401 (check API key)' end
    if status == 429 then return 'rate-limited-429' end
    if status == 408 then return 'request-timeout-408' end
    if type(status) == 'number' and status >= 500 then
        return 'server-error-' .. tostring(status)
    end
    if type(status) == 'number' and status >= 400 then
        return 'http-' .. tostring(status)
    end
    return 'http-' .. tostring(status)
end

-- ---------------------------------------------------------------------------
-- parseGoogleRetryDelay(decodedBody) -> seconds (number >= 0) | nil. PURE + TOTAL. [07-01]
-- Gemini delivers its retry wait in the JSON BODY, not a header: it lives at
-- decodedBody.error.details[i].retryDelay (a duration STRING like "30s" / "1.5s") on the entry
-- whose ['@type'] ENDS WITH "google.rpc.RetryInfo". We walk error.details, find that entry,
-- strip the trailing 's', tonumber it, and return seconds (>= 0) or nil.
--
-- [CODEX MUST-FIX 9] The GEMINI caller computes the retry wait as: decode the error body, take
-- bodyWait = parseGoogleRetryDelay(decoded); if bodyWait ~= nil it WINS over (takes PRECEDENCE
-- over) any header Retry-After classify found; otherwise fall back to the header value. The
-- OVER-CAP clamp in next() still applies on top. classify's header parsing is unchanged (it
-- still serves openai/claude). Every access is guarded (never index nil, never raise); a
-- negative/non-numeric/garbage duration -> nil. We do NOT read error.message (token-free).
-- ---------------------------------------------------------------------------
function M.parseGoogleRetryDelay(decodedBody)
    if type(decodedBody) ~= 'table' then return nil end
    local err = decodedBody.error
    if type(err) ~= 'table' then return nil end
    local details = err.details
    if type(details) ~= 'table' then return nil end
    for _, d in ipairs(details) do
        if type(d) == 'table' then
            local t = d['@type']
            if type(t) == 'string' and t:sub(-#'google.rpc.RetryInfo') == 'google.rpc.RetryInfo' then
                local rd = d.retryDelay
                if type(rd) == 'string' then
                    -- Match a non-negative duration "<number>s" (integer or decimal). A leading
                    -- '-' or any non-duration shape fails the pattern -> nil.
                    local num = rd:match('^(%d+%.?%d*)s$')
                    if num == nil then num = rd:match('^(%d*%.%d+)s$') end
                    if num ~= nil then
                        local n = tonumber(num)
                        if type(n) == 'number' and n == n and n >= 0 then
                            return n
                        end
                    end
                end
                return nil      -- a RetryInfo with a bad/absent duration -> nil (do not scan on).
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- QUOTA_FATAL — the unambiguous quota/billing/account-disabled enum values that turn a 429 from
-- a (silently-degrading) RETRY into an actionable FATAL. Membership is exact-string. ONLY clearly
-- non-transient enums are listed: a genuine transient (OpenAI rate_limit_exceeded, Anthropic
-- rate_limit_error / overloaded_error, Google RESOURCE_EXHAUSTED) is DELIBERATELY ABSENT and stays
-- RETRY. A spoofed value only causes an honest, actionable fatal (the safe direction) — never a
-- degrade-and-continue. (T-Q-03: conservative-by-design.)
-- ---------------------------------------------------------------------------
local QUOTA_FATAL = {
    -- OpenAI billing/quota/account-disabled enums (error.type / error.code).
    insufficient_quota = true,
    billing_hard_limit_reached = true,
    billing_not_active = true,
    access_terminated = true,
}

-- ---------------------------------------------------------------------------
-- ENUM_SAFE_LABEL — the ALLOWLIST of known-safe enum labels: the ONLY strings from the (untrusted)
-- body permitted to appear in the returned `err`. [CODEX no-leak round 2]
--
-- THE SECURITY BOUNDARY. A charset/length sanitize (the round-1 approach) is INSUFFICIENT: a
-- bare identifier-shaped secret — e.g. an OAuth/PAT token `ghp_abcd...`, an AWS key `AKIA...`, or
-- any pure [A-Za-z0-9_] token <= 64 chars — passes a `^[A-Za-z0-9_]+$` filter and would be echoed
-- verbatim into err, leaking a novel string from the body. We switch to a STRICT ALLOWLIST: an
-- enum value enriches the label ONLY if it is an EXACT member of this code-defined set of known,
-- NON-FATAL, informative provider enums. Any value not in the set is DROPPED (the label stays the
-- plain body-free 'rate-limited-429'). This GUARANTEES the untrusted body can never inject a novel
-- string into err — only these fixed, source-defined strings can ever appear.
--
-- These are all fixed provider enum identifiers (no secrets). Distinct concern from QUOTA_FATAL
-- (which reclassifies a 429 to a CONSTANT fatal err): this set is the safe-to-echo informative
-- retry labels only.
-- ---------------------------------------------------------------------------
local ENUM_SAFE_LABEL = {
    -- OpenAI (error.type / error.code) — transient rate/server enums worth surfacing.
    rate_limit_exceeded = true,
    server_error = true,
    tokens = true,
    requests = true,
    -- Anthropic (error.type).
    rate_limit_error = true,
    overloaded_error = true,
    api_error = true,
    timeout = true,
    -- Google (error.status) — gRPC canonical codes.
    RESOURCE_EXHAUSTED = true,
    UNAVAILABLE = true,
    INTERNAL = true,
    DEADLINE_EXCEEDED = true,
}

-- ---------------------------------------------------------------------------
-- safeEnumLabel(body) -> enumString | nil. PURE + TOTAL. [T-Q-01 / T-Q-02 / CODEX no-leak round 2]
-- GUARDEDLY decodes the UNTRUSTED retryable body via the non-raising json.decode tuple idiom and
-- returns ONLY the ALLOWLISTED provider enum(s): the DISTINCT values of decoded.error.type, then
-- .code, then (Google) .status — each included ONLY if ENUM_SAFE_LABEL[value] == true (EXACT set
-- membership) — joined with '/' in that order (so a body carrying both a generic type and a
-- specific code surfaces both, e.g. 'rate_limit_error/rate_limit_exceeded').
-- Every access is type-guarded (decoded / decoded.error may be absent or a non-table). It reads
-- NEVER error.message nor any other free-text/body/header field. CRITICAL: the enum FIELD VALUE is
-- itself untrusted — a hostile body can place "Bearer sk-LEAK data:image/..." OR a bare
-- identifier-shaped secret ("ghp_...", "AKIA...") directly in error.type/code/status. The
-- allowlist is the AUTHORITATIVE gate: anything not an exact member is DROPPED, so a novel string
-- from the body can NEVER reach err. If no allowlisted enum remains -> nil, so the label stays the
-- plain body-free 'rate-limited-429'. A non-table / empty / non-JSON / nil body -> nil.
-- ---------------------------------------------------------------------------
local function safeEnumLabel(body)
    if type(body) ~= 'string' or body == '' then return nil end
    local ok, parsed = json.decode(body)        -- non-raising tuple idiom (reused from the 200 branch)
    if not ok or type(parsed) ~= 'table' then return nil end
    local err = parsed.error
    if type(err) ~= 'table' then return nil end
    -- Collect ONLY the structured enum fields, in a stable order, de-duplicated. Each must be an
    -- EXACT member of ENUM_SAFE_LABEL (a numeric error.code is ignored; a hostile free-text value
    -- OR an identifier-shaped secret crammed into an enum field is DROPPED, never concatenated).
    local parts = {}
    local seen = {}
    local function add(v)
        if type(v) == 'string' and ENUM_SAFE_LABEL[v] == true and not seen[v] then
            seen[v] = true
            parts[#parts + 1] = v
        end
    end
    add(err.type)
    add(err.code)
    add(err.status)
    if #parts == 0 then return nil end
    return table.concat(parts, '/')
end

-- enumIsFatal(body) -> true | false. Checks each safe enum field (type/code/status) against
-- QUOTA_FATAL. Guards every access; reads NO message. A non-table/nil body -> false.
local function enumIsFatal(body)
    if type(body) ~= 'string' or body == '' then return false end
    local ok, parsed = json.decode(body)
    if not ok or type(parsed) ~= 'table' then return false end
    local err = parsed.error
    if type(err) ~= 'table' then return false end
    local t = err.type
    if type(t) == 'string' and QUOTA_FATAL[t] then return true end
    local c = err.code
    if type(c) == 'string' and QUOTA_FATAL[c] then return true end
    local s = err.status
    if type(s) == 'string' and QUOTA_FATAL[s] then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- classify(status, body, info) -> { outcome=..., parsed?, retryAfter?, err? }
-- `info` is the LrHttp headers table on an HTTP response, or the transport info table on a
-- network failure (status == nil). Never raises.
--
-- [CODEX MUST-FIX 1] Every `err` here is a STATUS-DERIVED label only -- it NEVER contains the
-- response body, headers, token, "Bearer", or "data:image/jpeg;base64".
-- [CODEX MUST-FIX 4] status 200 is NEVER network-retried: it ALWAYS -> outcome 'ok' and the
-- (possibly nil) decoded body is handed to openai_response.map, which owns the
-- repair-once/degrade decision for malformed JSON. There is no 200->retry path.
-- ---------------------------------------------------------------------------
function M.classify(status, body, info)
    -- Transport/network failure: nil status -> retry (transient). Body-free label.
    if status == nil then
        return { outcome = 'retry', err = 'transport-error' }
    end

    if status == 200 then
        -- ALWAYS hand the body to the response mapper (repair-once -> degrade). We try a decode
        -- here only to populate `parsed` for the happy path; a decode FAILURE still returns
        -- outcome 'ok' with parsed=nil so the mapper (not a network retry) owns recovery.
        local ok, parsed = json.decode(body)
        if ok and type(parsed) == 'table' then
            return { outcome = 'ok', parsed = parsed }
        end
        return { outcome = 'ok', parsed = nil }
    end

    if status == 401 or status == 400 then
        -- Non-retryable; status-derived, body-free, token-free (T-05-01 / MUST-FIX 1).
        return { outcome = 'fatal', err = statusLabel(status) }
    end

    if RETRYABLE[status] then
        -- Read ONLY the safe provider enum from the untrusted body (never error.message). An
        -- unambiguous quota/billing/account-disabled enum RECLASSIFIES this 429 to a fatal so the
        -- provider returns (nil, err) and the user sees an actionable error instead of burning the
        -- retries and silently degrading to "no bird found". Any OTHER enum merely ENRICHES the
        -- body-free retry label. A nil/empty/garbage/no-enum body falls through to the verbatim
        -- existing retry result (behavior unchanged). The decode is fully guarded — never raises.
        if enumIsFatal(body) then
            return {
                outcome = 'fatal',
                err = 'insufficient-quota-429 (add OpenAI billing/credits)',
            }
        end
        local enum = safeEnumLabel(body)
        local label = statusLabel(status)
        if enum ~= nil then
            label = label .. ' (' .. enum .. ')'
        end
        return {
            outcome = 'retry',
            retryAfter = parseRetryAfter(info),
            err = label,
        }
    end

    -- any other status (e.g. other 4xx) -> fatal, status-derived label only.
    return { outcome = 'fatal', err = statusLabel(status) }
end

-- ---------------------------------------------------------------------------
-- next(attempt, status, retryAfterSeconds) -> { retry=bool, delay=seconds }
-- Deterministic exponential-with-cap; bounded by MAX_ATTEMPTS; honors Retry-After.
--
-- [CODEX MUST-FIX 3] `attempt` is the number of the HTTP call JUST MADE (the provider posts
-- BEFORE consulting next). So total HTTP calls must equal MAX_ATTEMPTS on a permanent
-- retryable failure: next() returns retry=false once `attempt >= MAX_ATTEMPTS` (i.e. after the
-- MAX_ATTEMPTS-th post there is no further retry). This makes calls == MAX_ATTEMPTS, not
-- MAX_ATTEMPTS+1.
-- ---------------------------------------------------------------------------
function M.next(attempt, status, retryAfterSeconds)
    -- Non-retryable statuses never retry.
    if not RETRYABLE[status] then
        return { retry = false, delay = 0 }
    end

    -- Bounded max-attempts ceiling: after the MAX_ATTEMPTS-th post, stop (no further retry).
    -- (attempt is the post just made; retrying when attempt==MAX would make a MAX+1-th call.)
    if attempt >= M.MAX_ATTEMPTS then
        return { retry = false, delay = 0 }
    end

    -- OVER-CAP rule (CODEX MUST-FIX 2): a server wait greater than the local CAP -> do NOT
    -- retry early; defer/degrade. A within-cap Retry-After is preferred as the delay.
    if retryAfterSeconds ~= nil then
        if retryAfterSeconds > M.CAP then
            return { retry = false, delay = 0 }
        end
        return { retry = true, delay = retryAfterSeconds }
    end

    -- Deterministic exponential-with-cap (no jitter, no math.random).
    local delay = M.BASE * (2 ^ (attempt - 1))
    if delay > M.CAP then delay = M.CAP end
    return { retry = true, delay = delay }
end

return M
