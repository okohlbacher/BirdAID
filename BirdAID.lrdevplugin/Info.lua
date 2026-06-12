-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/Info.lua (FND-01)
--
-- The plugin manifest Lightroom Classic reads at load time. It registers a single
-- gated command under Library > Plug-in Extras:
--   "Identify Birds in Selected Photos..."
-- enabled only when photos are AVAILABLE (enabledWhen = "photosAvailable") and routed
-- to IdentifyBirds.lua (the async harness entry point).
--
-- LrPluginInfoProvider = "PluginInfoProvider.lua" registers the Phase 2 settings UI
-- (provider/model/prompt config in LrPrefs + the Keychain-backed API token via
-- LrPasswords). Manifest changes do NOT hot-reload; remove + re-add the .lrdevplugin
-- folder in Plug-in Manager after editing this file (a plain Reload will NOT pick up
-- the new InfoProvider registration).

return {
    LrSdkVersion        = 14.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = "com.okohlbacher.birdaid",
    LrPluginName        = "BirdAID",
    VERSION             = { major = 1, minor = 1, revision = 2, build = 0 },

    -- NOTE: editing this manifest does NOT hot-reload. After changing LrLibraryMenuItems
    -- (e.g. adding the deep command), REMOVE + RE-ADD the .lrdevplugin folder in Plug-in
    -- Manager — a plain Reload will NOT register the new menu item (surfaced in the 13-05
    -- live-verification checkpoint).
    LrLibraryMenuItems = {
        {
            title       = "Identify Birds in Selected Photos…",
            file        = "IdentifyBirds.lua",
            enabledWhen = "photosAvailable",
        },
        -- D-04: the always-available manual "Deep identify…" command — the full-res evidence
        -- pass (export -> upload/inline -> identify -> provider-copy cleanup). The SC1
        -- export-concurrency spike is a pref-guarded path INSIDE DeepIdentify.lua, so there is
        -- NO dev-harness menu entry here (the recursive dist gate stays clean on Info.lua).
        {
            title       = "Deep identify…",
            file        = "DeepIdentify.lua",
            enabledWhen = "photosAvailable",
        },
    },

    LrPluginInfoProvider = "PluginInfoProvider.lua",
}
