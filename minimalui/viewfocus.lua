-- Instance-only focus routing and one bounded, capability-matched menu surface.
-- Focus navigation below follows KOReader v2026.07.1 focusmanager.lua:220-277.
local bit = require("bit")
local ffi = require("ffi")
local BB = require("ffi/blitbuffer")
local Blitbuffer = BB
local BD = require("ui/bidi")
local Device = require("device")
local Event = require("ui/event")
local FramePaint = require("minimalui/framepaint")
local UIManager = require("ui/uimanager")
local ViewFocus = {}

local function copyPaint(dest, source, dx, dy, sx, sy, width, height)
    local bbtype = dest:getType()
    if bbtype ~= source:getType()
            or dest:getRotation() ~= source:getRotation() or dest:getInverse() ~= source:getInverse() then
        return dest:blitFrom(source, dx, dy, sx, sy, width, height)
    end
    width, dx, sx = Blitbuffer.checkBounds(width, dx, sx, dest:getWidth(), source:getWidth())
    height, dy, sy = Blitbuffer.checkBounds(height, dy, sy, dest:getHeight(), source:getHeight())
    if width <= 0 or height <= 0 then return end
    local logical_width, logical_height = width, height
    local logical_dx, logical_dy, logical_sx, logical_sy = dx, dy, sx, sy
    dx, dy, width, height = dest:getPhysicalRect(dx, dy, width, height)
    sx, sy = source:getPhysicalRect(sx, sy, logical_width, logical_height)
    if bbtype ~= Blitbuffer.TYPE_BB4 then
        local bytes = dest:getBytesPerPixel()
        local dp, sp = ffi.cast("uint8_t*", dest.data), ffi.cast("uint8_t*", source.data)
        dp, sp = dp + dy * dest.stride + dx * bytes, sp + sy * source.stride + sx * bytes
        if dx == 0 and sx == 0 and width == dest.w and width == source.w and dest.stride == source.stride then
            ffi.copy(dp, sp, height * dest.stride)
        else
            for row = 0, height - 1 do
                ffi.copy(dp + row * dest.stride, sp + row * source.stride, width * bytes)
            end
        end
        return
    end
    if dx % 2 ~= sx % 2 then
        return dest:blitFrom(source, logical_dx, logical_dy, logical_sx, logical_sy, logical_width, logical_height)
    end
    -- Whole packed scanlines are contiguous only without trailing padding or
    -- a shared last nibble. Partial rows/viewports keep the edge-preserving path.
    if dx == 0 and sx == 0 and width == dest.w and width == source.w
            and width % 2 == 0 and dest.stride == width / 2 and source.stride == dest.stride then
        ffi.copy(dest.data + dy * dest.stride, source.data + sy * source.stride, height * dest.stride)
        return
    end
    for row = 0, height - 1 do
        local dp = dest.data + (dy + row) * dest.stride
        local sp = source.data + (sy + row) * source.stride
        local tx, ox, remaining = dx, sx, width
        if tx % 2 == 1 then
            local pos = math.floor(tx / 2)
            dp[pos] = bit.bor(bit.band(dp[pos], 240), bit.band(sp[math.floor(ox / 2)], 15))
            tx, ox, remaining = tx + 1, ox + 1, remaining - 1
        end
        local pairs = math.floor(remaining / 2)
        ffi.copy(dp + tx / 2, sp + ox / 2, pairs)
        if remaining % 2 == 1 then
            local pos, source_pos = tx / 2 + pairs, ox / 2 + pairs
            dp[pos] = bit.bor(bit.band(dp[pos], 15), bit.band(sp[source_pos], 240))
        end
    end
end


function ViewFocus.invalidate(menu)
    local state = menu._minimal_view_focus
    if state then
        if state.surface then state.surface:free(); state.surface = nil end
        state.items = nil
    end
end

