local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local GestureRange = require("ui/gesturerange")
local Header = require("minimalui/header")
local UIManager = require("ui/uimanager")
local Size = require("ui/size")
local _ = require("gettext")
local T = require("ffi/util").template

local NativeHeaders = {}
local unpack = unpack or table.unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

-- Replace the tree reference too: Menu and CoverBrowser retain their header
-- inside content_group, while KeyValuePage keeps it in its native data layout.
local function replace(root, old, new)
    local changed = false
    for i, child in ipairs(root) do
        if child == old then root[i] = new; changed = true
        elseif type(child) == "table" and replace(child, old, new) then changed = true end
    end
    if changed and root.resetLayout then root:resetLayout() end
    return changed
end

local function relayout(widget)
    if widget.updateItems and widget.item_group then widget:updateItems(1, false) end
    UIManager:setDirty(widget.show_parent or widget, "ui")
end

local function context(title, subtitle)
    if not subtitle or subtitle == "" then return title end
    if not title or title == "" then return subtitle end
    return title .. " · " .. subtitle
end

local function layoutDetails(widget, header)
    local available = widget.dimen.h - header:getHeight() - Size.span.vertical_large
        - (widget.single_page and 0 or widget.page_info:getSize().h) - 2 * Size.line.thick
    widget.item_height = math.floor(available / widget.items_per_page)
    widget.items_font_size = math.min(require("ui/widget/textboxwidget"):getFontSizeToFitHeight(
        widget.item_height, 1, 1.0), 22)
    widget.textviewer_height = widget.dimen.h - 2 * (header:getHeight() - Size.padding.default - Size.line.thick)
    local function spacing(root)
        for i, child in ipairs(root) do
            if child == header and root[i + 1] then
                root[i + 1].width = math.floor((available - widget.items_per_page * widget.item_height) / 2)
                return true
            elseif type(child) == "table" and spacing(child) then return true end
        end
    end
    spacing(widget)
    widget:_populateItems()
    replace(widget, header, header) -- invalidate cached ancestor dimensions
end

local function restoreHooks(hooks)
    for i = #hooks, 1, -1 do
        local hook = hooks[i]
        -- A later plugin may have wrapped us. Leave its hook installed, but
        -- make our enclosed wrapper inert and release the controller reference.
        hook.state.owner = nil
        hook.state.handler = nil
        if rawget(hook.target, hook.name) == hook.wrapper then
            hook.target[hook.name] = hook.original
        end
    end
end

function NativeHeaders.mergeTitleBarIntoLayout(widget)
    if not widget.title_bar then return end
    local rows = widget.title_bar:generateVerticalLayout()
    if rows[1] and widget.layout[1] and widget.layout[1][1] == rows[1][1] then return end
    for i, row in ipairs(rows) do table.insert(widget.layout, i, row) end
    widget.selected.y = widget.selected.y + #rows
end

