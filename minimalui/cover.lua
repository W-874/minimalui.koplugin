-- Loads the native cover of exactly one book (custom cover first), scaled to fit.
-- Static images avoid opening a book; other covers use the native registry.
-- The fallback protects the BookInfo:getCoverImage() registry chain: unlike that
-- helper, it always closes the document even if getCoverPageImage() raises.
local CanvasContext = require("document/canvascontext")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local RenderImage = require("ui/renderimage")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Cover = {}
local retained
local reader_font = require("document/credocument").default_font

local function freeBB(bb)
    if bb and bb.free then pcall(bb.free, bb) end
end

-- A single Reader handoff, never a document/widget cache. Each operation
-- transfers ownership; callers must detach Home's entries before keeping them.
function Cover.clear(path)
    local entries = retained
    if not entries then return end
    for key, entry in pairs(entries) do
        if path == nil or entry.path == path then
            entries[key] = nil
            freeBB(entry.bb)
        end
    end
    if next(entries) == nil then retained = nil end
end

function Cover.keep(entries)
    Cover.clear()
    local kept, count = {}, 0
    for key, entry in pairs(entries or {}) do
        entries[key] = nil
        if count < 4 and entry.bb and entry.signature and not entry.invalid then
            kept[key] = { path = entry.path, signature = entry.signature, bb = entry.bb }
            count = count + 1
        else
            freeBB(entry.bb)
        end
    end
    retained = count > 0 and kept or nil
end

function Cover.take()
    local entries = retained
    retained = nil
    return entries or {}
end

-- CRE's preferred font bias is global, including SVG image rendering. Record
-- only its last live Reader value, never the Reader or its document.
function Cover.noteReaderFont(face)
    if type(face) == "string" and face ~= "" then reader_font = face end
end

-- Opens `file` through the registry, reads its cover page image and always closes the
-- document again. Returns an owned BlitBuffer or nil, err.
local function extract(file)
    local opened, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, file)
    if not opened then return nil, tostring(doc) end
    if not doc then return nil, "no document provider" end

    local ok, bb = pcall(function()
        if doc.loadDocument then doc:loadDocument(false) end -- CreDocument: metadata only
        return doc:getCoverPageImage()
    end)
    local closed, close_err = pcall(doc.close, doc)
    if not closed then logger.warn("minimalui cover: close failed", file, close_err) end

    if not ok then
        return nil, tostring(bb)
    end
    if not bb then return nil, "no cover" end
    return bb
end

-- Static custom images use the selected provider's exact decoder/rasterizer,
-- without DocumentRegistry's two GC sweeps or the full-size cover copies.
local function extractImage(file)
    local extension = file:match("%.([^.]+)$")
    extension = extension and extension:lower()
    if extension ~= "jpg" and extension ~= "jpeg" and extension ~= "png" then return end

    local doc, page, bb
    local ok = pcall(function()
        local provider = DocumentRegistry:getProvider(file)
        if not provider then return end
        if provider.provider == "picdocument" then
            local Pic = require("ffi/pic")
            Pic.color = CanvasContext.is_color_rendering_enabled
            doc = Pic.openDocument(file)
            bb = doc.image_bb
            doc.image_bb = nil -- transfer ownership before closing the image document
        elseif provider.provider == "mupdf" and G_defaults:readSetting("DKOPTREADER_CONFIG_TEXT_WRAP") ~= 1 then
            -- Same page, Canvas-sized raster, draw context and BB type as
            -- KoptInterface:getCoverPageImage, before the usual Home scaling.
            doc = require("ffi/mupdf").openDocument(file)
            doc:setColorRendering(CanvasContext.is_color_rendering_enabled)
            page = doc:openPage(1)
            local dc = require("ffi/drawcontext").new()
            local width, height = page:getSize(dc)
            local zoom = math.min(CanvasContext:getWidth() / width, CanvasContext:getHeight() / height)
            dc:setZoom(zoom)
            bb = page:draw_new(dc, math.ceil(width * zoom - 0.001), math.ceil(height * zoom - 0.001), 0, 0)
        end
    end)
    if page then pcall(page.close, page) end
    if doc then
        local closed, close_err = pcall(doc.close, doc)
        if not closed then logger.warn("minimalui cover: close failed", file, close_err) end
    end
    if ok then return bb end
    freeBB(bb)
end

local function customCoverFile(path)
    local ok, file = pcall(DocSettings.findCustomCoverFile, DocSettings, path)
    if ok and type(file) == "string" and file ~= "" then return file, true end
    return nil, ok
end

