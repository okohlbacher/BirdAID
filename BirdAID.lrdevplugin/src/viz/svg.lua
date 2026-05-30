-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/viz/svg.lua (Phase 9 — BL-04 detection report renderer)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
-- NO LrView, NO ImageMagick — the report is a plain SVG string built by concatenation. The Wave-2
-- glue (viz_report.lua) writes the string to a temp file and opens it in the browser.
--
-- WHAT IT DOES (BL-04): render a self-contained SVG for ONE photo's detections:
--   * an <svg> with width/height = frameW/frameH and a matching viewBox;
--   * an optional <image> base (the base64 preview) when imageDataUri is a valid data:image/ URI;
--   * per detection: a <rect> (stroke=blue, fill=none) at DENORMALIZED pixel coords, carrying a
--     child <title> for a REAL SVG hover tooltip (no JS), plus a visible <text> label near the box.
--
-- SECURITY: ALL label / title text is XML-escaped (& < > " ') so a species name or a user prompt
-- addition can NEVER inject markup. imageDataUri is embedded ONLY when it matches the expected
-- data:image/ prefix; any other URI (e.g. javascript:) is omitted.
--
-- M.render(opts) where opts = { frameW=<int>, frameH=<int>, imageDataUri=<string|nil>,
--   detections = { { bbox={x_min,y_min,x_max,y_max} (normalized [0,1]), label=<string>,
--   title=<string> }, ... } } -> an SVG string.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local M = {}

-- xmlEscape(s): escape the five XML special chars. & MUST be escaped FIRST so the entity
-- ampersands introduced by the later replacements are not double-escaped.
local function xmlEscape(s)
    s = tostring(s == nil and "" or s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&#39;")
    return s
end

-- numOr(v, default): a finite number, else the default. Used to coerce frame dims defensively.
local INF = 1 / 0
local function numOr(v, default)
    local n = tonumber(v)
    if type(n) ~= 'number' or n ~= n or n == INF or n == -INF then return default end
    return n
end

-- round to a short integer-ish string for clean coords (no trailing float noise).
local function coord(x)
    -- round to nearest integer (DC-grid coords are pixel space; sub-pixel precision is needless).
    local r = math.floor(x + 0.5)
    return tostring(r)
end

-- clamp v into [lo, hi].
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- a bbox is a 4-element array of unit numbers, ordered. Returns x,y,w,h in pixels or nil.
-- The normalized coords are CLAMPED to [0,1] (and so the emitted pixel rect lies inside the
-- [0,frameW] x [0,frameH] frame) so a model bbox that overshoots (e.g. {-0.5,0.2,1.5,1.2})
-- never renders outside the image (no x="-50" / width="200"). After clamping we also order the
-- edges so a degenerate / inverted box yields a non-negative width/height.
local function denorm(bbox, fw, fh)
    if type(bbox) ~= 'table' then return nil end
    local xmin, ymin, xmax, ymax = bbox[1], bbox[2], bbox[3], bbox[4]
    if type(xmin) ~= 'number' or type(ymin) ~= 'number'
        or type(xmax) ~= 'number' or type(ymax) ~= 'number' then
        return nil
    end
    -- reject non-finite coords (NaN / inf) rather than emitting garbage.
    if xmin ~= xmin or ymin ~= ymin or xmax ~= xmax or ymax ~= ymax then return nil end
    if xmin == INF or xmin == -INF or ymin == INF or ymin == -INF
        or xmax == INF or xmax == -INF or ymax == INF or ymax == -INF then return nil end
    -- clamp normalized coords to [0,1], then order edges (min<=max).
    xmin = clamp(xmin, 0, 1); xmax = clamp(xmax, 0, 1)
    ymin = clamp(ymin, 0, 1); ymax = clamp(ymax, 0, 1)
    if xmax < xmin then xmin, xmax = xmax, xmin end
    if ymax < ymin then ymin, ymax = ymax, ymin end
    -- denormalize to pixels; the result is guaranteed within [0,frameW] x [0,frameH].
    local x = xmin * fw
    local y = ymin * fh
    local w = (xmax - xmin) * fw
    local h = (ymax - ymin) * fh
    return x, y, w, h
end

-- a valid embeddable image data URI is a data:image/ payload (guard against script/other schemes).
local function safeImageUri(uri)
    if type(uri) ~= 'string' then return nil end
    if uri:find("^data:image/") then return uri end
    return nil
end

function M.render(opts)
    opts = type(opts) == 'table' and opts or {}
    local fw = numOr(opts.frameW, 0)
    local fh = numOr(opts.frameH, 0)
    if fw < 0 then fw = 0 end
    if fh < 0 then fh = 0 end

    local parts = {}
    parts[#parts + 1] = ('<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" '
        .. 'viewBox="0 0 %s %s">'):format(coord(fw), coord(fh), coord(fw), coord(fh))

    -- optional base image (the preview) — embedded only when the data URI is data:image/.
    local img = safeImageUri(opts.imageDataUri)
    if img then
        parts[#parts + 1] = ('<image x="0" y="0" width="%s" height="%s" href="%s" '
            .. 'xlink:href="%s"/>'):format(coord(fw), coord(fh), xmlEscape(img), xmlEscape(img))
    end

    local dets = type(opts.detections) == 'table' and opts.detections or {}
    for di = 1, #dets do
        local d = dets[di]
        if type(d) == 'table' then
            local x, y, w, h = denorm(d.bbox, fw, fh)
            if x ~= nil then
                local title = xmlEscape(d.title)
                local label = xmlEscape(d.label)
                -- a <g> wrapping the rect + its <title> so the tooltip is the box's hover.
                parts[#parts + 1] = '<g>'
                parts[#parts + 1] = ('<rect x="%s" y="%s" width="%s" height="%s" '
                    .. 'fill="none" stroke="blue" stroke-width="2">'):format(
                    coord(x), coord(y), coord(w), coord(h))
                parts[#parts + 1] = '<title>' .. title .. '</title>'
                parts[#parts + 1] = '</rect>'
                -- a visible label near the top-left of the box.
                parts[#parts + 1] = ('<text x="%s" y="%s" fill="blue" font-size="14" '
                    .. 'font-family="sans-serif">%s</text>'):format(
                    coord(x + 2), coord(y + 14), label)
                parts[#parts + 1] = '</g>'
            end
        end
    end

    parts[#parts + 1] = '</svg>'
    return table.concat(parts)
end

return M
