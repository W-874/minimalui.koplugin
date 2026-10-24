-- Native-view templates. Data/extraction remain owned by KOReader v2026.07.1.
local BB = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu = require("ui/widget/menu")
local ReadCollection = require("readcollection")
local Device = require("device")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template
local ViewRender = {}
local Item = InputContainer:extend{ _minimal_view_item = true }
local function px(n) return Screen:scaleBySize(n) end
local size_scale = Screen:scaleBySize(1000000) / 1000000
local function face(size) return Font:getFace("cfont", size / size_scale) end
local function single(s) return tostring(s or ""):gsub("[\r\n]+", " · ") end
local function first(s) return (s or "?"):match("^[%z\1-\127\194-\244][\128-\191]*") or "?" end

local function pageIndex(menu, index)
    if menu.items_max_lines then
        local page = menu.page_items and menu.page_items[menu.page]
        return page and page[index]
    end
    return (menu.page - 1) * menu.perpage + index
end

local function selectByShortcut(menu, _, keyevent)
    if not Device:hasKeyboard() then return true end
    for index, key in ipairs(menu.item_shortcuts) do
        if key == keyevent.key then
            local entry_index = pageIndex(menu, index)
            local entry = entry_index and menu.item_table[entry_index]
            if entry and (menu.items_max_lines or index <= menu.perpage) then
                entry.idx = entry_index
                menu:onMenuSelect(entry)
            end
            break
        end
    end
    return true
end

-- Native init/registerKeyEvents may replace the key table after configuring
-- the renderer. Save displaced values only while someone still owns the table.
function ViewRender.bindShortcuts(menu)
    local state = menu._minimal_view_shortcuts
    if not state then
        state = {
            flag = rawget(menu, "is_enable_shortcut"),
            handler = rawget(menu, "onSelectByShortCut"),
            bindings = setmetatable({}, { __mode = "k" }), hooks = {},
            original_binding = menu.key_events and rawget(menu.key_events, "SelectByShortCut"),
        }
        menu._minimal_view_shortcuts = state
        for _, name in ipairs({ "onPhysicalKeyboardConnected", "onPhysicalKeyboardDisconnected" }) do
            local original, fallback = rawget(menu, name), menu[name]
            local hook = { original = original }
            -- A later plugin may retain this wrapper after release. Capture only
            -- its hook/fallback, not the attachment's displaced key tables.
            local wrapper = function(instance, ...)
                local current = instance._minimal_view_shortcuts
                if not current or current.hooks[name] ~= hook then
                    if fallback then return fallback(instance, ...) end
                    return
                end
                if fallback then fallback(instance, ...) end
                local previous = current.enabled
                ViewRender.bindShortcuts(instance)
                if previous ~= current.enabled and instance.item_group then instance:updateItems() end
            end
            hook.wrapper = wrapper
            state.hooks[name] = hook
            menu[name] = wrapper
        end
    end
    local keys = menu.key_events
    if not keys then keys = {}; menu.key_events = keys end
    if not state.bindings[keys] then
        local binding = rawget(keys, "SelectByShortCut")
        if binding == state.binding then binding = state.original_binding end
        state.bindings[keys] = { value = binding }
    end
    local mode = menu._minimalui_view and menu._minimalui_view.mode
    state.enabled = Device:hasKeyboard() and not (mode and mode:find("^mosaic"))
    menu.is_enable_shortcut = state.enabled
    state.binding = state.binding or { { menu.item_shortcuts } }
    keys.SelectByShortCut = state.enabled and state.binding or nil
    menu.onSelectByShortCut = selectByShortcut
end

function Item:textAt(text, size, bold, width, x, y, align, color)
    if not text or text == "" or width < 1 then return end
    local widget, d
    repeat
        if widget then widget:free(); size = size - 1 end
        widget = TextWidget:new{
            text = single(text), face = face(size), bold = bold,
            max_width = math.max(1, math.floor(width)), fgcolor = color,
        }
        d = widget:getSize()
    until not self.shrink or not widget._is_truncated or size <= px(8)
    if align == "right" then x = x + width - d.w
    elseif align == "center" then x = x + math.floor((width - d.w) / 2) end
    self.parts[#self.parts + 1] = { widget = widget, x = math.floor(x), y = math.floor(y) }
    return d
end

function Item:init()
    self.filepath = self.entry.file or self.entry.path
    self.file_deleted = self.entry.dim
    self.is_directory = not self.native and not (self.entry.is_file or self.entry.file)
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{
            ges = self.menu.handle_hold_on_hold_release and "hold_release" or "hold", range = self.dimen,
        } },
    }
    self:update()
