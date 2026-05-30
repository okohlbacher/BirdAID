-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/cluster/jpeg_thumb.lua (Phase 9 — BL-07, RISKIEST pure module)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
-- NO ImageMagick, NO native modules — decode happens in pure Lua.
--
-- WHAT IT DOES (BL-07): decode ONLY enough of a BASELINE (Huffman, non-progressive) JPEG to
-- produce a coarse luma signal, then REDUCE it to a FIXED 8x8 (64-cell) grid that feeds the aHash
-- in similarity.lua. The DC coefficient of each 8x8 luma block yields a ~(Wblocks x Hblocks)
-- grayscale field WITHOUT a full IDCT; that field is box-averaged down to EXACTLY 8x8.
--
-- FAIL-OPEN CONTRACT: M.dcLumaGrid(bytes) returns nil on ANY of: not-a-JPEG, progressive/arithmetic
-- SOF, unsupported structure, parse/bounds error, or any Huffman/restart inconsistency. A nil grid
-- means similarity.similar() returns false -> frames are NOT merged -> identified independently.
-- A WRONG merge is worse than a missed merge, so when in doubt we return nil. The decode never
-- raises: it is wrapped so any internal error becomes a nil return.
--
-- SCOPE (DC-only, no IDCT): parse SOI; DQT (skip); SOF0 0xC0 ONLY (reject 0xC2 progressive, 0xC3+,
-- 0xC9 arithmetic) for dims + per-component sampling factors; DHT building canonical Huffman tables;
-- at SOS, per MCU decode each component's blocks: decode the DC Huffman symbol (category s), read s
-- additional bits, EXTEND, accumulate the per-component DC differential predictor; decode-and-DISCARD
-- the AC coefficients (walk run/size to 63 or EOB) to stay byte/bit-aligned. Honor 0xFF00 byte-
-- stuffing and RSTn restart markers (reset all DC predictors at each restart). Only the LUMA
-- component's per-block DC values are retained, laid out in a (mcuCols*Hl x mcuRows*Vl) block field,
-- then box-averaged (or replicate-up when < 8x8) to EXACTLY 64 cells. Only RELATIVE luma matters
-- for the aHash, so the constant level-shift offset is harmless and is not applied.
--
-- M.dcLumaGrid(bytes) -> a flat array of EXACTLY 64 integers (row-major), or nil (fail-open).
--
-- Strictly Lua 5.1 common subset: string.byte + integer arithmetic ONLY (NO string.unpack — 5.3+);
-- no \u{}, no //, no goto, no <close>; unpack is global.

local M = {}

local b = string.byte
local floor = math.floor

-- ---------------------------------------------------------------------------
-- A canonical Huffman table built from a DHT segment: BITS[1..16] counts + the
-- symbol values in code order. We build a decode map keyed by (length, code).
-- ---------------------------------------------------------------------------
-- buildHuff(counts, symbols) -> { maxLen, minCodeByLen, maxCodeByLen, valPtrByLen }
-- using the standard JPEG spec generation (mincode/maxcode/valptr) for O(1)-ish decode.
local function buildHuff(counts, symbols)
    -- huffsize / huffcode generation (Annex C).
    local sizes = {}
    local k = 0
    for l = 1, 16 do
        for _ = 1, counts[l] do
            k = k + 1
            sizes[k] = l
        end
    end
    local total = k
    if total == 0 then return nil end
    local codes = {}
    local code = 0
    local si = sizes[1]
    k = 1
    while sizes[k] ~= nil do
        while sizes[k] == si do
            codes[k] = code
            code = code + 1
            k = k + 1
            if sizes[k] == nil then break end
        end
        if sizes[k] == nil then break end
        code = code * 2
        si = si + 1
    end
    -- mincode/maxcode/valptr by length (Annex F.2.2.3).
    local mincode, maxcode, valptr = {}, {}, {}
    local p = 1
    for l = 1, 16 do
        if counts[l] > 0 then
            valptr[l] = p
            mincode[l] = codes[p]
            p = p + counts[l]
            maxcode[l] = codes[p - 1]
        else
            maxcode[l] = -1  -- no code of this length
        end
    end
    return { counts = counts, symbols = symbols,
             mincode = mincode, maxcode = maxcode, valptr = valptr }
