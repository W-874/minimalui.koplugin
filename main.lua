-- Minimal UI: owns Home/Library; KOReader owns menus, browser and reader.
-- Minimal UI plugin; install the repository as minimalui.koplugin.
local Books = require("minimalui/books")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FileManager = require("apps/filemanager/filemanager")
local Home = require("minimalui/home")
local InfoMessage = require("ui/widget/infomessage")
local MinimalScreen = require("minimalui/screen")
local NativeHeaders = require("minimalui/nativeheaders")
local ReaderBridge = require("minimalui/readerbridge")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")

local Screen = Device.screen

local function inputFlags()
    -- Include hardware capabilities that change native Library/header layouts.
    return (Device:hasKeys() and 1 or 0) + (Device:hasFewKeys() and 2 or 0)
        + (Device:hasKeyboard() and 4 or 0) + (Device:isTouchDevice() and 8 or 0)
end
local ENABLED_KEY = "minimalui_enabled"
local LEGACY_KEY = "minimalhome_autoshow"
local MinimalUI = WidgetContainer:extend{
    name = "minimalui",
    is_doc_only = false,
}

function MinimalUI:isEnabled()
    if self.closed then return false end
    local enabled = G_reader_settings:readSetting(ENABLED_KEY)
    if enabled == nil then enabled = G_reader_settings:readSetting(LEGACY_KEY) end
    return enabled ~= false
end

function MinimalUI:isLive()
    return not self.closed and not self.ui.tearing_down
        and FileManager.instance == self.ui and UIManager:isWidgetShown(self.ui)
end

function MinimalUI:canShowView()
    if not self:isEnabled() or not self:isLive() then return false end
    local top = UIManager:getTopmostVisibleWidget()
    return top == (self.screen or self.ui)
end


function MinimalUI:init()
    self.closed = false
    if self.ui.document then
        self.reader_bridge = ReaderBridge:new{ controller = self }
        if self:isEnabled() then self.reader_bridge:install() end
        return
    end
    self.focus = {}
    self:bindMetadataEvents()
    self.native_headers = NativeHeaders:new{ controller = self }
    self.ui.menu:registerToMainMenu(self)
    self.ui:registerPostInitCallback(function()
        local destination = ReaderBridge.takeDestination()
        self.start_task = function()
            self.start_task = nil
            if self:isEnabled() then
                self.native_headers:apply()
                self:startClock()
            end
            -- Post-init precedes UIManager:show(FileManager). Do not cover
            -- startup dialogs or revive a FileManager already closed for reading.
            if self:isEnabled() and self:isLive()
                    and UIManager:getTopmostVisibleWidget() == self.ui then
                if destination == "library" then self:showLibrary() else self:showHome() end
            end
        end
        UIManager:nextTick(self.start_task)
    end)
end

-- One minute-aligned task per FileManager, never a timer per page/widget.
function MinimalUI:stopClock()
    if self.clock_task then UIManager:unschedule(self.clock_task) end
    self.clock_task = nil
end

function MinimalUI:refreshClock()
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        local header = widget.header or widget.title_bar or widget.titlebar
        if header and header.refreshStatus then header:refreshStatus(); return end
        if widget.covers_fullscreen then return end
    end
end

function MinimalUI:startClock()
    self:stopClock()
    if not self:isEnabled() or self.ui.document then return end
    self:refreshClock()
    if not self.clock_tick then
        self.clock_tick = function()
            self.clock_task = nil
            if self:isEnabled() and self:isLive() then self:startClock() end
        end
    end
    self.clock_task = self.clock_tick
    UIManager:scheduleIn(60 - os.time() % 60, self.clock_task)
end

function MinimalUI:onSuspend()
    self:stopClock()
    self:closeStatistics()
end

function MinimalUI:onResume()
    self:startClock()
end

function MinimalUI:onCharging()
    if self:isEnabled() then self:refreshClock() end
end

MinimalUI.onNotCharging = MinimalUI.onCharging

