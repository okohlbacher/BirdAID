-- test/build_manifest_spec.lua (Phase 8 — HARD-03 build-exclusion decision)
--
-- Exercises tools/build_manifest.lua: a PURE module (no Lr, no filesystem I/O) that
-- DECIDES which relative paths are dev-only (excluded from the shipped .lrplugin) vs
-- shipped sources. The actual copy is the shell script in 08-04; this is just the rule,
-- so it is unit-testable from repo root without a tree walk. The build script (CODEX #8)
-- and its parity test consume this truth.
--
-- Loaded by test/run.lua via dofile (which runs from the repo root); the spec itself
-- dofile's the helper by its repo-relative path. Strictly Lua 5.1 common subset.

local bm = dofile("tools/build_manifest.lua")

-- ---- DEV-ONLY (excluded): all six Debug*.lua leaves (leaf-prefix match, not a count) ----
local debug_leaves = {
    "BirdAID.lrdevplugin/DebugPreviewMeta.lua",
    "BirdAID.lrdevplugin/DebugWriteKeywords.lua",
    "BirdAID.lrdevplugin/DebugIdentifyOpenAI.lua",
    "BirdAID.lrdevplugin/DebugCropIdentify.lua",
    "BirdAID.lrdevplugin/DebugIdentifyClaude.lua",
    "BirdAID.lrdevplugin/DebugIdentifyGemini.lua",
}
for _, p in ipairs(debug_leaves) do
    assert_true(bm.isDevOnly(p), "Debug*.lua leaf is dev-only: " .. p)
end

-- A hypothetical FUTURE Debug file (any count) is also dev-only via the leaf prefix.
assert_true(bm.isDevOnly("BirdAID.lrdevplugin/DebugSomethingNew.lua"),
    "any future Debug*.lua leaf is dev-only (leaf-prefix, not a hardcoded count)")

-- ---- DEV-ONLY (excluded): dev dirs + repo cruft ----
assert_true(bm.isDevOnly(".planning/STATE.md"),     ".planning/ is dev-only")
assert_true(bm.isDevOnly("test/run.lua"),           "test/ is dev-only")
assert_true(bm.isDevOnly("test/platform_spec.lua"), "test/ spec is dev-only")
assert_true(bm.isDevOnly("tools/build.sh"),         "tools/ is dev-only")
assert_true(bm.isDevOnly("tools/build_manifest.lua"), "tools/ helper itself is dev-only")
assert_true(bm.isDevOnly(".git/config"),            ".git/ is dev-only")
assert_true(bm.isDevOnly("CLAUDE.md"),              "CLAUDE.md is dev-only")
assert_true(bm.isDevOnly(".DS_Store"),              ".DS_Store is dev-only")
assert_true(bm.isDevOnly("BirdAID.lrdevplugin/.DS_Store"),
    "nested .DS_Store is dev-only")

-- NESTED dev-file case (CODEX #8): a stray test/ INSIDE the plugin folder must still be
-- classified dev-only by the test/ segment rule, so the build can't ship it.
assert_true(bm.isDevOnly("BirdAID.lrdevplugin/test/foo.lua"),
    "a nested BirdAID.lrdevplugin/test/... file is dev-only (test/ segment rule)")

-- ---- SHIPPED (NOT dev-only): the real plugin sources ----
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/Info.lua"), false,
    "Info.lua ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/IdentifyBirds.lua"), false,
    "IdentifyBirds.lua ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/PluginInfoProvider.lua"), false,
    "PluginInfoProvider.lua ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/birdaid_bootstrap.lua"), false,
    "birdaid_bootstrap.lua ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/platform.lua"), false,
    "src/platform.lua ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/lr/catalog_writer.lua"), false,
    "src/lr/* ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/providers/openai.lua"), false,
    "src/providers/* ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/crop/cropcmd.lua"), false,
    "src/crop/* ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/net/backoff.lua"), false,
    "src/net/* ships")
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/lib/dkjson.lua"), false,
    "src/lib/dkjson.lua ships")

-- A non-Debug source file whose name merely CONTAINS 'Debug' mid-leaf is NOT dev-only
-- (the rule is a leaf PREFIX 'Debug' + '.lua' suffix, not a substring).
assert_eq(bm.isDevOnly("BirdAID.lrdevplugin/src/NotDebugThing.lua"), false,
    "leaf with 'Debug' NOT at the start ships (prefix rule, not substring)")

-- ---- isExcludedDir helper: directory-segment classification ----
assert_true(bm.isExcludedDir(".planning/phases"), ".planning is an excluded dir")
assert_true(bm.isExcludedDir("test/fixtures"),    "test is an excluded dir")
assert_true(bm.isExcludedDir(".git/refs/heads"),  ".git is an excluded dir")
assert_true(bm.isExcludedDir("tools"),            "tools is an excluded dir")
assert_eq(bm.isExcludedDir("BirdAID.lrdevplugin/src"), false,
    "src under the plugin is NOT an excluded dir")
