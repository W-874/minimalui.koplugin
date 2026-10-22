-- Minimal Home 0.1.0 | KOReader / Kindle Keyboard (K3)
-- Only a home overlay. No book scanning, covers, patches or reader overrides.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")

local Screen = Device.screen
local SETTINGS_KEY = "minimalhome_autoshow"

local function bookInfo()
    local path = G_reader_settings:readSetting("lastfile")
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then
        return nil
    end
    local title = path:match("([^/]+)$") or path
    title = title:gsub("%.[^.]+$", "")
    local fraction = 0
    -- Broken or old sidecars must never prevent the home from opening.
    local ok, props, percent = pcall(function()
        local doc = DocSettings:open(path)
        return doc:readSetting("doc_props"), doc:readSetting("percent_finished")
    end)
    if ok then
        if type(props) == "table" then
            title = props.display_title or props.title or title
        end
        if type(percent) == "number" then
            fraction = math.max(0, math.min(percent, 1))
        end
    end
    return { title = tostring(title), fraction = fraction }
end

local function batteryText()
    if not Device:hasBattery() then return "" end
    local ok, value = pcall(function()
        return Device:getPowerDevice():getCapacity()
    end)
    if ok and type(value) == "number" then
        return string.format("%d%%", math.floor(value + 0.5))
    end
    return ""
end

local Home = InputContainer:extend{
    name = "minimalhome_screen",
    stop_events_propagation = true,
}

function Home:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.margin = math.floor(self.width * 0.065)
    self.content_width = self.width - self.margin * 2
    self.book = bookInfo()
    self.selected = self.book and 1 or 2
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.key_events.MoveUp = { { "Up" } }
    self.key_events.MoveDown = { { "Down" } }
    self.key_events.Activate = { { "Press" } }
    self.key_events.CloseHome = { { Device.input.group.Back } }
    self.key_events.ShowNativeMenu = { { "Menu" } }
    self[1] = self:buildView()
end

local function text(value, size, bold)
    return TextWidget:new{
        text = value,
        face = Font:getFace("cfont", size),
        bold = bold or false,
    }
end

function Home:rule()
    return LineWidget:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.content_width, h = 1 },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
end

function Home:actionRow(label, idx)
    local selected = self.selected == idx
    local pad = 12
    -- A fixed-width TextBoxWidget lets the selection highlight fill the row.
    local row = TextBoxWidget:new{
        text = "      " .. label,
        face = Font:getFace("cfont", 21),
        width = self.content_width - pad * 2,
        height = 43,
        use_xtext = false,
    }
    local frame = FrameContainer:new{
        bordersize = 0,
        margin = 0,
        padding = pad,
        background = selected and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
        row,
    }
    self.rows[idx] = frame
    return frame
end

