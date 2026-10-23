local UIManager = require("ui/uimanager")

local LibraryActions = {}

local function clearWaiter(screen)
    local waiter = screen._library_refresh_waiter
    if not waiter then return end
    if waiter.widget.onCloseWidget == waiter.handler then
        waiter.widget.onCloseWidget = waiter.original
    end
    screen._library_refresh_waiter = nil
end

function LibraryActions.cancelRefresh(screen)
    if screen._library_refresh_task then
        UIManager:unschedule(screen._library_refresh_task)
        screen._library_refresh_task = nil
    end
    screen._library_refresh_full = nil
    clearWaiter(screen)
end

function LibraryActions.queueRefresh(screen, metadata_only)
    -- A later metadata event must never downgrade a pending membership scan,
    -- including while waiting for a native confirmation/editor to close.
    screen._library_refresh_full = screen._library_refresh_full or not metadata_only
    if screen._library_refresh_task then return end
    screen._library_refresh_task = function()
        screen._library_refresh_task = nil
        local controller = screen.controller
        if controller.screen ~= screen or not controller:canShowView() then
            if controller.screen ~= screen or not controller:isLive() then
                screen._library_refresh_full = nil
                clearWaiter(screen)
                return
            end
            -- Book information can close and reopen itself after an edit. Wait
            -- for the covering native window, not a timer or an idle rescan.
            local widget = UIManager:getTopmostVisibleWidget()
            if not widget or widget == screen then return end
            local waiter = screen._library_refresh_waiter
            if waiter and waiter.widget == widget then return end
            clearWaiter(screen)
            waiter = { widget = widget, original = rawget(widget, "onCloseWidget") }
            local on_close = widget.onCloseWidget
            waiter.handler = function(closed_widget, ...)
                clearWaiter(screen)
                if on_close then on_close(closed_widget, ...) end
                LibraryActions.queueRefresh(screen, true)
            end
            screen._library_refresh_waiter = waiter
            widget.onCloseWidget = waiter.handler
            return
        end
        clearWaiter(screen)
        local full_scan = screen._library_refresh_full
        screen._library_refresh_full = nil
        -- Native confirmations call success callbacks BEFORE removing their
        -- own window. Only this deferred, uncovered path may scan/rebuild.
        if controller.view == "home" then
            -- Explicit native actions may rewrite same-size sidecars in one second.
            controller.home_source_cache = nil
            controller:showHome()
        elseif full_scan then
            controller:showLibrary()
        else
            screen:refreshMetadata()
        end
    end
    UIManager:nextTick(screen._library_refresh_task)
end

function LibraryActions.show(screen, item)
    if not item or item.select_enabled == false or not item.file then return true end
    -- Native book services are needed only when a real book is held, not when
    -- loading Home/Library or handling its nonselectable empty explanation.
    local BD = require("ui/bidi")
    local BookList = require("ui/widget/booklist")
    local ButtonDialog = require("ui/widget/buttondialog")
    local FileManager = require("apps/filemanager/filemanager")
    local InfoMessage = require("ui/widget/infomessage")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local lfs = require("libs/libkoreader-lfs")
    local _ = require("gettext")
    local T = require("ffi/util").template
    local file = item.file
    if lfs.attributes(file, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = T(_("File not found:\n%1"), BD.filepath(file)),
            icon = "notice-warning",
        })
        return true
    end

    local ui = screen.controller.ui
    local book_props = ui.coverbrowser and ui.coverbrowser:getBookInfo(file)
    local is_currently_opened = file == (ui.document and ui.document.file)
    local doc_settings_or_file = file
    if is_currently_opened then
        doc_settings_or_file = ui.doc_settings
        if not book_props then
            book_props = ui.doc_props
            book_props.has_cover = true
        end
    elseif BookList.hasBookBeenOpened(file) then
        doc_settings_or_file = BookList.getDocSettings(file)
        if not book_props then
            book_props = ui.bookinfo.extendProps(doc_settings_or_file:readSetting("doc_props"), file)
            book_props.has_cover = true
        end
    end

    local dialog
    local function closeDialog()
        if dialog and UIManager:isWidgetShown(dialog) then UIManager:close(dialog) end
    end
    local function refresh()
        LibraryActions.queueRefresh(screen, true)
    end
    local function closeAndRefresh()
        closeDialog()
        refresh()
    end
    local function closeAndRescan()
        closeDialog()
        LibraryActions.queueRefresh(screen)
    end

    local buttons = {
        filemanagerutil.genStatusButtonsRow(doc_settings_or_file, closeAndRefresh),
        {},
        {
            filemanagerutil.genResetSettingsButton(doc_settings_or_file, closeAndRescan, is_currently_opened),
            ui.collections:genAddToCollectionButton(file, closeDialog, refresh),
        },
        {
            {
                text = _("Delete"),
                enabled = not is_currently_opened,
                callback = function()
                    -- Leave the action dialog under the confirmation. Cancel
                    -- preserves it; only successful deletion closes/refreshes.
                    FileManager.showDeleteFileDialog(ui, file, function()
                        screen.controller.library_count = nil
                        closeAndRescan()
                    end)
                end,
            },
            {
                text = _("Open with…"),
                callback = function()
                    closeDialog()
                    -- Native provider/default confirmations own their entire
                    -- lifecycle; Library remains alive when they are canceled.
                    FileManager.showOpenWithDialog(ui, file)
                end,
            },
        },
        {
            filemanagerutil.genBookInformationButton(doc_settings_or_file, book_props, closeDialog),
        },
        {
            filemanagerutil.genBookCoverButton(file, book_props, closeDialog),
            filemanagerutil.genBookDescriptionButton(file, book_props, closeDialog),
        },
    }
    dialog = ButtonDialog:new{
        title = BD.filename(item.text),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return true
end

return LibraryActions