end
function Item:clear()
    for _, part in ipairs(self.parts or {}) do part.widget:free() end
    self.parts = {}
end
function Item:free() self:clear() end
function Item:onCloseWidget() self:free() end
function Item:onFocus() self.focused = true; return true end
function Item:onUnfocus() self.focused = false; return true end
function Item:getGesPosition(ges)
    if not ges or not ges.pos then return nil end
    return { x = (ges.pos.x - self.dimen.x) / self.dimen.w,
        y = (ges.pos.y - self.dimen.y) / self.dimen.h }
end
function Item:onTapSelect(_, ges)
    self.menu:onMenuSelect(self.entry, self:getGesPosition(ges)); return true
end
function Item:onHoldSelect(_, ges)
    self.menu:onMenuHold(self.entry, self:getGesPosition(ges)); return true
end

local function progress(info, cached, manager)
    if manager and manager:getSetting("hide_page_info") then return "" end
    if info.status == "complete" then return _("Finished") end
    if info.status == "abandoned" then return _("On hold") end
    local percent = info.percent_finished
    if not percent then return "" end
    local pages = info.pages or cached.pages
    local text
    if manager and pages and manager:getSetting("show_pages_read_as_progress") then
        text = T(_("Page %1 of %2"), math.floor(percent * pages + 0.5), pages)
    else text = string.format("%d%%", math.floor(percent * 100)) end
    if manager and pages and manager:getSetting("show_pages_left_in_progress") then
        text = T(_("%1, %2 to read"), text, math.floor(pages * (1 - percent) + 0.5))
    end
    return text
end

