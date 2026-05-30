-- test/fixtures/jpeg_fixtures.lua (Phase 3 — PREV-01 SOF-parser fixtures)
--
-- Self-contained, OFFLINE JPEG byte blobs built via string.char, each carrying its
-- expected OUTER (width,height). Returned as a plain Lua table so test/preview_spec.lua
-- can require it (no Lr, no real image files). Strictly Lua 5.1 common subset.
--
-- JPEG layout used here (only the bytes the SOF parser cares about):
--   SOI       = 0xFF 0xD8
--   EOI       = 0xFF 0xD9
--   segment   = 0xFF <marker> <len_hi> <len_lo> <payload...>, where the 2-byte BE
--               length INCLUDES the 2 length bytes (payload = len - 2).
--   SOF0      = 0xFF 0xC0 <len> <precision> <h_hi h_lo> <w_hi w_lo> <components...>
--   SOF2      = 0xFF 0xC2 (progressive) — same dimension offsets as SOF0.
--   APP0/APP1 = 0xFF 0xE0 / 0xFF 0xE1 — opaque payload (walked by length).
--
-- The EXIF-thumbnail fixture (CODEX MUST-FIX 5) embeds a COMPLETE little JPEG (with its
-- own SOF0 carrying DIFFERENT, smaller "thumb" dims) INSIDE an APP1 segment's payload,
-- with the REAL outer SOF0 appearing AFTER. A correct length-walking parser skips the
-- whole APP1 payload and returns the OUTER dims, never the thumbnail's.

local function u8(n) return string.char(n % 256) end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

local SOI = u8(0xFF) .. u8(0xD8)
local EOI = u8(0xFF) .. u8(0xD9)

-- A minimal SOF segment for the given marker (0xC0 baseline / 0xC2 progressive) with
-- a single grayscale component. length = 2 (len bytes) + 1 (precision) + 2 (h) + 2 (w)
-- + 3 (one component descriptor) = 10.
local function sofSegment(marker, w, h)
    local precision = u8(8)
    local component = u8(1) .. u8(0x11) .. u8(0)  -- id=1, sampling=0x11, quant-table=0
    local payload = precision .. be16(h) .. be16(w) .. component
    local len = 2 + #payload
    return u8(0xFF) .. u8(marker) .. be16(len) .. payload
end

-- A generic length-bearing opaque segment (APPn / COM / DHT etc.) with arbitrary payload.
local function segment(marker, payload)
    payload = payload or ""
    local len = 2 + #payload
    return u8(0xFF) .. u8(marker) .. be16(len) .. payload
end

local F = {}

-- (a) Baseline SOF0 JPEG: SOI + APP0 + SOF0(outer dims) + EOI.
F.baseline = {
    bytes = SOI
        .. segment(0xE0, "JFIF\0placeholder")        -- APP0, opaque
        .. sofSegment(0xC0, 640, 480)                 -- outer SOF0
        .. EOI,
    width = 640,
    height = 480,
    label = "baseline SOF0 640x480",
}

-- (b) Progressive SOF2 JPEG: SOI + SOF2(outer dims) + EOI (CODEX MUST-FIX 6: accept SOF2).
F.progressive = {
    bytes = SOI
        .. sofSegment(0xC2, 800, 600)                 -- outer SOF2
        .. EOI,
    width = 800,
    height = 600,
    label = "progressive SOF2 800x600",
}

-- (c) EXIF-embedded-thumbnail JPEG (CODEX MUST-FIX 5): an APP1 whose declared-length
-- payload itself CONTAINS a complete embedded JPEG (SOI + SOF0 with the SMALL thumb dims
-- + EOI). The REAL outer SOF0 (large dims) appears AFTER the APP1. The parser must walk
-- by length and return the OUTER dims (1920x1280), NEVER the thumbnail's (160x120).
do
    local embeddedThumb = SOI .. sofSegment(0xC0, 160, 120) .. EOI
    -- EXIF APP1 payload: an "Exif\0\0" header + the embedded thumbnail JPEG bytes.
    local app1Payload = "Exif\0\0" .. embeddedThumb
    F.exifThumbnail = {
        bytes = SOI
            .. segment(0xE1, app1Payload)             -- APP1 holding the thumbnail, opaque
            .. sofSegment(0xC0, 1920, 1280)           -- the REAL outer SOF0
            .. EOI,
        width = 1920,
        height = 1280,
        thumbWidth = 160,
        thumbHeight = 120,
        label = "EXIF-embedded-thumbnail; outer 1920x1280, thumb 160x120",
    }
end

-- Expose the byte builders so preview_spec can craft adversarial/failing inputs inline.
F.helpers = {
    u8 = u8,
    be16 = be16,
    SOI = SOI,
    EOI = EOI,
    sofSegment = sofSegment,
    segment = segment,
}

return F
