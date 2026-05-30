-- BirdAID pure-Lua test runner (FND-06)
--
-- Runs OUTSIDE Lightroom under stock `lua` / `lua5.1` / `luajit`. Imports NO Lr*
-- module at load time. Discovers test/*_spec.lua, loads each via dofile, and exits
-- NON-ZERO if any assertion fails OR if zero spec files are discovered (a vacuous
-- green run is forbidden).
--
-- Usage (from the repo root):
--   lua    test/run.lua
--   luajit test/run.lua
--
-- Self-test (proves the non-zero-on-failure wiring is real without leaving a
-- permanently failing spec on disk):
--   BIRDAID_SELFTEST=1 lua test/run.lua      -- env toggle
--   lua test/run.lua --selftest              -- argv toggle
--
-- Strictly Lua 5.1 common subset: no `//`, no `<close>`, no goto, `unpack` is global.

-- (a) Extend package.path to reach into the plugin folder so the dotted requires
--     `src.lib.dkjson`, and later `src.json` / `src.redact`, resolve from repo root.
package.path = package.path
    .. ";./BirdAID.lrdevplugin/?.lua"
    .. ";./BirdAID.lrdevplugin/?/init.lua"

local pass, fail = 0, 0

-- (b) GLOBAL assertion helpers so spec files loaded via dofile can call them.
function assert_eq(a, b, msg)
    if a == b then
        pass = pass + 1
    else
        fail = fail + 1
        io.write(("FAIL: %s (got %s, want %s)\n")
            :format(tostring(msg or ""), tostring(a), tostring(b)))
    end
end

function assert_true(v, msg)
    if v then
        pass = pass + 1
    else
        fail = fail + 1
        io.write(("FAIL: %s (got %s, want truthy)\n")
            :format(tostring(msg or ""), tostring(v)))
    end
end

-- Self-test toggle: env BIRDAID_SELFTEST=1 or argv --selftest. When set, run one
-- deliberately-failing assertion in-process so the exit-code wiring can be proven
-- for real without a permanent failing spec on disk.
local selftest = (os.getenv("BIRDAID_SELFTEST") == "1")
if not selftest and arg then
    local i = 1
    while arg[i] ~= nil do
        if arg[i] == "--selftest" then selftest = true end
        i = i + 1
    end
end

if selftest then
    io.write("running in-process self-test (expect one deliberate failure)\n")
    assert_eq(1, 2, "intentional self-test failure")
end

-- (c) Discover spec files reliably. Stock Lua 5.1 has NO glob/dir API, so enumerate
--     via io.popen("ls ...") and read every line. Skip the literal empty-match case
--     so a no-match `ls` yields an EMPTY list rather than a bogus path.
local specs = {}
local pipe = io.popen("ls test/*_spec.lua 2>/dev/null")
if pipe then
    for line in pipe:lines() do
        -- Skip blanks and the unexpanded glob (some shells echo the pattern itself).
        if line ~= "" and line ~= "test/*_spec.lua" then
            specs[#specs + 1] = line
        end
    end
    pipe:close()
end

-- Load each discovered spec. dofile runs it in the global env where assert_eq /
-- assert_true are visible. Each dofile is wrapped in pcall so a syntax error or a
-- top-level runtime error in one spec is counted as a failure and does NOT abort the
-- run or hide later specs (CODEX gate, Phase 1: "one failing spec doesn't hide others").
for _, path in ipairs(specs) do
    io.write("running " .. path .. "\n")
    local ok, err = pcall(dofile, path)
    if not ok then
        fail = fail + 1
        io.write(("FAIL: spec errored: %s (%s)\n"):format(path, tostring(err)))
    end
end

-- (d) Treat ZERO discovered specs as a FAILURE unless we ran an in-process self-test.
local zero_specs = (#specs == 0) and (not selftest)
if zero_specs then
    io.write("FAIL: no spec files discovered (test/*_spec.lua) -- refusing a vacuous green run\n")
end

-- (e) Summary.
io.write(("\n%d passed, %d failed\n"):format(pass, fail))

-- (f) Exit non-zero if any assertion failed OR zero specs were discovered.
if fail > 0 or zero_specs then
    os.exit(1)
end
os.exit(0)
