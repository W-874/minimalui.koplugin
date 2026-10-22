-- Temporary native-component view, not the final Home/Library design.
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Screen = Device.screen

local MinimalScreen = Menu:extend{
    name = "minimalui_screen",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    stop_events_propagation = true, -- only this screen's unhandled gestures
}

function MinimalScreen:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.is_enable_shortcut = Device:hasKeyboard()
    self.custom_title_bar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        title = self.title,
        left_icon = "home",
        left_icon_tap_callback = function() return self.controller:showHome() end,
        right_icon = "appbar.menu",
        right_icon_tap_callback = function() return self.controller:showNativeMenu() end,
        show_parent = self,
    }
    Menu.init(self)
    if Device:isTouchDevice() then
        -- The native TitleBar measures its height from fonts, padding and DPI.
        self.ges_events.MinimalMenu = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = self.width, h = self.title_bar:getHeight() },
            },
        }
    end
end

function MinimalScreen:registerKeyEvents()
    Menu.registerKeyEvents(self) -- native focus, paging and keyboard mappings
    if Device:hasKeys() then
        self.key_events.Home = { { "Home" } }
        self.key_events.LeftButtonTap = nil -- Menu must open settings, not the Home icon
        self.key_events.MinimalMenu = { { "Menu" } }
        if Device:hasFewKeys() then
            self.key_events.Right = nil -- native context-hold would also match Right
            self.key_events.MinimalMenu = { { { "Menu", "Right" } } }
        end
    end
end

function MinimalScreen:onMinimalMenu()
    return self.controller:showNativeMenu()
end

function MinimalScreen:onMenuSelect(item)
    -- Menu normally closes itself after callbacks; these rows are navigation.
    if item.select_enabled ~= false and item.callback then item.callback() end
    return true -- the activation must never reach the screen below
end

function MinimalScreen:onHome()
    self.controller:showHome()
    return true -- Menu:onHome would forward Home to the native file browser
end

function MinimalScreen:onClose()
    return self.controller:back()
end

MinimalScreen.onCloseAllMenus = MinimalScreen.onClose

function MinimalScreen:onLeftButtonTap()
    return self:onHome()
end

function MinimalScreen:onSwipe(arg, ges)
    if ges.direction == "south" and ges.pos.y < self.title_bar:getHeight() then
        return self.controller:showNativeMenu()
    end
    Menu.onSwipe(self, arg, ges)
    return true
end

function MinimalScreen:focusIndex()
    local focused = self:getFocusItem()
    return focused and focused.entry and focused.entry.idx or self:getFirstVisibleItemIndex()
end

function MinimalScreen:setItems(title, items, index)
    self.title = title
    self.itemnumber = index or 1
    self:switchItemTable(title, items, self.itemnumber)
end

function MinimalScreen:rebuild()
    local index = self:focusIndex()
    -- Rebuild in place: replacing the window would put Home above an open
    -- native menu/dialog, changing the input recipient during rotation.
    self:free()
    self[1] = nil
    self.ges_events = nil
    self.key_events = nil
    self.selected = { x = 1, y = 1 }
    Menu._init(self)
    self:init()
    self:setItems(self.title, self.item_table, index)
    UIManager:setDirty(self, "ui")
end

function MinimalScreen:onSetDimensions()
    self.controller:queueLayout()
end

-- Resize broadcasts must not run Menu:onScreenResize's immediate init.
MinimalScreen.onScreenResize = MinimalScreen.onSetDimensions

function MinimalScreen:onSetRotationMode(rotation)
    if self.controller:isLive() then
        -- Rotation is a normal event, not a broadcast. The covered FM would
        -- never receive it without this explicit, window-local delegation.
        self.controller.ui:onSetRotationMode(rotation)
        self.controller:queueLayout()
    end
    return true
end

function MinimalScreen:onPhysicalKeyboardConnected()
    Menu.onPhysicalKeyboardConnected(self) -- refresh native cached focus maps
    self.controller:queueLayout()
end

function MinimalScreen:onPhysicalKeyboardDisconnected()
    Menu.onPhysicalKeyboardDisconnected(self)
    self.controller:queueLayout()
end

function MinimalScreen:onCloseWidget()
    self.controller:screenClosed(self)
    Menu.onCloseWidget(self)
    self:free()
end

return MinimalScreen
