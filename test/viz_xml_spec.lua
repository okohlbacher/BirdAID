-- test/viz_xml_spec.lua (Wave-D D1 — single-source XML escaper)
--
-- Exercises BirdAID.lrdevplugin/src/viz/xml.lua directly: a PURE module hoisting the xmlEscape that
-- svg.lua and gallery.lua previously each carried verbatim. The escaper is the security backstop
-- against markup injection, so it stays DIRECTLY unit-tested even though both consumers also cover
-- it indirectly via render().
--
-- Loaded via dofile; runner globals assert_eq / assert_true. Lua 5.1 common subset.

local xml = require('src.viz.xml')

assert_true(type(xml) == 'table', "require 'src.viz.xml' resolves")
assert_true(type(xml.xmlEscape) == 'function', "exposes xmlEscape")

local esc = xml.xmlEscape

-- All five special chars escape to the documented entities.
assert_eq(esc('&'), '&amp;', "& escapes to &amp;")
assert_eq(esc('<'), '&lt;', "< escapes to &lt;")
assert_eq(esc('>'), '&gt;', "> escapes to &gt;")
assert_eq(esc('"'), '&quot;', '" escapes to &quot;')
assert_eq(esc("'"), '&#39;', "' escapes to &#39;")

-- & MUST be escaped FIRST so the entities introduced by later replacements are not double-escaped.
assert_eq(esc('a & b < c'), 'a &amp; b &lt; c', "ampersand escaped first, no double-escape")
assert_eq(esc('<&>'), '&lt;&amp;&gt;', "mixed run: no entity ampersand re-escaped")

-- A markup-injection attempt is fully neutralised (no surviving raw tag).
local injected = esc('<script>alert("x")</script>')
assert_true(injected:find('<script', 1, true) == nil, "raw <script must not survive")
assert_true(injected:find('&lt;script&gt;', 1, true) ~= nil, "script tag escaped")

-- nil and non-string inputs coerce safely (never raise).
assert_eq(esc(nil), '', "nil coerces to empty string")
assert_eq(esc(42), '42', "number coerces via tostring")
assert_eq(esc(''), '', "empty string is unchanged")