function NativeHeaders:goHome()
    local targets = {}
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if widget._minimal_header and not widget._minimal_header.is_browser then
            targets[#targets + 1] = widget
        end
    end
    for _, widget in ipairs(targets) do
        if UIManager:isWidgetShown(widget) then
            if widget.onCloseAllMenus then widget:onCloseAllMenus()
            elseif widget.onClose then widget:onClose() end
        end
    end
    return self.controller:showHome()
end

function NativeHeaders:new(args)
    return setmetatable({
        controller = args.controller, creators = {}, pages = {},
        callbacks = setmetatable({}, { __mode = "k" }),
    }, { __index = self })
end

function NativeHeaders:hook(hooks, target, name, handler)
    local original, fallback = rawget(target, name), target[name]
    local state = { owner = self, handler = handler }
    local wrapper = function(instance, ...)
        local owner = state.owner
        if owner and owner.controller:isEnabled() then
            return state.handler(owner, fallback, instance, ...)
        end
        if fallback then return fallback(instance, ...) end
    end
    hooks[#hooks + 1] = {
        target = target, name = name, original = original, wrapper = wrapper, state = state,
    }
    target[name] = wrapper
end

function NativeHeaders:refreshFiles()
    local ui = self.controller.ui
    local record = ui.file_chooser and ui.file_chooser._minimal_header
    if not record then return end
    local header = record.header
    local height = header:getHeight()
    header:setSubTitle(header.subtitle)
    header:setRightIcon(ui.selected_files ~= nil and "check" or "plus")
    if height ~= header:getHeight() then relayout(record.widget) end
end

function NativeHeaders:adapt(widget, page, is_browser, show_context, opds_browser)
    if not widget or not widget.title_bar or widget._minimal_header then return end
    local controller, old = self.controller, widget.title_bar
    local ui, extra = controller.ui, {}
    if is_browser then
        extra[#extra + 1] = {
            icon = ui.selected_files ~= nil and "check" or "plus", role = "left",
            callback = function() return ui:onShowPlusMenu() end,
        }
    else
        if old.left_icon then
            extra[#extra + 1] = {
                icon = (page == "HISTORY" or opds_browser) and "plus" or old.left_icon,
                role = "left", callback = old.left_icon_tap_callback,
                hold_callback = old.left_icon_hold_callback,
            }
        end
        if page ~= "HISTORY" and not opds_browser and (old.right_icon or old.close_callback) then
            extra[#extra + 1] = {
                icon = old.close_callback and "close" or old.right_icon, role = "right",
                callback = old.close_callback or old.right_icon_tap_callback,
                hold_callback = old.close_hold_callback or old.right_icon_hold_callback,
            }
        end
    end
    local header = Header:new{
        width = widget.dimen.w, title = "KO/" .. page,
        page = not is_browser and page or nil,
        native_title = old.title_widget and old.title_widget.text or old.title or widget.title,
        subtitle = old.subtitle_widget and old.subtitle_widget.text or old.subtitle,
        context_callback = is_browser and function()
            if ui.selected_files == nil then return nil end
            local count = 0
            for _ in pairs(ui.selected_files) do count = count + 1 end
            return T(_("Selected: %1"), count)
        end or show_context and context or nil,
        folder_title = is_browser and function() return ui.file_chooser.path end or nil,
        show_parent = is_browser and ui or widget,
        menu_callback = function() return controller:showNativeMenu() end,
        navigation_icon = opds_browser and "close" or nil,
        -- Submission selectors are intentionally never passed to adapt().
        home_callback = function()
            if not controller:isLive() then return true end
            if opds_browser then
                local close = widget.close_callback or old.close_callback
                if close then return close() end
                return true
            end
            if is_browser then return ui:onHome() end
            return self:goHome()
        end,
        home_hold_callback = is_browser and old.left_icon_hold_callback or nil,
        extra_buttons = extra,
    }
    local record = {
        widget = widget, old = old, header = header, custom = widget.custom_title_bar,
        is_browser = is_browser, hooks = {}, shortcut = rawget(widget, "is_enable_shortcut"),
        build_ui = rawget(widget, "_updateItemsBuildUI"),
        key_events = widget.key_events, ges_events = widget.ges_events,
    }
    self.pages[#self.pages + 1] = record
    widget._minimal_header = record
    widget.title_bar, widget.custom_title_bar = header, header
    replace(widget, old, header)
    if page == "HISTORY" or opds_browser then
        self:hook(record.hooks, header, "setLeftIcon", function(_, fallback, target, icon)
            return fallback(target, icon == "appbar.menu" and "plus" or icon)
        end)
    end
    if opds_browser then
        -- Native catalog/download menus anchor to left_button. The navigation
        -- slot is Exit, not the menu that opened the anchored dialog.
        header.left_button = header.left_extra_button or header.menu_button
        self:hook(record.hooks, widget, "init", function(owner, fallback, target, ...)
            -- OPDS returns to its root with init(), and Menu.init rebuilds the
            -- whole tree. Let native code own its paths and item tables, then
            -- attach to the newly-created title bar instead of reusing ours.
            owner:release(record, false)
            local result = pack(fallback(target, ...))
            owner:adapt(target, "OPDS", false, true, opds_browser)
            return unpack(result, 1, result.n)
        end)
        if widget == opds_browser then
            self:watch(widget, "showDownloadList", "OPDS", "download_list", true, false, record.hooks)
            self:watch(widget, "showFacetLinkList", "OPDS", nil, true, true, record.hooks)
        end
    end
    -- Initial policy; corrected for native OPDS keyboard hints in the next stage.
    widget.is_enable_shortcut = false
    local keys = {}
    for name, binding in pairs(widget.key_events or {}) do keys[name] = binding end
    keys.LeftButtonTap = nil
    keys.SelectByShortCut = nil
    keys.MinimalNativeMenu = { { "Menu" } }
    widget.key_events, record.keys = keys, keys
    self:hook(record.hooks, widget, "onMinimalNativeMenu", function(owner)
        return owner.controller:showNativeMenu()
    end)
    self:hook(record.hooks, widget, "onHome", function(owner)
        if opds_browser then return header.home_callback() end
        return owner:goHome()
    end)
    if widget.registerKeyEvents then
        self:hook(record.hooks, widget, "registerKeyEvents", function(_, fallback, target, ...)
            if fallback then fallback(target, ...) end
            target.key_events.LeftButtonTap = nil
            target.key_events.SelectByShortCut = nil
            target.key_events.MinimalNativeMenu = { { "Menu" } }
            record.keys = target.key_events
        end)
    end
    local gestures = {}
    for name, binding in pairs(widget.ges_events or {}) do gestures[name] = binding end
    widget.ges_events, record.gestures = gestures, gestures
    if Device:isTouchDevice() then
        gestures.MinimalNativeMenu = { GestureRange:new{
            ges = "tap", range = function() return header.dimen end,
        } }
        if is_browser then
            -- FileManager normally handles browser swipes itself, outside
            -- Menu.ges_events. Capture only the header; body stays native.
            gestures.Swipe = { GestureRange:new{
                ges = "swipe", range = function() return header.dimen end,
            } }
        end
    end
    self:hook(record.hooks, widget, "onSwipe", function(owner, fallback, target, arg, ges)
        local top = header.dimen.y or 0
        if ges.direction == "south" and ges.pos.y >= top and ges.pos.y < top + header:getHeight() then
            return owner.controller:showNativeMenu()
        end
        if fallback then return fallback(target, arg, ges) end
    end)
    if widget.item_group and widget.updateItems then
        record.builder = Header.listBuilder(record.build_ui)
        widget._updateItemsBuildUI = record.builder
        -- Native Sym/ScreenKB devices skip titlebar focus because Menu used to
        -- activate the left icon. Menu now means Settings, so expose every icon.
        self:hook(record.hooks, widget, "mergeTitleBarIntoLayout", function(_, _, target)
            NativeHeaders.mergeTitleBarIntoLayout(target)
        end)
        self:hook(record.hooks, widget, "updatePageInfo", function(_, fallback, target, ...)
            -- Native treats itemnumber as a one-shot visible-focus request.
            -- Set it only after the renderer chose its row, so neither paging
            -- nor native selection restoration is redirected to the first book.
            if not target.itemnumber and #target.item_table > 0 then target.itemnumber = 1 end
            return fallback(target, ...)
        end)
        local own_update = rawget(widget, "updateItems")
        self:hook(record.hooks, widget, "updateItems", function(_, fallback, target, selected, no_recalculate_dimen)
            if is_browser then
                local height = header:getHeight()
                header:setSubTitle(header.subtitle, true)
                if height ~= header:getHeight() then no_recalculate_dimen = false end
                -- CoverBrowser switches FileChooser's class method in place.
                fallback = own_update or getmetatable(target).updateItems
            end
            local result = pack(fallback(target, selected, no_recalculate_dimen))
            NativeHeaders.mergeTitleBarIntoLayout(target)
            return unpack(result, 1, result.n)
        end)
    elseif widget._populateItems then
        -- Keep native KeyValuePage rows, callbacks and return/footer controls.
        -- Add only the new header's focus targets after native population.
        self:hook(record.hooks, widget, "_populateItems", function(_, fallback, target, ...)
            local result = pack(fallback(target, ...))
            local rows = header:generateVerticalLayout()
            for i, row in ipairs(rows) do table.insert(target.layout, i, row) end
            if target.layout[#rows + 1] then
                target:moveFocusTo(1, #rows + 1, FocusManager.FORCED_FOCUS)
            end
            return unpack(result, 1, result.n)
        end)
        record.details = true
        layoutDetails(widget, header)
    end
    self:hook(record.hooks, widget, "onCloseWidget", function(owner, fallback, target, ...)
        owner:release(record, false)
        if fallback then return fallback(target, ...) end
    end)
    if is_browser then
        ui.title_bar = header
        self:hook(record.hooks, header, "setRightIcon", function(_, _, target, icon)
            return target:setLeftIcon(icon == "folder" and "plus" or icon)
        end)
        ui:updateTitleBarPath()
    end
    relayout(widget)
end

-- Local fullscreen menus (property lists and bookmark book filters) aren't
-- exposed by their owners. Inspect only windows created by a watched method,
-- never patch Menu/KeyValuePage/UIManager classes or unrelated task dialogs.
function NativeHeaders:watch(instance, method, page, field, show_context, scan, hooks)
    if not instance then return end
    local method_value = instance[method]
    local mt = type(method_value) == "table" and getmetatable(method_value)
    if type(method_value) ~= "function" and not (mt and mt.__call) then return end
    hooks = hooks or self.creators
    for _, record in ipairs(hooks) do
        if record.target == instance and record.name == method then return end
    end
    self:hook(hooks, instance, method, function(owner, fallback, target, ...)
        local before
        if scan then
            before = {}
            for _, window in ipairs(UIManager._window_stack) do before[window.widget] = true end
        end
        local result = pack(fallback(target, ...))
        local opds_browser = page == "OPDS" and (target.opds_browser or target) or nil
        owner:prune()
        if page == "BOOKMARKS" and target.ui and target.ui ~= owner.controller.ui then
            return unpack(result, 1, result.n)
        end
        if field and not (field == "coll_list" and target.selected_collections ~= nil) then
            owner:adapt(target[field], page, false, show_context, opds_browser)
        end
        if scan then
            for _, window in ipairs(UIManager._window_stack) do
                local widget = window.widget
                if not before[widget] and widget.title_bar and widget.item_group
                        and widget.covers_fullscreen and not widget.is_popout then
                    owner:adapt(widget, page, false, show_context, opds_browser)
                end
            end
        end
        owner:watchBookmarks()
        return unpack(result, 1, result.n)
    end)
end

function NativeHeaders:watchBookmarks()
    local browser = package.loaded["ui/widget/bookmarkbrowser"]
    if type(browser) ~= "table" then return end
    -- This module exports a singleton, not a widget class. Loading it is the
    -- user's native action; we only wrap its own methods after it exists.
    self:watch(browser, "show", "BOOKMARKS", "bm_list", true)
    self:watch(browser, "showBookList", "BOOKMARKS", nil, true, true)
    if browser.ui == self.controller.ui then self:adapt(browser.bm_list, "BOOKMARKS", false, true) end
end

function NativeHeaders:release(record, refresh)
    local widget, header = record.widget, record.header
    restoreHooks(record.hooks)
    if widget._minimal_header == record then
        if widget._updateItemsBuildUI == record.builder then widget._updateItemsBuildUI = record.build_ui end
        if widget.is_enable_shortcut == false then widget.is_enable_shortcut = record.shortcut end
        if widget.key_events == record.keys then widget.key_events = record.key_events end
        if widget.ges_events == record.gestures then widget.ges_events = record.ges_events end
        if widget.title_bar == header then widget.title_bar = record.old end
        if widget.custom_title_bar == header then widget.custom_title_bar = record.custom end
        replace(widget, header, record.old)
        widget._minimal_header = nil
        -- Closed native menus can remain cached on their owner. Their focus
        -- rows must not keep detached buttons (and their UI callbacks) alive.
        local removed = 0
        for i = #(widget.layout or {}), 1, -1 do
            for _, button in ipairs(header.buttons) do
                if widget.layout[i][1] == button then
                    table.remove(widget.layout, i)
                    removed = removed + 1
                    break
                end
            end
        end
        if widget.selected then widget.selected.y = math.max(1, widget.selected.y - removed) end
        record.old:setTitle(header.native_title or widget.title, true)
        record.old:setSubTitle(header.subtitle, true)
        if record.details and refresh then layoutDetails(widget, record.old) end
        if record.is_browser and self.controller.ui.title_bar == header then
            self.controller.ui.title_bar = record.old
            record.old:setRightIcon(self.controller.ui.selected_files ~= nil and "check" or "plus")
        end
        if refresh then relayout(widget) end
        header:free()
    end
    for i = #self.pages, 1, -1 do
        if self.pages[i] == record then table.remove(self.pages, i); break end
    end
end

function NativeHeaders:prune()
    local ui = self.controller.ui
    for i = #self.pages, 1, -1 do
        local record = self.pages[i]
        local retained = record.is_browser and record.widget == ui.file_chooser
            or not record.is_browser and UIManager:isWidgetShown(record.widget.show_parent or record.widget)
        if not retained then self:release(record, false) end
    end
end

function NativeHeaders:apply()
    local ui = self.controller.ui
    if not ui then return end
    self:prune()
    self:adapt(ui.file_chooser, "FILES", true)
    self:watch(ui.history, "onShowHist", "HISTORY", "booklist_menu")
    self:watch(ui.opds, "onShowOPDSCatalog", "OPDS", "opds_browser", true)
    local opds_browser = ui.opds and ui.opds.opds_browser
    if opds_browser and UIManager:isWidgetShown(opds_browser) then
        self:adapt(opds_browser, "OPDS", false, true, opds_browser)
        if opds_browser.download_list and UIManager:isWidgetShown(opds_browser.download_list) then
            self:adapt(opds_browser.download_list, "OPDS", false, true, opds_browser)
        end
    end
    self:watch(ui.collections, "onShowColl", "COLLECTIONS", "booklist_menu", true)
    self:watch(ui.collections, "onShowCollList", "COLLECTIONS", "coll_list")
    self:watch(ui.collections, "showCollFolderList", "COLLECTIONS", "coll_folder_list", true)
    self:watch(ui.collections, "showPropValueList", "COLLECTIONS", nil, true, true)
    self:watch(ui.collections, "onShowBookmarkBrowser", "BOOKMARKS")
    self:watch(ui.filesearcher, "onShowSearchResults", "SEARCH", "booklist_menu")
    self:watch(ui.bookinfo, "show", "INFO", "kvp_widget")
    for _, entry in ipairs({
        { ui.history, "booklist_menu", "HISTORY" },
        { ui.collections, "booklist_menu", "COLLECTIONS", true },
        { ui.collections, "coll_folder_list", "COLLECTIONS", true },
        { ui.filesearcher, "booklist_menu", "SEARCH" },
        { ui.bookinfo, "kvp_widget", "INFO" },
    }) do
        if entry[1] and entry[1][entry[2]] and UIManager:isWidgetShown(entry[1][entry[2]]) then
            self:adapt(entry[1][entry[2]], entry[3], false, entry[4])
        end
    end
    if ui.collections and ui.collections.selected_collections == nil and ui.collections.coll_list
            and UIManager:isWidgetShown(ui.collections.coll_list) then
        self:adapt(ui.collections.coll_list, "COLLECTIONS", false)
    end
    self:watchBookmarks()
    -- Selection changes without a path change (including the empty table on
    -- entry) must update immediately; native item rebuilds cover count changes.
    local installed = false
    for _, hook in ipairs(self.creators) do
        if hook.target == ui and hook.name == "onToggleSelectMode" then installed = true; break end
    end
    if not installed then
        self:hook(self.creators, ui, "onToggleSelectMode", function(owner, fallback, target, ...)
            local result = pack(fallback(target, ...))
            owner:refreshFiles()
            return unpack(result, 1, result.n)
        end)
        -- Bookmarks can also be launched by a file context menu. Wrap only the
        -- returned button's callback to discover its first lazy-loaded instance.
        if ui.collections and ui.collections.genBookmarkBrowserButton then
            self:hook(self.creators, ui.collections, "genBookmarkBrowserButton", function(owner, fallback, target, ...)
                local button = fallback(target, ...)
                if button and button.callback then
                    local callback, state = button.callback, { owner = owner }
                    owner.callbacks[state] = true
                    button.callback = function(...)
                        local result = pack(callback(...))
                        if state.owner and state.owner.controller:isEnabled() then
                            state.owner:watchBookmarks()
                        end
                        return unpack(result, 1, result.n)
                    end
                end
                return button
            end)
        end
    end
end

function NativeHeaders:restore()
    restoreHooks(self.creators)
    self.creators = {}
    for state in pairs(self.callbacks) do state.owner = nil end
    self.callbacks = setmetatable({}, { __mode = "k" })
    local ui = self.controller.ui
    for i = #self.pages, 1, -1 do
        local record = self.pages[i]
        self:release(record, not ui.tearing_down and not self.controller.closed
            and UIManager:isWidgetShown(record.widget.show_parent or record.widget))
    end
end

return NativeHeaders
