-- SPDX-License-Identifier: MIT
-- BirdAID.lrdevplugin/src/keyword_name.lua (BL-15 fix — uncertain keyword write-back)
--
-- PURE module: imports NO Lightroom SDK namespace and requires nothing, so it is
-- require-able under stock lua / lua5.1 / luajit for offline unit testing (the
-- separation invariant). It maps a RENDERED keyword display name (which may carry the
-- trailing '?' uncertainty marker emitted by src.keyword.render) to a Lightroom-WRITABLE
-- catalog keyword name.
--
-- WHY (root cause, debug session uncertain-keyword-write-fail / BACKLOG BL-15):
--   LrCatalog:createKeyword REJECTS the '?' character -- it returns nil (no throw), so EVERY
--   uncertain/degraded keyword ("Common (Scientific)?", "Genus sp.?", "Family (family)?") --
--   the NORMAL graceful-degradation case -- silently failed to write. Confident names (no '?')
--   wrote fine. The locked '?' marker is therefore AMENDED for the STORED catalog name to a
--   writable ' (uncertain)' suffix (see the ADR). The rendered display/report form keeps '?'.
--
-- RULE (toWritable): produce a name that LrCatalog:createKeyword will accept.
--   (1) Trailing '?' uncertainty marker -> ' (uncertain)'. If the name ends with '?' (one or more,
--       defensively), drop that trailing run of '?' plus surrounding trailing whitespace, then
--       append ' (uncertain)'. Names without a trailing '?' keep their stem unchanged.
--   (2) COMMAS removed. LrC uses comma as the keyword delimiter, so createKeyword REJECTS any name
--       containing ',' (returns nil). The AI sometimes returns a multi-language common name
--       ("Western Grebe, Westlicher Haubentaucher"); replace each comma with a space and collapse
--       the run so the name stays writable. (A nicer English-only fix is a prompt/render concern;
--       this is the safety net at the write boundary — see BACKLOG.)
--   * Idempotent: a name already ending ' (uncertain)' has no trailing '?', and a comma-free name is
--     left as-is -> re-running the plan against already-stored names produces zero new adds.
--   * Defensive: a non-string is passed through unchanged; a name that is ONLY a marker
--     (empty stem) is returned unchanged rather than producing a bare ' (uncertain)'.
--
-- Strictly Lua 5.1 common subset: no \u{}, no //, no goto, no <close>; unpack is global.
-- Imports no SDK and is kept clean of the SDK-import token so the negative-purity grep is quiet.

local M = {}

-- The writable uncertainty suffix that REPLACES the illegal trailing '?'. Uses only characters
-- proven to be accepted by createKeyword (letters, space, parentheses).
M.MARKER = ' (uncertain)'

-- toWritable(name) -> writable string | name unchanged | non-string passthrough
function M.toWritable(name)
    if type(name) ~= 'string' then return name end
    local out = name
    -- (1) commas are illegal in LrC keyword names -> replace with space, collapse, trim. Done FIRST
    --     so a comma sitting before the marker (e.g. "A?,") cannot RE-EXPOSE a trailing '?' after
    --     the marker step (CODEX review).
    if out:find(',', 1, true) then
        out = (out:gsub(',', ' '))
        out = (out:gsub('%s+', ' '))
        out = (out:gsub('^%s+', ''):gsub('%s+$', ''))
    end
    -- (2) trailing '?' marker -> ' (uncertain)' (after comma cleanup so the tail is final).
    local stem, n = out:gsub('%s*%?+%s*$', '')
    if n > 0 then
        stem = (stem:gsub('%s+$', ''))        -- trim residual trailing whitespace on the stem
        if stem ~= '' then out = stem .. M.MARKER end   -- else pathological: keep pre-marker `out`
    end
    -- (3) never emit a blank name (pathological comma-only / marker-only input): fall back to the
    --     original input unchanged rather than "" (the writer will simply skip a truly-blank name).
    if out == '' then return name end
    return out
end

return M
