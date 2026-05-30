-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/birdaid_bootstrap.lua
--
-- Lightroom-Classic-only module-loader shim. Lightroom's built-in `require` CANNOT
-- resolve subdirectory / dotted module names: `require 'src.log'` fails with
-- "Could not load toolkit script: src.log", and manipulating `package.path` does not
-- help (the `package` namespace is restricted in the LrC Lua environment). `dofile`,
-- however, works (it is the documented escape hatch). So this bootstrap installs a
-- global `require` shim that resolves OUR OWN `src.*` modules via dofile against the
-- plugin path (with caching), and delegates every other name to the original require.
--
-- It is loaded by each toolkit entry point (IdentifyBirds.lua, PluginInfoProvider.lua)
-- via `dofile(LrPathUtils.child(_PLUGIN.path, 'birdaid_bootstrap.lua'))` BEFORE any
-- `require 'src...'`. It is idempotent (safe to dofile from multiple entry points).
--
-- This file is LrC-only (uses import / _PLUGIN / dofile) and is never loaded by the
-- pure-Lua CLI test runner — under stock lua, `require 'src.x'` already resolves via the
-- runner's package.path, so the test suite is unaffected.
--
-- Strictly Lua 5.1 common subset.

if _G.__birdaidRequireInstalled then return end

local LrPathUtils = import 'LrPathUtils'
local base        = _PLUGIN.path
local origRequire = _G.require
local cache       = {}

-- Resolve only our own modules (the `src.` prefix covers src.json, src.redact, src.log,
-- src.settings, and src.lib.dkjson). dotted name -> relative path -> absolute dofile.
local function birdaidRequire(name)
    if type(name) == "string" and name:sub(1, 4) == "src." then
        local cached = cache[name]
        if cached ~= nil then return cached end
        local rel  = name:gsub("%.", "/") .. ".lua"
        local full = LrPathUtils.child(base, rel)
        local mod  = dofile(full)
        cache[name] = mod
        return mod
    end
    if origRequire then return origRequire(name) end
    error("require unavailable for: " .. tostring(name))
end

_G.require = birdaidRequire
_G.__birdaidRequireInstalled = true
