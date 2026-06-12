-- test/http_authheaders_spec.lua (Plan 07-01 — shared Lr HTTP glue: per-provider auth + attach)
--
-- Exercises BirdAID.lrdevplugin/src/lr/http.lua: the GENERALIZED Lr glue (the ONLY new HTTP
-- toucher this phase). http.lua imports Lr* at LOAD time via the global `import` function (an
-- LrC builtin), so under the stock runner we install a MINIMAL `import` shim that returns small
-- stub namespaces BEFORE requiring it. We test the two pure-ish surfaces that need no live
-- network: M.authHeaders(provider, token) (the per-provider {field=,value=} shape) and the
-- OpenAI {kind=bytes} data-URL attach REGRESSION (CODEX MUST-FIX 4 — openai must STILL attach the
-- data URL, and the raw b64 must be the no-prefix form Claude/Gemini need).
--
-- NO-LEAK: the SENTINEL token must appear ONLY as a header VALUE, never as a field name.
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

-- ---------------------------------------------------------------------------
-- Minimal Lr stubs. encodeBase64 is a KNOWN, deterministic transform so the attach regression
-- asserts an exact prefix + raw form without depending on a real base64 implementation.
-- ---------------------------------------------------------------------------
local STUB_LrStringUtils = {
    encodeBase64 = function(bytes) return 'B64(' .. tostring(bytes) .. ')' end,
}
local STUB_LrHttp      = { post = function() return nil, { error = {} } end }
local STUB_LrPasswords = { retrieve = function() return nil end }
local STUB_LrTasks     = { sleep = function() end }

-- src.log (required by buildDeps via deps.log) imports LrLogger/LrPathUtils/LrApplication at LOAD;
-- stub them so the buildDeps reconcile test can require src.log under the stock runner.
local STUB_logger = {}
STUB_logger.enable = function() return STUB_logger end
local function noop() end
STUB_logger.info, STUB_logger.warn, STUB_logger.error, STUB_logger.trace = noop, noop, noop, noop
local STUB_LrLogger = setmetatable({}, { __call = function() return STUB_logger end })
local STUB_LrPathUtils = {
    child = function(a, b) return tostring(a) .. '/' .. tostring(b) end,
    getStandardFilePath = function() return '/tmp' end,
}
local STUB_LrApplication = { versionTable = function() return { major = 14 } end }

local LR_STUBS = {
    LrHttp        = STUB_LrHttp,
    LrStringUtils = STUB_LrStringUtils,
    LrPasswords   = STUB_LrPasswords,
    LrTasks       = STUB_LrTasks,
    LrLogger      = STUB_LrLogger,
    LrPathUtils   = STUB_LrPathUtils,
    LrApplication = STUB_LrApplication,
}

-- Install the global `import` shim (LrC builtin; absent under stock lua) BEFORE the require.
-- Preserve any pre-existing import so we do not stomp a real environment.
local savedImport = import
import = function(name)
    local s = LR_STUBS[name]
    if s ~= nil then return s end
    return savedImport and savedImport(name) or {}
end

-- Require the module under the shim. http.lua requires the PURE src.settings (no Lr) at load.
local http = require('src.lr.http')

assert_true(type(http) == 'table', "require 'src.lr.http' resolves under the Lr stub")
assert_true(type(http.authHeaders) == 'function', "http exposes authHeaders")
assert_true(type(http.attachImage) == 'function', "http exposes attachImage")
assert_true(type(http.encodeBase64) == 'function', "http exposes encodeBase64")
assert_true(type(http.dataUrl) == 'function', "http exposes dataUrl")
assert_true(type(http.makeHttpPost) == 'function', "http exposes makeHttpPost")
assert_true(type(http.readToken) == 'function', "http exposes readToken")
assert_true(type(http.buildDeps) == 'function', "http exposes buildDeps")
assert_eq(http.PLUGIN_ID, 'com.okohlbacher.birdaid', "PLUGIN_ID is the canonical scope")

local SENTINEL = 'SENTINEL-TOKEN-do-not-leak-9999'

-- findHeader(headers, field) -> value | nil (case-insensitive field match over the array).
local function findHeader(headers, field)
    local want = field:lower()
    for _, h in ipairs(headers) do
        if type(h) == 'table' and type(h.field) == 'string' and h.field:lower() == want then
            return h.value
        end
    end
    return nil
end

