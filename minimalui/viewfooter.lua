-- Instance-only three-zone pagination. Native Menu v2026.07.1 retains ownership
-- of the buttons, their callbacks, and the jump/search input dialog.
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Screen = require("device").screen
local T = require("ffi/util").template
local _ = require("gettext")

local ViewFooter = {}

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

local Zone = InputContainer:extend{}

function Zone:init()
    self.ges_events.MinimalFooterTap = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
end

function Zone:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local button, size = self[1], self[1]:getSize()
    local bx = self.side == "right" and x + self.dimen.w - size.w
        or self.side == "center" and x + math.floor((self.dimen.w - size.w) / 2) or x
    button:paintTo(bb, bx, y + math.floor((self.dimen.h - size.h) / 2))
end

function Zone:onMinimalFooterTap()
    local button = self[1]
    if button.enabled and not button.hidden and button.callback then button.callback() end
    return true
end

local Footer = OverlapGroup:extend{ allow_mirroring = false }

-- Menu:updateItems calls this method on its original HorizontalGroup. Our
-- geometry is fixed, so page changes must not recreate or resize any widget.
function Footer:resetLayout() end

function Footer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local left, arrow = self[1], self.menu.page_return_arrow
    local offset = 0
    if arrow and not arrow.hidden then
        offset = math.min(self.third, math.max(0,
            (arrow.dimen.x or x) + arrow:getSize().w + Screen:scaleBySize(8) - x))
    end
    left.overlap_offset[1], left.dimen.w = offset, self.third - offset
    OverlapGroup.paintTo(self, bb, x, y)
end

local function hook(record, target, name, handler)
    local original, fallback = rawget(target, name), target[name]
    local state = { record = record }
    local wrapper = function(instance, ...)
        if state.record then return handler(state.record, fallback, instance, ...) end
        return fallback(instance, ...)
    end
    record.hooks[#record.hooks + 1] = {
        target = target, name = name, original = original, wrapper = wrapper, state = state,
    }
    target[name] = wrapper
end

local function configureText(record, button, width)
    if not record.text then
        record.text = button
        record.attributes = {}
        for _, key in ipairs({ "width", "height", "text_font_bold" }) do
            record.attributes[key] = { value = rawget(button, key) }
        end
        hook(record, button, "setText", function(rec, fallback, target, text, requested_width)
            if rec.updating then
                if #rec.menu.item_table > 0 then text = T("%1/%2", rec.menu.page, rec.menu.page_num) end
                -- Button:setText's fixed-width path updates its existing label.
                requested_width = target.width
            end
            return fallback(target, text, requested_width)
        end)
    end
    if button.width ~= width or not button.text_font_bold then
        local label_height = button.label_container:getSize().h
        button.width, button.height, button.text_font_bold = width, label_height, true
        button.label_widget:free()
        button:init()
    end
end

local function ensure(record)
    local menu = record.menu
    if not menu or menu._minimal_view_footer ~= record then return false end
    if not menu.page_info or not menu.page_info_text or not menu.inner_dimen then return false end
    if menu.page_info == record.footer then return true end
    -- A native init has made a fresh HorizontalGroup and BottomContainer.
    local original, width = menu.page_info, menu.inner_dimen.w
    local height, third = original:getSize().h, math.floor(width / 3)
    configureText(record, menu.page_info_text, third)
    local function zone(button, side, x, w)
        return Zone:new{
            dimen = Geom:new{ w = w, h = height }, side = side,
            overlap_offset = { x, 0 }, button,
        }
    end
    local footer = Footer:new{
        dimen = Geom:new{ w = width, h = height }, menu = menu, third = third,
        zone(menu.page_info_left_chev, "left", 0, third),
        zone(menu.page_info_text, "center", third, third),
        zone(menu.page_info_right_chev, "right", 2 * third, width - 2 * third),
    }
    record.original, record.footer = original, footer
    menu.page_info = footer
    replace(menu, original, footer)
    return true
end

local function finish(record)
    local menu = record.menu
    if not menu or menu._minimal_view_footer ~= record then return end
    menu.page_info_first_chev:hide()
    menu.page_info_last_chev:hide()
    -- Native disables the input on a one-page menu. Keep native jump/search
    -- available there too; an empty menu retains its native No items behavior.
    if #menu.item_table > 0 then menu.page_info_text:enable() end
end

function ViewFooter.apply(menu)
    if not menu or not menu.page_info or not menu.page_info_text then return false end
    local record = menu._minimal_view_footer
    if record then ensure(record); finish(record); return true end
    record = { menu = menu, hooks = {} }
    menu._minimal_view_footer = record
    hook(record, menu, "updatePageInfo", function(rec, fallback, target, ...)
        ensure(rec)
        rec.updating = true
        local result = pack(pcall(fallback, target, ...))
        rec.updating = nil
        if not result[1] then error(result[2], 0) end
        finish(rec)
        return unpack(result, 2, result.n)
    end)
    hook(record, menu, "init", function(rec, fallback, target, ...)
        local result = pack(fallback(target, ...))
        ensure(rec)
        finish(rec)
        return unpack(result, 1, result.n)
    end)
    ensure(record)
    record.updating = true
    menu.page_info_text:setText(#menu.item_table > 0 and "" or _("No items"))
    record.updating = nil
    finish(record)
    return true
end

function ViewFooter.release(menu)
    local record = menu and menu._minimal_view_footer
    if not record then return false end
    for i = #record.hooks, 1, -1 do
        local h = record.hooks[i]
        h.state.record = nil
        if rawget(h.target, h.name) == h.wrapper then h.target[h.name] = h.original end
    end
    if menu.page_info == record.footer then
        replace(menu, record.footer, record.original)
        menu.page_info = record.original
    end
    local button = record.text
    if button then
        for key, saved in pairs(record.attributes) do button[key] = saved.value end
        button.text = #menu.item_table > 0 and T(_("Page %1 of %2"), menu.page, menu.page_num) or _("No items")
        button.label_widget:free()
        button:init()
        if #menu.item_table > 0 and menu.page_num > 1 then button:enable()
        else button:disableWithoutDimming() end
    end
    for _, name in ipairs({ "first", "last" }) do
        local chev = menu["page_info_" .. name .. "_chev"]
        chev:showHide(#menu.item_table > 0)
    end
    if menu.page_info.resetLayout then menu.page_info:resetLayout() end
    menu._minimal_view_footer = nil
    record.menu = nil
    return true
end

return ViewFooter
