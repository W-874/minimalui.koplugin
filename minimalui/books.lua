-- Read-only book access. No database, document rendering or cover decoding.
local Device = require("device")
local DocSettings = require("docsettings")
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

function Books.lastBook()
    local path = G_reader_settings:readSetting("lastfile")
    if not Books.isFile(path) then return nil end
    local title = (path:match("([^/]+)$") or path):gsub("%.[^.]+$", "")
    local fraction
    local ok, props, percent = pcall(function()
        local settings = DocSettings:open(path)
        return settings:readSetting("doc_props"), settings:readSetting("percent_finished")
    end)
    if ok then
        if type(props) == "table" then
            local saved_title = props.display_title or props.title
            if type(saved_title) == "string" and saved_title ~= "" then title = saved_title end
        end
        if type(percent) == "number" and percent == percent then
            fraction = math.max(0, math.min(percent, 1))
        end
    end
    return { path = path, title = title, fraction = fraction }
end

function Books.scan()
    local root, reason = Books.documentsDirectory()
    if not root then return nil, reason end
    -- Provisional foundation only: one directory level, filename order.
    -- Recursive scope, sorting and presentation remain product decisions.
    local ok, books = pcall(function()
        local result = {}
        for name in lfs.dir(root) do
            if name:sub(1, 1) ~= "." then
                local path = root .. "/" .. name
                -- Do not expose directories, symlinks or auxiliary tools as books.
                -- getProviders is extension-only; hasProvider can read sidecars.
                if lfs.symlinkattributes(path, "mode") == "file"
                        and DocumentRegistry:getProviders(path) then
                    result[#result + 1] = { path = path, title = name }
                end
            end
        end
        table.sort(result, function(a, b) return a.title < b.title end)
        return result
    end)
    if not ok then return nil, _("Unable to read the Kindle documents directory.") end
    return books
end

return Books
