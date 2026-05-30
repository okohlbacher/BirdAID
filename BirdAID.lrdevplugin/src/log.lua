-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/log.lua (FND-05)
--
-- The single STRUCTURED logging sink. This is the ONLY file under src/ (besides the
-- vendored src/lib/) that imports an Lr* module: it owns the LrLogger and is the ONLY
-- consumer of redact(). All other src/ code stays pure (separation invariant), and the
-- IdentifyBirds.lua entry routes EVERY log line through here -- it never creates its
-- own LrLogger.
--
-- log.event(level, msg, fields):
--   * level  : "info" | "warn" | "error" | "trace"
--   * msg    : a string message
--   * fields : OPTIONAL table of structured key/values, serialized via the src.json
--              wrapper (NOT bare tostring) so structured context is real, machine-
--              parseable JSON -- not a Lua table address.
-- It composes a single stable line ("[LEVEL] msg | <json-fields>"), applies redact()
-- to the WHOLE composed line (so both the message and every serialized field value are
-- masked) at this single sink, then hands the masked line to LrLogger. Nothing reaches
-- the log file un-redacted.
--
-- Thin convenience wrappers info/warn/error/trace(msg, fields) delegate to log.event so
-- callers never touch the raw logger. No business logic lives here.
--
-- Log file location (verify path against the installed LrC version):
--   LrC 14+  -> ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/BirdAID.log
--   pre-14   -> ~/Documents/LrClassicLogs/ (older documented path)
--
-- Strictly Lua 5.1 common subset.

local LrLogger      = import 'LrLogger'
local LrPathUtils   = import 'LrPathUtils'
local LrApplication = import 'LrApplication'

local json   = require 'src.json'
local redact = require('src.redact').redact

local logger = LrLogger('BirdAID')
logger:enable('logfile')

local M = {}

-- logFilePath() -> best-effort absolute path of the BirdAID log, for showing the user
-- where to look. The location moved in LrC 14, so branch on the running version; default
-- to the 14+ location if the version can't be read. Never raises.
function M.logFilePath()
    local home = "~"
    pcall(function() home = LrPathUtils.getStandardFilePath("home") end)
    local major = 14
    pcall(function() major = LrApplication.versionTable().major end)
    local rel = (major >= 14)
        and "Library/Logs/Adobe/Lightroom/LrClassicLogs/BirdAID.log"  -- LrC 14+
        or  "Documents/LrClassicLogs/BirdAID.log"                     -- pre-14
    local path = home .. "/" .. rel
    pcall(function() path = LrPathUtils.child(home, rel) end)
    return path
end

-- Valid LrLogger levels we expose. Unknown levels fall back to 'info' so a typo never
-- silently drops a line.
local VALID = { info = true, warn = true, error = true, trace = true }

-- Serialize the optional structured fields table to a stable JSON segment. Returns ""
-- when there are no fields (nil/absent table) so the line stays clean. If encoding
-- fails for any reason, degrade to an explicit marker rather than raising.
local function encode_fields(fields)
    if fields == nil then
        return ""
    end
    if type(fields) ~= "table" then
        -- A non-table 'fields' is a caller error; wrap it so it is still structured.
        fields = { value = fields }
    end
    local ok, encoded = pcall(json.encode, fields)
    if ok and type(encoded) == "string" then
        return " | " .. encoded
    end
    return " | {\"_fields_encode_error\":true}"
end

-- log.event(level, msg, fields) -- the single emit path.
-- Best-effort by contract: logging must NEVER throw and abort the run (CODEX gate,
-- Phase 1). The entire compose+redact+emit body is wrapped so a hostile __tostring
-- metamethod, a redact bug, or an LrLogger failure degrades to a swallowed error
-- instead of propagating to the caller.
function M.event(level, msg, fields)
    if not VALID[level] then
        level = "info"
    end
    local ok, safe = pcall(function()
        -- Timestamp every line so support can order events and correlate with a run id.
        -- os.date is Lua 5.1 stdlib and available in LrC; degrade silently if it isn't.
        local ts = ""
        local tok, tval = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if tok and type(tval) == "string" then ts = tval .. " " end
        local line = ts .. "[" .. string.upper(level) .. "] " .. tostring(msg) .. encode_fields(fields)
        -- Redact the FULL composed line at this single sink, before any write.
        local s = redact(line)
        -- Route to the matching LrLogger method (logger:info(...), logger:error(...), ...).
        logger[level](logger, s)
        return s
    end)
    if ok then
        return safe
    end
    -- Last-resort: try to record that logging itself failed, but never raise.
    pcall(function() logger:error("[ERROR] log.event failed (suppressed)") end)
    return nil
end

-- Thin convenience wrappers -- every one delegates to log.event.
function M.info(msg, fields)  return M.event("info",  msg, fields) end
function M.warn(msg, fields)  return M.event("warn",  msg, fields) end
function M.error(msg, fields) return M.event("error", msg, fields) end
function M.trace(msg, fields) return M.event("trace", msg, fields) end

return M