-- Only explicit view items suppress their focus for the snapshot. Native
-- header/footer buttons retain their own painting and focus behavior.
local function items(menu)
    local found, seen = {}, {}
    for _, row in ipairs(menu.layout or {}) do
        for _, widget in pairs(row) do
            if type(widget) == "table" and widget._minimal_view_item and not seen[widget] then
                found[#found + 1], seen[widget] = widget, true
            end
        end
    end
    return found
end

local function signature(menu)
    local values = {}
    local function add(value) values[#values + 1] = tostring(value) end
    add(menu.page); add(menu.page_num); add(menu._minimal_view_revision)
    local header = menu.title_bar
    add(header)
    if header then
        add(header.title); add(header.native_title); add(header.context_subtitle)
        add(header.header_height); add(header.subtitle)
        for _, key in ipairs({ "title_widget", "subtitle_widget", "status_widget" }) do
            local widget = header[key]
            add(widget); add(widget and widget.text)
        end
        for _, widget in ipairs(header.buttons or {}) do
            add(widget); add(widget.focused); add(widget.enabled); add(widget.icon)
        end
    end
    for _, key in ipairs({ "page_info_text", "page_info_left_chev", "page_info_right_chev", "page_return_arrow" }) do
        local widget = menu[key]
        add(widget)
        if widget then add(widget.text); add(widget.enabled); add(widget.focused); add(widget.frame and widget.frame.invert); add(widget.invisible) end
    end
    for _, row in ipairs(menu.layout or {}) do
        add(row)
        for _, widget in pairs(row) do
            if type(widget) == "table" then
                add(widget)
                if not widget._minimal_view_item then
                    add(widget.focused); add(widget.frame and widget.frame.invert); add(widget.enabled); add(widget.text); add(widget.icon)
                    add(widget.hidden); add(widget.invisible); add(widget.is_inactive)
                end
            end
        end
    end
    return table.concat(values, "\0")
end

local function syncRoot(menu, state)
    local frame = menu[1]
    if state.frame == frame then return end
    if state.frame then FramePaint.release(state.frame) end
    state.frame = frame
    if frame then FramePaint.attach(frame) end
    -- A native init may replace the tree even when title/layout values match.
    ViewFocus.invalidate(menu)
end

local function paintTo(menu, bb, x, y, state)
    syncRoot(menu, state)
    local size = menu.dimen or menu:getSize()
    local width, height = size.w, size.h
    local kind, rotation, inverse = bb:getType(), bb:getRotation(), bb:getInverse()
    local stamp = signature(menu)
    if state.kind ~= kind or state.rotation ~= rotation or state.inverse ~= inverse
            or state.night ~= Device.screen.night_mode or state.x ~= x or state.y ~= y
            or state.width ~= width or state.height ~= height or state.stamp ~= stamp then
        ViewFocus.invalidate(menu)
    end
    local children = state.items
    if not state.surface then
        children = items(menu)
        -- Native fallback items may repaint themselves asynchronously. Until the
        -- renderer supplies the explicit focus/data contract, keep native paint.
        if #children == 0 or x < 0 or y < 0 or x + width > bb:getWidth() or y + height > bb:getHeight() then
            return state.original_paint(menu, bb, x, y)
        end
        local focused = {}
        for i, child in ipairs(children) do focused[i] = child.focused; child.focused = false end
        local ok, err = pcall(state.original_paint, menu, bb, x, y)
        for i, child in ipairs(children) do child.focused = focused[i] end
        if not ok then error(err, 0) end
        local surface = BB.new(rotation % 2 == 0 and width or height,
            rotation % 2 == 0 and height or width, kind)
        surface:setRotation(rotation); surface:setInverse(inverse)
        copyPaint(surface, bb, 0, 0, x, y, width, height)
        state.surface, state.items = surface, children
        state.kind, state.rotation, state.inverse = kind, rotation, inverse
        state.night, state.x, state.y = Device.screen.night_mode, x, y
        state.width, state.height, state.stamp = width, height, stamp
    else
        -- Restore the full surface on every repaint: native overlays can expose
        -- any part of this window, independently of the focus refresh rectangle.
        copyPaint(bb, state.surface, x, y, 0, 0, width, height)
    end
    for _, child in ipairs(children) do
        if child.focused then child:paintFocus(bb) end
    end
end

local function focusable(widget)
    return type(widget) == "table" and not widget.is_inactive and widget.enabled ~= false
        and not widget.hidden and not widget.invisible
end

local function closestColumn(row, preferred)
    local best, distance
    for column, widget in pairs(row) do
        if type(column) == "number" and focusable(widget) then
            local delta = math.abs(column - preferred)
            if not distance or delta < distance or (delta == distance and column < best) then
                best, distance = column, delta
            end
        end
    end
    return best
end

local function moveFocus(menu, current, x, y, native_events)
    local target = menu.layout[y][x]
    menu.selected.x, menu.selected.y = x, y
    -- Native body navigation emits Unfocus/Focus even when distinct layout
    -- positions share the same active widget. Footer no-ops remain silent.
    if target == current and not native_events then return end
    current:handleEvent(Event:new("Unfocus"))
    target:handleEvent(Event:new("Focus"))
    local area = current.dimen and target.dimen and current.dimen:combine(target.dimen)
    if not current._minimal_view_item or not target._minimal_view_item then ViewFocus.invalidate(menu) end
    UIManager:setDirty(menu.show_parent or menu, function() return "fast", area end)
end

-- Only transitions touching the footer depart from native body navigation.
-- Rows can be sparse and buttons may be disabled after a page change.
local function moveFooter(menu, dx, dy, current)
    local footer = menu._minimal_view_footer
    local row = footer and footer.focus_row
    if not row then return false end
    local selected = menu.selected
    local in_footer = menu.layout[selected.y] == row
    if dx ~= 0 then
        if not in_footer then return false end
        local candidate, wrapped
        for column, widget in pairs(row) do
            if type(column) == "number" and focusable(widget) then
                if (column - selected.x) * dx > 0
                        and (not candidate or (column - candidate) * dx < 0) then candidate = column end
                if not wrapped or (column - wrapped) * dx < 0 then wrapped = column end
            end
        end
        if candidate or wrapped then moveFocus(menu, current, candidate or wrapped, selected.y) end
        return true
    end
    if dy == 0 then return false end
    local y = (selected.y - 1 + dy) % #menu.layout + 1
    if not in_footer and menu.layout[y] ~= row then return false end
    for _ = 1, #menu.layout do
        local x = closestColumn(menu.layout[y], selected.x)
        if x then moveFocus(menu, current, x, y); break end
        y = (y - 1 + dy) % #menu.layout + 1
    end
    return true
end

function ViewFocus.onFocusMove(self, args)
    if not self.layout then return false end
    if not Device:hasDPad() and not Device:hasKeyboard() then return true end
    if not self.selected or not self.layout[self.selected.y]
            or not self.layout[self.selected.y][self.selected.x] then return true end
    local dx, dy = unpack(args)
    local current_item = self.layout[self.selected.y][self.selected.x]
    -- The footer's six slots deliberately retain physical left/right order,
    -- independently of mirrored body layouts.
    if (dx == 0 or self.movement_allowed.x) and (dy == 0 or self.movement_allowed.y)
            and moveFooter(self, dx, dy, current_item) then return true end
    local state = self._minimal_view_focus
    if not self._minimalui_view and state and state.original_focus then
        return state.original_focus(self, args)
    end
    if dx ~= 0 and BD.mirroredUILayout() then dx = -dx end
    if (dx ~= 0 and not self.movement_allowed.x)
        or (dy ~= 0 and not self.movement_allowed.y) then return true end
    while true do
        if not self.layout[self.selected.y + dy] then
            if not self:_wrapAroundY(dy) then break end
        elseif not self.layout[self.selected.y + dy][self.selected.x] then
            if not self:_verticalStep(dy) then break end
        elseif not self.layout[self.selected.y + dy][self.selected.x + dx] then
            if not self:_wrapAroundX(dx) then break end
        else
            self.selected.y = self.selected.y + dy
            self.selected.x = self.selected.x + dx
        end
        local next_item = self.layout[self.selected.y][self.selected.x]
        if next_item ~= current_item or not next_item.is_inactive then
            moveFocus(self, current_item, self.selected.x, self.selected.y, true)
            break
        end
    end
    return true
end

local footer_left, footer_right = { -1, 0 }, { 1, 0 }
local function keyPress(menu, key, repeat_event, state)
    local footer = menu._minimal_view_footer
    if Device:hasFewKeys() and footer and menu.selected and menu.layout
            and menu.layout[menu.selected.y] == footer.focus_row
            and (key.key == "Left" or key.key == "Right") then
        return ViewFocus.onFocusMove(menu, key.key == "Left" and footer_left or footer_right)
    end
    local fallback = repeat_event and state.original_repeat or state.original_key
    if fallback then return fallback(menu, key) end
end


function ViewFocus.attach(menu)
    if menu._minimal_view_focus then syncRoot(menu, menu._minimal_view_focus); return end
    local state = {
        active = true,
        raw_paint = rawget(menu, "paintTo"), original_paint = menu.paintTo,
        raw_focus = rawget(menu, "onFocusMove"), original_focus = menu.onFocusMove,
        raw_key = rawget(menu, "onKeyPress"), original_key = menu.onKeyPress,
        raw_repeat = rawget(menu, "onKeyRepeat"), original_repeat = menu.onKeyRepeat,
    }
    -- Later plugins may retain these wrappers after release. Capture this
    -- attachment's fallbacks rather than consulting a removed/replaced state.
    state.paint = function(instance, bb, x, y)
        if state.active then return paintTo(instance, bb, x, y, state) end
        return state.original_paint(instance, bb, x, y)
    end
    state.focus = function(instance, args)
        if state.active then return ViewFocus.onFocusMove(instance, args) end
        if state.original_focus then return state.original_focus(instance, args) end
    end
    state.key = function(instance, key)
        if state.active then return keyPress(instance, key, false, state) end
        if state.original_key then return state.original_key(instance, key) end
    end
    state.repeat_key = function(instance, key)
        if state.active then return keyPress(instance, key, true, state) end
        if state.original_repeat then return state.original_repeat(instance, key) end
    end
    menu._minimal_view_focus = state
    menu.paintTo, menu.onFocusMove = state.paint, state.focus
    menu.onKeyPress, menu.onKeyRepeat = state.key, state.repeat_key
    syncRoot(menu, state)
end

function ViewFocus.release(menu)
    local state = menu._minimal_view_focus
    if not state then return end
    state.active = false
    ViewFocus.invalidate(menu)
    if state.frame then FramePaint.release(state.frame); state.frame = nil end
    if rawget(menu, "paintTo") == state.paint then menu.paintTo = state.raw_paint end
    if rawget(menu, "onFocusMove") == state.focus then menu.onFocusMove = state.raw_focus end
    if rawget(menu, "onKeyPress") == state.key then menu.onKeyPress = state.raw_key end
    if rawget(menu, "onKeyRepeat") == state.repeat_key then menu.onKeyRepeat = state.raw_repeat end
    menu._minimal_view_focus = nil
end

return ViewFocus
