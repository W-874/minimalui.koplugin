-- Library keeps its own navigation while borrowing the active native renderer.
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Header = require("minimalui/header")
local LibraryView = require("minimalui/libraryview")
local Menu = require("ui/widget/menu")
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
    self.custom_title_bar = Header:new{
        width = self.width,
        page = "LIBRARY",
        show_parent = self,
        menu_callback = function() return self.controller:showNativeMenu() end,
        home_callback = function() return self.controller:showHome() end,
    }
    LibraryView.apply(self)
    Menu.init(self)
    -- Released Menu versions bind keys inline and never call registerKeyEvents.
    self:bindKeys()
    if Device:isTouchDevice() then
        -- Keep this region aligned with the shared Header's complete height.
        self.ges_events.MinimalMenu = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = self.width, h = self.title_bar:getHeight() },
            },
        }
    end
    LibraryView.remember(self)
end

function MinimalScreen:bindKeys()
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


function MinimalScreen:onSwipe(arg, ges)
    if ges.direction == "south" and ges.pos.y < self.title_bar:getHeight() then
        return self.controller:showNativeMenu()
    end
    Menu.onSwipe(self, arg, ges)
    return true
end

function MinimalScreen:focusIndex()
    local focused = self:getFocusItem()
    return focused and focused.entry and focused.entry.idx
        or ((self.page or 1) - 1) * (self.perpage or 1) + 1
end

function MinimalScreen:getFocusId()
    local item = self.item_table[self:focusIndex()]
    return item and item.id
end

function MinimalScreen:setItems(title, items, index)
    self.title = title
    self.item_table = items
    self.itemnumber = index or 1
    if LibraryView.changed(self) then
        self:rebuild(self.itemnumber)
        return
    end
    self:switchItemTable(title, items, self.itemnumber)
end

function MinimalScreen:refreshDisplayMode()
    if not LibraryView.changed(self) then return false end
    self:rebuild()
    return true
end

function MinimalScreen:rebuild(index)
    index = index or self:focusIndex()
    local stack, paths = self.item_table_stack, self.paths
    -- Rebuild in place: replacing the window would put Home above an open
    -- native menu/dialog, changing the input recipient during rotation.
    LibraryView.release(self)
    self:free()
    self[1] = nil
    self.ges_events = nil
    self.key_events = nil
    self.selected = { x = 1, y = 1 }
    Menu._init(self)
    self:init()
    self:setItems(self.title, self.item_table, index)
    self.item_table_stack, self.paths = stack, paths
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
    self:bindKeys()
    self.controller:queueLayout()
end

function MinimalScreen:onPhysicalKeyboardDisconnected()
    Menu.onPhysicalKeyboardDisconnected(self)
    self:bindKeys()
    self.controller:queueLayout()
end

function MinimalScreen:onCloseWidget()
    self.controller:screenClosed(self)
    if not LibraryView.release(self) then Menu.onCloseWidget(self) end
    self:free()
end

return MinimalScreen
