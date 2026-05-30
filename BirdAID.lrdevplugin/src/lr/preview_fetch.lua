-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/lr/preview_fetch.lua (PREV-01 live half)
--
-- THIN Lr-GLUE adapter. This file lives in the src/lr/ glue tier and MAY touch the
-- Lightroom SDK (LrTasks, LrDate, photo:requestJpegThumbnail). It is NOT pure and is
-- intentionally EXCLUDED from the negative-purity grep gate (which scopes only the pure
-- src/ modules). It is loaded only by an entry point AFTER birdaid_bootstrap.lua has
-- installed the require shim.
--
-- fetch(photo, maxEdge, opts) -> transport | (nil, reason)
--   transport = { kind='bytes', data=<jpeg bytes>, width=<int>, height=<int> }
--   reason    = 'failed' | 'timeout' | 'cancelled' | 'bad-preview-dims'
--
-- It implements 03-RESEARCH Pattern 3, hardened per CODEX, and delegates ALL decision
-- logic to the pure src.preview state machine (newState/onCallback/decide) + the pure
-- parseJpegDims. The ONLY Lr work here is: issue the async requestJpegThumbnail, hold the
-- request ref, and drive a cooperative LrTasks wait loop feeding the pure machine
-- elapsed-ms (wall clock) + a cancel signal + the callback events.
--
-- CODEX hardening folded in:
--   * MUST-FIX 2 (opts/cancel guard): opts = opts or {}; the cancel hook is ALWAYS called
--     through pcall so an absent or throwing isCanceled() can never crash the fetch.
--   * MUST-FIX 16 (ref lifetime + dedupe): HOLD `req` for the ENTIRE poll loop and release
--     it (req = nil) ONLY AFTER a TERMINAL verdict (ready|failed|timeout|cancelled) — NOT
--     merely "until the callback fires", because timeout/cancel may precede any callback.
--     onCallback dedupes (status guard) so a multi-fire callback is captured idempotently.
--   * MUST-FIX 17 (wall clock): elapsed time comes from a WALL-CLOCK source
--     (LrDate.currentTime() seconds if available, else os.time()), NEVER os.clock (CPU
--     time barely advances during LrTasks.sleep, so a clock-based timeout would never fire
--     and the task would hang).
--   * MUST-FIX 3 (fail closed on bad dims): on 'ready', if parseJpegDims returns nil we log
--     the parser error and return nil,'bad-preview-dims' — we NEVER build a transport with
--     nil dims.
--   * MUST-FIX 18 (PII): the `file` field in every log line is the FORMATTED filename
--     (getFormattedMetadata 'fileName'), NEVER the raw path; gps/date are never logged.
--
-- The timeout is MANDATORY. fetch() MUST run inside an LrTasks task (it sleeps/yields);
-- the caller (entry/pipeline) owns the task + per-photo LrTasks.pcall isolation. A
-- non-ready verdict returns nil + reason so the caller skips this photo and the run
-- continues (per-photo isolation), never aborting.
--
-- Strictly Lua 5.1 common subset.

local LrTasks = import 'LrTasks'

-- LrDate is the preferred wall-clock source (LrDate.currentTime() = seconds since the
-- Cocoa epoch, advances in real time). Import defensively: if it is somehow unavailable
-- we fall back to os.time(). NEVER use os.clock (CPU time).
local LrDate
pcall(function() LrDate = import 'LrDate' end)

local preview = require 'src.preview'
local log     = require 'src.log'

local M = {}

-- Default poll interval (seconds) and default timeout (ms). The timeout default mirrors
-- src.preview.newState's 8000ms; callers may override via opts.timeoutMs.
local POLL_SECONDS  = 0.05
local DEFAULT_TIMEOUT_MS = 8000

-- wallClockSeconds() -> a monotonically-advancing real-time seconds value (NOT CPU time).
-- LrDate.currentTime() when available (real wall clock during LrTasks.sleep), else os.time
-- (1s granularity, still real time — adequate as a fallback safety net).
local function wallClockSeconds()
    if LrDate and LrDate.currentTime then
        local ok, t = pcall(LrDate.currentTime)
        if ok and type(t) == 'number' then return t end
    end
    return os.time()
end

-- safeCancelled(opts) -> boolean. CODEX MUST-FIX 2: an absent/throwing isCanceled() must
-- never crash the fetch — wrap the hook in pcall and treat any failure/absence as "not
-- cancelled".
local function safeCancelled(opts)
    local okc, cancelled = pcall(function()
        return opts.isCanceled and opts.isCanceled() or false
    end)
    return (okc and cancelled) or false
end

-- fetch(photo, maxEdge, opts) -> { kind='bytes', data, width, height } | (nil, reason)
--   opts (optional) = {
--     isCanceled = function() -> boolean,   -- e.g. function() return progress:isCanceled() end
--     timeoutMs  = <number>,                -- override the 8000ms default
--     file       = <string>,                -- pre-computed FORMATTED filename for logs (loggable)
--     runId      = <string>,                -- run correlation id for logs
--   }
function M.fetch(photo, maxEdge, opts)
    opts = opts or {}                                  -- MUST-FIX 2
    local timeoutMs = type(opts.timeoutMs) == 'number' and opts.timeoutMs or DEFAULT_TIMEOUT_MS
    local file      = type(opts.file) == 'string' and opts.file or '(unknown file)'
    local runId     = opts.runId

    local st = preview.newState(timeoutMs)

    -- Issue the async request. The pure onCallback dedupes multi-fire callbacks (MUST-FIX
    -- 16) and records (nil,err) as a 'failed' status.
    local req = photo:requestJpegThumbnail(maxEdge, maxEdge, function(jpeg, err)
        preview.onCallback(st, jpeg, err)
    end)

    local startedAt = wallClockSeconds()

    -- Cooperative poll loop. `req` is HELD for the entire loop and released ONLY after a
    -- terminal verdict (MUST-FIX 16) — even if the callback never fires (the mandatory
    -- wall-clock timeout, MUST-FIX 17, is the safety net).
    local verdict
    while true do
        local elapsedMs = (wallClockSeconds() - startedAt) * 1000
        local cancelled = safeCancelled(opts)
        verdict = preview.decide(st, elapsedMs, cancelled)
        if verdict ~= 'pending' then break end
        LrTasks.sleep(POLL_SECONDS)
    end

    -- Terminal verdict reached: release the held request ref now (and only now).
    req = nil

    if verdict == 'ready' then
        -- MUST-FIX 3: actual decoded dims from the bytes, never the requested maxEdge.
        local w, h = preview.parseJpegDims(st.jpeg)
        if not w then
            -- Fail closed: a ready preview whose bytes don't parse is unusable. `h` carries
            -- the parser error string from parseJpegDims.
            log.warn("preview parse failed (skipping photo; run continues)", {
                runId = runId, file = file, reason = 'bad-preview-dims', error = tostring(h),
            })
            return nil, 'bad-preview-dims'
        end
        return { kind = 'bytes', data = st.jpeg, width = w, height = h }
    end

    -- 'failed' / 'timeout' / 'cancelled': per-photo isolation — log a redacted, structured
    -- warn (formatted filename only, never path/gps/date) and return nil + reason. The
    -- caller skips this photo; it NEVER aborts the run.
    log.warn("preview fetch did not produce bytes (skipping photo; run continues)", {
        runId = runId, file = file, reason = verdict, error = tostring(st.err or verdict),
    })
    return nil, verdict
end

return M
