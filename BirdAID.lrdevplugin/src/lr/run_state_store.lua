-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/run_state_store.lua (Phase 12 — RETRY-01 cross-session persistence glue)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and is one of the few modules
-- ALLOWED to touch the Lightroom SDK (LrPrefs.prefsForPlugin, photo:getRawMetadata('uuid')). It is
-- NOT a pure module and is intentionally EXCLUDED from the negative-purity grep gate (which scopes
-- only the pure src/ modules). It is loaded only by a live in-Lightroom entry point AFTER
-- birdaid_bootstrap.lua has installed the require shim. The PURE shape + OUTCOME taxonomy + the
-- serialize/deserialize projection live in src.run_state (Plan 02); this layer only persists/loads
-- that already-secret-free { photoId, outcome } shape across LrC sessions.
--
-- PERSISTENCE SCOPE (Task-1 decision, RESEARCH Open Q1 — confirmed): LrPrefs.prefsForPlugin (the
-- GLOBAL per-plugin store), for symmetry with the existing key prefs and a single store (RESEARCH
-- A1). The run-state is global across catalogs; a multi-catalog user shares one incomplete-set — an
-- accepted tradeoff for v1 (the alternative, catalog:setPropertyForPlugin, is deferred).
--
-- STABLE ID (LOCKED — CODEX HIGH-4, NOT a choice): M.stableIdFor(photo) derives the session-stable
-- id from a pcall-wrapped photo:getRawMetadata('uuid') (defensive, never raises). It returns the
-- uuid string when present and non-empty, otherwise nil (NON-RESUMABLE). It MUST NOT fall back to a
-- raw filesystem path: a path is PII (the run-state is asserted path-free) AND a path COLLAPSES
-- virtual copies of one master onto a single id (distinct virtual copies share the master's path),
-- corrupting per-photo resume. A photo with no uuid is simply not persisted (excluded from retry).
--
-- SECRETS / PII (T-12-08 / T-12-08b): the persisted value is ONLY the run_state.serialize
-- { photoId, outcome } array — NEVER a token, an AI response body, a raw per-photo status, GPS
-- coordinates, a capture date, or a file path. The photoId IS the uuid string, used purely as a map
-- key / return value; it is NEVER written to a log line. Logs carry only structured token-free
-- fields (runId + a record COUNT) through the single require 'src.log' sink (NEVER a new LrLogger).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global. MUST run from
-- within an LrTasks task only where the SDK calls require it (prefs access is synchronous).

-- Guarded import so the module LOADS under stock lua/luajit for offline tests (where `import` is
-- absent): then the prefs accessor is INJECTED by the spec (M.save/M.load/M.clear take an optional
-- deps.prefs). Under LrC `import` resolves and the default prefs store is used.
local ok_, LrPrefs = pcall(function() return import 'LrPrefs' end)
if not ok_ then LrPrefs = nil end

local run_state = require 'src.run_state'
local log = require 'src.log'

local M = {}

-- The fixed prefs key under which the serialized run-state array is stored. A single key (no per-run
-- fan-out) — each run REPLACES the prior incomplete-set so load() always returns the latest run.
local STATE_KEY = 'retryRunState'

-- resolvePrefs(deps): the injected prefs table (offline spec) or the real LrPrefs.prefsForPlugin
-- store (LrC). Returns nil when neither is available (degrades safely).
local function resolvePrefs(deps)
    if type(deps) == 'table' and type(deps.prefs) == 'table' then
        return deps.prefs
    end
    if LrPrefs and type(LrPrefs.prefsForPlugin) == 'function' then
        local ok, p = pcall(function() return LrPrefs.prefsForPlugin() end)
        if ok and type(p) == 'table' then return p end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- stableIdFor(photo) -> uuid string | nil
-- The session-stable per-photo id. Defensive: a nil photo, a non-photo, or a throwing
-- getRawMetadata('uuid') yields nil (NON-RESUMABLE) rather than raising — and NEVER a path.
-- ---------------------------------------------------------------------------
function M.stableIdFor(photo)
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return nil
    end
    local ok, uuid = pcall(function() return photo:getRawMetadata('uuid') end)
    if ok and type(uuid) == 'string' and uuid ~= '' then
        return uuid
    end
    -- No uuid (or the accessor threw): NON-RESUMABLE. NEVER fall back to a path (PII +
    -- virtual-copy collapse — CODEX HIGH-4).
    return nil
end

-- ---------------------------------------------------------------------------
-- save(runId, records[, deps]) -> boolean
-- records carry { photoId, outcome } (photoId may be nil for a NON-RESUMABLE photo). DROP any record
-- whose photoId is nil, run_state.serialize the rest (which strips to exactly { photoId, outcome }
-- and drops malformed records), then persist the plain-data array under STATE_KEY. Best-effort: a
-- missing store or a throwing assignment is logged token-free and returns false (never raises).
-- ---------------------------------------------------------------------------
function M.save(runId, records, deps)
    local prefs = resolvePrefs(deps)
    if prefs == nil then
        log.warn("run-state save skipped (no prefs store)", { runId = runId })
        return false
    end

    -- Drop NON-RESUMABLE (nil photoId) records BEFORE serialize so they are never persisted.
    local resumable = {}
    if type(records) == 'table' then
        for i = 1, #records do
            local r = records[i]
            if type(r) == 'table' and r.photoId ~= nil then
                resumable[#resumable + 1] = r
            end
        end
    end

    local serialized = run_state.serialize(resumable)

    -- The assignment to a prefs key can yield/throw under some SDK conditions; guard it. We log only
    -- the COUNT — never a photoId/uuid value.
    local ok = pcall(function() prefs[STATE_KEY] = serialized end)
    if not ok then
        log.warn("run-state save failed (non-fatal)", { runId = runId, reason = 'prefs-write-failed' })
        return false
    end

    log.info("run-state saved", { runId = runId, records = #serialized })
    return true
end

-- ---------------------------------------------------------------------------
-- load([deps]) -> { { photoId, outcome }, ... }
-- Read the persisted array + run_state.deserialize it (which rebuilds the secret-free shape and
-- drops malformed records). pcall-wrapped: a missing store or a throwing read degrades to {} without
-- raising.
-- ---------------------------------------------------------------------------
function M.load(deps)
    local prefs = resolvePrefs(deps)
    if prefs == nil then
        return {}
    end
    local ok, raw = pcall(function() return prefs[STATE_KEY] end)
    if not ok then
        log.warn("run-state load failed (non-fatal)", { reason = 'prefs-read-failed' })
        return {}
    end
    return run_state.deserialize(raw)
end

-- ---------------------------------------------------------------------------
-- clear([deps]) -> boolean
-- Drop the persisted run-state on a fully successful run (nothing left to retry). Best-effort.
-- ---------------------------------------------------------------------------
function M.clear(deps)
    local prefs = resolvePrefs(deps)
    if prefs == nil then
        return false
    end
    local ok = pcall(function() prefs[STATE_KEY] = nil end)
    if not ok then
        log.warn("run-state clear failed (non-fatal)", { reason = 'prefs-clear-failed' })
        return false
    end
    log.info("run-state cleared (fully successful run)", {})
    return true
end

return M
