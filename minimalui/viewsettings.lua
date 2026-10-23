-- Display preferences belong to the active instances, never to native classes.
-- In particular, do not require CoverBrowser or open its database when disabled.
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local T = require("ffi/util").template

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

-- One rendered-state contract for native pages and Library. Compare effective
-- consumers, not raw SQLite values (false is persisted as NULL by the native DB).
local grid_settings = { "nb_cols_portrait", "nb_rows_portrait", "nb_cols_landscape", "nb_rows_landscape" }
function ViewSettings.snapshot(ui, options)
    options = options or {}
    local mode, manager, browser = ViewSettings.effectiveMode(ui, options.kind)
    if options.force_classic then mode = nil end
    local current = { mode = mode, manager = manager, browser = browser }
    if options.page == "HISTORY" then
        current.history_datetime_short = G_reader_settings:isTrue("history_datetime_short")
    end
    if not mode then
        current.items_per_page = G_reader_settings:readSetting("items_per_page")
        current.items_font_size = G_reader_settings:readSetting("items_font_size")
        current.shrink = G_reader_settings:isTrue("items_multilines_show_more_text")
        return current
    end
    current.covermenu = require("covermenu")
    current.renderer = require(renderers[mode])
    current.flash_ui_cover_images = not not manager:getSetting("flash_ui_cover_images")
    if mode:match("^mosaic") then
        for _, key in ipairs(grid_settings) do current[key] = manager:getSetting(key) end
        current.show_progress_in_mosaic = not not manager:getSetting("show_progress_in_mosaic")
    else
        current.files_per_page = manager:getSetting("files_per_page")
        current.shrink = ViewSettings.shrinkEnabled(manager)
    end
    if options.kind == "files" then
        if not mode:match("^mosaic") then current.hide_file_info = not not manager:getSetting("hide_file_info") end
    else
        current.series_mode = manager:getSetting("series_mode") or nil
        if not mode:match("^mosaic") then
            for _, key in ipairs({ "hide_page_info", "show_pages_read_as_progress", "show_pages_left_in_progress" }) do
                current[key] = not not manager:getSetting(key)
            end
        end
        if options.page ~= "SEARCH" then
            current.hint_opened = not not manager:getSetting(options.page == "COLLECTIONS"
                and "collections_hint_opened" or "history_hint_opened")
        end
    end
    return current
end

local function snapshotsDiffer(previous, current)
    if not previous then return true end
    for key, value in pairs(previous) do if current[key] ~= value then return true end end
    for key, value in pairs(current) do if previous[key] ~= value then return true end end
    return false
end

function ViewSettings.changed(menu, ui, options)
    local state = menu._minimalui_view
    local previous = state and state.snapshot
    if not previous then return true end
    return snapshotsDiffer(previous, ViewSettings.snapshot(ui, options or state))
end

-- Acknowledge only what configure handed to the renderer. A later raw update
-- must not consume a mode/layout change that still needs Library's rebuild.
function ViewSettings.remember(menu)
    local state = menu._minimalui_view
    if not state then return end
    local current = state.pending_snapshot
    -- Native ListMenu initializes its shared default during the first draw.
    if state.snapshot ~= current and current.mode and not current.mode:match("^mosaic") and current.files_per_page == nil then
        local value = current.manager:getSetting("files_per_page")
        if value == menu.files_per_page then current.files_per_page = value end
    end
    state.snapshot = current
end

-- Return the configured state and whether its single snapshot differs from
-- the last completed render. configure itself never acknowledges the change.
function ViewSettings.configure(menu, ui, options)
    options = options or {}
    local current = ViewSettings.snapshot(ui, options)
    local mode, manager, browser = current.mode, current.manager, current.browser
    local previous = menu._minimalui_view
    local settings_changed = snapshotsDiffer(previous and previous.snapshot, current)
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
        force_classic = options.force_classic,
        snapshot = previous and previous.snapshot,
        pending_snapshot = current,
        native_update = Menu.updateItems,
    }
    menu._minimalui_view = state
    menu._do_cover_images, menu._do_filename_only = nil, nil
    menu._do_hint_opened, menu._do_center_partial_rows = nil, nil
    menu.display_mode_type, menu.getBookInfo = nil, nil
    menu._recalculateDimen, menu._updateItemsBuildUI = Menu._recalculateDimen, nil
    if not manager or not renderers[mode] then return state, settings_changed end
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
    return state, settings_changed
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
    [_("Flash when displaying covers")] = "flash_ui_cover_images",
    [_("Show progress in mosaic mode")] = "show_progress_in_mosaic",
    [_("Show progress in detailed list mode")] = "hide_page_info",
    [_("Show number of pages read instead of progress %")] = "show_pages_read_as_progress",
    [_("Show number of pages left to read")] = "show_pages_left_in_progress",
    [_("Show hint for book status in history")] = "history_hint_opened",
    [_("Show hint for book status in collections")] = "collections_hint_opened",
    [_("Do not show series metadata")] = "series_mode",
    [_("Show series metadata in separate line")] = "series_mode",
    [_("Append series metadata to title")] = "series_mode",
    [_("Append series metadata to authors")] = "series_mode",
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
        if widget._minimalui_view and widget.updateItems and ViewSettings.changed(widget, controller.ui) then
            local previous = widget._minimalui_view.snapshot
            local history = controller.ui.history
            if previous and previous.history_datetime_short ~= nil
                    and previous.history_datetime_short ~= G_reader_settings:isTrue("history_datetime_short")
                    and history and history.booklist_menu == widget then
                -- Native History rows are deep copies. Recreate their dates via
                -- the owner, preserving its filtering and collection prefixes.
                history:updateItemTable()
            else
                widget:updateItems()
            end
        end
    end
    if controller.screen and controller.view == "library"
            and require("minimalui/libraryview").changed(controller.screen) then controller:queueLayout(true) end
