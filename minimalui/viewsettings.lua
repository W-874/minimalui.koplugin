-- Display preferences belong to the active instances, never to native classes.
-- In particular, do not require CoverBrowser or open its database when disabled.
local Menu = require("ui/widget/menu")
local _ = require("gettext")

local ViewSettings = {}
local renderers = {
    mosaic_image = "mosaicmenu", mosaic_text = "mosaicmenu",
    list_image_meta = "listmenu", list_only_meta = "listmenu", list_image_filename = "listmenu",
}
local fields = {
    "_recalculateDimen", "_updateItemsBuildUI", "display_mode_type", "getBookInfo",
    "_do_cover_images", "_do_filename_only", "_do_hint_opened", "_do_center_partial_rows",
    "nb_cols_portrait", "nb_rows_portrait", "nb_cols_landscape", "nb_rows_landscape", "files_per_page",
    "_coverbrowser_overridden",
}

function ViewSettings.effectiveMode(ui, kind)
    local browser = ui and ui.coverbrowser
    local manager = browser and package.loaded.bookinfomanager
    if not manager then return nil, nil, browser end
    local mode = manager:getSetting(kind == "files" and "filemanager_display_mode" or "history_display_mode")
    if kind == "files" and not renderers[mode] then mode = nil end
    if kind ~= "files" and (not renderers[mode] or mode == "list_image_filename") then
        mode = "list_only_meta"
    end
    return mode, manager, browser
end

-- Native SQLite stores false as NULL, indistinguishable from an untouched
-- preference. One explicit UI-choice bit keeps Minimal's fixed-size default
-- while writing the existing native flag with its original boolean semantics.
function ViewSettings.shrinkEnabled(manager)
    return manager and not manager:getSetting("fixed_item_font_size")
        and G_reader_settings:isTrue("minimalui_list_shrink_enabled") or false
end

function ViewSettings.configure(menu, ui, options)
    options = options or {}
    local mode, manager, browser = ViewSettings.effectiveMode(ui, options.kind)
    if options.force_classic then mode = nil end
    local previous = menu._minimalui_view
    local saved = menu._minimalui_view_original
    if not saved then
        saved = {}
        for _, key in ipairs(fields) do saved[key] = { value = rawget(menu, key) } end
        menu._minimalui_view_original = saved
    end
    local state = {
        mode = mode, manager = manager, browser = browser,
        close_manager = previous and previous.close_manager,
        kind = options.kind or "books", page = options.page,
        native_update = Menu.updateItems,
    }
    menu._minimalui_view = state
    menu._do_cover_images, menu._do_filename_only = nil, nil
    menu._do_hint_opened, menu._do_center_partial_rows = nil, nil
    menu.display_mode_type, menu.getBookInfo = nil, nil
    menu._recalculateDimen, menu._updateItemsBuildUI = Menu._recalculateDimen, nil
    if not manager or not renderers[mode] then return state end
    state.covermenu = require("covermenu")
    state.renderer = require(renderers[mode])
    state.native_update = state.covermenu.updateItems
    state.native_builder = state.renderer._updateItemsBuildUI
    state.close_manager = manager
    -- Native getUpdateItemTableFunc would otherwise install its first-use
    -- methods over our instance wrappers when an originally Classic BookList
    -- is revisited after a display-mode change. We now own that setup.
    if state.kind == "books" then menu._coverbrowser_overridden = true end
    -- Reset only this instance; initGrid reads the original native extraction
    -- geometry and never saves display preferences.
    local grid_changed = not previous or previous.mode ~= mode or previous.manager ~= manager
    state.grid_settings = {}
    for _, key in ipairs({ "nb_cols_portrait", "nb_rows_portrait", "nb_cols_landscape", "nb_rows_landscape", "files_per_page" }) do
        state.grid_settings[key] = manager:getSetting(key)
        if previous and previous.grid_settings and previous.grid_settings[key] ~= state.grid_settings[key] then
            grid_changed = true
        end
    end
    if grid_changed then menu.nb_cols_portrait = nil end
    browser.initGrid(menu, mode)
    menu._recalculateDimen = state.renderer._recalculateDimen
    menu.getBookInfo = require("ui/widget/booklist").getBookInfo
    menu._do_cover_images = mode ~= "mosaic_text" and mode ~= "list_only_meta"
    menu._do_filename_only = state.kind == "files" or mode == "list_image_filename"
    menu._do_center_partial_rows = state.kind ~= "files"
    if state.page == "COLLECTIONS" then
        menu._do_hint_opened = manager:getSetting("collections_hint_opened")
    elseif state.page == "SEARCH" or state.kind == "files" then
        menu._do_hint_opened = true
    else
        menu._do_hint_opened = manager:getSetting("history_hint_opened")
    end
    return state
