local Blitbuffer = require("ffi/blitbuffer")
local datetime = require("datetime")
local Device = require("device")
local Font = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Header = InputContainer:extend{
    width = nil,
    title = "",
    fixed_title = nil,
    page = nil,
    show_parent = nil,
    subtitle = nil,
}

local function group(items)
    if #items == 0 then return nil end
    return HorizontalGroup:new(items)
end

function Header:init()
    self.width = self.width or Screen:getWidth()
    if self.page then self.fixed_title = "KO/" .. self.page end
    self.title = self.fixed_title or self.title
    self.title_widget = TextWidget:new{
        text = self.title,
        face = Font:getFace("cfont", 17),
        bold = true,
        padding = 0,
    }
    self.status_widget = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 15),
        padding = 0,
    }
    self:refreshStatus()

    local icon_size = self.title_widget:getSize().h
    local touch_height = Screen:scaleBySize(G_defaults:readSetting("DGENERIC_ICON_SIZE")) + 2 * Size.padding.default
    local button_padding = math.max(Size.padding.default, math.floor((touch_height - icon_size) / 2))
    local function button(icon, callback, hold_callback, icon_rotation_angle)
        if not icon then return nil end
        return IconButton:new{
            icon = icon,
            icon_rotation_angle = icon_rotation_angle or 0,
            width = icon_size,
            height = icon_size,
            padding = button_padding,
            show_parent = self.show_parent,
            callback = callback,
            hold_callback = hold_callback,
        }
    end
    self.menu_button = button("chevron.up", function()
        if self.menu_callback then return self.menu_callback() end
    end, nil, 180)
    self.home_button = self.home_callback and button("home", function()
        return self.home_callback()
    end, self.home_hold_callback) or nil
    self.left_button = self.home_button
    self.buttons = {}
    if self.menu_button then table.insert(self.buttons, self.menu_button) end
    if self.home_button then table.insert(self.buttons, self.home_button) end

    local left_items, right_items = {}, {}
    if self.menu_button then table.insert(left_items, self.menu_button) end
    if self.home_button then table.insert(left_items, self.home_button) end
    for _, extra in ipairs(self.extra_buttons or {}) do
        local extra_button = button(extra.icon, extra.callback, extra.hold_callback)
        if extra_button then
            if extra.role == "left" then
                table.insert(left_items, extra_button)
                self.left_extra_button = self.left_extra_button or extra_button
            else
                table.insert(right_items, extra_button)
                self.right_button = extra_button
            end
            table.insert(self.buttons, extra_button)
        end
    end
    self.left_group = group(left_items)
    if self.status_widget:getSize().w > 0 then
        table.insert(right_items, HorizontalSpan:new{ width = Size.span.horizontal_small })
        table.insert(right_items, self.status_widget)
        table.insert(right_items, HorizontalSpan:new{ width = Size.padding.default })
    end
    self.right_group = group(right_items)
    self.left_width = self.left_group and self.left_group:getSize().w or 0
    self.right_width = self.right_group and self.right_group:getSize().w or 0

    self.subtitle_widget = nil
    if self.subtitle and self.subtitle ~= "" then
        self.subtitle_widget = self:createSubtitle(self.subtitle)
    end
    self:_layout()
end

function Header:createSubtitle(text)
    return TextWidget:new{
        text = text,
        face = Font:getFace("cfont", 17),
        padding = 0,
        max_width = self.width - 2 * Size.padding.default,
    }
end

