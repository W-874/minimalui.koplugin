--[[--
Instance-only exact background fill for native FrameContainer paintTo.

Native reference: KOReader v2026.07.1
frontend/ui/widget/container/framecontainer.lua. With a Color8 background and
no radius, that code calls Blitbuffer.paintRoundedRect, which falls through to
BB4.paintRect and its per-pixel setPixel loop. This module replaces only that
one opaque, square background fill; stripes, borders, child painting, inner
borders, invert and dim remain native.

The wrapper is installed on individual instances, never on the class, and only
when the instance is a FrameContainer whose resolved paintTo is still the
native FrameContainer.paintTo. It is used only when the paint target is a
TYPE_BB4 buffer, the resolved background is a Color8, and the resolved radius
is nil/0. RGB/alpha backgrounds, rounded corners, custom/subclass paintTo and
already-installed foreign wrappers are forwarded untouched. No proxy buffer,
surface cache or image cache is introduced.
]]

local bit = require("bit")
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")

local FramePaint = {}
local band, bor, rshift = bit.band, bit.bor, bit.rshift
local ceil = math.ceil

local STATE_KEY = "_minimal_frame_paint"

-- Mirror paintRoundedRect -> paintRect for a Color8 fill with radius nil/0:
-- ceil the rectangle, bound it inside the logical viewport, rotate it to
-- physical coordinates, then write nibbles directly. Bytes outside the
-- requested rectangle (including stride padding and a shared edge nibble)
-- are preserved exactly like BB4.paintRect's setPixel loop.
local function fillRect(bb, x, y, w, h, color)
    x, y, w, h = bb:getBoundedRect(ceil(x), ceil(y), ceil(w), ceil(h))
    if w <= 0 or h <= 0 then return end
    x, y, w, h = bb:getPhysicalRect(x, y, w, h)
    if w <= 0 or h <= 0 then return end
    -- BB4.paintRect hands the value to setPixel, which inverts first.
    if bb:getInverse() == 1 then color = color:invert() end
    -- Even physical columns are the high nibble (Color4U), odd columns the low
    -- nibble (Color4L). Color8 conversions already place each nibble correctly.
    local high = band(color:getColor4U().a, 0xF0)
    local low = band(color:getColor4L().a, 0x0F)
    local byte = bor(high, low)
    local stride = bb.stride
    local data = bb.data

    -- Full physical width, even, with no stride tail: the whole rectangle is
    -- one contiguous run. This is the only path that fills padding bytes, and
    -- only because there are none.
    if x == 0 and w == bb.w and band(w, 1) == 0 and stride == w / 2 then
        ffi.fill(data + y * stride, stride * h, byte)
        return
    end

    local first = x
    local last = x + w - 1
    local low_edge = band(x, 1) == 1
    if low_edge then first = x + 1 end
    local high_edge = band(last, 1) == 0
    local full_last = high_edge and last - 1 or last
    for row = 0, h - 1 do
        local p = data + (y + row) * stride
        if low_edge then
            local pos = rshift(x, 1)
            p[pos] = bor(band(p[pos], 0xF0), low)
        end
        if full_last >= first then
            ffi.fill(p + rshift(first, 1), rshift(full_last - first + 1, 1), byte)
        end
        if high_edge then
            local pos = rshift(last, 1)
            p[pos] = bor(band(p[pos], 0x0F), high)
        end
    end
end

-- Exactly the native expression. Lua treats 0 as true, so radius=0 with a
-- non-zero bordersize yields a positive effective radius (rounded corners).
local function radiusOf(frame)
    return (frame.radius and frame.bordersize) and frame.radius + frame.bordersize or frame.radius
end

local function canFill(frame, bb, background)
    local radius = radiusOf(frame)
    return bb:getType() == Blitbuffer.TYPE_BB4 and Blitbuffer.isColor8(background)
        and (radius == nil or radius == 0)
end

-- Same width/height native paintTo uses for the background rectangle. Only
-- ask getSize when an explicit dimension is missing; native still calls it
-- unconditionally for its own layout work.
local function containerSize(frame)
    local width, height = frame.width, frame.height
    if width and height then return width, height end
    local size = frame:getSize()
    return width or size.w, height or size.h
end

local function isFrameContainer(frame)
    local mt = getmetatable(frame)
    while mt do
        if mt == FrameContainer then return true end
        mt = getmetatable(mt)
    end
    return false
end

function FramePaint.attach(frame)
    local current = rawget(frame, STATE_KEY)
    -- Idempotent: the active hook already owns this instance.
    if current and not current.inert then return frame end

    -- Only instances that still resolve to the unmodified native
    -- FrameContainer.paintTo are wrapped. A custom/subclass paintTo or an
    -- already-installed foreign wrapper keeps its own semantics; attaching
    -- must never change them.
    if not isFrameContainer(frame) or frame.paintTo ~= FrameContainer.paintTo then
        return frame
    end

    local state = { raw = rawget(frame, "paintTo"), native = FrameContainer.paintTo }
    local function paintTo(self, bb, x, y)
        -- A later foreign wrapper may still call us after release; stay inert.
        -- Identity check also covers a fresh attach that replaced this state.
        if state.inert or rawget(self, STATE_KEY) ~= state then
            return state.native(self, bb, x, y)
        end
        -- Re-entrant paint of this frame happens while the outer call has
        -- background=false. Use the effective background saved by the outer
        -- call: fill it exactly when this call is eligible, otherwise expose it
        -- to native for the nested call. Either way background returns to the
        -- value this nested call observed (false).
        if state.painting then
            local saved = rawget(self, "background")
            local background = state.background
            if canFill(self, bb, background) then
                local width, height = containerSize(self)
                fillRect(bb, x, y, width, height, background)
                self.background = false
                local ok, err = pcall(state.native, self, bb, x, y)
                self.background = saved
                if not ok then error(err, 0) end
            else
                self.background = background
                local ok, err = pcall(state.native, self, bb, x, y)
                self.background = saved
                if not ok then error(err, 0) end
            end
            return
        end
        local background = self.background
        if not canFill(self, bb, background) then
            return state.native(self, bb, x, y)
        end
        -- Same dimensions native paintTo uses for the background rectangle.
        local width, height = containerSize(self)
        fillRect(bb, x, y, width, height, background)
        -- false, not nil: shadow any class/metatable background while the
        -- native method paints the rest. Restore the raw value (including nil)
        -- even when a child paint raises.
        local raw_background = rawget(self, "background")
        state.painting, state.background = true, background
        self.background = false
        local ok, err = pcall(state.native, self, bb, x, y)
        state.painting, state.background = nil, nil
        self.background = raw_background
        if not ok then error(err, 0) end
    end
    state.wrapper = paintTo
    frame[STATE_KEY] = state
    frame.paintTo = paintTo
    return frame
end

function FramePaint.release(frame)
    local state = rawget(frame, STATE_KEY)
    if not state then return frame end
    if rawget(frame, "paintTo") == state.wrapper then
        -- Restore the exact raw value; nil means the method stays inherited.
        frame.paintTo = state.raw
    else
        -- A wrapper installed after ours owns the call chain. Never tear it
        -- out: make this hook inert and drop the instance reference instead.
        state.inert = true
    end
    frame[STATE_KEY] = nil
    return frame
end

return FramePaint
