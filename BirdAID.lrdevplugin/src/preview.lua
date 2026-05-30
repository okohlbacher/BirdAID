-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/preview.lua (PREV-01 pure half)
--
-- PURE module: imports NO Lightroom SDK module at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated
-- separation invariant). Run under stock lua/luajit; negative-purity grep clean.
--
-- Two pure pieces of the preview pipeline (the thin Lr wait-loop glue lives in the
-- entry/pipeline tier and is the ONLY Lr part of PREV-01):
--
--   * parseJpegDims(bytes) -> (width, height) | (nil, errString)
--     Reads the ACTUAL decoded outer width/height from raw JPEG bytes. The requested
--     thumbnail size is only a MINIMUM, never the decoded size, so bbox math MUST use
--     the parsed dims. The parser walks segments STRICTLY BY DECLARED LENGTH; it never
--     naive-scans the byte stream for 0xFFC0. That is what makes an EXIF-embedded
--     thumbnail's SOF impossible to mistake for the outer image's dimensions
--     (CODEX MUST-FIX 5) -- the APP1/EXIF payload is skipped wholesale.
--
--   * newState/onCallback/decide -- the pure timeout/cancel/stale state machine that
--     turns the async, possibly-multi-fire (or never-firing) callback into one verdict.
--
-- Strictly Lua 5.1 common subset: string.byte + arithmetic only (NO string.unpack,
-- which is 5.3+). No // , no goto, no <close>.

local M = {}

-- Start-Of-Frame markers that carry height/width = SOF0..SOF15 (0xC0..0xCF) EXCEPT the
-- non-SOF markers DHT=0xC4, JPG=0xC8, DAC=0xCC. SOF2 (0xC2, progressive) is ACCEPTED the
-- same as SOF0 (0xC0): we only need dimensions, and SOF2 carries height/width at the
-- identical offsets (CODEX MUST-FIX 6).
local SOF = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true,
    [0xC5] = true, [0xC6] = true, [0xC7] = true,
    [0xC9] = true, [0xCA] = true, [0xCB] = true,
    [0xCD] = true, [0xCE] = true, [0xCF] = true,
}

