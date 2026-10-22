-- Loads the native cover of exactly one book (custom cover first), scaled to fit.
-- The native BookInfo:getCoverImage() is not used: if getCoverPageImage() raises, it leaves
-- the document open and its DocumentRegistry refcount leaked. This runs the same registry
-- chain with every step protected so the document is always closed.
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local RenderImage = require("ui/renderimage")
local logger = require("logger")

local Cover = {}

local function freeBB(bb)
    if bb and bb.free then pcall(bb.free, bb) end
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
        freeBB(bb)
        return nil, tostring(bb)
    end
    if not bb then return nil, "no cover" end
    return bb
end

local function customCoverFile(path)
    local ok, file = pcall(DocSettings.findCustomCoverFile, DocSettings, path)
    if ok and type(file) == "string" and file ~= "" then return file end
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
function Cover.load(path, height, max_width)
    if type(path) ~= "string" or path == "" then return nil, "invalid path" end
    height = type(height) == "number" and math.floor(height) or 0
    max_width = type(max_width) == "number" and math.floor(max_width) or 0
    if height < 1 or max_width < 1 then return nil, "invalid size" end

    local bb, err
    local custom = customCoverFile(path)
    if custom then bb, err = extract(custom) end
    if not bb then bb, err = extract(path) end
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