end

-- ---------------------------------------------------------------------------
-- A bit reader over the entropy-coded scan data. Consumes 0xFF00 byte-stuffing.
-- A marker (0xFFxx, xx != 0x00) signals end-of-scan / restart: nextByte stops by
-- setting hitMarker so callers can detect it. NEVER reads past the buffer.
-- ---------------------------------------------------------------------------
local function newBitReader(bytes, startPos, n)
    local R = { pos = startPos, n = n, bits = 0, count = 0, hitMarker = false, markerByte = nil }

    -- pull the next data byte, handling 0xFF00 stuffing and stopping at a real marker.
    local function nextByte(R)
        if R.pos > R.n then R.hitMarker = true; return nil end
        local c = b(bytes, R.pos); R.pos = R.pos + 1
        if c == 0xFF then
            -- read the following byte to disambiguate stuffing vs marker.
            if R.pos > R.n then R.hitMarker = true; return nil end
            local c2 = b(bytes, R.pos)
            if c2 == 0x00 then
                R.pos = R.pos + 1   -- 0xFF00 -> a literal 0xFF data byte.
                return 0xFF
            else
                -- a real marker (RSTn / EOI / etc). Do NOT consume; signal the caller.
                R.hitMarker = true
                R.markerByte = c2
                return nil
            end
        end
        return c
    end

    -- getBit() -> 0/1, or nil if a marker/EOF was hit (decode must then fail-open).
    function R.getBit()
        if R.count == 0 then
            local byte = nextByte(R)
            if byte == nil then return nil end
            R.bits = byte
            R.count = 8
        end
        R.count = R.count - 1
        local bit = floor(R.bits / (2 ^ R.count)) % 2
        return bit
    end

    -- getBits(s) -> an s-bit unsigned value, or nil on EOF/marker.
    function R.getBits(s)
        local v = 0
        for _ = 1, s do
            local bit = R.getBit()
            if bit == nil then return nil end
            v = v * 2 + bit
        end
        return v
    end

    -- align to the next byte boundary (used at a restart marker).
    function R.resetBits()
        R.bits = 0
        R.count = 0
    end

    return R
end

-- decodeHuff(R, tbl) -> the decoded symbol value, or nil on inconsistency/EOF.
local function decodeHuff(R, tbl)
    local code = 0
    for l = 1, 16 do
        local bit = R.getBit()
        if bit == nil then return nil end
        code = code * 2 + bit
        if tbl.maxcode[l] ~= nil and tbl.maxcode[l] >= 0 and code <= tbl.maxcode[l] then
            local idx = tbl.valptr[l] + (code - tbl.mincode[l])
            local sym = tbl.symbols[idx]
            if sym == nil then return nil end
            return sym
        end
    end
    return nil  -- code longer than 16 bits -> corrupt.
end

-- EXTEND(v, s): the JPEG sign-extension of an s-bit magnitude (spec Figure F.12).
local function extend(v, s)
    if s == 0 then return 0 end
    local half = 2 ^ (s - 1)
    if v < half then
        return v - (2 ^ s) + 1
    end
    return v
end