-- Retained Home buffers are reusable only while their source and raster context
-- match. Native metadata events also invalidate them (same-second writes).
function Cover.resolve(path)
    -- A cold card needs both the signature and the selected source. Resolve
    -- custom-cover directories once and pass this short-lived result to load.
    local custom, found = customCoverFile(path)
    local resolved = { path = path, custom = custom }
    if not found then return resolved end
    local ok, signature = pcall(function()
        local custom = resolved.custom
        local source = custom or path
        local attr = lfs.attributes(source)
        local book = custom and lfs.attributes(path) or attr
        if not attr or attr.mode ~= "file" or not book or book.mode ~= "file" then return end
        -- Resolve the actual saved provider, not the sidecar's modification
        -- time: ordinary progress/annotation saves do not change cover pixels.
        local provider = DocumentRegistry:getProvider(source)
        local fallback = custom and DocumentRegistry:getProvider(path) or provider
        if not provider or not fallback then return end
        -- Loading the module does not initialize the engine/font list or open
        -- a document. Its gamma getter observes native global image state.
        local cre = require("libs/libkoreader-cre")
        local family = G_reader_settings:readSetting("cre_font_family_fonts") or {}
        return table.concat({
            source, tostring(attr.size), tostring(attr.modification), tostring(attr.change),
            tostring(attr.ino), tostring(attr.dev), tostring(book.size), tostring(book.modification),
            tostring(book.change), tostring(book.ino), tostring(book.dev),
            tostring(provider.provider), tostring(fallback.provider),
            tostring(reader_font), tostring(cre.getGammaIndex()),
            tostring(G_reader_settings:readSetting("monospace_font")),
            tostring(G_reader_settings:readSetting("fallback_font")),
            tostring(G_reader_settings:readSetting("additional_fallback_fonts")),
            tostring(G_reader_settings:readSetting("cre_adjusted_fallback_font_sizes")),
            tostring(G_reader_settings:readSetting("cre_monospace_scaling")),
            tostring(G_reader_settings:readSetting("cre_font_family_ignore_font_names")),
            tostring(family.serif), tostring(family["sans-serif"]), tostring(family.cursive),
            tostring(family.fantasy), tostring(family.monospace), tostring(family.math),
            tostring(family.emoji), tostring(family.fangsong),
            tostring(CanvasContext.is_color_rendering_enabled),
            tostring(CanvasContext:getWidth()), tostring(CanvasContext:getHeight()),
            tostring(G_defaults:readSetting("DKOPTREADER_CONFIG_TEXT_WRAP")),
        }, "\0")
    end)
    resolved.signature = ok and signature or nil
    return resolved
end

function Cover.signature(path)
    return Cover.resolve(path).signature
end

-- Aspect-preserving size that fits both height and max_width.
local function fitSize(bw, bh, height, max_width)
    local w = math.floor(bw * height / bh + 0.5)
    local h = height
    if w > max_width then
        w = max_width
        h = math.floor(bh * max_width / bw + 0.5)
    end
    return math.max(1, math.min(w, max_width)), math.max(1, math.min(h, height))
end

--- Returns an owned, aspect-preserving BlitBuffer scaled to `height` (or narrower/shorter when
--- that would exceed `max_width`), or nil, err when the book has no cover. Caller frees it.
function Cover.load(path, height, max_width, resolved)
    if type(path) ~= "string" or path == "" then return nil, "invalid path" end
    height = type(height) == "number" and math.floor(height) or 0
    max_width = type(max_width) == "number" and math.floor(max_width) or 0
    if height < 1 or max_width < 1 then return nil, "invalid size" end

    local bb, err
    local custom
    if resolved and resolved.path == path then custom = resolved.custom
    else custom = customCoverFile(path) end
    if custom then
        bb = extractImage(custom)
        if not bb then bb, err = extract(custom) end
    end
    if not bb then
        -- JPEG/PNG documents have the same native decoder as custom covers.
        -- Transfer its buffer without the registry/full-size-copy overhead.
        bb = extractImage(path)
        if not bb then bb, err = extract(path) end
    end
    if not bb then return nil, err end

    local bw, bh = bb:getWidth(), bb:getHeight()
    if bw < 1 or bh < 1 then
        freeBB(bb)
        return nil, "empty cover"
    end
    local w, h = fitSize(bw, bh, height, max_width)
    -- scaleBlitBuffer frees the source on success and returns it untouched when already sized.
    local ok, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb, w, h)
    if not ok or not scaled then
        freeBB(bb)
        return nil, ok and "scale failed" or tostring(scaled)
    end
    return scaled
end

return Cover
