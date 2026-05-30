-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/redact.lua (FND-05)
--
-- PURE-LUA string->string redaction. Imports NO Lr* module at load time, so it is
-- require-able under stock lua / lua5.1 / luajit for offline unit testing (the
-- CODEX-mandated separation invariant). The thin Lr logger sink (src/log.lua, a later
-- task) is the only consumer that imports Lr*; redaction itself never does.
--
-- Masks representative Phase-1 secrets and PII before any text can reach the log:
--   * API tokens: Anthropic sk-ant-, generic sk-, Google AIza, and case-insensitive
--     Bearer values whose charset INCLUDES base64 characters (+, /, =) plus -, _, .
--     so base64-ish bearer tokens are fully masked.
--   * GPS decimal coordinates (high-precision decimals).
--   * macOS filesystem paths under /Users and /Volumes, whose match extends across
--     spaces (so /Volumes/My Photos/... is masked), stopping at a quote/newline/end.
--   * Windows filesystem paths (HARD-01): drive paths (C:\... and lowercase c:\...,
--     keeping the captured root) and UNC paths (\\server\share\...), matched across
--     spaces up to a quote/newline/end like the macOS entries (UNC matched first).
--
-- Lua patterns ONLY -- no PCRE/regex, hence no ReDoS surface. Ordered longest/most-
-- specific first so sk-ant- is masked before generic sk-.
--
-- Strictly Lua 5.1 common subset.

local M = {}

local MASK = "***REDACTED***"

-- Keys whose VALUE is a secret or precise location, in any key/value form
-- (key=value, "key":"value", key: value, &key=value query strings). Matched
-- case-insensitively (the key capture is lowercased before lookup). Over-redaction
-- here is safe-by-design (A4): a false positive masks a non-secret; a false negative
-- would leak. CODEX gate (Phase 1) added the key-aware pass after value-only patterns
-- were shown to leak `"api_key":"..."`, `?api_key=...`, URL creds, and `lat=/lon=`.
local SECRET_KEYS = {
    ["api_key"] = true, ["apikey"] = true, ["api-key"] = true, ["x-api-key"] = true,
    ["apitoken"] = true, ["token"] = true, ["access_token"] = true,
    -- Phase 2 (SET-05, CODEX #9) defense-in-depth: the settings UI field names that
    -- could carry the AI token. The primary rule remains "never construct a log line
    -- containing the token value"; these are belt-and-suspenders. (apitoken/token are
    -- already present above; apitokenentry/api_token are the settings-surfaced names.)
    ["apitokenentry"] = true, ["api_token"] = true,
    ["refresh_token"] = true, ["id_token"] = true, ["authorization"] = true,
    ["auth"] = true, ["password"] = true, ["passwd"] = true, ["pwd"] = true,
    ["secret"] = true, ["client_secret"] = true, ["key"] = true,
    -- Precise-location keys (PII). Decimal coordinates are also caught by the
    -- high-precision-decimal pattern below; this covers labeled forms like lat=47.3.
    ["lat"] = true, ["lon"] = true, ["lng"] = true, ["latitude"] = true,
    ["longitude"] = true, ["gps"] = true,
}

-- Ordered value-only patterns: most-specific first. Each entry is { pattern, replacement }.
local patterns = {
    -- Anthropic sk-ant-... before the generic sk-... so the more specific form wins.
    { "sk%-ant%-[%w%-_]+", "sk-ant-" .. MASK },
    { "sk%-[%w%-_]+",      "sk-" .. MASK },
    -- Google AIza... key.
    { "AIza[%w%-_]+",      "AIza" .. MASK },
    -- Bearer <value>: value charset includes base64 chars (+, /, =) and -, _, ., :
    -- Case-insensitive "BEARER"/"Bearer"/"bearer". Masks a base64-ish bearer like
    -- "Bearer eyJhbGci/Oi+JIUz==" entirely, including a ':'-bearing suffix.
    { "[Bb][Ee][Aa][Rr][Ee][Rr]%s+[%w%+/=%-_%.:]+", "Bearer " .. MASK },
    -- URL embedded credentials: scheme://user:pass@host -> scheme://MASK@host.
    { "([%w%+%.%-]+://)[^/@%s]+@", "%1" .. MASK .. "@" },
    -- macOS paths: consume across spaces up to a quote/newline/end so spaced paths
    -- like "/Volumes/My Photos/raw/x.cr2" are fully masked. Over-redaction accepted (A4).
    { "/Users/[^\"'\n]+",   "/Users/" .. MASK },
    { "/Volumes/[^\"'\n]+", "/Volumes/" .. MASK },
    -- Windows paths (HARD-01, CODEX #7). The plugin RUNS on Windows even though crop is
    -- disabled there, so a Windows path could leak. Lua patterns only ('\\' is one
    -- literal backslash; '%a' is a single ASCII letter so both 'C:\' and 'c:\' match).
    -- The [^"'\n]+ body consumes across spaces up to a quote/newline/end exactly like
    -- the macOS entries, so spaced/quoted Windows paths are fully masked while a trailing
    -- quote survives. Over-redaction is safe-by-design (A4): mask non-secrets, never leak.
    --
    -- UNC FIRST so the leading double-backslash is consumed as a UNC prefix, not mistaken
    -- for a (single-backslash) drive body. \\server\share\... -> \\ + MASK.
    { "\\\\[^\"'\n]+", "\\\\" .. MASK },
    -- Drive path: keep the captured root (C:\ / c:\), mask the rest.
    { "(%a:\\)[^\"'\n]+", "%1" .. MASK },
    -- GPS high-precision decimal coordinates (>=4 fractional digits). A4 caveat: may
    -- over-redact other isolated high-precision decimals -- accepted for safety.
    { "%-?%d+%.%d%d%d%d+", MASK },
}

-- Key-aware pass. Matches an identifier, an optional quote + ':'/'=' separator (with
-- optional surrounding quote), and a value terminated by whitespace/quote/comma/&/}.
-- When the (lowercased) key is a SECRET_KEY, the value is masked; otherwise the match
-- is returned unchanged. Lua patterns only -- no PCRE/regex, hence no ReDoS surface.
local function redact_keyed(s)
    return (s:gsub('([%w_%-]+)("?%s*[=:]%s*"?)([^%s"\',&}]+)', function(key, sep, value)
        if SECRET_KEYS[key:lower()] then
            return key .. sep .. MASK
        end
        return key .. sep .. value
    end))
end

-- redact(s) -> masked string. Non-string input is returned unchanged (type guard).
function M.redact(s)
    if type(s) ~= "string" then
        return s
    end
    -- Value-only patterns first (so "Bearer <tok>" is masked before the key-aware pass
    -- sees it), then the key-aware pass for key/value-shaped secrets and coordinates.
    for _, p in ipairs(patterns) do
        s = s:gsub(p[1], p[2])
    end
    s = redact_keyed(s)
    return s
end

return M