end

function ViewSettings.release(menu)
    local saved = menu._minimalui_view_original
    if saved then
        for _, key in ipairs(fields) do menu[key] = saved[key].value end
    end
    menu._minimalui_view_original, menu._minimalui_view = nil, nil
end

-- KOReader 2026.07.1 supplies an id for the root Display mode menu, but its
-- CoverBrowser children have no keys. Resolve those known children only inside
-- that native subtree using their translated labels; future entries pass through.
local labels = {
    [_("Use this mode everywhere")] = "unified_display_mode",
    [_("History display mode")] = "history_display_mode",
    [_("Collections display mode")] = "collection_display_mode",
    [_("Show hint for books with description")] = "no_hint_description",
    [_("Show file properties")] = "hide_file_info",
    [_("Shrink item font size to fit more text")] = "fixed_item_font_size",
    [_("Mosaic and detailed list settings")] = "coverbrowser_settings",
}
local hidden = { unified_display_mode = true, collection_display_mode = true, no_hint_description = true }
local cover_settings_text = _("Mosaic and detailed list settings")

local function activeKind(controller)
    local ui_manager = package.loaded["ui/uimanager"]
    for i = #(ui_manager and ui_manager._window_stack or {}), 1, -1 do
        local view = ui_manager._window_stack[i].widget._minimalui_view
        if view then return view.kind end
    end
    return controller.screen and controller.view == "library" and "books" or "files"
end

function ViewSettings.refreshViews(controller)
    if not controller:isEnabled() then return end
    for _, record in ipairs(controller.native_headers and controller.native_headers.pages or {}) do
        local widget = record.widget
        if widget._minimalui_view and widget.updateItems then widget:updateItems() end
    end
    if controller.screen and controller.view == "library" then controller:queueLayout(true) end
end

