-- test/manifest_parity_spec.lua (Phase 8 — HARD-03 dev↔release manifest parity)
--
-- [CODEX #10] Guards against MANIFEST DRIFT: tools/Info.release.lua is a hand-kept copy
-- of BirdAID.lrdevplugin/Info.lua minus the six Debug* menu entries. If a future dev
-- manifest change touches a STABLE field (the SDK versions, the LrToolkitIdentifier that
-- scopes the user's Keychain token + prefs, the plugin name, the InfoProvider) or the
-- real "Identify Birds…" menu item, this spec FAILS until the release manifest is updated
-- to match — so the two cannot silently diverge.
--
-- PURE + offline: it loadfile()s both manifest tables (each Info.lua is a plain
-- `return { ... }` Lua chunk that imports no Lr* module) and compares fields. Loaded by
-- test/run.lua via dofile from the repo root, so the manifests are referenced by their
-- repo-relative paths. Strictly Lua 5.1 common subset.

local DEV_PATH     = "BirdAID.lrdevplugin/Info.lua"
local RELEASE_PATH = "tools/Info.release.lua"

local dev_chunk = assert(loadfile(DEV_PATH),
    "dev manifest must load: " .. DEV_PATH)
local rel_chunk = assert(loadfile(RELEASE_PATH),
    "release manifest must load: " .. RELEASE_PATH)
local dev = dev_chunk()
local rel = rel_chunk()

assert_true(type(dev) == "table", "dev manifest returns a table")
assert_true(type(rel) == "table", "release manifest returns a table")

-- ---- STABLE fields must be EQUAL across dev and release ----
-- These define the plugin's identity + load behavior; a dev change that silently failed
-- to propagate to the release would ship a divergent (potentially token-orphaning) build.
assert_eq(rel.LrSdkVersion, dev.LrSdkVersion,
    "LrSdkVersion parity dev↔release")
assert_eq(rel.LrSdkMinimumVersion, dev.LrSdkMinimumVersion,
    "LrSdkMinimumVersion parity dev↔release")
assert_eq(rel.LrToolkitIdentifier, dev.LrToolkitIdentifier,
    "LrToolkitIdentifier parity dev↔release (scopes Keychain token + prefs)")
assert_eq(rel.LrPluginName, dev.LrPluginName,
    "LrPluginName parity dev↔release")
assert_eq(rel.LrPluginInfoProvider, dev.LrPluginInfoProvider,
    "LrPluginInfoProvider parity dev↔release")

-- The identifier is also asserted byte-identical to the locked literal so a rename in
-- BOTH manifests (which would pass the parity check above) still trips here.
assert_eq(rel.LrToolkitIdentifier, "com.okohlbacher.birdaid",
    "release LrToolkitIdentifier is the locked byte-identical literal")
assert_eq(dev.LrToolkitIdentifier, "com.okohlbacher.birdaid",
    "dev LrToolkitIdentifier is the locked byte-identical literal")

-- ---- The real "Identify Birds…" menu item must be present + identical in BOTH ----
-- Find the entry whose file == "IdentifyBirds.lua" in each manifest's LrLibraryMenuItems.
local function findMenuItem(manifest, fileName)
    local items = manifest.LrLibraryMenuItems
    if type(items) ~= "table" then return nil end
    for _, entry in ipairs(items) do
        if type(entry) == "table" and entry.file == fileName then
            return entry
        end
    end
    return nil
end

local devItem = findMenuItem(dev, "IdentifyBirds.lua")
local relItem = findMenuItem(rel, "IdentifyBirds.lua")

assert_true(devItem ~= nil, "dev manifest registers the real IdentifyBirds.lua item")
assert_true(relItem ~= nil, "release manifest registers the real IdentifyBirds.lua item")

assert_eq(relItem.title, devItem.title,
    "real menu item title parity dev↔release")
assert_eq(relItem.enabledWhen, devItem.enabledWhen,
    "real menu item enabledWhen parity dev↔release")
assert_eq(relItem.file, devItem.file,
    "real menu item file parity dev↔release")

-- And the absolute expected values (so a coordinated change in both still trips).
assert_eq(relItem.title, "Identify Birds in Selected Photos…",
    "real menu item title is the locked literal")
assert_eq(relItem.enabledWhen, "photosAvailable",
    "real menu item enabledWhen is 'photosAvailable'")

-- ---- The release manifest must register ONLY the real item — NO Debug* entries ----
local relItems = rel.LrLibraryMenuItems
assert_true(type(relItems) == "table", "release LrLibraryMenuItems is a table")
for _, entry in ipairs(relItems) do
    local f = (type(entry) == "table" and entry.file) or ""
    assert_eq(f:match("^Debug") ~= nil, false,
        "release manifest has NO ^Debug menu entry (got file=" .. tostring(f) .. ")")
end
-- Exactly one menu item in the release (the real one). The dev manifest also carries only
-- the real item now that the temporary Debug* harness entries were stripped for the v0.9 release.
assert_eq(#relItems, 1, "release manifest registers exactly the one real menu item")

-- ---- VERSION set for the current release (bump with each release) ----
assert_true(type(rel.VERSION) == "table", "release VERSION is a table")
assert_eq(rel.VERSION.major, 1, "release VERSION.major is 1 (v1.1.2)")
assert_eq(rel.VERSION.minor, 1, "release VERSION.minor is 1 (v1.1.2)")
assert_eq(rel.VERSION.revision, 2, "release VERSION.revision is 2 (v1.1.2)")
