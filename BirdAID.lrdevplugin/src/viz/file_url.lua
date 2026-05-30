-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/viz/file_url.lua (Phase 9 — BL-04 file:// URL builder)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
-- NO network/process here. It is the PURE helper EXTRACTED from the viz_report Lr glue so the
-- file:// percent-escaping (a security/correctness surface for paths with spaces or specials) is
-- unit-testable offline.
--
-- WHY THIS EXISTS (BL-04 + T-09-06): viz_report writes the SVG to an absolute temp path and opens
-- it via LrHttp.openUrlInBrowser('file://' .. <escaped path>). A raw concatenation of a path that
-- contains a space (a likely macOS path) or a URL-reserved/unsafe byte would malform the URL (or,
-- in theory, be misinterpreted by the browser). This builder percent-encodes EACH path SEGMENT
-- byte-by-byte, KEEPING the '/' separators (so the directory structure survives) and encoding the
-- space and every other reserved/unsafe/non-ASCII byte as %XX. NO raw concat of the path.
--
-- M.pathToFileUrl(absPath) -> 'file://' .. <per-segment-percent-encoded absPath> | nil
--   * nil / non-string / empty / a relative path (not starting with '/') -> nil (fail closed: the
--     caller only ever has an absolute temp path; a bad path must not produce a half-valid URL).
--   * the leading '/' and every internal '/' are preserved verbatim; every OTHER byte in each
--     segment is passed through encodeSegment.
--
-- M.encodeSegment(seg) -> the percent-encoded form of one path segment (NO '/' inside a segment).
--   UNRESERVED bytes (RFC 3986 unreserved: A-Z a-z 0-9 - _ . ~) pass through verbatim; EVERY other
--   byte (space, %, ?, #, &, control chars, and any >=0x80 UTF-8 continuation byte) is encoded as
--   %XX with UPPERCASE hex. Byte-oriented (string.byte), so UTF-8 multibyte paths encode per byte
--   (the correct, browser-decodable form). Lua 5.1 safe (string.byte + string.format, no 5.3 APIs).
--
-- Strictly Lua 5.1 common subset: no \u{}, no // integer div, no goto, no <close>; unpack global.

local M = {}

-- isUnreserved(b): true for an RFC-3986 unreserved byte (A-Z a-z 0-9 - _ . ~) that needs NO
-- escaping inside a path segment. Everything else (incl. space 0x20, %, ?, #, reserved, control,
-- and >=0x80) is percent-encoded so the file:// URL is always well-formed.
local function isUnreserved(b)
    -- 0-9
    if b >= 48 and b <= 57 then return true end
    -- A-Z
    if b >= 65 and b <= 90 then return true end
    -- a-z
    if b >= 97 and b <= 122 then return true end
    -- - (45)  . (46)  _ (95)  ~ (126)
    if b == 45 or b == 46 or b == 95 or b == 126 then return true end
    return false
end

-- encodeSegment(seg) -> percent-encoded segment string. Operates BYTE-WISE so a UTF-8 path encodes
-- each byte as %XX (uppercase hex). A '/' is NOT expected inside a segment (pathToFileUrl splits on
-- '/'), but if one slips through it is encoded like any other reserved byte (it is not unreserved).
function M.encodeSegment(seg)
    if type(seg) ~= 'string' or seg == '' then return seg or '' end
    local out = {}
    for i = 1, #seg do
        local b = string.byte(seg, i)
        if isUnreserved(b) then
            out[i] = string.char(b)
        else
            out[i] = string.format('%%%02X', b)   -- UPPERCASE %XX
        end
    end
    return table.concat(out)
end

-- pathToFileUrl(absPath) -> 'file://<escaped>' | nil. Splits the absolute path on '/', percent-
-- encodes each segment, and re-joins with '/' (the separators survive). The leading '/' (the path
-- is absolute) yields a leading empty segment that re-joins as the leading '/', so the result is
-- 'file://' .. '/escaped/path' == 'file:///escaped/path' (three slashes — the correct file:// form
-- for an absolute local path).
function M.pathToFileUrl(absPath)
    if type(absPath) ~= 'string' or absPath == '' then return nil end
    -- Only an ABSOLUTE path is valid here (the caller always has a temp-dir absolute path). A
    -- relative path would yield a malformed file:// URL, so fail closed.
    if absPath:sub(1, 1) ~= '/' then return nil end

    -- Split on '/', preserving empty segments (the leading '' before the first '/', and any '//').
    -- gmatch('[^/]*') with a trailing-slash subtlety is fiddly in 5.1; iterate manually instead so
    -- empty segments (incl. the leading one) are preserved EXACTLY.
    local segments = {}
    local start = 1
    local n = #absPath
    local idx = 0
    while start <= n + 1 do
        local slash = absPath:find('/', start, true)
        local seg
        if slash then
            seg = absPath:sub(start, slash - 1)
            idx = idx + 1
            segments[idx] = M.encodeSegment(seg)
            start = slash + 1
        else
            seg = absPath:sub(start)
            idx = idx + 1
            segments[idx] = M.encodeSegment(seg)
            break
        end
    end

    return 'file://' .. table.concat(segments, '/')
end

return M
