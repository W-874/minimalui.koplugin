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

local HeaderButton = IconButton:extend{}

function HeaderButton:onFocus()
    self.focused = true
    return true
end

function HeaderButton:onUnfocus()
    self.focused = false
    return true
end

function HeaderButton:paintTo(bb, x, y)
    IconButton.paintTo(self, bb, x, y)
    if self.focused then
        local inset = Screen:scaleBySize(2)
        bb:invertRect(x + inset, y + inset, self.dimen.w - 2 * inset, self.dimen.h - 2 * inset)
    end
end

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

-- Keep native text intact: callers may need it when restoring the title bar.
function Header:_resolveText()
    if self.inline_context then
        local value = self.context_callback and self.context_callback(self.native_title, self.subtitle)
            or self.native_title or ""
        return "KO/" .. value, nil
    end
    local title = self.fixed_title or self.native_title or ""
    if self.folder_title and not self.fixed_title then
        local folder = self.folder_title():gsub("/+$", ""):match("([^/]+)$") or ""
        title = "KO/" .. folder
    elseif self.title_prefix then
        title = self.title_prefix .. (self.native_title or "")
    end
    local subtitle
    if self.context_callback then
        subtitle = self.context_callback(self.native_title, self.subtitle)
    elseif not self.folder_title then
        subtitle = self.subtitle
    end
    if self.hide_subtitle then subtitle = nil end
    return title, subtitle ~= "" and subtitle or nil
end

function Header:init()
    self.width = self.width or Screen:getWidth()
    self.native_title = self.native_title or self.title
    if self.page then self.fixed_title = "KO/" .. self.page end
    self.title, self.context_subtitle = self:_resolveText()
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
    local function button(icon, callback, hold_callback, icon_rotation_angle, allow_flash)
        if not icon then return nil end
        return HeaderButton:new{
            icon = icon,
            icon_rotation_angle = icon_rotation_angle or 0,
            width = icon_size,
            height = icon_size,
            padding = button_padding,
            padding_left = Screen:scaleBySize(12),
            padding_right = Screen:scaleBySize(12),
            show_parent = self.show_parent,
            callback = callback,
            hold_callback = hold_callback,
            -- Native callbacks may close and free this button's container.
            allow_flash = allow_flash == true,
        }
    end
    self.menu_button = button("chevron.up", function()
        if self.menu_callback then return self.menu_callback() end
    end, nil, 180)
    self.left_button = self.menu_button
    self.buttons = { self.menu_button }
    local left_items = { self.menu_button }
    local right_items = {}
    self.left_group = group(left_items)
    if self.status_widget:getSize().w > 0 then
        table.insert(right_items, HorizontalSpan:new{ width = Size.span.horizontal_small })
        table.insert(right_items, self.status_widget)
        table.insert(right_items, HorizontalSpan:new{ width = Screen:scaleBySize(12) })
    end
    self.right_group = group(right_items)
    self.left_width = self.left_group and self.left_group:getSize().w or 0
    self.right_width = self.right_group and self.right_group:getSize().w or 0

    self.subtitle_widget = nil
    if self.context_subtitle then
        self.subtitle_widget = self:createSubtitle(self.context_subtitle)
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
    if self.dimen then
        -- InputContainer:paintTo owns x/y; resizing must retain painted coordinates.
        self.dimen.w, self.dimen.h = self.width, self.header_height
    else
        self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.header_height }
    end

    if not self[1] then
        local main = OverlapGroup:new{ allow_mirroring = false }
        self.title_container = CenterContainer:new{ dimen = Geom:new{}, self.title_widget }
        main[#main + 1] = self.title_container
        if self.left_group then
            self.left_container = LeftContainer:new{ dimen = Geom:new{}, self.left_group }
            main[#main + 1] = self.left_container
        end
        if self.right_group then
            self.right_container = RightContainer:new{ dimen = Geom:new{}, self.right_group }
            main[#main + 1] = self.right_container
        end
        self.rule = LineWidget:new{
            overlap_offset = { 0, 0 },
            dimen = Geom:new{},
            background = Blitbuffer.COLOR_BLACK,
        }
        main[#main + 1] = self.rule
        self[1] = OverlapGroup:new{ allow_mirroring = false, main }
    end
    local overlay, main = self[1], self[1][1]
    overlay.dimen.w, overlay.dimen.h = self.width, self.header_height
    overlay._size.w, overlay._size.h = self.width, self.header_height
    main.dimen.w, main.dimen.h = self.width, self.bar_height
    main._size.w, main._size.h = self.width, self.bar_height
    local main_height = self.bar_height - Size.line.thick
    self.title_container.dimen.w, self.title_container.dimen.h = self.width, main_height
    if self.left_container then
        self.left_container.dimen.w, self.left_container.dimen.h = self.width, main_height
    end
    if self.right_container then
        self.right_container.dimen.w, self.right_container.dimen.h = self.width, main_height
    end
    self.rule.overlap_offset[2] = main_height
    self.rule.dimen.w, self.rule.dimen.h = self.width, Size.line.thick
    if self.subtitle_widget then
        if not self.subtitle_container then
            self.subtitle_group = VerticalGroup:new{ VerticalSpan:new{ width = Size.padding.small } }
            self.subtitle_container = CenterContainer:new{
                overlap_offset = { 0, 0 },
                dimen = Geom:new{},
                self.subtitle_group,
            }
        end
        self.subtitle_group[2] = self.subtitle_widget
        self.subtitle_group:resetLayout()
        self.subtitle_container.overlap_offset[2] = self.bar_height
        self.subtitle_container.dimen.w, self.subtitle_container.dimen.h = self.width, self.subtitle_height
        overlay[2] = self.subtitle_container
    else
        overlay[2] = nil
        if self.subtitle_group then
            self.subtitle_group[2] = nil
            self.subtitle_group:resetLayout()
        end
    end
end

function Header:getHeight() return self.header_height end
function Header:getSize() return self.dimen end
function Header:_refreshText(no_refresh)
    local title, subtitle = self:_resolveText()
    local title_changed = self.title ~= title
    local subtitle_changed = self.context_subtitle ~= subtitle
    if not title_changed and not subtitle_changed then return end
    local old_height = self.header_height
    if title_changed then
        self.title = title
        self.title_widget:setText(title)
    end
    if subtitle_changed then
        local had_subtitle = self.subtitle_widget ~= nil
        self.context_subtitle = subtitle
        if subtitle then
            if self.subtitle_widget then
                self.subtitle_widget:setText(subtitle)
                self.subtitle_group:resetLayout()
            else
                self.subtitle_widget = self:createSubtitle(subtitle)
            end
        else
            self.subtitle_widget:free()
            self.subtitle_widget = nil
        end
        if had_subtitle ~= (self.subtitle_widget ~= nil) then self:_layout() end
    end
    if not no_refresh then
        local region = self.dimen
        if old_height > self.header_height then
            region = self.dimen:copy()
            region.h = old_height
        end
        UIManager:setDirty(self.show_parent, "ui", region)
    end
end

function Header:setTitle(title, no_refresh)
    self.native_title = title
    self:_refreshText(no_refresh)
end

function Header:setSubTitle(subtitle, no_refresh)
    self.subtitle = subtitle
    self:_refreshText(no_refresh)
end
function Header:setLeftIcon(icon)
    if self.icon_callback then return self.icon_callback("left", icon) end
end
function Header:setRightIcon(icon)
    if self.icon_callback then return self.icon_callback("right", icon) end
end
function Header:generateVerticalLayout()
    return {} -- The hardware Menu key owns this action; only touch uses the icon.
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