-- ---------------------------------------------------------------------------
-- The real decoder, wrapped by dcLumaGrid in pcall so any error fails-open.
-- ---------------------------------------------------------------------------
local function decode(bytes)
    if type(bytes) ~= 'string' or #bytes < 4 then return nil end
    local n = #bytes
    if b(bytes, 1) ~= 0xFF or b(bytes, 2) ~= 0xD8 then return nil end  -- SOI

    local i = 3
    local frame = nil           -- { width, height, comps = { {id,h,v,qt}, ... } }
    local dcTables = {}         -- [tableId] = huff table
    local acTables = {}         -- [tableId] = huff table
    local restartInterval = 0

    while i < n do
        if b(bytes, i) ~= 0xFF then return nil end
        while i <= n and b(bytes, i) == 0xFF do i = i + 1 end
        if i > n then return nil end
        local marker = b(bytes, i); i = i + 1

        if marker == 0xD9 then
            return nil  -- EOI before SOS -> no scan.
        elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
            -- standalone marker, no payload.
        elseif marker == 0xC0 then
            -- SOF0 baseline. Length-bearing.
            if i + 1 > n then return nil end
            local len = b(bytes, i) * 256 + b(bytes, i + 1)
            if len < 8 or i + len > n + 1 then return nil end
            -- body: precision(1) height(2) width(2) nc(1) then nc*(id,sampling,qt)
            local height = b(bytes, i + 3) * 256 + b(bytes, i + 4)
            local width  = b(bytes, i + 5) * 256 + b(bytes, i + 6)
            local nc = b(bytes, i + 7)
            if nc < 1 or nc > 4 then return nil end
            if i + 8 + nc * 3 - 1 > i + len - 1 then return nil end
            local comps = {}
            for c = 1, nc do
                local o = i + 8 + (c - 1) * 3
                local id = b(bytes, o)
                local samp = b(bytes, o + 1)
                local hf = floor(samp / 16)
                local vf = samp % 16
                local qt = b(bytes, o + 2)
                if hf < 1 or hf > 4 or vf < 1 or vf > 4 then return nil end
                comps[c] = { id = id, h = hf, v = vf, qt = qt }
            end
            if width <= 0 or height <= 0 then return nil end
            frame = { width = width, height = height, comps = comps }
            i = i + len
        elseif (marker >= 0xC1 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC) then
            -- Any SOF that is NOT baseline SOF0 (0xC0) -> reject. This covers SOF1 (extended
            -- sequential, 0xC1), SOF2 (progressive), SOF3 (lossless), SOF5-7 (differential),
            -- SOF9-15 (arithmetic). 0xC4 = DHT, 0xC8 = JPG (reserved), 0xCC = DAC are NOT SOFs
            -- and are handled elsewhere / skipped; every other 0xC1..0xCF marker is a non-baseline
            -- SOF and MUST fail-open (a wrong merge is worse than a missed merge).
            return nil
        elseif marker == 0xC4 then
            -- DHT: one or more tables.
            if i + 1 > n then return nil end
            local len = b(bytes, i) * 256 + b(bytes, i + 1)
            if len < 2 or i + len > n + 1 then return nil end
            local p = i + 2
            local segEnd = i + len
            while p < segEnd do
                local tc_th = b(bytes, p); p = p + 1
                local class = floor(tc_th / 16)  -- 0 = DC, 1 = AC
                local id = tc_th % 16
                if id > 3 then return nil end
                local counts = {}
                local total = 0
                for l = 1, 16 do
                    if p > n then return nil end
                    counts[l] = b(bytes, p); p = p + 1
                    total = total + counts[l]
                end
                if p + total - 1 > segEnd - 1 then return nil end
                local symbols = {}
                for s = 1, total do
                    symbols[s] = b(bytes, p); p = p + 1
                end
                local tbl = buildHuff(counts, symbols)
                if not tbl then return nil end
                if class == 0 then dcTables[id] = tbl else acTables[id] = tbl end
            end
            i = i + len
        elseif marker == 0xDD then
            -- DRI restart interval.
            if i + 1 > n then return nil end
            local len = b(bytes, i) * 256 + b(bytes, i + 1)
            if len ~= 4 or i + len > n + 1 then return nil end
            restartInterval = b(bytes, i + 2) * 256 + b(bytes, i + 3)
            i = i + len
        elseif marker == 0xDA then
            -- SOS: begin the scan. We support a scan over all frame components (baseline
            -- interleaved). Parse the scan header then entropy-decode.
            if not frame then return nil end
            if i + 1 > n then return nil end
            local len = b(bytes, i) * 256 + b(bytes, i + 1)
            if len < 6 or i + len > n + 1 then return nil end
            local ns = b(bytes, i + 2)
            -- BASELINE-SCAN SHAPE: ns must match the frame's component count, the segment length
            -- must be EXACTLY 6 + 2*ns, and the three trailing spectral-selection / successive-
            -- approximation bytes (Ss, Se, AhAl) must describe a full baseline DC+AC scan:
            -- Ss == 0, Se == 63, Ah == 0 AND Al == 0 (the AhAl byte == 0). Anything else is a
            -- progressive / partial scan and MUST fail-open (a wrong merge is worse than a missed one).
            if ns < 1 or ns > #frame.comps then return nil end
            if ns ~= #frame.comps then return nil end
            if len ~= 6 + 2 * ns then return nil end
            -- map each scan component to (dcTableId, acTableId) and to its frame component.
            local scan = {}
            for s = 1, ns do
                local o = i + 3 + (s - 1) * 2
                local cs = b(bytes, o)
                local td_ta = b(bytes, o + 1)
                local dcId = floor(td_ta / 16)
                local acId = td_ta % 16
                -- find the frame component with this selector id.
                local fc = nil
                for ci = 1, #frame.comps do
                    if frame.comps[ci].id == cs then fc = ci; break end
                end
                if not fc then return nil end
                scan[s] = { fc = fc, dcId = dcId, acId = acId }
            end
            -- the three spectral-selection bytes follow the ns component pairs.
            local spo = i + 3 + ns * 2
            local ss   = b(bytes, spo)
            local se   = b(bytes, spo + 1)
            local ahal = b(bytes, spo + 2)
            if ss ~= 0 or se ~= 63 or ahal ~= 0 then return nil end
            -- scan data begins after the SOS header (i + len). Build the bit reader.
            local scanStart = i + len
            return { frame = frame, dcTables = dcTables, acTables = acTables,
                     restartInterval = restartInterval, scan = scan,
                     scanStart = scanStart, n = n }
        else
            -- any other length-bearing segment: skip by declared length.
            if i + 1 > n then return nil end
            local len = b(bytes, i) * 256 + b(bytes, i + 1)
            if len < 2 or i + len > n + 1 then return nil end
            i = i + len
        end
    end
    return nil  -- reached EOF without an SOS.
