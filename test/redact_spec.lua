-- test/redact_spec.lua (FND-05)
--
-- Exercises BirdAID.lrdevplugin/src/redact.lua: a pure string->string masking function
-- (Lua patterns only, no regex/ReDoS surface) covering representative Phase-1 secrets
-- and PII -- API tokens (incl. base64-ish bearer values with +,/,=), GPS decimal
-- coordinate pairs, and macOS filesystem paths (incl. paths with spaces).
--
-- Loaded by test/run.lua via dofile; uses the runner's global assert_eq / assert_true.
-- Strictly Lua 5.1 common subset.

local redact = require('src.redact').redact

-- (1) Generic OpenAI-form sk- token: no raw token body remains.
assert_eq(redact("token sk-ABC123xyz"):find("sk%-ABC"), nil, "masks generic sk- token body")

-- (2) Anthropic-form sk-ant- token: no raw token body remains.
assert_eq(redact("sk-ant-AAA111"):find("AAA111"), nil, "masks sk-ant- token body")

-- (3) Google-form AIza token: no raw token body remains.
assert_eq(redact("key AIzaSyD-EXAMPLE"):find("SyD%-EXAMPLE"), nil, "masks AIza token body")

-- (4) Plain Bearer value is masked.
assert_eq(redact("Authorization: Bearer abc.def.ghi"):find("abc%.def%.ghi"), nil,
    "masks plain Bearer value")

-- (5) Base64-ish Bearer value with +,/,= -- none of the raw token body remains.
local b64 = redact("Authorization: Bearer eyJhbGci/Oi+JIUz==")
assert_eq(b64:find("eyJhbGci"), nil, "masks base64-ish bearer head")
assert_eq(b64:find("JIUz"), nil, "masks base64-ish bearer tail")
assert_eq(b64:find("/Oi"), nil, "masks base64-ish bearer with slash")
assert_eq(b64:find("Oi%+J"), nil, "masks base64-ish bearer with plus")

-- (6) macOS /Users path: the username path body is gone.
assert_eq(redact("at /Users/okohlbacher/Pictures/x.cr2"):find("okohlbacher"), nil,
    "masks /Users path body")

-- (7) Spaced /Volumes path: the spaced path fragment is gone.
assert_eq(redact("/Volumes/My Photos/raw/x.cr2"):find("My Photos"), nil,
    "masks spaced /Volumes path body")

-- (8) GPS decimal coordinate: the high-precision value is gone.
assert_eq(redact("gps 47.3769, 8.5417"):find("47%.3769"), nil, "masks GPS decimal")

-- (9) Non-string input passes through unchanged (type guard).
assert_eq(redact(42), 42, "non-string number passes through unchanged")
assert_eq(redact(nil), nil, "non-string nil passes through unchanged")
local t = {}
assert_eq(redact(t), t, "non-string table passes through unchanged (identity)")

-- ---- CODEX gate (Phase 1) regression cases: forms that previously leaked. ----

-- (10) All-caps BEARER is masked (case-insensitive keyword).
assert_eq(redact("Authorization: BEARER SECRET123tok"):find("SECRET123tok"), nil,
    "masks all-caps BEARER value")

-- (11) JSON-embedded secret value: "api_key":"SECRET..." -- value gone (key-aware).
assert_eq(redact('{"api_key":"SECRETvalue99"}'):find("SECRETvalue99"), nil,
    "masks JSON api_key value")

-- (12) Query-string secret: ?api_key=SECRET&... -- value gone, & boundary respected.
local q = redact("GET /v1/x?api_key=QSECRET42&model=gpt")
assert_eq(q:find("QSECRET42"), nil, "masks query-string api_key value")
assert_true(q:find("model=gpt") ~= nil, "leaves non-secret query param intact")

-- (13) YAML/plain key: value form for a secret key.
assert_eq(redact("token: tok_abcdef123"):find("tok_abcdef123"), nil,
    "masks 'token: value' form")

-- (14) Generic "secret"/"password" keys.
assert_eq(redact("password=hunter2pass"):find("hunter2pass"), nil, "masks password=value")
assert_eq(redact('"client_secret":"cs_live_x9"'):find("cs_live_x9"), nil,
    "masks client_secret value")