function MinimalUI:rememberFocus()
    if self.screen then
        self.focus[self.view] = self.screen:getFocusId()
    end
end

function MinimalUI:showView(view, title, items, book, home_data)
    if not self:canShowView() then return true end
    local old = self.screen
    self:rememberFocus()
    local index = 1
    for i, item in ipairs(items) do
        if item.id == self.focus[view] then index = i; break end
    end
    if old and self.view == view then
        if view == "home" then old:setContent(items, book, index, home_data)
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
        screen = self.home_screen
        if screen then
            screen:setContent(items, book, index, home_data)
        else
            screen = Home:new{ controller = self, item_table = items, book = book, selected = index, home_data = home_data }
            self.home_screen = screen
        end
    else
        screen = MinimalScreen:new{ controller = self, title = title, item_table = items, itemnumber = index }
        screen._minimalui_input_flags = inputFlags()
    end
    self.screen, self.view = screen, view
    UIManager:show(screen)
    if old then UIManager:close(old) end
    return true
end

function MinimalUI:showHome()
    if not self:canShowView() then return true end
    local items = {}
    local path = G_reader_settings:readSetting("lastfile")
    local book = Books.isFile(path) and { path = path, title = (path:match("([^/]+)$") or path):gsub("%.[^.]+$", "") } or nil
    self.home_source_cache = self.home_source_cache or {}
    self.home_statistics_cache = self.home_statistics_cache or {}
    local home_data = require("minimalui/homesource").collect(self.ui, book, self.library_count,
        self.home_source_cache, self.home_statistics_cache)
    if book then
        items[#items + 1] = {
            id = "continue",
            text = book.title,
            file = book.path, book = book,
            callback = function() self:openBook(book.path) end,
        }
    end
    for i, recent in ipairs(home_data.recent) do
        local path = recent.path
        items[#items + 1] = {
            id = "recent:" .. path, kind = "recent", recent_index = i,
            file = path, book = recent, text = recent.title,
            callback = function() self:openBook(path) end,
        }
    end
    items[#items + 1] = { id = "library", text = _("LIBRARY"), callback = function() self:showLibrary() end }
    items[#items + 1] = {
        id = "history", text = _("HISTORY"), callback = function() self.ui.history:onShowHist() end,
    }
    items[#items + 1] = {
        id = "browser", text = _("FILE BROWSER"), callback = function() self:showFileBrowser() end,
    }
    return self:showView("home", _("Minimal UI"), items, book, home_data)
end

function MinimalUI:showLibrary()
    if not self:canShowView() then return true end
    local books, reason = Books.scan() -- explicit entry only; never on focus/menu/resize
    self.library_count = books and #books or nil
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

function MinimalUI:closeStatistics()
    if self.home_statistics_cache then
        require("minimalui/statcache").close(self.home_statistics_cache)
        self.home_statistics_cache = nil
    end
end

function MinimalUI:releaseScreens()
    local home, screen = self.home_screen, self.screen
    -- Clear ownership before CloseWidget: an active Home must dispose, not park.
    self.home_screen = nil
    self:closeScreen()
    if home and home ~= screen then home:dispose() end
    self.home_source_cache = nil
    self:closeStatistics()
    self.library_count = nil -- native file operations can run while Home is disabled
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
    if not self:canShowView() then return true end
    self.library_count = nil -- native file operations may change Library contents
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
            if full then
                if screen == self.home_screen then
                    screen:rebuild() -- Home checks dimensions/keycaps itself.
                else
                    local inputs = inputFlags()
                    if screen.width ~= Screen:getWidth() or screen.height ~= Screen:getHeight()
                            or screen._minimalui_input_flags ~= inputs then
                        screen:rebuild()
                        screen._minimalui_input_flags = inputs
                    else
                        screen:refreshDisplayMode()
                    end
                end
            else
                screen:refreshDisplayMode()
            end
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
    self:releaseScreens()
    -- Do not consume this broadcast: the native host still needs to close.
end

function MinimalUI:onCloseWidget()
    self.closed = true
    self:stopClock()
    if self.reader_bridge then self.reader_bridge:restore() end
    self:restoreBrowserNavigation()
    self:restoreMetadataEvents()
    if self.native_headers then self.native_headers:restore() end
    if self.start_task then
        UIManager:unschedule(self.start_task)
        self.start_task = nil
    end
    self:releaseScreens()
end

-- The native plugin manager calls stopPlugin before disabling (restart still
-- controls plugin loading). Use the same idempotent teardown as the host.
MinimalUI.stopPlugin = MinimalUI.onCloseWidget

function MinimalUI:bindMetadataEvents()
    if self.metadata_hook or self.ui.document or not self:isEnabled() then return end
    local original, fallback = rawget(self.ui, "handleEvent"), self.ui.handleEvent
    local handler = function(widget, event, ...)
        if not self.closed and (event.handler == "onInvalidateMetadataCache"
                or event.handler == "onBookMetadataChanged") then
            -- CoverBrowser can consume metadata events before this plugin.
            -- The active Home receives broadcasts itself; only forward parked.
            self.home_source_cache = nil
            local home = self.home_screen
            if home and home ~= self.screen then
                home[event.handler](home, unpack(event.args, 1, event.args.n))
            end
        end
        return fallback(widget, event, ...)
    end
    self.metadata_hook = { original = original, handler = handler }
    self.ui.handleEvent = handler
end

function MinimalUI:restoreMetadataEvents()
    local hook = self.metadata_hook
    if hook and rawget(self.ui, "handleEvent") == hook.handler then
        self.ui.handleEvent = hook.original
    end
    self.metadata_hook = nil
end

function MinimalUI:onInvalidateMetadataCache()
    self.home_source_cache = nil
end

MinimalUI.onBookMetadataChanged = MinimalUI.onInvalidateMetadataCache

function MinimalUI:onSaveSettings()
    if self.ui.document and self:isEnabled() then require("minimalui/homesource").capture(self.ui) end
end

-- Native Reader closes its document before the dialog's final FlushSettings.
-- Capture live TOC/position here; the native save that follows persists both.
MinimalUI.onCloseDocument = MinimalUI.onSaveSettings

function MinimalUI:addToMainMenu(menu_items)
    if self.closed then return end
    menu_items.minimalui_folder_actions = {
        text = _("Current folder actions"),
        sorting_hint = "filemanager_settings",
        enabled_func = function() return self:isEnabled() end,
        callback = function()
            self.ui.menu:onCloseFileManagerMenu()
            self.ui:onShowPlusMenu()
        end,
    }
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
                        self:bindMetadataEvents()
                        self.native_headers:apply()
                        self:startClock()
                        if UIManager:getTopmostVisibleWidget() == self.ui then self:showHome() end
                    else
                        self:stopClock()
                        self:restoreBrowserNavigation()
                        self.native_headers:restore()
                        self:releaseScreens()
                        self:restoreMetadataEvents()
                    end
                end,
            },
            {
                text = _("Home appearance"),
                enabled_func = function() return self:isEnabled() end,
                sub_item_table = (function()
                    local entries = {}
                    for _, option in ipairs({
                        { "recent", _("Recent books") }, { "covers", _("Book covers") },
                        { "metadata", _("Book information") }, { "stats", _("Reading statistics") },
                        { "counts", _("Navigation details") },
                    }) do
                        local key = "minimalui_home_" .. option[1]
                        entries[#entries + 1] = {
                            text = option[2],
                            checked_func = function() return G_reader_settings:readSetting(key) ~= false end,
                            callback = function()
                                G_reader_settings:saveSetting(key, G_reader_settings:readSetting(key) == false)
                                if option[1] == "stats" then self:closeStatistics() end
                                self.ui.menu:onCloseFileManagerMenu()
                                if self.view == "home" then self:showHome() end
                            end,
                        }
                    end
                    return entries
                end)(),
            },
        },
    }
end

return MinimalUI