function Home:buildView()
    self.rows = {}
    local width = self.content_width
    local headerLeft = text("KO / HOME", 17, true)
    local status = os.date("%H:%M") .. "   " .. batteryText()
    local headerRight = text(status, 16)
    local gap = math.max(10, width - headerLeft:getWidth() - headerRight:getWidth())
    local vg = VerticalGroup:new{ align = "left" }

    vg[#vg + 1] = HorizontalGroup:new{
        headerLeft, HorizontalSpan:new{ width = gap }, headerRight,
    }
    vg[#vg + 1] = VerticalSpan:new{ width = 16 }
    vg[#vg + 1] = self:rule()
    vg[#vg + 1] = VerticalSpan:new{ width = 62 }
    vg[#vg + 1] = text("CONTINUE READING", 16)
    vg[#vg + 1] = VerticalSpan:new{ width = 20 }

    if self.book then
        local featured = FrameContainer:new{
            bordersize = 0, margin = 0, padding = 9,
            background = self.selected == 1 and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
            TextBoxWidget:new{
                text = self.book.title,
                face = Font:getFace("cfont", 33),
                bold = true,
                width = width - 18,
                height = 88,
                height_overflow_show_ellipsis = true,
                use_xtext = false,
            },
        }
        self.rows[1] = featured
        vg[#vg + 1] = featured
        vg[#vg + 1] = VerticalSpan:new{ width = 16 }
        vg[#vg + 1] = ProgressWidget:new{
            width = width, height = 6,
            margin_h = 0, margin_v = 0,
            radius = 0, bordersize = 0,
            bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
            fillcolor = Blitbuffer.COLOR_BLACK,
            percentage = self.book.fraction,
        }
        vg[#vg + 1] = VerticalSpan:new{ width = 9 }
        vg[#vg + 1] = text(string.format("%d%%    PRESS TO READ", math.floor(self.book.fraction * 100 + 0.5)), 16)
    else
        vg[#vg + 1] = TextBoxWidget:new{
            text = "No recently opened book. Choose Library to begin.",
            face = Font:getFace("cfont", 22),
            width = width,
            height = 95,
            use_xtext = false,
        }
    end

    vg[#vg + 1] = VerticalSpan:new{ width = 52 }
    vg[#vg + 1] = self:rule()
    vg[#vg + 1] = self:actionRow("LIBRARY", 2)
    vg[#vg + 1] = self:rule()
    vg[#vg + 1] = self:actionRow("HISTORY", 3)
    vg[#vg + 1] = self:rule()
    vg[#vg + 1] = self:actionRow("KOReader MENU", 4)
    vg[#vg + 1] = self:rule()
    vg[#vg + 1] = VerticalSpan:new{ width = 32 }
    vg[#vg + 1] = text("UP / DOWN  ·  PRESS  ·  BACK", 14)

    return FrameContainer:new{
        margin = 0,
        bordersize = 0,
        padding = 0,
        padding_left = self.margin,
        padding_top = math.floor(self.height * 0.042),
        vg,
    }
end

function Home:paintTo(bb, x, y)
    -- An opaque fullscreen background is essential over the existing FileManager.
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    InputContainer.paintTo(self, bb, x, y)
end

-- A single repaint on selection: keep the already-laid-out widgets and fonts.
-- In particular, never rebuild the book title or read sidecars per key press.
function Home:setSelection(next_selection)
    if self.selected == next_selection then return true end
    local old_row = self.rows[self.selected]
    if old_row then old_row.background = Blitbuffer.COLOR_WHITE end
    self.selected = next_selection
    local new_row = self.rows[next_selection]
    if new_row then new_row.background = Blitbuffer.COLOR_LIGHT_GRAY end
    UIManager:setDirty(self, "ui")
    return true
end

function Home:onMoveUp()
    return self:setSelection(math.max(self.book and 1 or 2, self.selected - 1))
end

function Home:onMoveDown()
    return self:setSelection(math.min(4, self.selected + 1))
end

function Home:onActivate()
    local selected = self.selected
    local host = self.host
    UIManager:close(self)
    if selected == 1 and self.book then
        host:onOpenLastDoc()
    elseif selected == 3 then
        host.history:onShowHist()
    elseif selected == 4 then
        host.menu:onShowMenu()
    end
    -- Selection 2: simply reveal the native file browser underneath.
    return true
end

function Home:onCloseHome()
    UIManager:close(self)
    return true
end

function Home:onShowNativeMenu()
    UIManager:close(self)
    self.host.menu:onShowMenu()
    return true
end

function Home:onHome()
    return self:onCloseHome()
end

local MinimalHome = WidgetContainer:extend{
    name = "minimalui",
    is_doc_only = false,
}

function MinimalHome:init()
    -- Only runs in FileManager. It does not hook into the reader.
    if self.ui.document then return end
    self.ui.menu:registerToMainMenu(self)
    self.ui:registerPostInitCallback(function()
        -- Defer until the underlying FileManager has been shown.
        if G_reader_settings:readSetting(SETTINGS_KEY, true) then
            UIManager:nextTick(function()
                self:showHome()
            end)
        end
    end)
end

function MinimalHome:showHome()
    if self.screen then return end
    self.screen = Home:new{ host = self.ui }
    local screen = self.screen
    screen.onCloseWidget = function()
        self.screen = nil
        UIManager:setDirty(nil, "full")
    end
    UIManager:show(screen, "full")
end

function MinimalHome:addToMainMenu(menu_items)
    menu_items.minimal_ui = {
        text = "Minimal Home",
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = "Show home now",
                callback = function() self:showHome() end,
            },
            {
                text = "Show home when file browser starts",
                checked_func = function()
                    return G_reader_settings:readSetting(SETTINGS_KEY, true)
                end,
                callback = function()
                    local enabled = G_reader_settings:readSetting(SETTINGS_KEY, true)
                    G_reader_settings:saveSetting(SETTINGS_KEY, not enabled)
                end,
            },
        },
    }
end

return MinimalHome
