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

local function paintTo(menu, bb, x, y)
    local state = menu._minimal_view_focus
    if not state then return end
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

function ViewFocus.onFocusMove(self, args)
    if not self.layout then return false end
    local dx, dy = unpack(args)
    if dx ~= 0 and BD.mirroredUILayout() then dx = -dx end
    if (dx ~= 0 and not self.movement_allowed.x)
        or (dy ~= 0 and not self.movement_allowed.y) then return true end
    if not self.layout[self.selected.y] or not self.layout[self.selected.y][self.selected.x] then return true end
    local current_item = self.layout[self.selected.y][self.selected.x]
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
            current_item:handleEvent(Event:new("Unfocus"))
            next_item:handleEvent(Event:new("Focus"))
            local area = current_item.dimen and next_item.dimen and current_item.dimen:combine(next_item.dimen)
            if not current_item._minimal_view_item or not next_item._minimal_view_item then
                ViewFocus.invalidate(self)
            end
            UIManager:setDirty(self.show_parent or self, function() return "fast", area end)
            break
        end
    end
    return true
end

function ViewFocus.attach(menu)
    if menu._minimal_view_focus then syncRoot(menu, menu._minimal_view_focus); return end
    menu._minimal_view_focus = {
        raw_paint = rawget(menu, "paintTo"), original_paint = menu.paintTo,
        raw_focus = rawget(menu, "onFocusMove"),
    }
    menu.paintTo, menu.onFocusMove = paintTo, ViewFocus.onFocusMove
    syncRoot(menu, menu._minimal_view_focus)
end

function ViewFocus.release(menu)
    local state = menu._minimal_view_focus
    if not state then return end
    ViewFocus.invalidate(menu)
    if state.frame then FramePaint.release(state.frame); state.frame = nil end
    if menu.paintTo == paintTo then menu.paintTo = state.raw_paint end
    if menu.onFocusMove == ViewFocus.onFocusMove then menu.onFocusMove = state.raw_focus end
    menu._minimal_view_focus = nil
end

return ViewFocus