-- parseJpegDims(bytes) -> (width, height) or (nil, errString). NEVER raises: every byte
-- read is bounds-checked and any overflow/truncation returns (nil, err).
function M.parseJpegDims(bytes)
    if type(bytes) ~= 'string' or #bytes < 4 then return nil, 'not-a-jpeg' end
    local b = string.byte
    local n = #bytes
    if b(bytes, 1) ~= 0xFF or b(bytes, 2) ~= 0xD8 then return nil, 'no-soi' end

    local i = 3
    while i < n do
        -- Every marker begins with 0xFF; collapse any run of 0xFF fill/padding bytes.
        if b(bytes, i) ~= 0xFF then return nil, 'bad-marker' end
        while i <= n and b(bytes, i) == 0xFF do i = i + 1 end
        if i > n then return nil, 'truncated' end

        local marker = b(bytes, i)
        i = i + 1

        if marker == 0xD9 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
            -- Standalone markers (EOI / TEM / RST0-7) carry NO length payload: skip.
        elseif marker == 0xDA then
            -- CODEX MUST-FIX (review item 3): Start-Of-Scan. From here the byte stream is
            -- ENTROPY-CODED scan data in which 0xFF<marker>-looking byte pairs occur as
            -- ordinary compressed bytes (and 0xFF00 byte-stuffing). Continuing to walk it
            -- as if it were segments would mis-read random scan bytes as a SOF and return
            -- garbage dimensions. A conforming JPEG always carries its SOF BEFORE the SOS,
            -- so reaching SOS without having returned dims means the outer SOF is missing.
            -- STOP and reject rather than scan scan-data for markers.
            return nil, 'sos-before-sof'
        else
            -- Length-bearing segment: next 2 bytes are a big-endian length that INCLUDES
            -- the 2 length bytes themselves.
            if i + 1 > n then return nil, 'truncated-len' end
            local len = b(bytes, i) * 256 + b(bytes, i + 1)
            -- CODEX MUST-FIX 4: length includes its own 2 bytes, so len<2 is corrupt;
            -- reject IMMEDIATELY (before any skip) to prevent an infinite loop / negative
            -- skip.
            if len < 2 then return nil, 'bad-segment-length' end

            if SOF[marker] then
                -- CODEX MUST-FIX review item 1: the declared SOF length must be large
                -- enough to actually CONTAIN the dimension bytes. The SOF body after the
                -- 2 length bytes is precision(1) + height(2) + width(2) = 5 bytes minimum,
                -- so len must be >= 7 (2 length bytes + 5). A real SOF also carries >=1
                -- component descriptor (>=3 bytes) making the practical minimum 8 (a
                -- grayscale SOF is 11); enforce len >= 8 per the review note. A short
                -- declared length (e.g. len=2) that nonetheless has trailing bytes in the
                -- buffer must NOT be trusted for dims.
                if len < 8 then return nil, 'bad-sof-length' end
                -- CODEX MUST-FIX review item 2: a SOF whose DECLARED length overruns EOF
                -- is corrupt and must be rejected, not trusted for dims. The segment
                -- occupies bytes [i .. i+len-1] (i = first length byte), so require
                -- i+len <= n+1. We check this BEFORE reading dims so a SOF claiming a
                -- length that runs past the buffer can never yield garbage dimensions.
                if i + len > n + 1 then return nil, 'truncated' end
                -- The dimension bytes (precision at +2, height at +3..+4 BE, width at
                -- +5..+6 BE relative to i) must lie WITHIN the declared segment AND within
                -- the buffer (review item 1). dimsEnd is the width low byte.
                local dimsEnd = i + 6
                if dimsEnd > i + len - 1 then return nil, 'bad-sof-length' end
                if dimsEnd > n then return nil, 'truncated-sof' end
                local h = b(bytes, i + 3) * 256 + b(bytes, i + 4)
                local w = b(bytes, i + 5) * 256 + b(bytes, i + 6)
                return w, h
            end

            -- Walk strictly by the declared length: this skips APP1/EXIF payload (and any
            -- embedded thumbnail JPEG inside it) WHOLESALE so the OUTER SOF wins. Defend a
            -- segment whose declared length runs past the buffer.
            if i + len > n + 1 then return nil, 'truncated' end
            i = i + len
        end
    end
    return nil, 'no-sof'
end

-- ---------------------------------------------------------------------------
-- Pure preview decision state machine (PREV-01). The glue feeds it events
-- (callback fired? cancelled? elapsed time); decide() reads the state.
-- ---------------------------------------------------------------------------

-- newState(timeoutMs) -> a plain table the glue mutates; default timeout 8000ms.
function M.newState(timeoutMs)
    return { status = 'pending', timeoutMs = timeoutMs or 8000 }
end

-- onCallback(state, jpeg, err): record the FIRST callback only. The Lr callback may fire
-- more than once; subsequent fires (status ~= 'pending') are IGNORED (no overwrite).
function M.onCallback(state, jpeg, err)
    if state.status ~= 'pending' then return end
    if type(jpeg) == 'string' and #jpeg > 0 then
        state.status = 'ready'
        state.jpeg = jpeg
    else
        state.status = 'failed'
        state.err = tostring(err or 'no-preview')
    end
end

-- decide(state, elapsedMs, cancelled) -> 'cancelled' | 'ready' | 'failed' | 'timeout' | 'pending'
-- cancelled WINS over everything; then a recorded ready/failed; then the mandatory timeout
-- branch (elapsed >= timeoutMs) so a never-firing callback can never hang the wait loop.
function M.decide(state, elapsedMs, cancelled)
    if cancelled then return 'cancelled' end
    if state.status == 'ready' then return 'ready' end
    if state.status == 'failed' then return 'failed' end
    if elapsedMs and elapsedMs >= state.timeoutMs then return 'timeout' end
    return 'pending'
end

return M
