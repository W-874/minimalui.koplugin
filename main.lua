-- Minimal UI: owns Home/Library; KOReader owns menus, browser and reader.
-- Minimal UI plugin; install the repository as minimalui.koplugin.
local Books = require("minimalui/books")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local MinimalScreen = require("minimalui/screen")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")

local ENABLED_KEY = "minimalui_enabled"
local LEGACY_KEY = "minimalhome_autoshow"
local MinimalUI = WidgetContainer:extend{
    name = "minimalui",
    is_doc_only = false,
}

function MinimalUI:isEnabled()
    return not self.closed and G_reader_settings:readSetting(ENABLED_KEY,
        G_reader_settings:readSetting(LEGACY_KEY, true)) ~= false
end

function MinimalUI:isLive()
    return not self.closed and not self.ui.tearing_down
        and FileManager.instance == self.ui and UIManager:isWidgetShown(self.ui)
end

function MinimalUI:init()
    if self.ui.document then return end
    self.closed = false
    self.focus = {}
    self.ui.menu:registerToMainMenu(self)
    self.ui:registerPostInitCallback(function()
        self.start_task = function()
            self.start_task = nil
            -- Post-init precedes UIManager:show(FileManager). Do not cover
            -- startup dialogs or revive a FileManager already closed for reading.
            if self:isEnabled() and self:isLive()
                    and UIManager:getTopmostVisibleWidget() == self.ui then
                self:showHome()
            end
        end
        UIManager:nextTick(self.start_task)
    end)
end

function MinimalUI:rememberFocus()
    if self.screen then
        local index = self.screen:focusIndex()
        local item = self.screen.item_table[index]
        self.focus[self.view] = item and item.id
    end
end

function MinimalUI:showView(view, title, items)
    if not self:isEnabled() or not self:isLive() then return true end
    self:rememberFocus()
    self.view = view
    local index = 1
    for i, item in ipairs(items) do
        if item.id == self.focus[view] then index = i; break end
    end
    if self.screen then
        self.screen:setItems(title, items, index)
    else
        self.screen = MinimalScreen:new{ controller = self, title = title, item_table = items }
        self.screen:setItems(title, items, index)
        UIManager:show(self.screen)
    end
    return true
end

function MinimalUI:showHome()
    if not self:isEnabled() or not self:isLive() then return true end
    local items = {}
    local book = Books.lastBook()
    if book then
        items[#items + 1] = {
            id = "continue",
            text = _("Continue reading") .. ": " .. book.title,
            mandatory = book.fraction and string.format("%d%%", math.floor(book.fraction * 100 + 0.5)),
            callback = function() self:openBook(book.path) end,
        }
    end
    items[#items + 1] = { id = "library", text = _("Library"), callback = function() self:showLibrary() end }
    items[#items + 1] = {
        id = "browser", text = _("File browser"), callback = function() self:showFileBrowser() end,
    }
    return self:showView("home", _("Minimal UI"), items)
end

function MinimalUI:showLibrary()
    if not self:isEnabled() or not self:isLive() then return true end
    local books, reason = Books.scan() -- explicit entry only; never on focus/menu/resize
    local items = {}
    if not books or #books == 0 then
        items[1] = {
            text = reason or _("No books found in the current documents scan."),
            select_enabled = false,
        }
    else
        for _, book in ipairs(books) do
            local path = book.path
            items[#items + 1] = {
                id = path, text = book.title, callback = function() self:openBook(path) end,
            }
        end
    end
    return self:showView("library", _("Library"), items)
end

function MinimalUI:showNativeMenu()
    if not self:isLive() then return true end
    local menu = self.ui.menu
    if not (menu.menu_container and UIManager:isWidgetShown(menu.menu_container)) then
        menu:onShowMenu()
    end
    return true -- keep Home/Library in the stack, with its focus intact
end

function MinimalUI:openBook(path)
    if not self:isLive() then return true end
    if not Books.isFile(path) then
        UIManager:show(InfoMessage:new{ text = _("This book is no longer available.") })
        return true
    end
    -- Respect native confirmation/provider handling. Keep our screen alive
    -- until ShowingReader or host CloseWidget, so cancellation is harmless.
    filemanagerutil.openFile(self.ui, path)
    return true
end

function MinimalUI:back()
    if self.view == "library" then return self:showHome() end
    -- Home is the root, so Back stays here. Exit remains in KOReader's menu.
    return true
end

function MinimalUI:closeScreen()
    local screen = self.screen
    if screen then UIManager:close(screen) end
end

function MinimalUI:screenClosed(screen)
    if self.screen == screen then self.screen = nil end
    if self.layout_task then
        UIManager:unschedule(self.layout_task)
        self.layout_task = nil
    end
end

function MinimalUI:showFileBrowser()
    -- Native FM is already present as the service host. Expose it explicitly;
    -- preserve its directory, Back behavior and input bindings.
    self:closeScreen()
    return true
end

function MinimalUI:queueLayout()
    if not self.screen or self.layout_task then return end
    local screen = self.screen
    self.layout_task = function()
        self.layout_task = nil
        if self:isLive() and self.screen == screen then screen:rebuild() end
    end
    UIManager:nextTick(self.layout_task)
end

-- FM reinit sends dimensions to its children, not to our window above it.
MinimalUI.onSetDimensions = MinimalUI.queueLayout

function MinimalUI:onShowingReader()
    if self.screen then self.ui:onSetupShowReader() end
    self:closeScreen()
    -- Do not consume this broadcast: the native host still needs to close.
end

function MinimalUI:onCloseWidget()
    self.closed = true
    if self.start_task then
        UIManager:unschedule(self.start_task)
        self.start_task = nil
    end
    self:closeScreen()
end

-- The native plugin manager calls stopPlugin before disabling (restart still
-- controls plugin loading). Use the same idempotent teardown as the host.
MinimalUI.stopPlugin = MinimalUI.onCloseWidget

function MinimalUI:addToMainMenu(menu_items)
    if self.closed then return end
    menu_items.minimal_ui = {
        text = _("Minimal UI"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Show home"),
                enabled_func = function() return self:isEnabled() end,
                callback = function()
                    self.ui.menu:onCloseFileManagerMenu()
                    self:showHome()
                end,
            },
            {
                text = _("Enable Minimal UI"),
                enabled_func = function() return not self.closed end,
                checked_func = function() return self:isEnabled() end,
                callback = function()
                    local enabled = not self:isEnabled()
                    G_reader_settings:saveSetting(ENABLED_KEY, enabled)
                    self.ui.menu:onCloseFileManagerMenu()
                    if enabled then self:showHome() else self:closeScreen() end
                end,
            },
        },
    }
end

return MinimalUI