-- (15) URL embedded credentials: scheme://user:pass@host -- creds gone, host kept.
local u = redact("connect https://admin:s3cretpw@db.example.com/x")
assert_eq(u:find("s3cretpw"), nil, "masks URL embedded credentials")
assert_eq(u:find("admin:s3cret"), nil, "masks URL embedded username:password")
assert_true(u:find("db.example.com") ~= nil, "keeps host after masking URL creds")

-- (16) Labeled GPS keys lat=/lon= (not just decimal pairs).
local g = redact("fix lat=47.1 lon=-8.2 sats=9")
assert_eq(g:find("47%.1"), nil, "masks labeled lat value")
assert_eq(g:find("%-8%.2"), nil, "masks labeled lon value")

-- (17) A non-secret key/value is preserved (no over-redaction of ordinary fields).
assert_true(redact("status=ok count=3"):find("status=ok") ~= nil,
    "leaves non-secret key/value pairs intact")

-- ---- Phase 2 (SET-05, CODEX #9): specs over the ACTUAL composed settings log lines ----
-- The settings UI surfaces a field named apiTokenEntry; even though the primary rule is
-- "never construct a line containing the token value", these prove defense-in-depth.

-- (18) A settings-context JSON line carrying the token in the apiTokenEntry field has the
--      token body masked (SECRET_KEYS now includes apitokenentry).
assert_eq(redact('{"apiTokenEntry":"plainsecret123"}'):find("plainsecret123"), nil,
    "masks settings apiTokenEntry value (defense-in-depth)")

-- (19) A non-secret settings line survives intact: provider/model are NOT secrets.
local ns = redact("provider=openai model=gpt-4o")
assert_true(ns:find("provider=openai", 1, true) ~= nil, "non-secret provider=openai survives")
assert_true(ns:find("model=gpt-4o", 1, true) ~= nil, "non-secret model=gpt-4o survives")

-- (20) A bare token-shaped value in a settings line is masked by the value-only patterns.
assert_eq(redact("api token saved sk-LEAKEXAMPLE123"):find("LEAKEXAMPLE123"), nil,
    "masks bare sk- token-shaped value in a settings line")

-- ---- Phase 8 (HARD-01, CODEX #7): Windows drive-path + UNC redaction ----
-- The plugin RUNS on Windows (HTTP/keywords/settings/Keychain are cross-platform even
-- though crop is disabled there), so a `C:\Users\...` or `\\server\share\...` path could
-- otherwise leak into a log line. MASK is the module's masking token.
local MASK = "***REDACTED***"

-- (21) UPPERCASE drive path: body masked, root `C:\` kept, username + filename gone.
local wpu = redact([[at C:\Users\alice\Pictures\bird.cr2]])
assert_true(wpu:find(MASK, 1, true) ~= nil, "uppercase drive path contains MASK")
assert_eq(wpu:find("alice"), nil, "uppercase drive path masks username")
assert_eq(wpu:find("bird%.cr2"), nil, "uppercase drive path masks filename")
assert_true(wpu:find("C:\\", 1, true) ~= nil, "uppercase drive path keeps the C:\\ root")

-- (22) LOWERCASE drive path: %a matches lowercase too -> body masked.
local wpl = redact([[at c:\Users\bob\Pictures\x.cr2]])
assert_true(wpl:find(MASK, 1, true) ~= nil, "lowercase drive path contains MASK")
assert_eq(wpl:find("bob"), nil, "lowercase drive path masks username")
assert_eq(wpl:find("x%.cr2"), nil, "lowercase drive path masks filename")
assert_true(wpl:find("c:\\", 1, true) ~= nil, "lowercase drive path keeps the c:\\ root")

-- (23) UNC path \\server\share\... : host/share/user/filename all masked.
-- [CODEX #N2 / A4] The PRIVACY GUARANTEE is "no path fragment leaks", and we assert
-- exactly that here. UNC/drive masking is greedy to the line end, so it MAY consume
-- trailing non-path prose (the "done" word below). That over-redaction is ACCEPTED by
-- the documented A4 safe-by-design policy: it is strictly safe (it never leaks), so we
-- do NOT assert that the trailing word survives — only that every path fragment is gone.
local unc = redact([[from \\fileserver\photos\alice\bird.cr2 done]])
assert_true(unc:find(MASK, 1, true) ~= nil, "UNC path contains MASK")
assert_eq(unc:find("fileserver"), nil, "UNC path masks the host")
assert_eq(unc:find("alice"), nil, "UNC path masks the user segment")
assert_eq(unc:find("bird%.cr2"), nil, "UNC path masks the filename")
-- A4 over-redaction is acceptable: trailing prose MAY be consumed; we assert the
-- privacy guarantee (no path fragment leaks), NOT that "done" survives.
assert_eq(unc:find("photos"), nil, "UNC path masks the share segment (no fragment leaks)")

-- (24) SPACE-bearing drive path: body masked across the space.
local wsp = redact([[D:\My Photos\2026\heron.dng]])
assert_true(wsp:find(MASK, 1, true) ~= nil, "spaced drive path contains MASK")
assert_eq(wsp:find("My Photos"), nil, "spaced drive path masks across the space")
assert_eq(wsp:find("heron%.dng"), nil, "spaced drive path masks the filename")

-- (25) QUOTED-terminator fragment: path masked, trailing `"}` survives (quote terminator).
local wq = redact([[{"src":"E:\Users\jo\a.cr2"}]])
assert_true(wq:find(MASK, 1, true) ~= nil, "quoted drive path contains MASK")
assert_eq(wq:find("jo"), nil, "quoted drive path masks username")
assert_eq(wq:find("a%.cr2"), nil, "quoted drive path masks filename")
assert_true(wq:find('"}', 1, true) ~= nil, "quoted drive path preserves the trailing quote-brace")

-- (26) NO-false-positive regression: a token-free, path-free string is UNCHANGED.
local clean = "colon: value, ratio 16:9"
assert_eq(redact(clean), clean, "non-path colon string is returned unchanged (no false positive)")

-- ---- Phase 11 (DKEY-03, SC3): keyring summary no-leak backstop ----
-- DESIGN GOAL: no keyring code path EVER places a token VALUE into a fields table -- a
-- summary/log line references a key only by its stable ORDINAL (slot=N). These tests are
-- the backstop at the single redact sink: (a) ordinals are non-secret and pass through,
-- (b) IF a token-shaped value ever leaked into such a line, redact masks it.

-- (27) A representative keyring summary line carries the integer ordinal `slot = 2`
--      (modeled as the encoded fields a summary would log). The ordinal SURVIVES --
--      ordinals identify a key position, never the secret, so they are safe.
local ord = redact('keyring select runId=r1 slot=2 status=healthy')
assert_true(ord:find("2", 1, true) ~= nil, "keyring summary keeps the slot ordinal (non-secret)")
assert_true(ord:find("slot=2", 1, true) ~= nil, "keyring summary 'slot=2' ordinal passes through")

-- (28) BACKSTOP: a keyring-style line that DID embed a token value is masked at the sink,
--      proving DKEY-03 even though the design never places a value there. Reuse the same
--      sk-/sk-ant-/AIza/Bearer fixtures as the existing masking assertions above.
assert_eq(redact("keyring slot=2 token sk-LEAKABC123"):find("sk%-LEAKABC"), nil,
    "keyring line with an sk- token-shaped value is masked (backstop)")
assert_eq(redact("keyring slot=3 sk-ant-LEAKANT9"):find("LEAKANT9"), nil,
    "keyring line with an sk-ant- token-shaped value is masked (backstop)")
assert_eq(redact("keyring slot=1 AIzaSyLEAK-KEY"):find("SyLEAK%-KEY"), nil,
    "keyring line with an AIza token-shaped value is masked (backstop)")
assert_eq(redact("keyring slot=2 Authorization: Bearer leak.tok.val"):find("leak%.tok%.val"), nil,
    "keyring line with a Bearer value is masked (backstop)")
