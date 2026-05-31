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
-- RULE (toWritable):
--   * If the name ends with '?' (one or more, defensively), drop that trailing run of '?' plus
--     any surrounding trailing whitespace, then append ' (uncertain)'.
--   * Names WITHOUT a trailing '?' are returned UNCHANGED (confident keywords are untouched).
--   * Idempotent: a name already ending in ' (uncertain)' has no trailing '?', so it is left
--     as-is -> re-running the plan against already-stored names produces zero new adds.
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
    -- Strip a trailing run of '?' (defensive against any '??') plus surrounding whitespace.
    local stem, n = name:gsub('%s*%?+%s*$', '')
    if n == 0 then
        return name                       -- no trailing '?': confident/clean name, unchanged
    end
    stem = (stem:gsub('%s+$', ''))        -- trim any residual trailing whitespace on the stem
    if stem == '' then return name end    -- pathological: never emit a bare marker
    return stem .. M.MARKER
end

return M
