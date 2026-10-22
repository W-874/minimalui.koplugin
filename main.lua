-- Minimal UI: owns Home/Library; KOReader owns menus, browser and reader.
-- Minimal UI plugin; install the repository as minimalui.koplugin.
local Books = require("minimalui/books")
local ConfirmBox = require("ui/widget/confirmbox")
local FileManager = require("apps/filemanager/filemanager")
local Home = require("minimalui/home")
local InfoMessage = require("ui/widget/infomessage")
local MinimalScreen = require("minimalui/screen")
local NativeHeaders = require("minimalui/nativeheaders")
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

function MinimalUI:canShowView()
    return self:isEnabled() and self:isLive()
        and (not self.screen or UIManager:getTopmostVisibleWidget() == self.screen)
end

function MinimalUI:init()
    if self.ui.document then return end
    self.closed = false
    self.focus = {}
    self.native_headers = NativeHeaders:new{ controller = self }
    self.ui.menu:registerToMainMenu(self)
    self.ui:registerPostInitCallback(function()
        self.start_task = function()
            self.start_task = nil
            if self:isEnabled() then self.native_headers:apply() end
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
        self.focus[self.view] = self.screen:getFocusId()
    end
end

function MinimalUI:showView(view, title, items, book)
    if not self:canShowView() then return true end
    local old = self.screen
    self:rememberFocus()
    local index = 1
    for i, item in ipairs(items) do
        if item.id == self.focus[view] then index = i; break end
    end
    if old and self.view == view then
        if view == "home" then old:setContent(items, book, index)
        else old:setItems(title, items, index) end
        return true
    end
    if self.layout_task then
        UIManager:unschedule(self.layout_task)
        self.layout_task = nil
    end
    self.layout_required = nil
    local screen
    if view == "home" then
        screen = Home:new{ controller = self, item_table = items, book = book, selected = index }
    else
        screen = MinimalScreen:new{ controller = self, title = title, item_table = items, itemnumber = index }
    end
    self.screen, self.view = screen, view
    UIManager:show(screen)
    if old then UIManager:close(old) end
    return true
end

function MinimalUI:showHome()
    if not self:canShowView() then return true end
    local items = {}
    local book = Books.lastBook()
    if book then
        items[#items + 1] = {
            id = "continue",
            text = book.title,
            callback = function() self:openBook(book.path) end,
        }
    end
    items[#items + 1] = { id = "library", text = _("LIBRARY"), callback = function() self:showLibrary() end }
    items[#items + 1] = {
        id = "history", text = _("HISTORY"), callback = function() self.ui.history:onShowHist() end,
    }
    items[#items + 1] = {
        id = "browser", text = _("FILE BROWSER"), callback = function() self:showFileBrowser() end,
    }
    return self:showView("home", _("Minimal UI"), items, book)
end

function MinimalUI:showLibrary()
    if not self:canShowView() then return true end
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
                id = path, file = path, text = book.title, mandatory = "",
                callback = function() self:openBook(path) end,
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
        local container = menu.menu_container
        if container then
            local on_close = container.onCloseWidget
            container.onCloseWidget = function(widget, ...)
                if on_close then on_close(widget, ...) end
                if self.view == "library" then self:queueLayout(true) end
            end
        end
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
    if self:isEnabled() and self:isLive() and self.screen
            and UIManager:getTopmostVisibleWidget() == self.screen then
        UIManager:show(ConfirmBox:new{
            text = _("Exit KOReader?"),
            ok_text = _("Exit"),
            ok_callback = function()
                if self:isEnabled() and self:isLive() then self.ui.menu:exitOrRestart() end
            end,
        })
    end
    return true
end

function MinimalUI:closeScreen()
    local screen = self.screen
    if screen then UIManager:close(screen) end
end

function MinimalUI:screenClosed(screen)
    if self.screen ~= screen then return end
    self.screen = nil
    if self.layout_task then
        UIManager:unschedule(self.layout_task)
        self.layout_task = nil
    end
    self.layout_required = nil
end

function MinimalUI:showFileBrowser()
    self:rememberFocus()
    self:bindBrowserNavigation()
    self:closeScreen()
    return true
end

function MinimalUI:restoreBrowserNavigation()
    for _, hook in ipairs(self.browser_hooks or {}) do
        if rawget(hook.target, hook.name) == hook.handler then
            hook.target[hook.name] = hook.original
        end
    end
    self.browser_hooks = nil
    self.browser_chooser = nil
end

function MinimalUI:bindBrowserNavigation()
    local chooser = self.ui.file_chooser
    if not self:isEnabled() or not chooser then return end
    if self.browser_chooser == chooser then return end
    self:restoreBrowserNavigation()
    self.browser_chooser, self.browser_hooks = chooser, {}
    local function bind(target, name)
        local original, fallback = rawget(target, name), target[name]
        local handler = function(widget, ...)
            if self:isEnabled() and self:isLive() and not self.screen
                    and UIManager:getTopmostVisibleWidget() == self.ui then
                return self:showHome()
            end
            if fallback then return fallback(widget, ...) end
        end
        self.browser_hooks[#self.browser_hooks + 1] = {
            target = target, name = name, original = original, handler = handler,
        }
        target[name] = handler
    end
    -- FileChooser receives input before its FileManager parent. Bind only
    -- these live instances, never the shared classes or global input flow.
    bind(chooser, "onBack")
    bind(chooser, "onClose") -- native few-key Back is mapped to Close
    bind(chooser, "onHome")
    bind(self.ui, "onHome") -- also handles the native title bar Home button
end

function MinimalUI:queueLayout(display_only)
    if not self.screen then return end
    self.layout_required = self.layout_required or not display_only
    if self.layout_task then return end
    local screen = self.screen
    self.layout_task = function()
        local full = self.layout_required
        self.layout_task, self.layout_required = nil, nil
        if self:isLive() and self.screen == screen then
            if full then screen:rebuild() else screen:refreshDisplayMode() end
        end
    end
    UIManager:nextTick(self.layout_task)
end

-- FM reinit replaces FileChooser and directs dimensions to its own children.
function MinimalUI:onSetDimensions()
    self:bindBrowserNavigation()
    if self.native_headers and self:isEnabled() then self.native_headers:apply() end
    self:queueLayout()
end

function MinimalUI:onShowingReader()
    if self.screen then self.ui:onSetupShowReader() end
    self:closeScreen()
    -- Do not consume this broadcast: the native host still needs to close.
end

function MinimalUI:onCloseWidget()
    self.closed = true
    self:restoreBrowserNavigation()
    if self.native_headers then self.native_headers:restore() end
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
                    if enabled then
                        self:bindBrowserNavigation()
                        self.native_headers:apply()
                        self:showHome()
                    else
                        self:restoreBrowserNavigation()
                        self.native_headers:restore()
                        self:closeScreen()
                    end
                end,
            },
        },
    }
end

return MinimalUI
