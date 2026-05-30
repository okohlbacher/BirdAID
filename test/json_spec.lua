-- test/json_spec.lua (FND-04)
--
-- Exercises BirdAID.lrdevplugin/src/json.lua: a pure thin wrapper over the vendored
-- dkjson. The decode contract is keyed on dkjson's OWN error signal (NOT value==nil),
-- so valid JSON `null` is a SUCCESS and malformed JSON is a FAILURE that never raises.
--
-- Loaded by test/run.lua via dofile; uses the runner's global assert_eq / assert_true.
-- Strictly Lua 5.1 common subset.

local json = require('src.json')

-- (1) Round-trip: a scalar field and a nested array element both survive.
local enc = json.encode({ a = 1, b = { "x", "y" } })
assert_true(type(enc) == "string", "encode yields a JSON string")
local ok, dec = json.decode(enc)
assert_eq(ok, true, "round-trip decode ok")
assert_eq(dec.a, 1, "round-trip preserves scalar a.x")
assert_eq(dec.b[2], "y", "round-trip preserves nested array element b[2]")

-- (2) Decoding a JSON object yields a Lua table whose keys match.
local ok2, obj = json.decode('{"name":"cardinal","present":true}')
assert_eq(ok2, true, "object decode ok")
assert_eq(obj.name, "cardinal", "object decode key 'name'")
assert_eq(obj.present, true, "object decode key 'present'")

-- (3) decode("null") is a SUCCESS (value may legitimately be nil or the null sentinel),
--     NOT a failure. Success is keyed on the ABSENCE of a dkjson error.
local oknull, valnull, errnull = json.decode("null")
assert_eq(oknull, true, "decode('null') is ok=true (valid JSON null is success)")
assert_eq(errnull, nil, "decode('null') carries no error")

-- (4) Malformed JSON returns ok=false with a non-nil error string and does NOT raise.
--     Use pcall to prove decode itself never throws.
local called_ok, oknbad, valbad, errbad = pcall(json.decode, "{bad")
assert_eq(called_ok, true, "decode does not raise on malformed input")
assert_eq(oknbad, false, "malformed decode is ok=false")
assert_true(type(errbad) == "string", "malformed decode carries a non-nil error string")
assert_eq(valbad, nil, "malformed decode value is nil")
