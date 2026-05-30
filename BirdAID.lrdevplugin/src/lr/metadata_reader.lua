-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/metadata_reader.lua (META-01 live half)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the
-- Lightroom SDK (it calls photo:getRawMetadata / photo:getFormattedMetadata). It is
-- NOT a pure module and is intentionally EXCLUDED from the negative-purity grep gate
-- (which scopes only the pure src/ modules: contract/preview/metadata/prompt/providers).
-- It is loaded only by a live in-Lightroom entry point (the real per-photo pipeline)
-- AFTER birdaid_bootstrap.lua has installed the require shim.
--
-- read(photo) -> raw, where raw is the exact shape src.metadata.shape consumes:
--     raw = {
--       gps     = photo:getRawMetadata('gps'),            -- {latitude,longitude} | nil
--       dateRaw = photo:getRawMetadata('dateTimeOriginal')-- number (Cocoa epoch) | nil
--                 or photo:getRawMetadata('dateTimeDigitized')
--                 or photo:getRawMetadata('dateTime'),
--       path    = photo:getRawMetadata('path'),           -- string
--     }
-- It does NOT shape, gate, or normalize anything — ALL of that (privacy toggles, NaN/inf
-- rejection, Cocoa->UTC date, gps precedence, sanitizePathHint) lives in the PURE
-- require('src.metadata').shape called at the call site. This keeps the only Lr work
-- here a set of dumb getRawMetadata reads.
--
-- LOGGING / PII: this file does not create its own LrLogger; if it ever logs it MUST use
-- the single require 'src.log' sink. The raw GPS / date / path values it returns are PII
-- and MUST NEVER be logged anywhere — only the FORMATTED filename
-- (photo:getFormattedMetadata('fileName')) is loggable, and redaction at the sink is the
-- backstop. A formattedFileName(photo) helper is exported for callers that need a safe,
-- loggable subject.
--
-- Strictly Lua 5.1 common subset. MUST run inside an LrTasks task (getRawMetadata is an
-- SDK call); the caller (entry/pipeline) owns the task + per-photo LrTasks.pcall isolation.

local M = {}

-- read(photo) -> raw table for src.metadata.shape. Never raises on a nil photo (returns
-- an all-nil raw table so shape can fail closed). The dateRaw fallback chain matches
-- 03-RESEARCH Pattern 1 / Assumption A6 (dateTimeOriginal may be nil on some files).
-- rawField(photo, key) -> the value of photo:getRawMetadata(key), or nil if the accessor
-- is missing OR THROWS. CODEX review item 6: a single throwing accessor (e.g. an SDK that
-- errors on 'dateTimeOriginal' for a given file) must NOT abort read() — each field is read
-- independently under pcall and a failure yields nil for that field only. Pure: no Lr import.
local function rawField(photo, key)
    local ok, value = pcall(function() return photo:getRawMetadata(key) end)
    if ok then return value end
    return nil
end

function M.read(photo)
    if type(photo) ~= 'userdata' and type(photo) ~= 'table' then
        return { gps = nil, dateRaw = nil, path = nil }
    end
    -- Each getRawMetadata call is guarded (review item 6): a throwing accessor on one
    -- field leaves that field nil while the others are still read, and read() always
    -- returns a table so the downstream pure shaper can fail closed.
    local gps     = rawField(photo, 'gps')
    local dateRaw = rawField(photo, 'dateTimeOriginal')
                 or rawField(photo, 'dateTimeDigitized')
                 or rawField(photo, 'dateTime')
    local path    = rawField(photo, 'path')
    return { gps = gps, dateRaw = dateRaw, path = path }
end

-- formattedFileName(photo) -> a safe, loggable filename string (NEVER the raw path).
-- Best-effort: never raises, returns "(unknown file)" if the SDK call fails. Use this as
-- the `file` field in any log line about a photo (CODEX MUST-FIX 18).
function M.formattedFileName(photo)
    local name
    pcall(function() name = photo:getFormattedMetadata('fileName') end)
    return name or "(unknown file)"
end

return M
