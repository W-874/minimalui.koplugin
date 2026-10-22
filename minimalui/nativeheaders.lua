local Header = require("minimalui/header")
local UIManager = require("ui/uimanager")

local NativeHeaders = {}

-- Replace the actual widget-tree reference, not only Menu.title_bar: Menu keeps
-- its header inside content_group after init, including CoverBrowser layouts.
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

function NativeHeaders:new(args)
    return setmetatable({ controller = args.controller, creators = {}, pages = {} }, { __index = self })
end

function NativeHeaders:adapt(widget, page, is_browser)
    if not widget or not widget.title_bar or widget._minimal_header then return end
    local controller, old = self.controller, widget.title_bar
    local ui = controller.ui
    local extra = {}
    if not is_browser and old.left_icon then
        extra[#extra + 1] = {
            icon = old.left_icon, role = "left", callback = old.left_icon_tap_callback,
            hold_callback = old.left_icon_hold_callback,
        }
    end
    if not is_browser and page ~= "HISTORY" and (old.right_icon or old.close_callback) then
        extra[#extra + 1] = {
            icon = old.close_callback and "close" or old.right_icon, role = "right",
            callback = old.close_callback or old.right_icon_tap_callback,
            hold_callback = old.close_hold_callback or old.right_icon_hold_callback,
        }
    end
    local header = Header:new{
        width = widget.dimen.w, title = "KO/" .. page, page = not is_browser and page or nil,
        subtitle = not is_browser and (old.subtitle_widget and old.subtitle_widget.text or old.subtitle) or nil,
        folder_title = is_browser and function() return ui.file_chooser.path end or nil,
        show_parent = is_browser and ui or widget,
        menu_callback = function() return controller:showNativeMenu() end,
        home_callback = function()
            if not controller:isLive() then return true end
            if is_browser then return ui:onHome() end
            if widget.close_callback then widget.close_callback() end
            return controller:showHome()
        end,
        home_hold_callback = is_browser and old.left_icon_hold_callback or nil,
        extra_buttons = extra,
    }
    header.native_title = old.title_widget and old.title_widget.text or old.title or widget.title
    -- Native FM anchors its folder menu to title_bar.left_button.image.dimen.
    if is_browser then header.left_button = header.home_button end
    local record = {
        widget = widget, old = old, header = header, custom = widget.custom_title_bar,
        is_browser = is_browser,
    }
    self.pages[#self.pages + 1] = record
    widget._minimal_header = record
    widget.title_bar, widget.custom_title_bar = header, header
    replace(widget, old, header)
    if is_browser then
        ui.title_bar = header
        ui:updateTitleBarPath()
    end
    relayout(widget)
end

function NativeHeaders:watch(instance, method, page)
    if not instance or not instance[method] then return end
    for _, record in ipairs(self.creators) do
        if record.instance == instance and record.method == method then return end
    end
    local original, fallback = rawget(instance, method), instance[method]
    local wrapper = function(target, ...)
        local result = fallback(target, ...)
        self:prune()
        if self.controller:isEnabled() then self:adapt(target.booklist_menu, page, false) end
        return result
    end
    self.creators[#self.creators + 1] = {
        instance = instance, method = method, original = original, wrapper = wrapper,
    }
    instance[method] = wrapper
end

function NativeHeaders:prune()
    local ui = self.controller.ui
    for i = #self.pages, 1, -1 do
        local record = self.pages[i]
        local retained = record.is_browser and record.widget == ui.file_chooser
            or not record.is_browser and UIManager:isWidgetShown(record.widget.show_parent or record.widget)
        if not retained then
            record.old:free()
            record.header:free()
            record.widget._minimal_header = nil
            table.remove(self.pages, i)
        end
    end
end

function NativeHeaders:apply()
    local ui = self.controller.ui
    if not ui then return end
    self:prune()
    self:adapt(ui.file_chooser, "FILES", true)
    for _, entry in ipairs({
        { ui.history, "onShowHist", "HISTORY" },
        { ui.collections, "onShowColl", "COLLECTIONS" },
        { ui.filesearcher, "onShowSearchResults", "SEARCH" },
    }) do
        self:watch(entry[1], entry[2], entry[3])
        if entry[1] then self:adapt(entry[1].booklist_menu, entry[3], false) end
    end
end

function NativeHeaders:restore()
    for _, record in ipairs(self.creators) do
        if rawget(record.instance, record.method) == record.wrapper then
            record.instance[record.method] = record.original
        end
    end
    self.creators = {}
    for _, record in ipairs(self.pages) do
        local widget = record.widget
        if widget._minimal_header == record then
            widget.title_bar, widget.custom_title_bar = record.old, record.custom
            replace(widget, record.header, record.old)
            widget._minimal_header = nil
            if record.is_browser and self.controller.ui.file_chooser == widget then
                self.controller.ui.title_bar = record.old
                if not self.controller.ui.tearing_down and not self.controller.closed then
                    self.controller.ui:updateTitleBarPath()
                    record.old:setRightIcon(self.controller.ui.selected_files and "check" or "plus")
                end
            end
            if not record.is_browser then
                record.old:setTitle(record.header.native_title or widget.title, true)
                record.old:setSubTitle(record.header.subtitle, true)
            end
            if not self.controller.ui.tearing_down and not self.controller.closed
                    and UIManager:isWidgetShown(widget.show_parent or widget) then relayout(widget) end
            record.header:free()
        end
    end
    self.pages = {}
end

return NativeHeaders