-- tokenAppearsAsFieldName(headers): true iff the SENTINEL is used as a field NAME (a leak).
local function tokenInAnyFieldName(headers)
    for _, h in ipairs(headers) do
        if type(h) == 'table' and type(h.field) == 'string'
            and h.field:find(SENTINEL, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- =====================================================================
-- authHeaders: OpenAI -> Authorization Bearer + Content-Type.
-- =====================================================================
do
    local h = http.authHeaders('openai', SENTINEL)
    assert_true(type(h) == 'table', "openai authHeaders is a table")
    local auth = findHeader(h, 'Authorization')
    assert_true(type(auth) == 'string', "openai has an Authorization header")
    assert_true(auth:sub(1, 7) == 'Bearer ', "openai Authorization value starts with 'Bearer '")
    assert_true(auth:find(SENTINEL, 1, true) ~= nil, "openai Authorization carries the token VALUE")
    assert_true(findHeader(h, 'Content-Type') == 'application/json', "openai sets Content-Type json")
    assert_true(findHeader(h, 'x-api-key') == nil, "openai has no x-api-key")
    assert_true(not tokenInAnyFieldName(h), "openai: token never a field NAME")
end

-- =====================================================================
-- authHeaders: Claude -> x-api-key (== token) + anthropic-version 2023-06-01 + content-type.
-- =====================================================================
do
    local h = http.authHeaders('claude', SENTINEL)
    assert_true(type(h) == 'table', "claude authHeaders is a table")
    assert_eq(findHeader(h, 'x-api-key'), SENTINEL, "claude x-api-key value == the token")
    assert_eq(findHeader(h, 'anthropic-version'), '2023-06-01', "claude anthropic-version is constant")
    assert_eq(findHeader(h, 'content-type'), 'application/json', "claude sets content-type json")
    assert_true(findHeader(h, 'Authorization') == nil, "claude has NO Authorization header")
    assert_true(not tokenInAnyFieldName(h), "claude: token never a field NAME")
end

-- =====================================================================
-- authHeaders: Gemini -> x-goog-api-key (== token, NOT a ?key= query) + Content-Type, NO Authorization.
-- =====================================================================
do
    local h = http.authHeaders('gemini', SENTINEL)
    assert_true(type(h) == 'table', "gemini authHeaders is a table")
    assert_eq(findHeader(h, 'x-goog-api-key'), SENTINEL, "gemini x-goog-api-key value == the token")
    assert_eq(findHeader(h, 'Content-Type'), 'application/json', "gemini sets Content-Type json")
    assert_true(findHeader(h, 'Authorization') == nil, "gemini has NO Authorization header")
    assert_true(findHeader(h, 'x-api-key') == nil, "gemini has no x-api-key")
    assert_true(not tokenInAnyFieldName(h), "gemini: token never a field NAME")
end

-- =====================================================================
-- authHeaders: unknown provider -> nil (never an auth-less default header set).
-- =====================================================================
do
    assert_eq(http.authHeaders('nope', SENTINEL), nil, "unknown provider -> nil")
    assert_eq(http.authHeaders(nil, SENTINEL), nil, "nil provider -> nil")
end

-- =====================================================================
-- REGRESSION (CODEX MUST-FIX 4): openai {kind=bytes} STILL attaches the data URL; b64 is RAW.
-- D3 (M6): the retired openai_http.attachDataUrl was a pure delegate to http.attachImage; we now
-- drive http.attachImage directly (the live surface) under the same stub.
-- =====================================================================
do
    assert_true(type(http.attachImage) == 'function', "http exposes attachImage")

    local image = { kind = 'bytes', data = 'ABC' }
    http.attachImage(image)

    assert_true(type(image.dataUrl) == 'string', "attach sets image.dataUrl for {kind=bytes}")
    assert_true(image.dataUrl:sub(1, 23) == 'data:image/jpeg;base64,',
        "image.dataUrl STARTS WITH the data:image/jpeg;base64, prefix (OpenAI regression)")
    -- With the stub encodeBase64('ABC') == 'B64(ABC)', the data URL is the prefix + that transform.
    assert_eq(image.dataUrl, 'data:image/jpeg;base64,B64(ABC)',
        "image.dataUrl is prefix .. encodeBase64(bytes)")
    -- The RAW b64 (no prefix) is ALSO attached for the Claude/Gemini consumers.
    assert_eq(image.b64, 'B64(ABC)', "image.b64 is the RAW (no-prefix) base64")
end

-- =====================================================================
-- attachImage directly: a missing/empty source leaves BOTH dataUrl and b64 nil (token-free degrade).
-- =====================================================================
do
    local empty = { kind = 'bytes' }       -- no data
    http.attachImage(empty)
    assert_eq(empty.dataUrl, nil, "no source -> dataUrl stays nil")
    assert_eq(empty.b64, nil, "no source -> b64 stays nil")
end

-- =====================================================================
-- [CODEX phase-7 N2] buildDeps model reconcile (end-to-end through the glue): a token is needed,
-- so point the stub Keychain at a non-empty value for these calls. Asserts:
--   * buildDeps('claude', {model='gpt-4o'}) -> deps.model == claude default (stale cross-provider);
--   * buildDeps('gemini', {model='gemini-custom-xyz'}) -> keeps 'gemini-custom-xyz' (escape hatch);
--   * buildDeps('claude', {model='claude-opus-4-8'}) -> keeps it (this provider's catalog model).
-- =====================================================================
do
    local savedRetrieve = STUB_LrPasswords.retrieve
    STUB_LrPasswords.retrieve = function() return 'KEYCHAIN-TOKEN-stub' end

    local d1 = http.buildDeps('claude', { model = 'gpt-4o' })
    assert_true(type(d1) == 'table', "buildDeps('claude',{model=gpt-4o}) returns deps")
    assert_eq(d1.model, 'claude-opus-4-8',
        "buildDeps reconciles a STALE cross-provider model to the claude default")

    local d2 = http.buildDeps('gemini', { model = 'gemini-custom-xyz' })
    assert_true(type(d2) == 'table', "buildDeps('gemini',{model=custom}) returns deps")
    assert_eq(d2.model, 'gemini-custom-xyz',
        "buildDeps KEEPS a non-catalog custom model (escape hatch)")

    local d3 = http.buildDeps('claude', { model = 'claude-opus-4-8' })
    assert_true(type(d3) == 'table', "buildDeps('claude',{model=catalog}) returns deps")
    assert_eq(d3.model, 'claude-opus-4-8',
        "buildDeps KEEPS this provider's catalog model")

    STUB_LrPasswords.retrieve = savedRetrieve
end

-- Restore the original import (be a good neighbour for any later spec in the same process).
import = savedImport
