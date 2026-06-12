-- test/run_id_spec.lua (Wave-D D8 — single-source run-id minting)
--
-- Exercises BirdAID.lrdevplugin/src/run_id.lua: a PURE module hoisting newRunId (formerly duplicated
-- byte-for-byte in IdentifyBirds.lua and DeepIdentify.lua). The id seeds the per-run scratch dir
-- name, so its FORMAT (sanitize-safe, no '.') and its UNIQUENESS (monotonic counter) are load-bearing.
-- The fractional LrDate clock is INJECTED, so this runs under stock lua / luajit with a fake clock.
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local runId = require('src.run_id')
local sweep = require('src.crop.sweep')

assert_true(type(runId) == 'table', "require 'src.run_id' resolves")
assert_true(type(runId.newRunId) == 'function', "exposes newRunId")

-- ---- format stability: "<secs>-<frac>-<counter>", ONLY [%w-_], NO '.' ----
do
    local id = runId.newRunId(function() return 1234.5678 end)
    assert_true(type(id) == 'string' and id ~= '', "newRunId returns a non-empty string")
    -- The three '-'-joined parts.
    local a, b, c = id:match("^(%d+)%-(%d+)%-(%d+)$")
    assert_true(a ~= nil and b ~= nil and c ~= nil, "id matches <secs>-<frac>-<counter> (all digits)")
    assert_eq(id:find('.', 1, true), nil, "id contains NO '.' (sweep.sanitizeRunId would reject it)")
end

-- ---- sanitize-safe: every minted id is accepted by sweep.sanitizeRunId UNCHANGED ----
do
    -- across a battery of clocks (incl. an absent / throwing / NaN clock -> frac '0').
    local clocks = {
        function() return 0.0 end,
        function() return 9999.9999 end,
        function() return 0 / 0 end,          -- NaN -> frac '0'
        function() error("boom") end,         -- throwing -> frac '0'
        nil,                                  -- absent clock -> frac '0'
        function() return "not a number" end, -- non-number -> frac '0'
    }
    for i = 1, 6 do
        local id = runId.newRunId(clocks[i])
        assert_eq(sweep.sanitizeRunId(id), id,
            "minted id is sanitize-safe and passes through sweep.sanitizeRunId unchanged (clock " .. i .. ")")
    end
end

-- ---- monotonic counter: the trailing counter strictly increases across calls ----
do
    local function counterOf(id) return tonumber(id:match("%-(%d+)$")) end
    local id1 = runId.newRunId(function() return 1.0 end)
    local id2 = runId.newRunId(function() return 1.0 end)
    local id3 = runId.newRunId(function() return 1.0 end)
    local c1, c2, c3 = counterOf(id1), counterOf(id2), counterOf(id3)
    assert_true(c2 == c1 + 1, "counter increments by 1 between consecutive calls")
    assert_true(c3 == c2 + 1, "counter keeps incrementing (monotonic, module-scoped)")
    -- Even with an IDENTICAL clock the ids differ (the counter is the disambiguator).
    assert_true(id1 ~= id2 and id2 ~= id3, "same-clock ids are DISTINCT (counter disambiguates)")
end

-- ---- never raises ----
do
    assert_true(pcall(runId.newRunId), "newRunId never raises (no clock)")
    assert_true(pcall(runId.newRunId, function() return 5.5 end), "newRunId never raises (clock)")
    assert_true(pcall(runId.newRunId, function() error("x") end), "newRunId never raises (throwing clock)")
end
