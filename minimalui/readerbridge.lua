local Bridge = {}
local pending_destination

local function finishDestination(previous, ok, ...)
    local route = pending_destination
    pending_destination = previous
    if not ok then error((...), 0) end
    if route and route.destination == nil then
        -- The new FM has consumed the route and is now shown. Finish its
        -- startup before the current native input callback can repaint it.
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

local function finishEntry(bridge, ok, ...)
    bridge.entry_depth = bridge.entry_depth - 1
    if bridge.entry_depth == 0 and not bridge.installed then bridge:restore() end
    if not ok then error((...), 0) end
    return ...
end

local function finishMenu(bridge, ...)
    local menu_items = bridge.controller.ui.menu.menu_items
    local entry = menu_items and menu_items.filemanager
    if not entry then
        for _, tab in ipairs(bridge.controller.ui.menu.tab_item_table or {}) do
            if tab.id == "filemanager" then entry = tab; break end
        end
    end
    for i = #bridge.wrappers, 1, -1 do
        local record = bridge.wrappers[i]
        if record.method == "callback" and record.instance ~= entry then
            if record.instance.callback == record.wrapper then record.instance.callback = record.original end
            table.remove(bridge.wrappers, i)
        end
    end
    bridge:watch(entry, "callback", false)
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

function Bridge:watch(instance, method, is_destination)
    if not instance or type(instance[method]) ~= "function" then return end
    for _, record in ipairs(self.wrappers) do
        if record.instance == instance and record.method == method then return end
    end
    local original, fallback = rawget(instance, method), instance[method]
    local wrapper
    if is_destination == "menu" then
        wrapper = function(...)
            if not self.installed then return fallback(...) end
            return finishMenu(self, fallback(...))
        end
    elseif is_destination then
        wrapper = function(...)
            -- Only the menu/status browser entries opt in. Reader Home and
            -- other native callers retain the normal FileManager startup.
            if self.entry_depth == 0 then return fallback(...) end
            local previous = pending_destination
            pending_destination = previous or { destination = "library" }
            return finishDestination(previous, pcall(fallback, ...))
        end
    else
        wrapper = function(...)
            -- A later plugin may retain this wrapper after our restore.
            if not self.installed then return fallback(...) end
            self.entry_depth = self.entry_depth + 1
            return finishEntry(self, pcall(fallback, ...))
        end
    end
    self.wrappers[#self.wrappers + 1] = {
        instance = instance, method = method, original = original,
        wrapper = wrapper, is_destination = is_destination,
    }
    instance[method] = wrapper
end

function Bridge:install()
    if self.installed then return end
    self.installed = true
    local ui = self.controller.ui
    self:watch(ui, "showFileManager", true)
    self:watch(ui.status, "openFileBrowser", false)
    self:watch(ui.menu, "setUpdateItemTable", "menu")
    local menu_items = ui.menu and ui.menu.menu_items
    self:watch(menu_items and menu_items.filemanager, "callback", false)
end

function Bridge:restore()
    self.installed = false
    for i = #self.wrappers, 1, -1 do
        local record = self.wrappers[i]
        -- Native browser entries close/save the reader before calling
        -- showFileManager. Finalize/CloseWidget can stop this plugin during
        -- that close: keep only the destination wrapper until the entry exits.
        if not record.is_destination or self.entry_depth == 0 then
            if record.instance[record.method] == record.wrapper then
                record.instance[record.method] = record.original
            end
            table.remove(self.wrappers, i)
        end
    end
end

return Bridge
