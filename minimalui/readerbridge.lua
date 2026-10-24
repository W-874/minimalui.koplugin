local Bridge = {}
local pending_destination
local home_id = "minimalui_home"

local function copy(source)
    local target = {}
    for key, value in pairs(source) do target[key] = value end
    return target
end

local function remapIndex(index, source, target)
    local selected = index and source and source[index]
    if not selected then return index end
    if selected.id ~= home_id then
        for position, item in ipairs(target or {}) do
            if item == selected or selected.id and item.id == selected.id then return position end
        end
    end
    return 1
end

local function finishEntry(bridge, previous, route, ok, ...)
    pending_destination = previous
    bridge.entry_depth = bridge.entry_depth - 1
    if not ok then error((...), 0) end
    if not previous and route.destination == nil then
        -- FileManager post-init consumed the route before its first show.
        -- Complete startup before the native input callback can repaint it.
        local manager = require("apps/filemanager/filemanager").instance
        local controller = manager and manager.minimalui
        if controller and controller.start_task then
            local task = controller.start_task
            require("ui/uimanager"):unschedule(task)
            task()
        end
    end
    return ...
end

local function finishMenu(bridge, source, index, ...)
    if bridge.installed then
        local menu = bridge.controller.ui.menu
        menu.last_tab_index = remapIndex(index, source, menu.tab_item_table)
        bridge:updateMenu()
    end
    return ...
end

function Bridge:new(args)
    return setmetatable({
        controller = args.controller,
        wrappers = {},
        entry_depth = 0,
    }, { __index = self })
end

-- FileManager post-init runs synchronously inside ReaderUI:showFileManager,
-- before that FileManager is shown. Consume once there, not in its nextTick.
function Bridge.takeDestination()
    if not pending_destination then return end
    local destination = pending_destination.destination
    pending_destination.destination = nil
    return destination
end

function Bridge:watch(instance, method, destination)
    if not instance or type(instance[method]) ~= "function" then return end
    for _, record in ipairs(self.wrappers) do
        if record.instance == instance and record.method == method then return end
    end
    local original, fallback = rawget(instance, method), instance[method]
    local wrapper
    if destination == "menu" then
        wrapper = function(...)
            if not self.installed then return fallback(...) end
            self:removeTab()
            local menu = self.controller.ui.menu
            return finishMenu(self, menu.tab_item_table, menu.last_tab_index, fallback(...))
        end
    else
        wrapper = function(...)
            -- Another plugin may retain this wrapper after our restore.
            if not self.installed then return fallback(...) end
            local previous = pending_destination
            local route = previous or { destination = destination }
            pending_destination = route
            self.entry_depth = self.entry_depth + 1
            -- Native onClose finalizes plugins before showFileManager. The
            -- active closure owns this route even after all hooks are restored.
            return finishEntry(self, previous, route, pcall(fallback, ...))
        end
    end
    self.wrappers[#self.wrappers + 1] = {
        instance = instance, method = method, original = original, wrapper = wrapper,
    }
    instance[method] = wrapper
end

function Bridge:restoreCallbacks()
    for i = #self.wrappers, 1, -1 do
        local record = self.wrappers[i]
        if record.method == "callback" then
            if record.instance.callback == record.wrapper then record.instance.callback = record.original end
            table.remove(self.wrappers, i)
        end
    end
end

function Bridge:closeMenu()
    local menu = self.controller.ui.menu
    -- A live TouchMenu retains its own table and numeric bar callbacks. Close
    -- it natively before changing the cached table, never mutate that array.
    if menu and menu.menu_container and menu.onCloseReaderMenu then menu:onCloseReaderMenu() end
end

function Bridge:removeTab()
    local menu = self.controller.ui.menu
    if self.tab_table and menu.tab_item_table == self.tab_table then
        self:closeMenu()
        menu.last_tab_index = remapIndex(menu.last_tab_index, self.tab_table, self.tab_source)
        menu.tab_item_table = self.tab_source
    elseif self.home_tab and menu and menu.tab_item_table then
        local source = menu.tab_item_table
        local tabs
        for i, item in ipairs(source) do
            if item.id == home_id and item.callback == self.home_tab.callback then
                if not tabs then tabs = copy(source) end
                tabs[i] = false
            end
        end
        if tabs then
            self:closeMenu()
            local target = {}
            for _, item in ipairs(tabs) do
                if item then
                    for _, record in ipairs(self.wrappers) do
                        if record.method == "callback" and item.callback == record.wrapper then
                            item = copy(item)
                            item.callback = record.original
                            break
                        end
                    end
                    target[#target + 1] = item
                end
            end
            menu.last_tab_index = remapIndex(menu.last_tab_index, source, target)
            menu.tab_item_table = target
        end
    end
    self.tab_table, self.tab_source = nil, nil
    self:restoreCallbacks()
    if self.menu_items and menu.menu_items == self.menu_items then menu.menu_items = self.menu_source end
    self.menu_items, self.menu_source = nil, nil
end

function Bridge:updateMenu()
    local ui = self.controller.ui
    local menu = ui.menu
    if not menu then return end
    local source = menu.tab_item_table
    if source then
        local filemanager
        for _, item in ipairs(source) do
            if item.id == "filemanager" then filemanager = item; break end
        end
        if not filemanager then return end
        self:closeMenu()
        local tabs = copy(source)
        for i = #tabs, 1, -1 do
            if tabs[i].id == home_id then table.remove(tabs, i) end
        end
        for i, item in ipairs(tabs) do
            if item == filemanager then
                -- Callback wrapping is private too: native/shared source entries
                -- and the cached reader_menu_order module remain untouched.
                tabs[i] = copy(item)
                self:watch(tabs[i], "callback", "library")
                table.insert(tabs, i + 1, self.home_tab)
                break
            end
        end
        menu.last_tab_index = remapIndex(menu.last_tab_index, source, tabs)
        self.tab_source, self.tab_table = source, tabs
        menu.tab_item_table = tabs
    elseif menu.menu_items and menu.menu_items.filemanager then
        -- Before the first native sort the action still lives in menu_items.
        -- Give MenuSorter a private map; it consumes entries while sorting.
        local items = copy(menu.menu_items)
        items.filemanager = copy(items.filemanager)
        self.menu_source, self.menu_items = menu.menu_items, items
        menu.menu_items = items
        self:watch(items.filemanager, "callback", "library")
    end
end

function Bridge:install()
    if self.installed then return end
    self.installed = true
    local ui = self.controller.ui
    local menu = ui.menu
    self.home_tab = {
        id = home_id,
        icon = "home",
        remember = false,
        callback = function()
            -- Closing a native menu may immediately free its button widgets.
            -- Own ReaderUI/menu references before close; never read a button.
            local reader, reader_menu = ui, menu
            reader_menu:onTapCloseMenu()
            return reader:onHome()
        end,
    }
    self:watch(ui, "onHome", "home")
    self:watch(ui.status, "openFileBrowser", "library")
    self:watch(menu, "setUpdateItemTable", "menu")
    self:updateMenu()
end

function Bridge:restore()
    self.installed = false
    self:removeTab()
    for i = #self.wrappers, 1, -1 do
        local record = self.wrappers[i]
        if record.instance[record.method] == record.wrapper then record.instance[record.method] = record.original end
        self.wrappers[i] = nil
    end
    self.home_tab = nil
end

return Bridge