end

-- entropyDecodeLuma(ctx, bytes) -> a (lumaCols x lumaRows) block field of DC values (flat,
-- row-major) + its dims, or nil. The LUMA component is the FIRST frame component (id ordering;
-- JPEG always lists Y first). We decode every component per MCU to stay aligned but retain only
-- luma DC.
local function entropyDecodeLuma(ctx, bytes)
    local frame = ctx.frame
    local comps = frame.comps

    -- max sampling factors -> MCU dims in blocks.
    local hmax, vmax = 1, 1
    for c = 1, #comps do
        if comps[c].h > hmax then hmax = comps[c].h end
        if comps[c].v > vmax then vmax = comps[c].v end
    end
    -- MCUs across / down (ceil over 8*hmax / 8*vmax pixels).
    local mcusX = floor((frame.width + 8 * hmax - 1) / (8 * hmax))
    local mcusY = floor((frame.height + 8 * vmax - 1) / (8 * vmax))

    -- The luma component (component 1) is what we keep. Identify it by being the FIRST scan
    -- component whose frame component is index 1, else just frame component 1.
    local lumaFc = 1
    local lumaH = comps[lumaFc].h
    local lumaV = comps[lumaFc].v
    -- luma block field dims.
    local lumaCols = mcusX * lumaH
    local lumaRows = mcusY * lumaV
    if lumaCols < 1 or lumaRows < 1 then return nil end
    -- guard against absurd sizes (corrupt dims) to keep the pure decode bounded.
    if lumaCols * lumaRows > 1000000 then return nil end

    local field = {}
    for k = 1, lumaCols * lumaRows do field[k] = 0 end

    local R = newBitReader(bytes, ctx.scanStart, ctx.n)

    -- per-component DC predictor.
    local pred = {}
    for c = 1, #comps do pred[c] = 0 end

    -- validate tables exist for each scan component.
    for s = 1, #ctx.scan do
        local sc = ctx.scan[s]
        if not ctx.dcTables[sc.dcId] then return nil end
        if not ctx.acTables[sc.acId] then return nil end
    end
    -- map frame-component index -> its scan entry (so we know its DC/AC tables).
    local fcScan = {}
    for s = 1, #ctx.scan do fcScan[ctx.scan[s].fc] = ctx.scan[s] end

    local mcuCount = 0
    local ri = ctx.restartInterval

    for my = 0, mcusY - 1 do
        for mx = 0, mcusX - 1 do
            -- restart handling.
            if ri > 0 and mcuCount > 0 and (mcuCount % ri) == 0 then
                -- expect a RSTn marker: realign + skip the marker + reset predictors.
                R.resetBits()
                -- advance R.pos past any pending 0xFF.. marker bytes (RST0..7).
                -- the bit reader stopped at a marker (hitMarker). consume FF + RSTn.
                local p = R.pos
                -- skip fill 0xFF then a single RSTn (0xD0..0xD7).
                while p <= ctx.n and b(bytes, p) == 0xFF do p = p + 1 end
                if p > ctx.n then return nil end
                local mk = b(bytes, p)
                if mk < 0xD0 or mk > 0xD7 then return nil end
                R.pos = p + 1
                R.hitMarker = false
                R.markerByte = nil
                for c = 1, #comps do pred[c] = 0 end
            end

            -- decode every component's blocks in this MCU (component order = frame order).
            for c = 1, #comps do
                local sc = fcScan[c]
                if not sc then return nil end
                local dcT = ctx.dcTables[sc.dcId]
                local acT = ctx.acTables[sc.acId]
                local blocksH = comps[c].h
                local blocksV = comps[c].v
                for by = 0, blocksV - 1 do
                    for bx = 0, blocksH - 1 do
                        -- DC coefficient.
                        local t = decodeHuff(R, dcT)
                        if t == nil then return nil end
                        local diff = 0
                        if t > 0 then
                            if t > 16 then return nil end
                            local v = R.getBits(t)
                            if v == nil then return nil end
                            diff = extend(v, t)
                        end
                        pred[c] = pred[c] + diff
                        -- store luma DC into the block field.
                        if c == lumaFc then
                            local col = mx * lumaH + bx
                            local row = my * lumaV + by
                            field[row * lumaCols + col + 1] = pred[c]
                        end
                        -- AC coefficients: decode-and-discard to stay aligned (walk to 63 or EOB).
                        local k = 1
                        while k <= 63 do
                            local rs = decodeHuff(R, acT)
                            if rs == nil then return nil end
                            local run = floor(rs / 16)
                            local size = rs % 16
                            if size == 0 then
                                if run == 15 then
                                    k = k + 16   -- ZRL: skip 16 zeros.
                                else
                                    break        -- EOB.
                                end
                            else
                                k = k + run + 1
                                local av = R.getBits(size)
                                if av == nil then return nil end
                                -- value discarded (we only need DC for the coarse luma field).
                            end
                        end
                    end
                end
            end
            mcuCount = mcuCount + 1
        end
    end

    return field, lumaCols, lumaRows
