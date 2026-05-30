-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/crop/cropcmd.lua (Phase 6 — Crop-for-ID, CROP-02 build half)
--
-- PURE module: it pulls in no Lightroom SDK namespace at load time, so it is require-able
-- under stock lua / lua5.1 / luajit for offline unit testing (the CODEX-mandated separation
-- invariant). Run under stock lua/luajit; negative-purity grep clean. (The bare SDK-load
-- token is NEVER written here, even in comments, because the purity grep false-positives on
-- it.)
--
-- This is the SECURITY BOUNDARY of Phase 6: file paths + the AI-returned bbox flow into a
-- /bin/sh command string. The escaping rule is POSIX SINGLE-QUOTE wrapping — wrap the token
-- in single quotes and replace every embedded single quote with the close-escape-reopen
-- sequence '\'' . Nothing is special to /bin/sh inside single quotes, so this is
-- injection-proof for spaces, $(), backticks, ;, &, and newlines. We DELIBERATELY do NOT use
-- string.format('%q', ...): %q emits DOUBLE quotes + backslash escapes, which /bin/sh does
-- NOT interpret the same way (an apostrophe becomes \' which sh mishandles) — that would be a
-- shell-injection hole.
--
-- Command shape (ImageMagick v7):
--   '<tool>' '<in>' -crop WxH+X+Y +repage -resize '<edge>x<edge>>' '<out>' 2>'<err>'
-- The -resize '<edge>x<edge>>' is the SHRINK-ONLY backstop (the trailing '>' means "only if
-- larger") so the re-query image stays modest even if the geometry is large (CODEX #14).
-- +repage discards the virtual-canvas offset left by -crop so the output is a clean WxH image.
--
-- decodeExit treats ONLY a raw status of EXACTLY 0 as success (CODEX #4): LrTasks.execute
-- returns the raw OS status, and a naive floor(raw/256) would mask signal kills (raw=9 ->
-- floor=0=success) and turn nil into success. We do not do that.
--
-- Strictly Lua 5.1 common subset: no //, no goto, no <close>; unpack is global.

local M = {}

-- Finite numeric guard (mirrors contract.isNum): number, not NaN, not +-inf.
local INF = 1 / 0
local function isNum(x)
    return type(x) == 'number' and x == x and x ~= INF and x ~= -INF
end

-- A finite non-negative integer (x % 1 == 0 is the Lua 5.1 integer test for a finite number).
local function isFiniteInt(x)
    return isNum(x) and x % 1 == 0
end

-- shquote(s) -> a POSIX-sh-safe single-quoted token. Wrap in single quotes and replace every
-- embedded ' with '\'' (close-quote, backslash-escaped-quote, reopen-quote). The gsub result
-- is parenthesized to drop the substitution count (Lua 5.1 multi-return).
function M.shquote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- geometry(rect) -> "WxH+X+Y" | (nil, 'bad-geometry'). VALIDATES that x,y,w,h are FINITE
-- INTEGERS with x>=0, y>=0, w>0, h>0 before formatting, so an invalid/degenerate rect can
-- never emit a malformed -crop geometry (CODEX #3).
function M.geometry(rect)
    if type(rect) ~= 'table' then return nil, 'bad-geometry' end
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    if not (isFiniteInt(x) and x >= 0) then return nil, 'bad-geometry' end
    if not (isFiniteInt(y) and y >= 0) then return nil, 'bad-geometry' end
    if not (isFiniteInt(w) and w > 0) then return nil, 'bad-geometry' end
    if not (isFiniteInt(h) and h > 0) then return nil, 'bad-geometry' end
    return string.format('%dx%d+%d+%d', w, h, x, y)
end

-- build(toolPath, inPath, rect, outPath, errPath, maxEdge) -> command string | (nil, err).
-- Each path is single-quoted (injection-safe); the geometry is validated via M.geometry (the
-- gate propagates: an invalid rect yields (nil,'bad-geometry')). maxEdge feeds the -resize
-- shrink-only backstop and is VALIDATED here as a FINITE POSITIVE INTEGER [CODEX #6] — a nil /
-- NaN / <=0 / non-integer maxEdge yields (nil,'bad-max-edge') instead of emitting a malformed
-- `-resize 'nilxnil>'` (or a fractional edge) at the security boundary.
function M.build(toolPath, inPath, rect, outPath, errPath, maxEdge)
    local geo, gerr = M.geometry(rect)
    if not geo then return nil, gerr end
    if not (isFiniteInt(maxEdge) and maxEdge > 0) then return nil, 'bad-max-edge' end
    local q = M.shquote
    local resizeArg = string.format('%dx%d>', maxEdge, maxEdge)
    return table.concat({
        q(toolPath),
        q(inPath),
        '-crop', geo,
        '+repage',
        '-resize', q(resizeArg),
        q(outPath),
        '2>' .. q(errPath),
    }, ' ')
end

-- decodeExit(raw) -> (ok:boolean, exit:number). Success is RAW STATUS EXACTLY 0 (CODEX #4).
-- nil / non-number -> (false, -1) (a sentinel, never raises; nil is NOT success). Any other
-- number (9 signal-kill, 256, 65280, ...) -> (false, raw). No floor(raw/256) masking.
function M.decodeExit(raw)
    if raw == 0 then return true, 0 end
    if type(raw) ~= 'number' then return false, -1 end
    return false, raw
end

return M
