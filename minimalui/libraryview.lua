local Menu = require("ui/widget/menu")

-- Borrow only the renderer methods from the active native plugin. Never load
-- CoverBrowser (or its settings database) on behalf of a disabled plugin.
local LibraryView = {}
local modes = {
    mosaic_image = "mosaicmenu",
    mosaic_text = "mosaicmenu",
    list_image_meta = "listmenu",
    list_only_meta = "listmenu",
    list_image_filename = "listmenu",
}
local settings = {
    "unified_display_mode", "filemanager_display_mode", "history_display_mode",
    "nb_cols_portrait", "nb_rows_portrait", "nb_cols_landscape", "nb_rows_landscape",
    "files_per_page", "history_hint_opened", "series_mode", "fixed_item_font_size",
    "hide_file_info", "hide_page_info", "show_pages_read_as_progress",
    "show_pages_left_in_progress", "show_progress_in_mosaic", "no_hint_description",
    "flash_ui_cover_images",
}
local global_settings = { "items_per_page", "items_font_size" }

local function state(screen)
    local browser = screen.controller.ui.coverbrowser
    local manager = browser and package.loaded.bookinfomanager
    local current = { browser = browser, manager = manager }
    for _, key in ipairs(global_settings) do
        current[key] = G_reader_settings:readSetting(key)
    end
    if not manager then return current end
    for _, key in ipairs(settings) do
        current[key] = manager:getSetting(key)
    end
    current.source = current.unified_display_mode and "filemanager" or "history"
    local mode = current[current.source .. "_display_mode"]
    if not modes[mode] then return current end
    -- CoverBrowser loads BookList renderers lazily on first display, not when
    -- selecting the History preference. Only the enabled plugin reaches here.
    current.covermenu = require("covermenu")
    current.renderer = require(modes[mode])
    -- Native cover items require a real path, even for their collection marks.
    -- Keep our nonselectable empty-page explanation in the native classic list.
    for _, item in ipairs(screen.item_table or {}) do
        if not (item.file or item.path) then return current end
    end
    current.mode = mode
    return current
end

function LibraryView.changed(screen)
    local previous, current = screen._library_display, state(screen)
    if not previous then return true end
    for _, key in ipairs({ "browser", "manager", "source", "mode", "covermenu", "renderer" }) do
        if previous[key] ~= current[key] then return true end
    end
    for _, keys in ipairs({ settings, global_settings }) do
        for _, key in ipairs(keys) do
            if previous[key] ~= current[key] then return true end
        end
    end
    return false
end

function LibraryView.apply(screen)
    local current = state(screen)
    screen._library_display = current
    screen.ui = screen.controller.ui -- newer native renderers use ui.bookinfo
    screen.updateItems = Menu.updateItems
    screen._recalculateDimen = Menu._recalculateDimen
    screen._updateItemsBuildUI = nil
    screen._do_cover_images = nil
    screen._do_filename_only = nil
    screen._do_hint_opened = nil
    screen._do_center_partial_rows = nil
    screen.display_mode_type = nil
    screen.getBookInfo = nil
    screen._covermenu_onclose_done = nil
    if not current.mode then return end

    -- initGrid is a static native helper, not setupWidgetDisplayMode: the latter
    -- patches History/FileChooser classes and invokes their data-source updates.
    screen.nb_cols_portrait = nil
    current.browser.initGrid(screen, current.mode)
    screen.updateItems = current.covermenu.updateItems
    screen._recalculateDimen = current.renderer._recalculateDimen
    screen._updateItemsBuildUI = current.renderer._updateItemsBuildUI
    screen.getBookInfo = require("ui/widget/booklist").getBookInfo
    screen._do_cover_images = current.mode ~= "mosaic_text" and current.mode ~= "list_only_meta"
    screen._do_filename_only = current.mode == "list_image_filename"
    screen._do_center_partial_rows = true
    screen._do_hint_opened = current.source == "filemanager" or current.history_hint_opened
    screen._library_covermenu = current.covermenu
end

function LibraryView.remember(screen)
    -- Native ListMenu may have just initialized its shared files_per_page setting.
    screen._library_display = state(screen)
end

function LibraryView.release(screen)
    local covermenu = screen._library_covermenu
    if not covermenu then return false end
    screen._library_covermenu = nil
    -- Use the original renderer even if ui.coverbrowser has since disappeared.
    -- This terminates extraction, closes its DB and cancels scheduled item updates.
    covermenu.onCloseWidget(screen)
    screen.items_to_update = nil
    screen.cover_specs = nil
    screen.dithered = nil
    return true
end

return LibraryView
