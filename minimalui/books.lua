-- Read-only book access. No database, document rendering or cover decoding.
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Books = {}

function Books.documentsDirectory()
    -- KOReader exposes the Kindle storage mount as home_dir, not documents.
    -- Do not follow the native file browser's configurable home/last directory.
    if Device:isKindle() and Device.home_dir then
        return Device.home_dir:gsub("/+$", "") .. "/documents"
    end
    return nil, _("The documents source is currently available on Kindle devices.")
end

function Books.isFile(path)
    return type(path) == "string" and lfs.attributes(path, "mode") == "file"
end

local function collect(root, result)
    local count, eligibility = 0, {}
    for name in lfs.dir(root) do
        if name:sub(1, 1) ~= "." then
            local path = root .. "/" .. name
            -- Cache extension eligibility only for this directory pass; a
            -- newly registered native provider is visible on the next pass.
            local suffix = (name:match("%..*$") or ""):lower()
            local eligible = eligibility[suffix]
            if eligible == nil then
                eligible = not not DocumentRegistry:getProviders(path)
                eligibility[suffix] = eligible
            end
            if eligible and lfs.symlinkattributes(path, "mode") == "file" then
                count = count + 1
                if result then result[#result + 1] = { path = path, title = name } end
            end
        end
    end
    return count
end

function Books.scan()
    local root, reason = Books.documentsDirectory()
    if not root then return nil, reason end
    local result = {}
    local ok = pcall(collect, root, result)
    if not ok then return nil, _("Unable to read the Kindle documents directory.") end
    table.sort(result, function(a, b) return a.title < b.title end)
    return result
end

function Books.count()
    local root = Books.documentsDirectory()
    if not root then return 0 end
    local ok, count = pcall(collect, root)
    return ok and count or 0
end

return Books
