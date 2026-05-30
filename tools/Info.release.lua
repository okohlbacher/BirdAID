-- SPDX-License-Identifier: MIT
-- tools/Info.release.lua (Phase 8 — HARD-03 release manifest)
--
-- The BUILD-TIME release manifest. tools/build.sh copies this file over
-- dist/BirdAID.lrplugin/Info.lua, replacing the dev manifest (BirdAID.lrdevplugin/Info.lua)
-- so the shipped package registers ONLY the real "Identify Birds in Selected Photos…"
-- command — NONE of the six TEMPORARY dev-harness entry points the dev manifest carries.
--
-- NOTE: this file is itself swapped into the dist and must survive the build's recursive
-- dev-harness-token gate (tools/build.sh step 6b), so its comments deliberately avoid the
-- literal D-e-b-u-g token that the gate forbids anywhere in the shipped package.
--
-- CRITICAL — LrToolkitIdentifier MUST stay byte-identical to the dev manifest
-- ("com.okohlbacher.birdaid"). It scopes the user's macOS Keychain API token
-- (LrPasswords) AND their LrPrefs settings. Changing it ORPHANS the user's stored key
-- and preferences when they switch from the dev .lrdevplugin to the installed .lrplugin.
-- NEVER change this identifier. Only bump VERSION between releases.
--
-- The STABLE fields here (LrSdkVersion, LrSdkMinimumVersion, LrToolkitIdentifier,
-- LrPluginName, LrPluginInfoProvider) and the real menu item (title/file/enabledWhen)
-- are asserted to match the dev manifest by tools/manifest_parity_spec.lua, so a dev
-- manifest change can never silently drift the release manifest.

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
