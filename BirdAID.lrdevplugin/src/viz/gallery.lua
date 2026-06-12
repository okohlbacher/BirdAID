-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/viz/gallery.lua (Phase 12 — GAL-01 single combined detection report)
--
-- PURE module: imports NO Lightroom SDK module, uses NO os.time/date/clock, NO math.random.
-- Deterministic and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation
-- invariant). It requires ONLY src.viz.svg (REUSED verbatim — box math is NOT re-implemented here).
-- The Lr glue that writes this string to a temp file and opens it in the browser is Plan 03.
--
-- WHAT IT DOES (GAL-01): render(photos) -> ONE self-contained <html> page with one <section> per
-- photo, each embedding that photo's svg.render body plus an escaped caption (file label + the
-- per-detection labels). A 200-photo run opens as ONE page, not 200 browser tabs (the flood guard).
--
-- SECURITY:
--   * Markup injection (T-12-04 / ASVS V5): EVERY dynamic string (file label, detection label,
--     any user-prompt-derived text reflected in a caption) passes through xmlEscape BEFORE embed.
--     xmlEscape is the single-source escaper from src.viz.xml (shared with svg.lua; & escaped FIRST
--     so the entity ampersands of the later replacements are not double-escaped). There is NO public
--     raw HTML/SVG body passthrough
--     for user/provider content — render builds every svg body itself via svg.render.
--   * Image embedding (T-12-04b / CODEX MEDIUM-2): constrained to GENERATED RASTER base64 ONLY.
--     gallery accepts an imageDataUri ONLY when it matches `^data:image/jpeg;base64,` or
--     `^data:image/png;base64,` (the raster previews this pipeline produces). It MUST reject
--     `data:image/svg+xml` (an active-content vector), any non-base64 `data:image/*`, and any
--     non-data: scheme. It does NOT reuse svg.safeImageUri's loose `^data:image/` guard (which
--     would admit svg+xml). A rejected uri is dropped to nil and ONLY the vetted (or nil) uri is
--     passed down to svg.render, so the loose svg guard can never admit a uri the gallery refused.
--
-- M.render(photos) where photos[i] = { frameW, frameH, imageDataUri, detections, label } ->
--   ONE html string. render({}) / render(nil) -> a valid empty page (never raises).
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack global.

local svg = require('src.viz.svg')
local xml = require('src.viz.xml')

local M = {}

-- xmlEscape: the single-source escaper (src.viz.xml), shared with svg.lua. & is escaped FIRST so
-- the entity ampersands introduced by the later replacements are not double-escaped.
local xmlEscape = xml.xmlEscape

-- safeRasterUri(uri): STRICT raster-only guard. Returns the uri ONLY when it is a generated
-- jpeg/png base64 data URI; nil otherwise. Deliberately STRICTER than svg.safeImageUri (which only
-- guards `^data:image/` and so admits `data:image/svg+xml`, a script vector). Rejects: svg+xml,
-- any non-base64 data:image/*, and any non-data: scheme.
local function safeRasterUri(uri)
    if type(uri) ~= 'string' then return nil end
    if uri:find('^data:image/jpeg;base64,') then return uri end
    if uri:find('^data:image/png;base64,') then return uri end
    return nil
end

-- captionFor(photo): the escaped caption text — the file label followed by each detection label.
local function captionFor(photo)
    local parts = {}
    parts[#parts + 1] = xmlEscape(photo.label)
    local dets = type(photo.detections) == 'table' and photo.detections or {}
    for di = 1, #dets do
        local d = dets[di]
        if type(d) == 'table' and d.label ~= nil then
            parts[#parts + 1] = ' &middot; ' .. xmlEscape(d.label)
        end
    end
    return table.concat(parts)
end

-- minimal stacked-gallery CSS (static, no dynamic content — safe to embed verbatim).
local STYLE = 'body{font-family:sans-serif;margin:1em;background:#fafafa}'
    .. 'section{margin:0 0 2em;padding:0.5em;border:1px solid #ddd;background:#fff}'
    .. 'h2{font-size:14px;margin:0 0 0.5em;font-weight:600}'
    .. 'svg{max-width:100%;height:auto;border:1px solid #eee}'

function M.render(photos)
    if type(photos) ~= 'table' then photos = {} end

    local parts = {}
    parts[#parts + 1] = '<!DOCTYPE html><html><head><meta charset="utf-8">'
    parts[#parts + 1] = '<title>BirdAID detections</title><style>' .. STYLE .. '</style></head><body>'

    for i = 1, #photos do
        local photo = photos[i]
        if type(photo) == 'table' then
            -- vet the image uri to generated raster base64 ONLY before handing it to svg.render.
            local img = safeRasterUri(photo.imageDataUri)
            local body = svg.render({
                frameW = photo.frameW,
                frameH = photo.frameH,
                imageDataUri = img,                 -- nil if rejected
                detections = photo.detections,
            })
            parts[#parts + 1] = '<section>'
            parts[#parts + 1] = '<h2>' .. captionFor(photo) .. '</h2>'
            parts[#parts + 1] = body
            parts[#parts + 1] = '</section>'
        end
    end

    parts[#parts + 1] = '</body></html>'
    return table.concat(parts)
end

return M
