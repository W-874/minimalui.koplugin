-- Home retains the v0.1 hierarchy; native services stay on the FileManager host.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Cover = require("minimalui/cover")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Header = require("minimalui/header")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local Home = InputContainer:extend{
    name = "minimalui_home",
    covers_fullscreen = true,
    stop_events_propagation = true,
}

local function text(value, size, bold, width)
    return TextWidget:new{
        text = value, face = Font:getFace("cfont", size), bold = bold,
        max_width = width,
    }
end

function Home:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.selected = self.selected or 1
    self:bindKeys()
    self[1] = self:buildView()
    if Device:isTouchDevice() then
        self.ges_events.MinimalTap = { GestureRange:new{ ges = "tap", range = self.dimen } }
        self.ges_events.MinimalSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
end

function Home:bindKeys()
    self.key_events = {}
    if not Device:hasKeys() then return end
    self.key_events.MinimalUp = { { "Up" } }
    self.key_events.MinimalDown = { { "Down" } }
    self.key_events.MinimalActivate = { { "Press" } }
    self.key_events.MinimalMenu = { { "Menu" } }
    self.key_events.MinimalBack = { { Device.input.group.Back } }
    self.key_events.Home = { { "Home" } }
    if Device:hasFewKeys() then
        self.key_events.MinimalBack = { { "Left" } }
        self.key_events.MinimalMenu = { { { "Menu", "Right" } } }
    end
end

function Home:rule(width)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = Size.line.medium },
        background = Blitbuffer.COLOR_GRAY,
    }
end