function Header:_layout()
    local center_width = math.max(0, self.width - 2 * math.max(self.left_width, self.right_width))
    self.title_widget:setMaxWidth(center_width)
    local title_height = self.title_widget:getSize().h
    local icon_height = Screen:scaleBySize(G_defaults:readSetting("DGENERIC_ICON_SIZE"))
    self.bar_height = Size.border.window + math.max(title_height, icon_height + 2 * Size.padding.default) + Size.line.thick
    self.subtitle_height = 0
    if self.subtitle_widget then
        self.subtitle_widget:setMaxWidth(self.width - 2 * Size.padding.default)
        self.subtitle_height = self.subtitle_widget:getSize().h + Size.padding.small
    end
    self.header_height = self.bar_height + self.subtitle_height
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.header_height }

    local overlay = OverlapGroup:new{ dimen = self.dimen, allow_mirroring = false }
    local main_height = self.bar_height - Size.line.thick
    local main = OverlapGroup:new{ dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.bar_height }, allow_mirroring = false }
    main[1] = CenterContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.width, h = main_height },
        self.title_widget,
    }
    if self.left_group then
        main[2] = LeftContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = self.width, h = main_height },
            self.left_group,
        }
    end
    if self.right_group then
        main[3] = RightContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = self.width, h = main_height },
            self.right_group,
        }
    end
    main[4] = LineWidget:new{
        overlap_offset = { 0, main_height },
        dimen = Geom:new{ x = 0, y = main_height, w = self.width, h = Size.line.thick },
        background = Blitbuffer.COLOR_BLACK,
    }
    overlay[1] = main
    if self.subtitle_widget then
        overlay[2] = CenterContainer:new{
            overlap_offset = { 0, self.bar_height },
            dimen = Geom:new{ x = 0, y = self.bar_height, w = self.width, h = self.subtitle_height },
            VerticalGroup:new{
                VerticalSpan:new{ width = Size.padding.small },
                self.subtitle_widget,
            },
        }
    end
    self[1] = overlay
end

function Header:getHeight() return self.header_height end
function Header:getSize() return self.dimen end
function Header:setTitle(title, no_refresh)
    self.native_title = title
    title = self.fixed_title or title
    if self.title == title then return end
    self.title = title
    self.title_widget:setText(title)
    if not no_refresh then UIManager:setDirty(self.show_parent, "ui", self.dimen) end
end
function Header:setSubTitle(subtitle, no_refresh)
    if self.subtitle == subtitle then return end
    if self.folder_title then
        self.subtitle = subtitle
        local path = self.folder_title()
        local folder = path:gsub("/+$", ""):match("([^/]+)$") or "/"
        if self.title == "KO/" .. folder then return end
        self.title = "KO/" .. folder
        self.title_widget:setText(self.title)
        if not no_refresh then UIManager:setDirty(self.show_parent, "ui", self.dimen) end
        return
    end
    local had_subtitle = self.subtitle_widget ~= nil
    local has_subtitle = subtitle ~= nil and subtitle ~= ""
    self.subtitle = subtitle
    if has_subtitle then
        if self.subtitle_widget then
            self.subtitle_widget:setText(subtitle)
        else
            self.subtitle_widget = self:createSubtitle(subtitle)
        end
    else
        if self.subtitle_widget then self.subtitle_widget:free() end
        self.subtitle_widget = nil
    end
    if had_subtitle ~= has_subtitle then self:_layout() end
    if not no_refresh then UIManager:setDirty(self.show_parent, "ui", self.dimen) end
end
function Header:setLeftIcon(icon)
    if self.left_extra_button then self.left_extra_button:setIcon(icon) end
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
end
function Header:setRightIcon(icon)
    if self.right_button then self.right_button:setIcon(icon) end
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
end
function Header:generateVerticalLayout()
    local rows = {}
    for _, button in ipairs(self.buttons) do table.insert(rows, { button }) end
    return rows
end
function Header:refreshStatus()
    if not self.status_widget then return end
    local status = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        local capacity = powerd:getCapacity()
        status = status .. " ⌁" .. powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), capacity) .. capacity .. "%"
        if Device:hasAuxBattery() and powerd:isAuxBatteryConnected() then
            local aux = powerd:getAuxCapacity()
            status = status .. "+" .. powerd:getBatterySymbol(powerd:isAuxCharged(), powerd:isAuxCharging(), aux) .. aux .. "%"
        end
    end
    if self.status_widget.text == status then return end
    self.status_widget:setText(status)
    if self.right_group then
        self.right_group:resetLayout()
        local width = self.right_group:getSize().w
        if width ~= self.right_width then
            self.right_width = width
            self:_layout()
        end
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
    end
end

Header.onResume = Header.refreshStatus

return Header