end

-- Native TouchMenu closes immediately after opening these dialogs, before
-- their close_callback saves the preview. Observe only the new dialog instance.
local function geometryDialog(item, chooser)
    if not chooser or not item.text_func or item.text or item.keep_menu_open then return end
    local ok, text = pcall(item.text_func)
    if not ok then return end
    if text == T(_("Items per page in portrait mosaic mode: %1 × %2"), chooser.nb_cols_portrait, chooser.nb_rows_portrait)
            or text == T(_("Items per page in landscape mosaic mode: %1 × %2"), chooser.nb_cols_landscape, chooser.nb_rows_landscape) then
        return "ui/widget/doublespinwidget"
    elseif text == T(_("Items per page in portrait list mode: %1"), chooser.files_per_page or 10) then
        return "ui/widget/spinwidget"
    end
end

local function geometryCallback(callback, module, controller)
    return function(...)
        local ui_manager = require("ui/uimanager")
        local before = {}
        for _, window in ipairs(ui_manager._window_stack) do before[window.widget] = true end
        callback(...)
        local dialog = require(module)
        for i = #ui_manager._window_stack, 1, -1 do
            local widget = ui_manager._window_stack[i].widget
            if not before[widget] and getmetatable(widget) == dialog then
                local original, close = rawget(widget, "close_callback"), widget.close_callback
                widget.close_callback = function(...)
                    widget.close_callback = original
                    if close then close(...) end
                    ViewSettings.refreshViews(controller)
                end
                break
            end
        end
    end
end

-- Return a new menu tree. Known display callbacks notify the same comparator
-- after native work; native/shared entries and unknown options stay untouched.
-- CoverBrowser is optional: native launch entries still need hiding without it.
-- Reader registers those launch entries but never CoverBrowser's display modes,
-- so its menu is filtered for launches only and keeps every mode entry intact.
function ViewSettings.filterMenu(root, controller)
    local ui = controller.ui or {}
    local browser = ui.coverbrowser
    local manager = browser and package.loaded.bookinfomanager
    local display = manager and not ui.document
    local mode_by_text = {}
    if display then
        for _, option in ipairs(browser.modes or {}) do mode_by_text[option[1]] = { mode = option[2] } end
    end
    local book_page = display and activeKind(controller) == "books"
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
                if display and not key then
                    key = ((context == "display" or context == "cover_settings" or context == "history") and labels[item.text])
                        or (context == "settings" and item.text == cover_settings_text and "coverbrowser_settings")
                end
                local next_context = key == "filemanager_display_mode" and "display"
                    or key == "history_display_mode" and "history"
                    or key == "coverbrowser_settings" and "cover_settings"
                    or key == "filebrowser_settings" and "settings" or context
                local choice = display and mode_by_text[item.text]
                -- Native launch entries carry MenuSorter ids. Translated labels
                -- also name unrelated plugins and collections, so never match them.
                local remove = item.id == "history" or item.id == "favorites"
                    or (display and (hidden[key] or (key == "hide_file_info" and book_page)
                        or (context == "history" and choice and (not choice.mode or choice.mode == "list_image_filename"))))
                if not remove then
                    local copy = clone(item, next_context)
                    if display and key == "history_display_mode" then copy.enabled_func = function() return true end end
                    if display and key == "fixed_item_font_size" then
                        copy.checked_func = function() return ViewSettings.shrinkEnabled(manager) end
                        copy.callback = function()
                            local shrink = not ViewSettings.shrinkEnabled(manager)
                            G_reader_settings:saveSetting("minimalui_list_shrink_enabled", shrink)
                            manager:saveSetting(key, not shrink)
                            local chooser = controller.ui.file_chooser
                            if chooser and not chooser._minimalui_view then chooser:updateItems(1, true) end
                            ViewSettings.refreshViews(controller)
                        end
                    end
                    if display and choice and (context == "display" or context == "history") then
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
                    if display and context == "cover_settings" and key and key ~= "fixed_item_font_size" and copy.callback then
                        local callback = copy.callback
                        copy.callback = function(...)
                            callback(...)
                            ViewSettings.refreshViews(controller)
                        end
                    end
                    if display and context == "cover_settings" and copy.callback then
                        local dialog = geometryDialog(item, controller.ui.file_chooser)
                        if dialog then copy.callback = geometryCallback(copy.callback, dialog, controller) end
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
    if hook.browser ~= browser then
        if hook.browser and hook.browser.setDisplayMode == hook.browser_handler then
            hook.browser.setDisplayMode = hook.browser_original
        end
        hook.browser, hook.browser_original, hook.browser_handler = nil, nil, nil
    end
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
