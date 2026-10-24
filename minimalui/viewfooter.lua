-- Instance-only six-slot footer. Native buttons retain pagination, return,
-- keyboard activation, feedback, and jump/search dialog ownership.
local Button = require("ui/widget/button")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Size = require("ui/size")
local Screen = require("device").screen
local T = require("ffi/util").template
local _ = require("gettext")

local ViewFooter = {}
local positions = { 0, 72, 192, 264, 336, 528 }
local generic_icon_size = G_defaults:readSetting("DGENERIC_ICON_SIZE")
local attributes = {
    "width", "height", "padding_h", "padding_v", "align", "text_font_bold",
    "text_font_face", "avoid_text_truncation", "callback", "hold_callback",
    "overlap_offset", "overlap_align",
    "icon_width", "icon_height",
}

local function pack(...)
    return { n = select("#", ...), ... }
end

local function replace(root, old, new)
    local changed = false
    for i, child in ipairs(root) do
        if child == old then
            root[i], changed = new, true
        elseif type(child) == "table" and replace(child, old, new) then
            changed = true
        end
    end
    if changed and root.resetLayout then root:resetLayout() end
    return changed
end

local function hook(record, target, name, handler)
    local original, fallback = rawget(target, name), target[name]
    local state = { record = record, fallback = fallback }
    local wrapper = function(instance, ...)
        if state.record then return handler(state.record, state.fallback, instance, ...) end
        return state.fallback(instance, ...)
    end
    local entry = {
        target = target, name = name, original = original, wrapper = wrapper, state = state,
    }
    record.hooks[#record.hooks + 1] = entry
    target[name] = wrapper
    return entry
end

local function pagination(record)
    local menu = record.menu
    if record.key_value then return #menu.kv_pairs > 0, menu.show_page, menu.pages end
    return #menu.item_table > 0, menu.page, menu.page_num
end

local function saveButton(record, button)
    if record.saved[button] then return end
    local saved = {}
    for _, key in ipairs(attributes) do saved[key] = { value = rawget(button, key) } end
    record.saved[button] = saved
end

local function sizeButton(record, button, width, height)
    saveButton(record, button)
    local text = button == record.menu.page_info_text
    -- Native Button defaults use screen density, which can exceed the footer
    -- height after a narrower window resize. Scale glyphs with their regions
    -- using the native generic icon size at the same 600px design baseline.
    local icon_size = math.min(width, height, math.floor(height * generic_icon_size / 50 + 0.5))
    if button.width == width and button.height == height and button.padding_h == 0
            and button.padding_v == 0 and button.align == "center"
            and (text and button.text_font_bold and button.text_font_face == "cfont"
                or not text and button.icon_width == icon_size and button.icon_height == icon_size) then return end
    local invert = button.frame and button.frame.invert
    local hidden = button.hidden
    button:show()
    button.width, button.height = width, height
    button.padding_h, button.padding_v, button.align = 0, 0, "center"
    if text then
        button.text_font_bold, button.text_font_face = true, "cfont"
        -- Long localized "No items" labels must not rebuild the button on each
        -- page. The fixed slot clips its text instead of changing its geometry.
        button.avoid_text_truncation = false
    else
        button.icon_width, button.icon_height = icon_size, icon_size
    end
    button.label_widget:free()
    button:init()
    if button == record.navigation_button or button == record.action_button then
        -- Native OPDS popups anchor to IconButton.image rather than the tap
        -- region. Keep that interface on our owned buttons' actual glyphs.
        button.image = button.label_widget
    end
    button.frame.invert = invert
    button:showHide(not hidden)
end

local function setIcon(button, icon)
    if not icon or icon == button.icon then return end
    local hidden, invert = button.hidden, button.frame.invert
    button:show()
    button:setIcon(icon, button.width)
    button.image = button.label_widget
    button.frame.invert = invert
    button:showHide(not hidden)
end

local function removeFocusRow(record)
    local layout = record.menu.layout
    if not layout then return end
    for i = #layout, 1, -1 do
        if layout[i] == record.buttons then table.remove(layout, i) end
    end
end

local function focusRow(record)
    local menu, row = record.menu, record.buttons
    if not menu.layout then return end
    local selected = menu.selected and menu.layout[menu.selected.y]
    selected = selected and selected[menu.selected.x]
    local count, changed = 0, false
    for _, button in ipairs(record.footer) do
        if not button.hidden and button.enabled then
            count = count + 1
            if row[count] ~= button then
                row[count], changed = button, true
            end
        end
    end
    if #row ~= count then changed = true end
    for i = #row, count + 1, -1 do row[i] = nil end
    -- Paint still checks live visibility/enabled state, but an unchanged final
    -- row needs neither layout surgery nor a full search for the focused item.
    if not changed and count > 0 and menu.layout[#menu.layout] == row then return end
    removeFocusRow(record)
    if count > 0 then menu.layout[#menu.layout + 1] = row end
    -- Appending the row must not steal initial content focus. Retain an
    -- already-focused footer button when live context changes its neighbours.
    if selected and menu.selected then
        for y, widgets in ipairs(menu.layout) do
            for x, button in ipairs(widgets) do
                if button == selected then
                    menu.selected.x, menu.selected.y = x, y
                    return
                end
            end
        end
        selected:onUnfocus()
        menu.selected.x, menu.selected.y = 1, 1
    end
end

local function finish(record)
    local menu = record.menu
    if not menu or menu._minimal_view_footer ~= record then return end
    menu.page_info_first_chev:hide()
    menu.page_info_last_chev:hide()
    menu.page_info_left_chev:show()
    menu.page_info_right_chev:show()
    local has_items = pagination(record)
    if has_items then menu.page_info_text:enable() end
    if not has_items then
        menu.page_info_left_chev:disable()
        menu.page_info_right_chev:disable()
    end
    local stack = menu.item_table_stack
    local has_stack = stack and #stack > 0
    local can_return = record.key_value and menu.callback_return ~= nil
        or not record.key_value and (menu.onReturn ~= nil or has_stack or menu.paths and #menu.paths > 0)
    local context = record.context
    if context.return_visible ~= nil then
        local visible = context.return_visible
        if type(visible) == "function" then visible = visible() end
        can_return = can_return and visible
    end
    local arrow = menu.page_return_arrow
    -- Nested plain Menu uses onClose to pop its native item_table_stack.
    -- FileChooser/OPDS/KeyValuePage keep their original return callback.
    arrow.callback = has_stack and not menu.onReturn and record.stack_return_callback
        or record.saved[arrow].callback.value
    arrow:showHide(can_return)
    arrow:enableDisable(not not can_return)
    local nav, action = record.navigation_button, record.action_button
    nav.callback, nav.hold_callback = context.navigation_callback, context.navigation_hold_callback
    local navigation_icon = context.navigation_icon
    setIcon(nav, navigation_icon)
    local show_navigation = navigation_icon ~= nil and nav.callback ~= nil
    nav:showHide(show_navigation)
    nav:enableDisable(show_navigation)
    local icon = context.action_icon
    if type(icon) == "function" then icon = icon() end
    action.callback, action.hold_callback = context.action_callback, context.action_hold_callback
    setIcon(action, icon)
    local show_action = icon ~= nil and action.callback ~= nil
    action:showHide(show_action)
    action:enableDisable(show_action)
    focusRow(record)
end

local Footer = OverlapGroup:extend{ allow_mirroring = false }
function Footer:init() end
function Footer:resetLayout() end
function Footer:getSize() return self.dimen end
function Footer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    finish(self.record)
    OverlapGroup.paintTo(self, bb, x, y)
end

local function geometry(record, width)
    local footer = record.footer
    local height = math.floor(width * 50 / 600 + 0.5)
    if footer.dimen.w == width and footer.dimen.h == height then return false end
    footer.dimen.w, footer.dimen.h = width, height
    record.sizing.h = math.max(0, height - Size.padding.button)
    for i, button in ipairs(footer) do
        local x = math.floor(width * positions[i] / 600 + 0.5)
        local edge = math.floor(width * (positions[i] + 72) / 600 + 0.5)
        button.overlap_offset[1] = x
        sizeButton(record, button, edge - x, height)
    end
    return true
end

local function ensure(record, after_init)
    local menu = record.menu
    if not menu or menu._minimal_view_footer ~= record then return false end
    geometry(record, record.key_value and menu.dimen.w or menu.inner_dimen.w)
    local sizing_hook = record.dimension_hook
    if sizing_hook and menu._recalculateDimen ~= sizing_hook.wrapper then
        -- ViewSettings swaps the native renderer's calculator on each update.
        -- Rearm one retained hook around the latest implementation, not around
        -- an accumulating chain of obsolete per-render wrappers.
        sizing_hook.original = rawget(menu, "_recalculateDimen")
        sizing_hook.state.fallback = menu._recalculateDimen
        menu._recalculateDimen = sizing_hook.wrapper
    end
    local rebuilt = menu.page_info ~= record.footer or menu.return_button ~= record.empty_return
    if menu.page_info ~= record.footer then record.original = menu.page_info end
    if menu.return_button ~= record.empty_return then record.original_return = menu.return_button end
    menu.page_info, menu.return_button = record.footer, record.empty_return
    -- Both KeyValuePage and direct Menu.init callers can adapt page_info
    -- before native init assembles its final local BottomContainers. Track
    -- the actual tree root, not just the public page_info reference.
    if rebuilt or after_init or record.tree_root ~= menu[1] then
        replace(menu, record.original, record.footer)
        replace(menu, record.original_return, record.empty_return)
        record.tree_root = menu[1]
    end
    return true
end

local function layoutKeyValue(menu)
    local available = menu.dimen.h - menu.title_bar:getHeight() - Size.span.vertical_large
        - (menu.single_page and 0 or menu.page_info:getSize().h) - 2 * Size.line.thick
    menu.item_height = math.floor(available / menu.items_per_page)
    menu.items_font_size = math.min(require("ui/widget/textboxwidget"):getFontSizeToFitHeight(
        menu.item_height, 1, 1.0), 22)
    local function spacing(root)
        for i, child in ipairs(root) do
            if child == menu.title_bar and root[i + 1] then
                root[i + 1].width = math.floor((available - menu.items_per_page * menu.item_height) / 2)
                return true
            elseif type(child) == "table" and spacing(child) then return true end
        end
    end
    spacing(menu)
    menu:_populateItems()
    replace(menu, menu.title_bar, menu.title_bar)
end

function ViewFooter.apply(menu, context, before_init)
    if not menu or not menu.page_info or not menu.page_info_text then return false end
    local record = menu._minimal_view_footer
    if record and record.releasing then return false end
    if record then
        if context ~= nil then record.context = context end
        ensure(record)
        if not before_init then finish(record) end
        return true
    end
    record = {
        menu = menu, context = context or {}, hooks = {}, saved = {}, buttons = {},
        key_value = not menu.updatePageInfo and menu._populateItems ~= nil,
        sizing = Geom:new{},
        empty_return = WidgetContainer:new{ dimen = Geom:new{ w = 0, h = 0 } },
    }
    record.empty_return.resetLayout = function() end
    record.focus_row = record.buttons
    record.stack_return_callback = function() menu:onClose() end
    record.navigation_button = Button:new{ icon = "home", bordersize = 0, show_parent = menu.show_parent or menu }
    record.action_button = Button:new{ icon = "appbar.menu", bordersize = 0, show_parent = menu.show_parent or menu }
    record.footer = Footer:new{
        dimen = Geom:new{ w = 0, h = 0 }, record = record,
        menu.page_return_arrow, record.navigation_button, menu.page_info_left_chev,
        menu.page_info_text, menu.page_info_right_chev, record.action_button,
    }
    for _, button in ipairs(record.footer) do
        saveButton(record, button)
        button.overlap_offset, button.overlap_align = { 0, 0 }, nil
    end
    menu._minimal_view_footer = record
    hook(record, menu.page_info_text, "setText", function(rec, fallback, target, text, width)
        if rec.updating then
            local has_items, page, pages = pagination(rec)
            text = has_items and T("%1/%2", page, pages) or _("No items")
            width = target.width
        end
        return fallback(target, text, width)
    end)
    if not record.key_value then
        -- Native Menu reserves max(return, page text) + button padding. Its
        -- sizing probe excludes that padding because the new height includes it.
        for _, button in ipairs({ menu.page_return_arrow, menu.page_info_text }) do
            hook(record, button, "getSize", function(rec, fallback, target, ...)
                if rec.recalculating then return rec.sizing end
                return fallback(target, ...)
            end)
        end
        record.dimension_hook = hook(record, menu, "_recalculateDimen", function(rec, fallback, target, ...)
            ensure(rec)
            rec.recalculating = true
            local result = pack(pcall(fallback, target, ...))
            rec.recalculating = nil
            if not result[1] then error(result[2], 0) end
            return unpack(result, 2, result.n)
        end)
    end
    hook(record, menu, record.key_value and "_populateItems" or "updatePageInfo", function(rec, fallback, target, ...)
        ensure(rec)
        -- Native focus selection must see content, never the prior footer row.
        removeFocusRow(rec)
        rec.updating = true
        local result = pack(pcall(fallback, target, ...))
        rec.updating = nil
        if not result[1] then error(result[2], 0) end
        finish(rec)
        return unpack(result, 2, result.n)
    end)
    hook(record, menu, "init", function(rec, fallback, target, ...)
        -- Native KeyValuePage reads its fresh group's height before population.
        -- Size its retained buttons before native init performs that calculation.
        if rec.key_value then geometry(rec, target.width or Screen:getWidth()) end
        local result = pack(fallback(target, ...))
        if ensure(rec, true) then finish(rec) end
        return unpack(result, 1, result.n)
    end)
    ensure(record)
    if not before_init then
        if record.key_value then layoutKeyValue(menu)
        else menu:updateItems(1, false) end
        finish(record)
    end
    return true
end

-- Arm only a caller's upcoming native Menu.init. Its first sizing call happens
-- after buttons exist, but before content is built; ordinary apply still reflows
-- an already-built menu whose rows were sized for the native footer.
function ViewFooter.prepare(menu)
    local original, fallback = rawget(menu, "_recalculateDimen"), menu._recalculateDimen
    menu._recalculateDimen = function(target, ...)
        target._recalculateDimen = original
        ViewFooter.apply(target, nil, true)
        if target._minimal_view_footer then return target:_recalculateDimen(...) end
        return fallback(target, ...)
    end
end

function ViewFooter.release(menu, reflow)
    local record = menu and menu._minimal_view_footer
    if not record then return false end
    record.releasing = true
    removeFocusRow(record)
    for i = #record.hooks, 1, -1 do
        local h = record.hooks[i]
        h.state.record = nil
        if rawget(h.target, h.name) == h.wrapper then h.target[h.name] = h.original end
    end
    replace(menu, record.footer, record.original)
    replace(menu, record.empty_return, record.original_return)
    menu.page_info, menu.return_button = record.original, record.original_return
    for button, saved in pairs(record.saved) do
        if button ~= record.navigation_button and button ~= record.action_button then
            for key, value in pairs(saved) do button[key] = value.value end
            local hidden = button.hidden
            button:show()
            button.label_widget:free()
            button:init()
            button:showHide(not hidden)
        end
    end
    local has_items, page, pages = pagination(record)
    local text = menu.page_info_text
    text.text = has_items and T(_("Page %1 of %2"), page, pages) or _("No items")
    text.label_widget:free()
    text:init()
    menu.page_info:resetLayout()
    menu.return_button:resetLayout()
    -- A closing/rebuilding owner restores its renderer separately. Never start
    -- a native row/extraction rebuild there after its jobs were cancelled.
    if reflow ~= false then
        -- Visible standalone release restores current geometry and state, not
        -- stale pagination captured before navigation.
        if record.key_value then layoutKeyValue(menu)
        else menu:updateItems(1, false) end
    end
    menu._minimal_view_footer = nil
    record.navigation_button:free()
    record.action_button:free()
    record.menu = nil
    return true
end

return ViewFooter