function Item:cover(cached, maxw, maxh, x, y, center)
    local border = Size.border.thin
    local w, h = math.max(1, math.floor(maxw)), math.max(1, math.floor(maxh))
    if cached.cover_bb and cached.has_cover and not cached.ignore_cover then
        local image = ImageWidget:new{
            image = cached.cover_bb, width = math.max(1, w - 2 * border),
            height = math.max(1, h - 2 * border), scale_factor = 0,
        }
        cached.cover_bb = nil -- ownership transfers to the item/ImageWidget
        image:_render()
        local d = image:getSize()
        w, h = d.w + 2 * border, d.h + 2 * border
        if center then x = x + math.floor((maxw - w) / 2) end
        self.parts[#self.parts + 1] = { widget = image, x = x + border, y = y + border }
        self._has_cover_image, self.menu._has_cover_images = true, true
    else
        if center then
            w = math.min(w, math.floor(h * 0.7))
            x = x + math.floor((maxw - w) / 2)
        end
        local size = self.grid and math.floor(self.width * 0.38) or math.min(px(22), math.floor(h * 0.48))
        local cover_face = face(math.max(1, size))
        local probe = TextWidget:new{ text = first(self.title), face = cover_face, bold = true }
        local th = probe:getSize().h; probe:free()
        self:textAt(first(self.title), size, true, w - 2 * border, x + border,
            y + math.floor((h - th) / 2), "center")
    end
    self.cover_rect = { x = x, y = y, w = w, h = h }
    return w, h
end

function Item:update()
    local menu, state = self.menu, self.menu._minimalui_view or {}
    local manager = state.manager
    local cached, info = {}, {}
    if not self.native and not self.classic and not self.is_directory and self.filepath then
        info = BookList.getBookInfo(self.filepath)
        if manager then
            local found = manager:getBookInfo(self.filepath, menu._do_cover_images)
            cached = found or {}
            if menu._do_cover_images and not cached.ignore_cover and not self.file_deleted then
                if not cached.cover_fetched or (cached.has_cover and not menu.no_refresh_covers
                        and manager.isCachedCoverInvalid(cached, menu.cover_specs)) then
                    if cached.cover_bb then cached.cover_bb:free() end
                    cached, found = {}, nil
                end
            end
            self.bookinfo_found = found ~= nil
            self.cover_specs = menu._do_cover_images and menu.cover_specs or nil
        else self.bookinfo_found = true end
    else self.bookinfo_found = true end
    if self.built and not self.bookinfo_found then return end
    self:clear()
    self._has_cover_image, self.cover_rect, self.progress_rect, self.complete_rect = nil, nil, nil, nil
    self.shrink = not self.grid and ((self.classic and G_reader_settings:isTrue("items_multilines_show_more_text"))
        or (not self.classic and manager and require("minimalui/viewsettings").shrinkEnabled(manager)))
    local files = state.kind == "files"
    self.title = single((files or self.classic or self.is_directory) and Menu.getMenuText(self.entry)
        or (not cached.ignore_meta and cached.title) or Menu.getMenuText(self.entry))
    if self.classic and not menu.single_line and (menu.items_max_lines or menu.multilines_forced) then
        self.title = tostring(Menu.getMenuText(self.entry) or "")
    end
    local authors = single(not cached.ignore_meta and cached.authors or "")
    if not files and not self.classic and cached.series then
        local series = cached.series .. (cached.series_index and " #" .. cached.series_index or "")
        local mode = manager and manager:getSetting("series_mode")
        if mode == "append_series_to_title" then self.title = self.title .. " - " .. series
        elseif mode then authors = authors ~= "" and authors .. " · " .. series or series end
    end
    if state.page == "HISTORY" and self.entry.mandatory then
        authors = authors ~= "" and authors .. " · " .. self.entry.mandatory or self.entry.mandatory
    end
    if info.has_annotations then authors = authors ~= "" and authors .. " · " .. _("Has notes") or _("Has notes") end
    local reading = info.percent_finished and info.percent_finished > 0 and info.percent_finished < 1
        and info.status ~= "complete" and info.status ~= "abandoned"
    local w, h, pad = self.width, self.height, px(10)
    local left = pad
    if self.shortcut then
        local size = math.min(px(26), math.max(1, h - px(8)))
        local badge = menu:getItemShortCutIcon(Geom:new{ w = size, h = size }, self.shortcut, "square")
        self.parts[#self.parts + 1] = { widget = badge, x = pad, y = math.floor((h - size) / 2) }
        left = pad + size + px(8)
    end
    if self.classic then
        local right = self.entry.mandatory_func and self.entry.mandatory_func() or self.entry.mandatory
        local size = px(menu.items_mandatory_font_size or menu.font_size - 4)
        local dim = self.entry.dim
        if self.entry.dim_func then dim = self.entry.dim_func() end
        local mandatory_dim = self.entry.mandatory_dim
        if mandatory_dim == nil then mandatory_dim = dim end
        if self.entry.mandatory_dim_func then mandatory_dim = self.entry.mandatory_dim_func() end
        local r = self:textAt(right, size, false, math.max(1, (w - left - pad) * 0.4), left, 0, "right",
            mandatory_dim and BB.COLOR_DARK_GRAY or nil)
        local rw = r and r.w + px(12) or 0
        if r then self.parts[#self.parts].x = w - pad - r.w; self.parts[#self.parts].y = math.floor((h - r.h) / 2) end
        local bold = self.entry.bold == true or menu.item_table.current == self.entry.idx
        local color = dim and BB.COLOR_DARK_GRAY or nil
        local available = w - left - pad - rw
        local post = self:textAt(self.entry.post_text, size, bold, available * 0.5, left, 0, nil, color)
        if post then
            self.parts[#self.parts].x = w - pad - rw - post.w
            self.parts[#self.parts].y = math.floor((h - post.h) / 2)
            available = available - post.w - px(8)
        end
        if not menu.single_line and (menu.items_max_lines or menu.multilines_forced) then
            local widget = TextBoxWidget:new{
                text = self.title, face = face(px(menu.font_size)), bold = bold, fgcolor = color,
                width = math.max(1, math.floor(available)), height = math.max(1, h - px(4)), height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
            self.parts[#self.parts + 1] = { widget = widget, x = left,
                y = math.max(0, math.floor((h - widget:getSize().h) / 2)) }
        else
            local d = self:textAt(self.title, px(menu.font_size), bold, available, left, 0, nil, color)
            if d then self.parts[#self.parts].y = math.floor((h - d.h) / 2) end
        end
        self.separator_x = left
    elseif self.grid then
        local title_size = math.min(px(15), math.max(px(10), math.floor(w * 0.09)))
        local probe = TextWidget:new{ text = self.title, face = face(title_size), bold = true }
        local th = probe:getSize().h; probe:free()
        local top, bottom = px(4), px(4)
        local cover_h = math.max(1, math.min(menu.cover_specs and menu.cover_specs.max_cover_h or h,
            h - top - bottom - th - px(12)))
        local cover_w = math.max(1, math.min(w - px(8), menu.cover_specs and menu.cover_specs.max_cover_w or w))
        if self.is_directory then
            cover_w = math.min(cover_w, math.floor(cover_h * 0.7))
            self.folder_rect = { x = math.floor((w - cover_w) / 2), y = top, w = cover_w, h = cover_h }
            self:textAt(self.entry.mandatory, px(14), false, cover_w - px(8), self.folder_rect.x + px(4),
                top + math.floor(cover_h / 2), "center", BB.COLOR_DARK_GRAY)
        else
            local cw, ch = self:cover(cached, cover_w, cover_h, math.floor((w - cover_w) / 2), top, true)
            if reading and manager and manager:getSetting("show_progress_in_mosaic") then
                self.progress_rect = { x = self.cover_rect.x, y = top + ch + px(3), w = cw, h = px(4), value = info.percent_finished }
            end
            if info.status == "complete" and menu._do_hint_opened then
                local s = px(11)
                self.complete_rect = { x = self.cover_rect.x + cw - s, y = top + ch - s, w = s, h = s }
                self:textAt("✓", px(10), true, s, self.complete_rect.x, self.complete_rect.y - px(1), "center")
            end
        end
        self:textAt(self.title, title_size, true, w - px(8), px(4), h - bottom - th, "center")
    else
        local cover_left = left
        if menu._do_cover_images then
            local ch = math.max(1, math.min(h - px(8), menu.cover_specs.max_cover_h + 2 * Size.border.thin))
            local cw = math.min(math.floor(ch * 0.7), menu.cover_specs.max_cover_w + 2 * Size.border.thin)
            self:cover(cached, cw, ch, cover_left, math.floor((h - ch) / 2), false)
            left = cover_left + cw + px(14)
        end
        local right = ""
        if files then
            if not manager or not manager:getSetting("hide_file_info") then right = self.entry.mandatory or "" end
        else
            right = progress(info, cached, manager)
            if info.status == "complete" and not menu._do_hint_opened then right = "" end
            if self.filepath and ReadCollection:isFileInCollections(self.filepath) then right = "★" .. (right ~= "" and " " .. right or "") end
        end
        local title_size = math.min(px(20), math.max(px(12), math.floor(h * 0.29)))
        local author_size = math.min(px(16), math.max(px(10), math.floor(h * 0.23)))
        local top = math.max(px(3), math.floor((h - title_size - author_size - px(12)) / 2))
        local rd = self:textAt(right, author_size, reading, math.max(1, (w - left) * 0.5), left, top, "right")
        local rw = rd and rd.w + pad or 0
        if rd then self.parts[#self.parts].x = w - pad - rd.w end
        self:textAt(self.title, title_size, true, w - left - pad - rw, left, top)
        self:textAt(authors, author_size, false, w - left - pad, left, top + title_size + px(3))
        if reading then self.progress_rect = { x = left, y = h - px(8), w = math.floor((w - left - pad) * 0.5), h = px(3), value = info.percent_finished } end
        self.separator_x = left
    end
    if cached.cover_bb then cached.cover_bb:free() end
    self.built = true
    self.refresh_dimen = self.dimen
    local focus = package.loaded["minimalui/viewfocus"]
    if focus then focus.invalidate(menu) end
end

function Item:paintFocus(bb)
    if not self.focused then return end
    local d = self.dimen
    if self.grid then bb:paintBorder(d.x, d.y, d.w, d.h, px(2), BB.COLOR_BLACK)
    else bb:paintRect(d.x + px(1), d.y + px(3), px(3), math.max(1, d.h - px(6)), BB.COLOR_BLACK) end
end
function Item:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r = self.cover_rect
    if r then bb:paintBorder(x + r.x, y + r.y, r.w, r.h, Size.border.thin, BB.COLOR_BLACK) end
    r = self.folder_rect
    if r then
        local tab = math.max(px(3), math.floor(r.h * 0.08))
        bb:paintBorder(x + r.x, y + r.y + tab, r.w, r.h - tab, Size.border.thin, BB.COLOR_BLACK)
        bb:paintBorder(x + r.x, y + r.y, math.floor(r.w * 0.45), tab + Size.border.thin, Size.border.thin, BB.COLOR_BLACK)
    end
    r = self.progress_rect
    if r then
        bb:paintRect(x + r.x, y + r.y, r.w, r.h, BB.COLOR_LIGHT_GRAY)
        bb:paintRect(x + r.x, y + r.y, math.floor(r.w * r.value), r.h, BB.COLOR_BLACK)
    end
    -- Completion badge covers the image, so it must be composited after it.
    for _, part in ipairs(self.parts) do
        if part.widget.image then part.widget:paintTo(bb, x + part.x, y + part.y) end
    end
    r = self.complete_rect
    if r then
        bb:paintRect(x + r.x, y + r.y, r.w, r.h, BB.COLOR_WHITE)
        bb:paintBorder(x + r.x, y + r.y, r.w, r.h, Size.border.thin, BB.COLOR_BLACK)
    end
    for _, part in ipairs(self.parts) do
        if not part.widget.image then part.widget:paintTo(bb, x + part.x, y + part.y) end
    end
    if self.separator_x and not self.last then
        bb:paintRect(x + self.separator_x, y + self.height - Size.line.thin,
            self.width - self.separator_x - px(10), Size.line.thin, BB.COLOR_DARK_GRAY)
    end
    self:paintFocus(bb)
end

function ViewRender.build(menu)
    local state = menu._minimalui_view or {}
    ViewRender.bindShortcuts(menu)
    local grid = state.mode and state.mode:find("^mosaic") ~= nil
    local classic = not state.mode
    local border = Size.border.thin
    -- These are exactly the native same-mode extraction specs, independent of
    -- the smaller display rectangle (ListMenuItem has two 1px underline pads).
    if not classic then
        menu.cover_specs = menu._do_cover_images and {
            max_cover_w = grid and menu.item_width - 2 * border or menu.item_height - 2 - 2 * border,
            max_cover_h = grid and menu.item_height - 2 * border or menu.item_height - 2 - 2 * border,
        } or false
    end
    local selected, row, line
    local page = classic and menu.items_max_lines and menu.page_items and menu.page_items[menu.page]
    local count = page and #page or math.min(menu.perpage, #menu.item_table - (menu.page - 1) * menu.perpage)
    for idx = 1, count do
        local index = page and page[idx] or (menu.page - 1) * menu.perpage + idx
        local entry = menu.item_table[index]; entry.idx = index
        if index == menu.itemnumber then selected = idx end
        if grid and (idx - 1) % menu.nb_cols == 0 then
            line = {}; menu.layout[#menu.layout + 1] = line
            menu.item_group[#menu.item_group + 1] = VerticalSpan:new{ width = menu.item_margin }
            row = HorizontalGroup:new{}
            local container = menu._do_center_partial_rows and CenterContainer or LeftContainer
            menu.item_group[#menu.item_group + 1] = container:new{
                dimen = Geom:new{ w = menu.inner_dimen.w, h = menu.item_height }, row,
            }
            row[#row + 1] = HorizontalSpan:new{ width = menu.item_margin }
        end
        local dimen = menu.item_dimen:copy()
        if page then dimen.h = entry.height end
        local item = Item:new{
            menu = menu, entry = entry, dimen = dimen, width = dimen.w, height = dimen.h,
            grid = grid, classic = classic, native = state.kind == "native", last = idx == count,
            idx = index, shortcut = menu.is_enable_shortcut and menu.item_shortcuts[idx] or nil,
        }
        if grid then
            row[#row + 1] = item; row[#row + 1] = HorizontalSpan:new{ width = menu.item_margin }
            line[#line + 1] = item
        else
            menu.item_group[#menu.item_group + 1] = item
            if not classic then menu.item_group[#menu.item_group + 1] = VerticalSpan:new{ width = Size.line.thin } end
            menu.layout[#menu.layout + 1] = { item }
        end
        if not item.native and not classic and not item.bookinfo_found and not item.is_directory and not item.file_deleted then
            menu.items_to_update[#menu.items_to_update + 1] = item
        end
    end
    if grid then menu.item_group[#menu.item_group + 1] = VerticalSpan:new{ width = menu.item_margin } end
    return selected
end

-- Same layout/data protocol as native CoverMenu:updateItems, with instance-
-- owned cancellable launch/poll callbacks (v2026.07.1 covermenu.lua:34-176).
function ViewRender.updateCover(menu, selected, no_recalculate)
    local old = menu.dimen and menu.dimen:copy()
    local Jobs = require("minimalui/viewjobs")
    Jobs.cancel(menu)
    require("minimalui/viewfocus").invalidate(menu)
    menu.layout = {}; menu.item_group:clear()
    if not no_recalculate then menu:_recalculateDimen() end
    menu.page_info:resetLayout(); menu.return_button:resetLayout(); menu.content_group:resetLayout()
    menu.items_to_update = {}; menu._has_cover_images = false
    selected = ViewRender.build(menu) or selected
    menu:updatePageInfo(selected); menu:mergeTitleBarIntoLayout()
    require("minimalui/viewfooter").apply(menu)
    menu.show_parent.dithered = menu._has_cover_images
    local manager = menu._minimalui_view.manager
    UIManager:setDirty(menu.show_parent, function()
        local mode = menu._has_cover_images and manager:getSetting("flash_ui_cover_images") and "flashui" or "ui"
        return mode, old and old:combine(menu.dimen) or menu.dimen, menu.show_parent.dithered
    end)
    if menu.path_items then menu.path_items[menu.path] = (menu.page - 1) * menu.perpage + (selected or 1) end
    Jobs.start(menu, manager)
end

-- Menu's classic builder is inline, so replace its instance update method while
-- retaining its dimension calculation, native selection and refresh lifecycle.
function ViewRender.updateClassic(menu, selected, no_recalculate)
    local old = menu.dimen and menu.dimen:copy()
    require("minimalui/viewjobs").cancel(menu)
    require("minimalui/viewfocus").invalidate(menu)
    menu.layout = {}; menu.item_group:clear()
    menu.page_info:resetLayout(); menu.return_button:resetLayout(); menu.content_group:resetLayout()
    ViewRender.bindShortcuts(menu)
    menu:_recalculateDimen(no_recalculate)
    selected = ViewRender.build(menu) or selected
    menu:updatePageInfo(selected); menu:mergeTitleBarIntoLayout()
    require("minimalui/viewfooter").apply(menu)
    if menu.path_items then menu.path_items[menu.path] = (menu.page - 1) * menu.perpage + (selected or 1) end
    UIManager:setDirty(menu.show_parent or menu, function() return "ui", old and old:combine(menu.dimen) or menu.dimen end)
end
function ViewRender.attach(menu, options)
    ViewRender.bindShortcuts(menu)
    require("minimalui/viewfocus").attach(menu)
    require("minimalui/viewfooter").apply(menu)
end
function ViewRender.release(menu)
    require("minimalui/viewjobs").cancel(menu, true)
    require("minimalui/viewfocus").release(menu)
    require("minimalui/viewfooter").release(menu, false)
    local state = menu._minimal_view_shortcuts
    if state then
        for keys, saved in pairs(state.bindings) do keys.SelectByShortCut = saved.value end
        menu.is_enable_shortcut = state.flag
        if menu.onSelectByShortCut == selectByShortcut then menu.onSelectByShortCut = state.handler end
        for name, hook in pairs(state.hooks) do
            if rawget(menu, name) == hook.wrapper then menu[name] = hook.original end
        end
        menu._minimal_view_shortcuts = nil
    end
end
ViewRender.Item = Item
return ViewRender
