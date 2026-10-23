local Menu = require("ui/widget/menu")
local ViewSettings = require("minimalui/viewsettings")

-- Borrow only the renderer methods from the active native plugin. Never load
-- CoverBrowser (or its settings database) on behalf of a disabled plugin.
local LibraryView = {}
local function options(screen)
    -- Native cover items require a real path, even for their collection marks.
    -- Keep our nonselectable empty-page explanation in the native classic list.
    local items = screen.item_table or {}
    if screen._library_items ~= items then
        screen._library_items, screen._library_has_paths = items, true
        for _, item in ipairs(items) do
            if not (item.file or item.path) then screen._library_has_paths = false; break end
        end
    end
    return { kind = "books", page = "LIBRARY", force_classic = not screen._library_has_paths }
end

function LibraryView.changed(screen)
    return ViewSettings.changed(screen, screen.controller.ui, options(screen))
end

function LibraryView.apply(screen)
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
    local ViewRender = require("minimalui/viewrender")
    local current = ViewSettings.configure(screen, screen.controller.ui, options(screen))
    if not current.mode then
        screen._updateItemsBuildUI = function(target) return ViewRender.build(target) end
        screen.updateItems = function(target, ...)
            ViewRender.updateClassic(target, ...)
            ViewSettings.remember(target)
        end
        ViewRender.attach(screen, { kind = "books", page = "LIBRARY" })
        return
    end

    -- configure borrows only renderer methods; never patch native data owners.
    screen.updateItems = function(target, ...)
        require("minimalui/viewfocus").invalidate(target)
        ViewRender.updateCover(target, ...)
        target:mergeTitleBarIntoLayout()
        ViewSettings.remember(target)
    end
    screen._recalculateDimen = current.renderer._recalculateDimen
    screen._updateItemsBuildUI = function(target) return ViewRender.build(target) end
    screen._library_covermenu = current.covermenu
    ViewRender.attach(screen, { kind = "books", page = "LIBRARY" })
end

function LibraryView.remember(screen)
    require("minimalui/viewrender").attach(screen, { kind = "books", page = "LIBRARY" })
    -- Native ListMenu may have just initialized its shared files_per_page setting.
    ViewSettings.remember(screen)
end

function LibraryView.release(screen)
    require("minimalui/viewrender").release(screen)
    local manager = screen._minimalui_view and screen._minimalui_view.close_manager
    ViewSettings.release(screen)
    if not screen._library_covermenu then return false end
    screen._library_covermenu = nil
    -- Keep native resource cleanup, but never terminate another page's batch.
    require("minimalui/viewjobs").close(screen, manager)
    screen.items_to_update = nil
    screen.cover_specs = nil
    screen.dithered = nil
    return true
end

return LibraryView
