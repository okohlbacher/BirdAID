-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/providers/init.lua (provider interface + selector — PURE core)
--
-- PURE module: the only require is the pure src.providers.fake, so it is require-able under
-- stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant). NO network/process primitive here.
--
-- ===========================================================================
-- PROVIDER INTERFACE (SPEC s6)
-- ===========================================================================
-- A provider is an object exposing:
--
--   identify(image, ctx) -> (response_table) | (nil, err)
--
-- where:
--   image = { kind = 'bytes' | 'file',
--             data  = <non-empty string> | nil,   -- when kind == 'bytes'
--             path  = <non-empty string> | nil,    -- when kind == 'file'
--             width  = <finite number > 0>,
--             height = <finite number > 0> }       -- the EXACT decoded frame sent
--   ctx   = the privacy-gated context from metadata.shape (gps?/date?/locationHint?),
--           optionally carrying provider-specific hints (e.g. ctx.fakeFixture).
--   response_table MUST pass contract.validateResponse.
--
-- The live providers (openai/claude/gemini) implement this same interface in Phases 5-7,
-- each handling its own encoding/auth/structured-output and returning the common schema.
-- This file is the EXACT interface + the test/offline selector, defined now.
--
-- CODEX MUST-FIX 15: the fake is a NON-CATALOG provider. 'fake' is intentionally NOT in
-- settings.PROVIDERS (so it never appears in the user-facing dropdown), and this selector
-- does NOT read, add to, or mutate settings.PROVIDERS anywhere. Selecting 'fake' resolves
-- to fake.new(fake.BUILTIN).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.

local fake = require 'src.providers.fake'

local M = {}

-- get(name[, deps]) -> (provider) | (nil, err)
--   Resolves a provider by name to an object exposing identify(image, ctx).
--   'fake' (NON-catalog) -> fake.new(fake.BUILTIN). 'openai' -> openai.new(deps), the pure
--   dependency-injected provider (Plan 05-03): all Lr (httpPost/sleep/token/model/rateLimit/log)
--   is INJECTED via `deps`, so resolving 'openai' stays pure and does NOT touch
--   settings.PROVIDERS (CODEX MUST-FIX 15). The require of src.providers.openai is LAZY (inside
--   this branch) so this selector stays trivially require-able and the openai chain is only
--   pulled in when actually selected. claude/gemini remain not-implemented (Phases 6-7).
function M.get(name, deps)
    if name == 'fake' then
        return fake.new(fake.BUILTIN)
    end
    if name == 'openai' then
        -- Lazy pure require: src.providers.openai imports no Lr (all injected via deps).
        local openai = require 'src.providers.openai'
        return openai.new(deps)
    end
    if name == 'claude' then
        -- [07-01] Lazy pure require: src.providers.claude imports no Lr (all injected via deps).
        -- The provider OBJECT itself lands in 07-02; this is the wave-1 dispatch SEAM. Until the
        -- module exists the pcall-guarded require returns a SPEAKING, token-free pending error
        -- (NOT a raise) so the run degrades cleanly; once 07-02 adds the module it resolves to
        -- claude.new(deps) with no further change here.
        local ok, claude = pcall(require, 'src.providers.claude')
        if not ok or type(claude) ~= 'table' then
            return nil, 'provider-pending:claude'
        end
        return claude.new(deps)
    end
    if name == 'gemini' then
        -- [07-01] Lazy pure require: src.providers.gemini imports no Lr (all injected via deps).
        -- The provider OBJECT itself lands in 07-03; this is the wave-1 dispatch SEAM. Same
        -- pcall-guarded pending behavior as claude above until 07-03 adds the module.
        local ok, gemini = pcall(require, 'src.providers.gemini')
        if not ok or type(gemini) ~= 'table' then
            return nil, 'provider-pending:gemini'
        end
        return gemini.new(deps)
    end
    if name == nil then
        return nil, 'no-provider-name'
    end
    -- Any other (unknown) provider name: fail explicitly rather than silently.
    return nil, 'provider-not-implemented:' .. tostring(name)
end

-- select(opts) -> (provider) | (nil, err)
--   opts.provider names the provider to resolve; opts.deps (optional) is forwarded to get for
--   the dependency-injected catalog providers (e.g. 'openai'). opts.provider == 'fake' returns
--   the fake. This is a NON-catalog hook: it does NOT touch settings.PROVIDERS (CODEX MUST-FIX 15).
function M.select(opts)
    if type(opts) ~= 'table' then
        return nil, 'opts-not-table'
    end
    return M.get(opts.provider, opts.deps)
end

return M
