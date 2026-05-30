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
    VERSION             = { major = 1, minor = 0, revision = 0, build = 0 },

    LrLibraryMenuItems = {
        {
            title       = "Identify Birds in Selected Photos…",
            file        = "IdentifyBirds.lua",
            enabledWhen = "photosAvailable",
        },
    },

    LrPluginInfoProvider = "PluginInfoProvider.lua",
}