-- Return a new menu tree. Native/shared entries, callbacks and all unknown
-- options remain untouched; removal only applies to this menu presentation.
function ViewSettings.filterMenu(root, controller)
    local browser = controller.ui and controller.ui.coverbrowser
    local manager = browser and package.loaded.bookinfomanager
    if not manager then return root end
    local mode_by_text = {}
    for _, option in ipairs(browser.modes or {}) do mode_by_text[option[1]] = { mode = option[2] } end
    local book_page = activeKind(controller) == "books"
    local function clone(source, context)
        local target = {}
        for key, value in pairs(source) do
            if type(key) ~= "number" and key ~= "sub_item_table" then target[key] = value end
        end
        for _, item in ipairs(source) do
            if type(item) ~= "table" then
                target[#target + 1] = item
            else
                local key = item.key or item.id or item.setting
                -- Labels are deliberately scoped to CoverBrowser's two roots.
                key = key or ((context == "display" or context == "cover_settings" or context == "history") and labels[item.text])
                    or (context == "settings" and item.text == cover_settings_text and "coverbrowser_settings")
                local next_context = key == "filemanager_display_mode" and "display"
                    or key == "history_display_mode" and "history"
                    or key == "coverbrowser_settings" and "cover_settings"
                    or key == "filebrowser_settings" and "settings" or context
                local choice = mode_by_text[item.text]
                local remove = hidden[key] or (key == "hide_file_info" and book_page)
                    or (context == "history" and choice and (not choice.mode or choice.mode == "list_image_filename"))
                if not remove then
                    local copy = clone(item, next_context)
                    if key == "history_display_mode" then copy.enabled_func = function() return true end end
                    if key == "fixed_item_font_size" then
                        copy.checked_func = function() return ViewSettings.shrinkEnabled(manager) end
                        copy.callback = function()
                            local shrink = not ViewSettings.shrinkEnabled(manager)
                            G_reader_settings:saveSetting("minimalui_list_shrink_enabled", shrink)
                            manager:saveSetting(key, not shrink)
                            local chooser = controller.ui.file_chooser
                            if chooser then chooser:updateItems(1, true) end
                            ViewSettings.refreshViews(controller)
                        end
                    end
                    if choice and (context == "display" or context == "history") then
                        local mode = choice.mode
                        copy.checked_func = function()
                            return ViewSettings.effectiveMode(controller.ui, context == "display" and "files" or "books") == mode
                        end
                        copy.callback = function(...)
                            if context == "display" then
                                browser:setupFileManagerDisplayMode(mode)
                            elseif item.callback then
                                item.callback(...)
                            end
                            ViewSettings.refreshViews(controller)
                        end
                    end
                    target[#target + 1] = copy
                end
            end
        end
        if source.sub_item_table then target.sub_item_table = clone(source.sub_item_table, context) end
        return target
    end
    -- menu_items maps roots by key; sorted tab_item_table is an array. Support
    -- both without relying on the order in which native plugins registered.
    local result = clone(root)
    for key, value in pairs(root) do
        if type(key) ~= "number" and type(value) == "table" then
            local context = key == "filemanager_display_mode" and "display"
                or key == "filebrowser_settings" and "settings"
            result[key] = clone(value, context)
        end
    end
    return result
end

function ViewSettings.updateMenu(controller)
    local hook = controller._minimalui_settings_hook
    if not hook then return end
    local menu = hook.menu
    if menu.tab_item_table == hook.filtered then menu.tab_item_table = hook.original_table end
    hook.original_table, hook.filtered = nil, nil
    if controller:isEnabled() and menu.tab_item_table then
        hook.original_table = menu.tab_item_table
        hook.filtered = ViewSettings.filterMenu(menu.tab_item_table, controller)
        menu.tab_item_table = hook.filtered
    end
end

function ViewSettings.install(controller)
    local menu = controller.ui.menu
    local hook = controller._minimalui_settings_hook
    if not hook then
        hook = { menu = menu, original = rawget(menu, "setUpdateItemTable"), fallback = menu.setUpdateItemTable }
        if hook.fallback then
            hook.handler = function(target, ...)
                local result = hook.fallback(target, ...)
                ViewSettings.updateMenu(controller)
                return result
            end
            menu.setUpdateItemTable = hook.handler
        end
        controller._minimalui_settings_hook = hook
    end
    -- Native setDisplayMode otherwise consults the saved unified flag and
    -- rewrites History/Collections. The original remains intact on its class.
    local browser = controller.ui.coverbrowser
    if browser and browser ~= hook.browser and browser.setupFileManagerDisplayMode then
        hook.browser, hook.browser_original = browser, rawget(browser, "setDisplayMode")
        hook.browser_handler = function(target, mode)
            if controller:isEnabled() then return target:setupFileManagerDisplayMode(mode) end
            if hook.browser_original then return hook.browser_original(target, mode) end
            return getmetatable(target).setDisplayMode(target, mode)
        end
        browser.setDisplayMode = hook.browser_handler
    end
    ViewSettings.updateMenu(controller)
end

function ViewSettings.restore(controller)
    local hook = controller._minimalui_settings_hook
    if not hook then return end
    local menu = hook.menu
    if menu.tab_item_table == hook.filtered then menu.tab_item_table = hook.original_table end
    if menu.setUpdateItemTable == hook.handler then menu.setUpdateItemTable = hook.original end
    if hook.browser and hook.browser.setDisplayMode == hook.browser_handler then
        hook.browser.setDisplayMode = hook.browser_original
    end
    controller._minimalui_settings_hook = nil
end

return ViewSettings
