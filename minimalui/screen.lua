-- Library keeps its own navigation while borrowing the active native renderer.
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Header = require("minimalui/header")
local LibraryActions = require("minimalui/libraryactions")
local LibraryView = require("minimalui/libraryview")
local Menu = require("ui/widget/menu")
local NativeHeaders = require("minimalui/nativeheaders")
local UIManager = require("ui/uimanager")
local ViewFooter = require("minimalui/viewfooter")
local ViewRender = require("minimalui/viewrender")
local Screen = Device.screen

local MinimalScreen = Menu:extend{
    name = "minimalui_screen",
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    stop_events_propagation = true, -- only this screen's unhandled gestures
}

MinimalScreen.mergeTitleBarIntoLayout = NativeHeaders.mergeTitleBarIntoLayout

function MinimalScreen:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.is_enable_shortcut = Device:hasKeyboard()
    self.custom_title_bar = Header:new{
        width = self.width,
        page = "LIBRARY",
        show_parent = self,
        menu_callback = function() return self.controller:showNativeMenu() end,
    }
    LibraryView.apply(self)
    ViewFooter.prepare(self)
    -- Native init computes per-page dimensions before its first updateItems.
    -- current selects the correct page without building it a second time.
    local current = self.item_table.current
    self.item_table.current = self.itemnumber
    -- This index restores the page, not an explicit visible-focus request on
    -- a pure touch device. Native Menu leaves those rows unhighlighted.
    if not Device:hasDPad() then self.itemnumber = nil end
    Menu.init(self)
    self.item_table.current = current
    ViewFooter.apply(self, {
        navigation_icon = "home",
        navigation_callback = function() return self.controller:showHome() end,
    })
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
    ViewRender.bindShortcuts(self)
end

function MinimalScreen:onMinimalMenu()
    return self.controller:showNativeMenu()
end

function MinimalScreen:onMenuSelect(item)
    -- Menu normally closes itself after callbacks; these rows are navigation.
    if item.select_enabled ~= false and item.callback then item.callback() end
    return true -- the activation must never reach the screen below
end

function MinimalScreen:onMenuHold(item)
    -- Classic Menu and native CoverBrowser items both dispatch this method.
    return LibraryActions.show(self, item)
end

function MinimalScreen:onBookMetadataChanged()
    -- Native Book information emits this only for actual metadata/review edits.
    LibraryActions.queueRefresh(self, true)
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
    local itemnumber = index or 1
    -- A page restoration index is not a request to show a touch focus. This
    -- matters when two saved modes map to the same effective book renderer.
    self.itemnumber = Device:hasDPad() and itemnumber or nil
    if LibraryView.changed(self) then
        self:rebuild(itemnumber)
        return
    end
    self:switchItemTable(title, items, itemnumber)
end

function MinimalScreen:refreshMetadata()
    -- Recreate visible native rows to reread status, collections and book info.
    -- Membership, filename order and the current selection stay unchanged.
    self:setItems(self.title, self.item_table, self:focusIndex())
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
    self.itemnumber = index
    self:init()
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
    LibraryActions.cancelRefresh(self)
    self.controller:screenClosed(self)
    if not LibraryView.release(self) then Menu.onCloseWidget(self) end
    self:free()
end

return MinimalScreen
