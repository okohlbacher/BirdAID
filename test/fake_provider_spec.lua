-- test/fake_provider_spec.lua (Phase 3 — Fake provider + selector: FAKE-01)
--
-- Exercises BirdAID.lrdevplugin/src/providers/fake.lua and .../init.lua: PURE modules
-- (the only requires are the pure src.contract / src.providers.fake), require-able under
-- stock lua / luajit. Proves loader resolution of the nested dotted names, that BUILTIN
-- default + none fixtures pass contract.validateResponse, that new(fixtures) REJECTS a
-- malformed fixture and identify RE-VALIDATES (CODEX MUST-FIX 14), that
-- providers.get('fake')/select({provider='fake'}) return an identify object WITHOUT
-- touching settings.PROVIDERS (CODEX MUST-FIX 15), and the no-network source grep
-- (CODEX MUST-FIX 22).
--
-- Loaded by test/run.lua via dofile; uses the runner globals assert_eq / assert_true.
-- Strictly Lua 5.1 common subset (no \u{}, no //, no goto, no <close>; unpack global).

-- Loader resolution: require the nested dotted names under both interpreters.
local fake = require('src.providers.fake')
local providers = require('src.providers.init')
local contract = require('src.contract')
local settings = require('src.settings')

assert_true(type(fake) == 'table', "require 'src.providers.fake' resolves")
assert_true(type(providers) == 'table', "require 'src.providers.init' resolves")

-- =====================================================================
-- BUILTIN fixtures pass the validator; 'none' has bird_present=false.
-- =====================================================================
do
    local okD = contract.validateResponse(fake.BUILTIN.default)
    assert_true(okD, "BUILTIN.default passes validateResponse")
    local okN = contract.validateResponse(fake.BUILTIN.none)
    assert_true(okN, "BUILTIN.none passes validateResponse")
    assert_eq(fake.BUILTIN.none.bird_present, false, "BUILTIN.none bird_present == false")
    assert_eq(#fake.BUILTIN.none.detections, 0, "BUILTIN.none has empty detections")
end

-- =====================================================================
-- new(fixtures) constructs a provider; identify returns validator-passing responses.
-- =====================================================================
do
    local prov, err = fake.new(fake.BUILTIN)
    assert_true(prov ~= nil, "fake.new(BUILTIN) constructs (err=" .. tostring(err) .. ")")
    assert_true(type(prov.identify) == 'function', "provider exposes identify")

    local image = { kind = 'bytes', data = "JPEGBYTES", width = 640, height = 480 }

    -- default fixture
    local respD = prov.identify(image, {})
    assert_true(contract.validateResponse(respD), "identify default passes validateResponse")
    assert_eq(respD.bird_present, true, "default response bird_present true")

    -- 'none' via ctx.fakeFixture
    local respN = prov.identify(image, { fakeFixture = 'none' })
    assert_true(contract.validateResponse(respN), "identify none passes validateResponse")
    assert_eq(respN.bird_present, false, "none response bird_present false")

    -- 'none' via explicit fixtureName arg
    local respN2 = prov.identify(image, {}, 'none')
    assert_eq(respN2.bird_present, false, "identify explicit fixtureName 'none' works")

    -- unknown fixture name falls back to default
    local respFallback = prov.identify(image, { fakeFixture = 'does-not-exist' })
    assert_eq(respFallback.bird_present, true, "unknown fixture falls back to default")
end

-- =====================================================================
-- CODEX MUST-FIX 14: new(fixtures) REJECTS a malformed fixture (returns nil, err).
-- =====================================================================
do
    -- malformed: bird_present is not a boolean
    local prov, err = fake.new({ bad = { bird_present = "yes", detections = {} } })
    assert_eq(prov, nil, "new rejects malformed fixture (nil provider)")
    assert_true(type(err) == 'string' and string.find(err, 'bad-fixture:', 1, true) ~= nil,
        "new returns a bad-fixture error (got " .. tostring(err) .. ")")
end
do
    -- malformed: contradictory bird_present=false with a non-empty detections array
    local prov, err = fake.new({
        contradiction = { bird_present = false, detections = { { bbox = {0,0,1,1} } } },
    })
    assert_eq(prov, nil, "new rejects contradictory fixture")
    assert_true(type(err) == 'string', "new contradictory returns err string")
end
do
    -- non-table fixtures argument
    local prov, err = fake.new("nope")
    assert_eq(prov, nil, "new('nope') rejected")
    assert_eq(err, 'fixtures-not-table', "new non-table err")
end

-- =====================================================================
-- CODEX MUST-FIX 14 (defence in depth): identify RE-VALIDATES the selected response.
-- We cannot get a bad fixture past new(), so prove re-validation by mutating the stored
-- fixture AFTER construction and asserting identify catches it (returns nil, err).
-- =====================================================================
do
    local prov = fake.new({ default = fake.BUILTIN.default })
    assert_true(prov ~= nil, "constructed for re-validation test")
    -- corrupt the stored fixture post-construction (simulates a tampered/derived response)
    prov.fixtures.default = { bird_present = "no", detections = {} }
    local resp, err = prov.identify({ kind = 'bytes', data = "x", width = 1, height = 1 }, {})
    assert_eq(resp, nil, "identify re-validates and rejects a corrupted fixture")
    assert_true(type(err) == 'string' and string.find(err, 'fixture-failed-validation', 1, true) ~= nil,
        "identify returns a fixture-failed-validation err (got " .. tostring(err) .. ")")
end

-- =====================================================================
-- CODEX review item 7: identify returns a DEEP COPY, so a caller mutating the result
-- cannot corrupt the shared fixture store reused by a later providers.get('fake').
-- =====================================================================
do
    -- get fake, identify, then DESTRUCTIVELY mutate the returned response.
    local prov1 = providers.get('fake')
    assert_true(prov1 ~= nil, "item 7: first providers.get('fake')")
    local r1 = prov1.identify({ kind = 'bytes', data = "x", width = 1, height = 1 }, {})
    assert_true(contract.validateResponse(r1), "item 7: first result valid")
    -- Corrupt the returned table every way a careless caller might.
    r1.bird_present = "tampered"
    r1.detections[1].bbox = { 9, 9, 9, 9 }
    r1.detections[1].common_name = nil
    r1.detections[1] = nil
    r1.injected = { evil = true }

    -- get fake AGAIN and identify: the fixture must be pristine (mutation did not leak).
    local prov2 = providers.get('fake')
    assert_true(prov2 ~= nil, "item 7: second providers.get('fake')")
    local r2 = prov2.identify({ kind = 'bytes', data = "x", width = 1, height = 1 }, {})
    assert_true(contract.validateResponse(r2),
        "item 7: second result STILL valid after first was mutated")
    assert_eq(r2.bird_present, true, "item 7: bird_present not corrupted by earlier mutation")
    assert_eq(r2.detections[1].common_name, "Northern Cardinal",
        "item 7: detection name not corrupted by earlier mutation")
    assert_eq(r2.injected, nil, "item 7: injected key did not leak into the fixture")

    -- The shared BUILTIN itself must be untouched.
    assert_eq(fake.BUILTIN.default.bird_present, true, "item 7: BUILTIN.default untouched")
    assert_eq(fake.BUILTIN.default.detections[1].common_name, "Northern Cardinal",
        "item 7: BUILTIN.default detection untouched")

    -- Two results from the SAME provider must be independent objects (not the same ref).
    local a = prov2.identify({ kind = 'bytes', data = "x", width = 1, height = 1 }, {})
    local b = prov2.identify({ kind = 'bytes', data = "x", width = 1, height = 1 }, {})
    assert_true(a ~= b, "item 7: each identify returns a fresh copy (distinct tables)")
    a.detections[1].confidence = 0.0
    assert_eq(b.detections[1].confidence, 0.82,
        "item 7: mutating one result does not affect another")
end

-- =====================================================================
-- CODEX MUST-FIX 15: selector returns an identify object WITHOUT touching settings.PROVIDERS.
-- =====================================================================
do
    -- snapshot the catalog size before selecting 'fake'
    local before = #settings.PROVIDERS

    local prov1, e1 = providers.get('fake')
    assert_true(prov1 ~= nil, "providers.get('fake') returns a provider (err=" .. tostring(e1) .. ")")
    assert_true(type(prov1.identify) == 'function', "get('fake') object exposes identify")

    local prov2, e2 = providers.select({ provider = 'fake' })
    assert_true(prov2 ~= nil, "providers.select({provider='fake'}) returns a provider (err=" .. tostring(e2) .. ")")
    assert_true(type(prov2.identify) == 'function', "select('fake') object exposes identify")

    -- 'fake' must NOT have been added to the user-facing catalog.
    assert_eq(#settings.PROVIDERS, before, "selecting 'fake' did not change PROVIDERS size")
    local fakeInCatalog = false
    for _, p in ipairs(settings.PROVIDERS) do
        if p.value == 'fake' then fakeInCatalog = true end
    end
    assert_true(not fakeInCatalog, "'fake' is NOT in settings.PROVIDERS (non-catalog)")
end

-- unknown / nil provider names fail explicitly (no silent fallback to a live provider).
-- NOTE: 'openai' is wired (Plan 05-03). [07-02] 'claude' is now wired too — get('claude', deps)
-- resolves the lazy-required pure provider object (identify + rateLimit). [07-03] 'gemini' is now
-- wired too — get('gemini', deps) resolves the lazy-required pure provider object. A genuinely
-- UNKNOWN name still hard-fails.
do
    local p, e = providers.get('claude', { rateLimit = 2 })
    assert_true(type(p) == 'table' and type(p.identify) == 'function',
        "get('claude', deps) resolves the provider object (lands in 07-02)")
    assert_eq(e, nil, "claude resolves with no error")

    local pg, eg = providers.get('gemini', { rateLimit = 2 })
    assert_true(type(pg) == 'table' and type(pg.identify) == 'function',
        "get('gemini', deps) resolves the provider object (lands in 07-03)")
    assert_eq(eg, nil, "gemini resolves with no error")

    -- a genuinely unknown provider name still hard-fails explicitly.
    local pu, eu = providers.get('totally-unknown')
    assert_eq(pu, nil, "unknown provider rejected")
    assert_true(string.find(eu, 'provider-not-implemented', 1, true) ~= nil, "unknown -> not-implemented err")

    local pn, en = providers.get(nil)
    assert_eq(pn, nil, "get(nil) rejected")
    assert_eq(en, 'no-provider-name', "get(nil) err")

    local ps, es = providers.select("nope")
    assert_eq(ps, nil, "select(non-table) rejected")
    assert_eq(es, 'opts-not-table', "select non-table err")
end

-- =====================================================================
-- CODEX MUST-FIX 22: no network/process primitive in EITHER provider source file.
-- Read the sources and assert none of the forbidden tokens appear.
-- =====================================================================
do
    local function readFile(path)
        local f = io.open(path, 'r')
        assert_true(f ~= nil, "open provider source " .. path)
        local s = f:read('*a')
        f:close()
        return s
    end
    local forbidden = { "LrHttp", "io%.popen", "os%.execute", "curl", "socket" }
    local files = {
        "BirdAID.lrdevplugin/src/providers/fake.lua",
        "BirdAID.lrdevplugin/src/providers/init.lua",
    }
    for _, path in ipairs(files) do
        local src = readFile(path)
        for _, tok in ipairs(forbidden) do
            assert_true(string.find(src, tok) == nil,
                "no '" .. tok .. "' in " .. path)
        end
    end
end