end

-- boxTo8x8(field, cols, rows) -> a flat 64-cell array (row-major). Box-average the (cols x rows)
-- field into 8x8 cells; when cols/rows < 8, replicate (nearest) up to 8. Always emits 64 cells.
local function boxTo8x8(field, cols, rows)
    local out = {}
    for gy = 0, 7 do
        for gx = 0, 7 do
            -- source rectangle for this output cell (handles both down- and up-sampling).
            local x0 = floor(gx * cols / 8)
            local x1 = floor((gx + 1) * cols / 8)
            local y0 = floor(gy * rows / 8)
            local y1 = floor((gy + 1) * rows / 8)
            if x1 <= x0 then x1 = x0 + 1 end   -- ensure at least one source sample (replicate-up).
            if y1 <= y0 then y1 = y0 + 1 end
            if x1 > cols then x1 = cols end
            if y1 > rows then y1 = rows end
            if x0 >= cols then x0 = cols - 1 end
            if y0 >= rows then y0 = rows - 1 end
            local sum, cnt = 0, 0
            for sy = y0, y1 - 1 do
                for sx = x0, x1 - 1 do
                    sum = sum + field[sy * cols + sx + 1]
                    cnt = cnt + 1
                end
            end
            if cnt == 0 then return nil end
            out[gy * 8 + gx + 1] = sum / cnt
        end
    end
    return out
end

-- M.dcLumaGrid(bytes) -> a fixed 64-cell grid (flat, row-major) | nil (fail-open).
function M.dcLumaGrid(bytes)
    local ok, result = pcall(function()
        local ctx = decode(bytes)
        if not ctx then return nil end
        local field, cols, rows = entropyDecodeLuma(ctx, bytes)
        if not field then return nil end
        local grid = boxTo8x8(field, cols, rows)
        if not grid then return nil end
        if #grid ~= 64 then return nil end
        return grid
    end)
    if not ok then return nil end
    return result
end

return M
