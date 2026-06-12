-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/viz/xml.lua (Wave-D D1 — single-source XML escaper for the viz layer)
--
-- PURE module: imports NO Lr* module, uses NO os.time/date/clock, NO math.random. Deterministic
-- and require-able under stock lua / lua5.1 / luajit (the CODEX-mandated separation invariant).
--
-- WHY THIS EXISTS: svg.lua and gallery.lua each carried a byte-identical xmlEscape (gallery's was
-- literally "COPIED VERBATIM from svg.lua"). The escaper is the single security backstop against
-- markup injection of species names / user-prompt text into the report — having two copies that can
-- drift is a hazard, so the canonical implementation lives here and both consumers require it.
--
-- M.xmlEscape(s): escape the five XML special chars. & MUST be escaped FIRST so the entity
-- ampersands introduced by the later replacements are not double-escaped.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>.

local M = {}

function M.xmlEscape(s)
    s = tostring(s == nil and "" or s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&#39;")
    return s
end

return M