function Home:buildView()
    local scale = function(n) return Screen:scaleBySize(n) end
    local margin = math.floor(self.width * 0.065)
    local width = self.width - 2 * margin
    self.header = Header:new{
        width = self.width, title = "KO/HOME", show_parent = self,
        menu_callback = function() return self:onMinimalMenu() end,
    }
    self.header_height = self.header:getHeight()

    local label = text("CONTINUE READING", 16)
    local percent = self.book and text(self.book.fraction
        and string.format("%d%%", math.floor(self.book.fraction * 100 + 0.5))
        or _("Progress unavailable"), 16, false, width)
    local title_pad, row_pad = scale(9), scale(12)
    self.rows = {}
    local row_height = 0
    for i, item in ipairs(self.item_table) do
        if item.id ~= "continue" then
            local row_text = text(item.text, 21, false, width - 2 * row_pad)
            local row = FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0,
                padding_left = row_pad, padding_right = row_pad,
                padding_top = Size.padding.default, padding_bottom = Size.padding.default,
                background = Blitbuffer.COLOR_WHITE, invert = self.selected == i,
                CenterContainer:new{
                    dimen = Geom:new{ w = width - 2 * row_pad, h = row_text:getSize().h + scale(12) },
                    HorizontalGroup:new{ row_text, HorizontalSpan:new{
                        width = math.max(0, width - 2 * row_pad - row_text:getWidth()),
                    } },
                },
            }
            self.rows[i] = row
            row_height = row_height + row:getSize().h + Size.line.medium
        end
    end
    -- Reserve all actions before allocating the v0.1 whitespace and book title.
    local fixed = row_height + Size.line.medium
        + (percent and percent:getSize().h + scale(6) or 0)
    local available = self.height - self.header_height - fixed
    local title_face = Font:getFace("cfont", self.book and 25 or 22)
    local title_height = 2 * math.floor(1.3 * title_face.size + 0.5)
    local cover_limit = math.floor((width - 2 * title_pad) / 3)
    local face_height = title_face.ftsize and title_face.ftsize:getHeightAndAscender() or 0
    local rendered_height = title_height + math.max(0, math.ceil(face_height - title_height / 2))
    local title_gap = scale(20)
    local cover_height = label:getSize().h + title_gap + 2 * title_pad + rendered_height
    self:loadCover(cover_height, cover_limit)
    local cover_width = self.cover_bb and self.cover_bb:getWidth() or 0
    local cover_gap = cover_width > 0 and scale(16) or 0
    self.title_widget = TextBoxWidget:new{
        text = self.book and self.book.title or _("No recently opened book. Choose Library to begin."),
        face = title_face, bold = self.book ~= nil,
        width = width - 2 * title_pad - cover_width - cover_gap,
        height = title_height, height_overflow_show_ellipsis = true,
    }
    local title_frame = FrameContainer:new{
        bordersize = 0, margin = 0, padding = title_pad,
        background = Blitbuffer.COLOR_WHITE,
        invert = self.book ~= nil and self.selected == 1,
        self.title_widget,
    }
    local text_column = VerticalGroup:new{
        align = "left", label, VerticalSpan:new{ width = title_gap }, title_frame,
    }
    local featured_content = HorizontalGroup:new{ align = "top", text_column }
    if self.cover_bb then
        featured_content[#featured_content + 1] = HorizontalSpan:new{ width = cover_gap }
        self.cover_widget = ImageWidget:new{
            image = self.cover_bb, image_disposable = false, scale_factor = 1,
        }
        featured_content[#featured_content + 1] = FrameContainer:new{
            bordersize = 0, inner_bordersize = Size.line.medium, color = Blitbuffer.COLOR_GRAY,
            margin = 0, padding = 0, self.cover_widget,
        }
    else
        self.cover_widget = nil
    end
    local featured = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE, featured_content,
    }
    if self.book then self.rows[1] = featured end
    self.featured_title = title_frame
    local whitespace = math.max(0, available - featured:getSize().h)
    local desired_space = scale(62 + 16 + 9 + 52)
    local ratio = math.min(1, whitespace / desired_space)
    local body = VerticalGroup:new{ align = "left" }
    local function add(widget) body[#body + 1] = widget end
    local function gap(n) add(VerticalSpan:new{ width = math.floor(scale(n) * ratio) }) end
    gap(62)
    add(featured)
    if self.book then
        gap(16)
        add(ProgressWidget:new{
            width = width, height = scale(6), margin_h = 0, margin_v = 0,
            radius = 0, bordersize = 0, bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
            fillcolor = Blitbuffer.COLOR_BLACK, percentage = self.book.fraction or 0,
        })
        gap(9)
        add(percent)
    end
    gap(52)
    add(self:rule(width))
    for i, item in ipairs(self.item_table) do
        if item.id ~= "continue" then
            add(self.rows[i])
            add(self:rule(width))
        end
    end
    return VerticalGroup:new{
        align = "left", self.header,
        FrameContainer:new{
            margin = 0, bordersize = 0, padding = 0, padding_left = margin, body,
        },
    }
end

function Home:loadCover(height, max_width)
    local path = self.book and self.book.path
    if self.cover_path == path and self.cover_height == height and self.cover_limit == max_width then return end
    if self.cover_bb then self.cover_bb:free(); self.cover_bb = nil end
    self.cover_path, self.cover_height, self.cover_limit = path, height, max_width
    if path then self.cover_bb = Cover.load(path, height, max_width) end
end

function Home:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    InputContainer.paintTo(self, bb, x, y)
end

function Home:getFocusId()
    return self.item_table[self.selected] and self.item_table[self.selected].id
end

function Home:setSelection(index)
    if self.selected == index then return true end
    local old, new = self.rows[self.selected], self.rows[index]
    if old then
        if self.item_table[self.selected].id == "continue" then self.featured_title.invert = false
        else old.invert = false end
    end
    self.selected = index
    if new then
        if self.item_table[index].id == "continue" then self.featured_title.invert = true
        else new.invert = true end
    end
    UIManager:setDirty(self, function()
        return "ui", old and old.dimen and new and new.dimen and old.dimen:combine(new.dimen) or self.dimen
    end)
    return true
end

function Home:onMinimalUp()
    return self:setSelection(math.max(1, self.selected - 1))
end

function Home:onMinimalDown()
    return self:setSelection(math.min(#self.item_table, self.selected + 1))
end

function Home:onMinimalActivate()
    local item = self.item_table[self.selected]
    if item and item.callback then item.callback() end
    return true
end

function Home:onMinimalMenu()
    return self.controller:showNativeMenu()
end

function Home:onMinimalBack()
    return self.controller:back()
end

function Home:onHome()
    return true
end

function Home:onMinimalTap(_, ges)
    if ges.pos.y < self.header_height then return self:onMinimalMenu() end
    for i, row in ipairs(self.rows) do
        if row.dimen and row.dimen:contains(ges.pos) then
            self:setSelection(i)
            return self:onMinimalActivate()
        end
    end
    return true
end

function Home:onMinimalSwipe(_, ges)
    if ges.direction == "south" and ges.pos.y < self.header_height then return self:onMinimalMenu() end
    return true
end

function Home:setContent(items, book, index)
    self.item_table, self.book, self.selected = items, book, index
    self:rebuild()
end

function Home:rebuild()
    self:free()
    self[1] = nil
    self.ges_events = {}
    self:init()
    UIManager:setDirty(self, "ui")
end

function Home:onSetDimensions()
    self.controller:queueLayout()
end
Home.onScreenResize = Home.onSetDimensions
Home.onPhysicalKeyboardConnected = Home.onSetDimensions
Home.onPhysicalKeyboardDisconnected = Home.onSetDimensions

function Home:onSetRotationMode(rotation)
    if self.controller:isLive() then
        self.controller.ui:onSetRotationMode(rotation)
        self.controller:queueLayout()
    end
    return true
end

function Home:onCloseWidget()
    self.controller:screenClosed(self)
    self:free()
    if self.cover_bb then self.cover_bb:free(); self.cover_bb = nil end
end

return Home
