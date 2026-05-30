-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/crop/bbox_transform.lua (Phase 6 — Crop-for-ID, CROP-03)
--
-- PURE module: it pulls in no Lightroom SDK namespace at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant). Run under stock lua/luajit; negative-purity grep clean. (The bare SDK-load
-- token is NEVER written here, even in comments, because the purity grep false-positives on
-- it.)
--
-- Maps a normalized [0,1] top-left bbox + the EXACT export frame dimensions to an INTEGER
-- pixel rect {x,y,w,h}, with: padding (in normalized space, clamped to [0,1]), a minimum
-- crop size, a longest-edge CAP to maxEdge (so a full-frame box cannot balloon the re-query
-- image, CODEX #14), and a hard clamp so x+w <= exportW and y+h <= exportH (never indexes
-- outside the frame). All invalid input -> (nil, errString); the function NEVER crashes and
-- NEVER returns a degenerate rect (CODEX #10).
--
-- The bbox convention mirrors src/contract.lua: { x_min, y_min, x_max, y_max }, each in
-- [0,1], top-left origin, with x_min < x_max and y_min < y_max (strict — a zero-area box is
-- useless to crop). The finite guard (NaN / +-inf rejection) mirrors contract.isNum.
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; unpack is global.

local M = {}

-- maxEdge default mirrors settings.previewSize / settings.maxCropEdge (2048) so the
-- re-query crop stays modest even when the caller omits opts.maxEdge.
local DEFAULT_MAX_EDGE = 2048
local DEFAULT_PAD      = 0.08
local DEFAULT_MIN_PX   = 32

-- Finite numeric guard (mirrors contract.isNum): a number, not NaN (x==x is false for NaN),
-- and neither +inf nor -inf.
local INF = 1 / 0
local function isNum(x)
    return type(x) == 'number' and x == x and x ~= INF and x ~= -INF
end

-- A finite number constrained to the unit interval [0,1].
local function inUnit(x)
    return isNum(x) and x >= 0 and x <= 1
end

-- A finite POSITIVE INTEGER (x % 1 == 0 is the Lua 5.1 integer test for a finite number).
-- Used for the export frame dims so the clamp invariant (x+w <= exportW) truly holds on
-- integers [CODEX #8] — a fractional dim like 0.5 is rejected, not silently floored.
local function isPosInt(x)
    return isNum(x) and x > 0 and x % 1 == 0
end

-- Round-half-up (Lua 5.1 has no //): floor(v + 0.5).
local function roundHalfUp(v)
    return math.floor(v + 0.5)
end

-- transform(bbox, exportW, exportH, opts) -> {x=,y=,w=,h=} integer rect | (nil, errString)
--   bbox = { x_min, y_min, x_max, y_max } normalized [0,1] top-left, RELATIVE TO the frame
--          the provider saw (== the export frame, only the pixel scale differs).
--   opts = { pad = <fraction, default 0.08>, minPx = <int, default 32>,
--            maxEdge = <int, default 2048> }
function M.transform(bbox, exportW, exportH, opts)
    -- 1. Validate export dims FIRST: finite POSITIVE INTEGERS [CODEX #10/#8]. A non-integer dim
    --    (e.g. 0.5) is rejected so the integer clamp invariant (x+w <= exportW) truly holds.
    if not isPosInt(exportW) then return nil, 'bad-export-dims' end
    if not isPosInt(exportH) then return nil, 'bad-export-dims' end

    -- 2. Validate bbox shape + range + strict ordering (mirror contract validateBbox). [CODEX #10]
    if type(bbox) ~= 'table' then return nil, 'bad-bbox' end
    local x_min, y_min, x_max, y_max = bbox[1], bbox[2], bbox[3], bbox[4]
    if not (inUnit(x_min) and inUnit(y_min) and inUnit(x_max) and inUnit(y_max)) then
        return nil, 'bad-bbox'
    end
    if x_min >= x_max then return nil, 'bad-bbox' end
    if y_min >= y_max then return nil, 'bad-bbox' end

    -- 3. Resolve opts with finite-number fallbacks (a non-number opt falls back to default).
    opts = type(opts) == 'table' and opts or {}
    local pad     = isNum(opts.pad) and opts.pad or DEFAULT_PAD
    local minPx   = isNum(opts.minPx) and opts.minPx or DEFAULT_MIN_PX
    local maxEdge = (isNum(opts.maxEdge) and opts.maxEdge > 0) and opts.maxEdge or DEFAULT_MAX_EDGE

    -- 4. Pad by `pad` of each side in NORMALIZED space, then clamp to [0,1] (before pixels).
    local bw = x_max - x_min
    local bh = y_max - y_min
    local nx0 = x_min - bw * pad
    local ny0 = y_min - bh * pad
    local nx1 = x_max + bw * pad
    local ny1 = y_max + bh * pad
    if nx0 < 0 then nx0 = 0 end
    if ny0 < 0 then ny0 = 0 end
    if nx1 > 1 then nx1 = 1 end
    if ny1 > 1 then ny1 = 1 end

    -- 5. To EXPORT pixels (float).
    local px = nx0 * exportW
    local py = ny0 * exportH
    local pw = (nx1 - nx0) * exportW
    local ph = (ny1 - ny0) * exportH

    -- 6. Enforce a minimum crop size (a tiny box is useless to re-query): widen, re-center.
    if pw < minPx then local c = px + pw / 2; px = c - minPx / 2; pw = minPx end
    if ph < minPx then local c = py + ph / 2; py = c - minPx / 2; ph = minPx end

    -- 7. maxEdge CAP [CODEX #14]: if the longest edge exceeds maxEdge, scale w AND h DOWN
    --    proportionally (preserve aspect) so the re-query image stays modest.
    local longest = pw
    if ph > longest then longest = ph end
    if longest > maxEdge then
        local scale = maxEdge / longest
        -- keep the box centered while shrinking.
        local cx = px + pw / 2
        local cy = py + ph / 2
        pw = pw * scale
        ph = ph * scale
        px = cx - pw / 2
        py = cy - ph / 2
    end

    -- 8. Integer-round + hard clamp so x in [0, exportW-1], w in [1, exportW-x] (analogous y).
    if px < 0 then px = 0 end
    if py < 0 then py = 0 end
    local x = roundHalfUp(px)
    local y = roundHalfUp(py)
    if x > exportW - 1 then x = roundHalfUp(exportW - 1) end
    if y > exportH - 1 then y = roundHalfUp(exportH - 1) end
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end

    local w = roundHalfUp(pw)
    local h = roundHalfUp(ph)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    -- clamp the extent so it never crosses the frame edge.
    local maxW = exportW - x
    local maxH = exportH - y
    if maxW < 1 then maxW = 1 end
    if maxH < 1 then maxH = 1 end
    if w > maxW then w = roundHalfUp(maxW) end
    if h > maxH then h = roundHalfUp(maxH) end
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end

    return { x = x, y = y, w = w, h = h }
end

return M
