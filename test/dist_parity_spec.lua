-- test/dist_parity_spec.lua (Phase 8 — HARD-03 dist ↔ isDevOnly parity)
--
-- [CODEX #8] Asserts the BUILT dist tree (dist/BirdAID.lrplugin, produced by
-- tools/build.sh) agrees with the PURE exclusion truth (tools/build_manifest.lua):
-- EVERY file that was shipped must be classified isDevOnly==false. The build's exclusions
-- and the pure helper are thereby kept in agreement, so a future
-- BirdAID.lrdevplugin/test/... dev file would either be excluded by the build OR fail this
-- parity spec — it can never silently ship.
--
-- The spec SKIPS gracefully when dist/BirdAID.lrplugin does not exist (it is only
-- meaningful after a build); tools/build.sh's verify step runs the build first, then
-- re-runs the suite so this spec executes against a fresh dist.
--
-- [CODEX #N2] This is a BUILD-TIME GATE. A no-op (SKIP) run WITHOUT a dist is acceptable
-- BECAUSE tools/build.sh now ENFORCES the same parity itself (per CODEX #1/#4): build.sh
-- walks the freshly-built dist tree and fails the build on ANY shipped file that is
-- isDevOnly==true via this exact helper, AND runs this spec (and manifest_parity_spec) as
-- a build gate. So packaging drift is caught by `bash tools/build.sh` ALONE — this spec is
-- the redundant in-suite assertion, not the sole line of defense.
--
-- It also asserts (always, build-independent) that the helper IS the exclusion authority:
-- a synthetic nested test/ path and a Debug leaf are isDevOnly==true.
--
-- io.popen('find') is acceptable here: this is a dev-only test file (never shipped), and
-- the runner itself already enumerates specs via io.popen. Strictly Lua 5.1 common subset.

local bm = dofile("tools/build_manifest.lua")

-- ---- ALWAYS: the helper truly is the exclusion authority (no build needed) ----
-- A synthetic nested dev file inside the plugin folder is dev-only (test/ segment rule).
assert_true(bm.isDevOnly("BirdAID.lrdevplugin/test/foo_spec.lua"),
    "synthetic nested BirdAID.lrdevplugin/test/foo_spec.lua is dev-only")
-- A Debug leaf is dev-only (leaf-prefix rule).
assert_true(bm.isDevOnly("BirdAID.lrdevplugin/DebugX.lua"),
    "synthetic DebugX.lua leaf is dev-only")
-- And a real shipped source is NOT dev-only (the converse, so the helper isn't trivially true).
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/lr/catalog_writer.lua"), false,
    "a real shipped src file is NOT dev-only")

-- ---- Locate the built dist (skip if absent) ----
local DIST = "dist/BirdAID.lrplugin"

local function distExists()
    -- `test -d` exits 0 when the directory exists; capture that via io.popen.
    local p = io.popen('test -d "' .. DIST .. '" && echo yes || echo no')
    if not p then return false end
    local out = p:read("*l")
    p:close()
    return out == "yes"
end

if not distExists() then
    io.write("dist_parity_spec: dist/BirdAID.lrplugin not present — SKIP "
        .. "(meaningful only after tools/build.sh)\n")
    -- Count a passing assertion so a skipped run is still visibly green, not vacuous.
    assert_true(true, "dist_parity_spec skipped (no dist) — helper-authority checks ran")
    return
end

-- ---- Enumerate EVERY file in the built dist and assert each is NOT dev-only ----
-- find prints paths like "./Info.lua", "./src/lr/catalog_writer.lua". The pure helper
-- keys on the plugin-relative vocabulary, so we map each leaf-relative path to its
-- BirdAID.lrdevplugin/<rel> equivalent before classifying.
local checked = 0
local pipe = io.popen('cd "' .. DIST .. '" && find . -type f 2>/dev/null')
assert_true(pipe ~= nil, "find over the dist tree opened")
if pipe then
    for line in pipe:lines() do
        if line ~= "" then
            -- Strip a leading "./" then re-root under the dev plugin folder name.
            local rel = line:gsub("^%./", "")
            local devRel = "BirdAID.lrdevplugin/" .. rel
            assert_eq(bm.isDevOnly(devRel), false,
                "shipped dist file is NOT dev-only per build_manifest: " .. rel)
            checked = checked + 1
        end
    end
    pipe:close()
end

-- A built dist must contain real files; a zero-file dist would be a broken build.
assert_true(checked > 0,
    "the built dist contains at least one shipped file (checked " .. checked .. ")")
