-- Home is a bounded view of native history and the current reading snapshot.
local bit = require("bit")
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Cover = require("minimalui/cover")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Header = require("minimalui/header")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LibraryActions = require("minimalui/libraryactions")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local recent_keys = { "Q", "W", "E" }

local Home = InputContainer:extend{
    name = "minimalui_home",
    covers_fullscreen = true,
    stop_events_propagation = true,
}

-- Matching native layouts copy physical scanlines directly, with or without
-- CBB: its rotated copy still visits each pixel. BB4 also needs packed-byte
-- copying even without rotation. Color conversion stays with the native API.
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

local function invertFocus(bb, x, y, width, height)
    if bb:getType() ~= Blitbuffer.TYPE_BB4 then return bb:invertRect(x, y, width, height) end
    x, y, width, height = bb:getBoundedRect(x, y, width, height)
    if width <= 0 or height <= 0 then return end
    x, y, width, height = bb:getPhysicalRect(x, y, width, height)
    for row = y, y + height - 1 do
        local p = bb.data + row * bb.stride
        local first, last = math.floor(x / 2), math.floor((x + width) / 2)
        if x % 2 == 1 then p[first] = bit.bxor(p[first], 15); first = first + 1 end
        for col = first, last - 1 do p[col] = bit.bxor(p[col], 255) end
        if (x + width) % 2 == 1 then p[last] = bit.bxor(p[last], 240) end
    end
end

local function paintBuffer(width, height, target)
    local packed = target:getType() == Blitbuffer.TYPE_BB4
    local rotation = target:getRotation()
    local bb = Blitbuffer.new(rotation % 2 == 0 and width or height,
        rotation % 2 == 0 and height or width, packed and Blitbuffer.TYPE_BB4 or Blitbuffer.TYPE_BB8)
    bb:setRotation(rotation)
    bb:setInverse(target:getInverse())
    return bb
end

local function canvas(width, height)
    return OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height }, allow_mirroring = false,
    }
end

local function place(group, widget, x, y)
    widget.overlap_offset = { x, y }
    group[#group + 1] = widget
    return widget
end

local function frame(content, background, border)
    return FrameContainer:new{
        margin = 0, padding = 0, bordersize = 0,
        inner_bordersize = border or 0, color = Blitbuffer.COLOR_GRAY,
        background = background, allow_mirroring = false, content,
    }
end

-- Both dimensions are bounded, including the real font's ascender/descender.
local function text(value, size, bold, width, height, color, truncate_left)
    local face = Font:getFace("cfont", size)
    local font_height = face.ftsize and face.ftsize:getHeightAndAscender()
    if not font_height or math.ceil(font_height) > height then
        face = Font:getFace("cfont", math.min(size, TextWidget:getFontSizeToFitHeight("cfont", height, 0)))
    end
    return TextWidget:new{
        text = tostring(value or ""), face = face,
        bold = bold, max_width = math.max(1, width), padding = 0,
        fgcolor = color or Blitbuffer.COLOR_BLACK, truncate_left = truncate_left,
    }
end

local function title(value, size, width, height)
    local fit = TextBoxWidget:getFontSizeToFitHeight(height, 2, 0.2, "cfont", true)
    local face = Font:getFace("cfont", math.min(size, fit))
    height = math.min(height, 2 * math.floor(1.2 * face.size + 0.5))
    return TextBoxWidget:new{
        text = tostring(value or ""), face = face,
        bold = true, width = math.max(1, width), height = height,
        line_height = 0.2, height_overflow_show_ellipsis = true,
    }
end

local function authors(book)
    if type(book.authors) == "table" then return table.concat(book.authors, ", ") end
    return book.authors
end

local function fraction(book)
    local n = book and book.fraction
    if type(n) == "number" and n == n then return math.max(0, math.min(1, n)) end
end

local function progressText(book)
    local n = fraction(book)
    if book.status == "complete" or book.status == "finished" or n == 1 then
        return _("Finished")
    end
    if n then return string.format("%d%%", math.floor(n * 100 + 0.5)) end
end

function Home:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.has_keys, self.few_keys = Device:hasKeys(), Device:hasFewKeys()
    self.keyboard, self.touch = Device:hasKeyboard(), Device:isTouchDevice()
    self.disposed = false
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.item_table = self.item_table or {}
    self.home_data = self.home_data or {}
    self.selected = math.max(1, math.min(self.selected or 1, #self.item_table))
    self:bindKeys()
    self[1] = self:buildView()
    self.ges_events = {}
    if self.touch then
        self.ges_events.MinimalTap = { GestureRange:new{ ges = "tap", range = self.dimen } }
        self.ges_events.MinimalHold = { GestureRange:new{ ges = "hold", range = self.dimen } }
        self.ges_events.MinimalSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
end

function Home:bindKeys()
    self.key_events = {}
    if not self.has_keys then return end
    self.key_events.MinimalUp = { { "Up" } }
    self.key_events.MinimalDown = { { "Down" } }
    self.key_events.MinimalActivate = { { { "Press", "Enter" } } }
    self.key_events.MinimalMenu = { { "Menu" } }
    self.key_events.MinimalBack = { { Device.input.group.Back } }
    self.key_events.Home = { { "Home" } }
    -- Native focus-manager context combinations, without stealing few-key Right.
    self.key_events.MinimalContext = {
        { "ContextMenu" }, { "Shift", "Press" }, { "ScreenKB", "Press" }, { "Sym", "AA" },
    }
    if self.few_keys then
        self.key_events.MinimalBack = { { "Left" } }
        self.key_events.MinimalMenu = { { { "Menu", "Right" } } }
    else
        self.key_events.MinimalLeft = { { "Left" } }
        self.key_events.MinimalRight = { { "Right" } }
    end
    if self.keyboard then
        self.key_events.MinimalLibrary = { { "L" } }
        self.key_events.MinimalHistory = { { "H" } }
        self.key_events.MinimalBrowser = { { "F" } }
        for i = 1, 3 do
            self.key_events["MinimalRecent" .. i] = { { recent_keys[i] }, event = "MinimalRecent", args = i }
        end
    end
end

local function coverKey(path, height, width)
    return path and table.concat({ path, height, width }, "\0")
end

-- Prune before loading: at most the current book and three visible recent covers
-- are owned, even while changing pages or rotating. Failed loads are cached too.
function Home:prepareCovers(requests)
    local wanted = {}
    for _, request in ipairs(requests) do
        wanted[coverKey(request.path, request.height, request.width)] = true
    end
    self.cover_cache = self.cover_cache or {}
    for key, entry in pairs(self.cover_cache) do
        if not wanted[key] or entry.invalid then
            if entry.bb then entry.bb:free() end
            self.cover_cache[key] = nil
        end
    end
end

function Home:getCover(path, height, width)
    if not path then return end
    local key = coverKey(path, height, width)
    local entry = self.cover_cache[key]
    if not entry then
        local source = Cover.resolve(path)
        entry = { path = path, signature = source.signature, bb = Cover.load(path, height, width, source) }
        self.cover_cache[key] = entry
    end
    return entry.bb
end

function Home:bookCard(book, width, height, index, recent_index, cover_height, cover_width, ratio)
    local featured = recent_index == nil
    local pad = math.max(5, math.floor(Screen:scaleBySize(featured and 16 or 9) * ratio))
    local inner_height = math.max(1, height - 2 * pad)
    local cover = self.show_covers and self:getCover(book.path, cover_height, cover_width)
    local gap = cover and math.max(5, math.floor(Screen:scaleBySize(12) * ratio)) or 0
    local image_width = cover and cover:getWidth() or 0
    local text_width = math.max(1, width - 2 * pad - image_width - gap)
    local text_x = pad + (not featured and cover and image_width + gap or 0)
    local show_badge = self.keyboard and not featured
    local badge_size = show_badge and math.max(12, math.floor(Screen:scaleBySize(22) * ratio)) or 0
    local badge_over_cover = show_badge and cover
    local title_width = text_width - (show_badge and not badge_over_cover and badge_size + math.max(3, gap) or 0)
    local content = canvas(width, height)
    local line = math.max(10, math.floor(Screen:scaleBySize(featured and 23 or 18) * ratio))
    local progress_height = math.max(2, math.floor(Screen:scaleBySize(featured and 7 or 4) * ratio))
    local small_gap = math.max(2, math.floor(Screen:scaleBySize(7) * ratio))
    local progress = progressText(book) or (featured and _("Progress unavailable") or nil)
    local remaining = self.show_metadata and featured and book.chapter_time_text
    if remaining then remaining = T(_("Chapter left %1"), remaining) end
    local bottom = progress and remaining and (progress .. " · " .. remaining) or progress or remaining
    local metadata = self.show_metadata and authors(book)
    if featured and self.show_metadata and book.chapter then
        metadata = metadata and metadata ~= "" and (metadata .. " · " .. book.chapter) or book.chapter
    end
    if metadata == "" then metadata = nil end
    local bar = fraction(book)
    local show_bar = featured or (bar ~= nil and bar ~= 1 and book.status ~= "complete" and book.status ~= "finished")
    local reserved = (metadata and line + small_gap or 0)
        + (bottom and line + small_gap or 0)
        + (show_bar and progress_height + small_gap or 0)
    local title_height = math.max(line, inner_height - reserved)
    local title_widget = title(book.title or book.path, featured and 27 or 15, title_width, title_height)
    place(content, title_widget, text_x, pad)
    local y = pad + title_height + small_gap
    if metadata then
        place(content, text(metadata, featured and 16 or 14, false, text_width, line), text_x, y)
        y = y + line + small_gap
    end
    if show_bar then
        place(content, ProgressWidget:new{
            width = text_width, height = progress_height, margin_h = 0, margin_v = 0,
            radius = 0, bordersize = 0, bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
            fillcolor = Blitbuffer.COLOR_BLACK, percentage = bar or 0,
        }, text_x, y)
        y = y + progress_height + small_gap
    end
    if bottom then
        place(content, text(bottom, featured and 16 or 14, false, text_width, line), text_x, y)
    end
    local focus = frame(content, Blitbuffer.COLOR_WHITE, featured and 0 or Size.line.medium)
    focus.invert = self.selected == index
    -- The body snapshot is unfocused; focus is composed without repainting text.
    self.focus_exclusions[index] = {}
    self.focus_frames[index] = focus
    local layers = canvas(width, height)
    place(layers, focus, 0, 0)
    -- Paint covers after the invertible content; image pixels are never inverted.
    if cover then
        local image = ImageWidget:new{ image = cover, image_disposable = false, scale_factor = 1 }
        place(layers, image, featured and width - pad - image_width or pad, pad)
        self.cover_widgets[#self.cover_widgets + 1] = image
        self.focus_exclusions[index][#self.focus_exclusions[index] + 1] = image
        if featured then self.cover_widget = image end
    end
    if show_badge then
        local badge = canvas(badge_size, badge_size)
        local label = text(recent_keys[recent_index], 13, true, badge_size, badge_size)
        place(badge, label, math.max(0, math.floor((badge_size - label:getWidth()) / 2)), 0)
        local badge_frame = frame(badge, Blitbuffer.COLOR_WHITE, Size.line.medium)
        place(layers, badge_frame, badge_over_cover and pad or text_x + text_width - badge_size, pad)
        self.badge_widgets[#self.badge_widgets + 1] = badge_frame
        self.focus_exclusions[index][#self.focus_exclusions[index] + 1] = badge_frame
    end
    local card = frame(layers)
    self.rows[index] = card
    self.row_books[index] = book
    if featured then
        self.cover_bb, self.cover_path = cover, book.path
        self.cover_height, self.cover_limit = cover_height, cover_width
        self.title_widget, self.featured_title = title_widget, focus
    end
    return card
end

function Home:buildView()
    local scale = function(n) return Screen:scaleBySize(n) end
    local data, options = self.home_data, self.home_data.options or {}
    self.show_covers, self.show_metadata = options.covers ~= false, options.metadata ~= false
    self.rows, self.focus_frames, self.row_books = {}, {}, {}
    self.focus_exclusions, self.cover_widgets, self.badge_widgets = {}, {}, {}
    self.recent_indices = {}
    self.cover_bb, self.cover_widget, self.featured_title, self.title_widget = nil, nil, nil, nil
    self.header = Header:new{
        width = self.width, title = "KO/HOME", show_parent = self,
        menu_callback = function() return self:onMinimalMenu() end,
    }
    self.header_height = self.header:getHeight()
    local margin = math.min(scale(22), math.floor(self.width * 0.06))
    local width = self.width - 2 * margin
    local nav, recent, continue_index = {}, {}, nil
    for i, item in ipairs(self.item_table) do
        if item.id == "continue" then
            continue_index = i
        elseif item.id == "library" or item.id == "history" or item.id == "browser" then
            nav[#nav + 1] = { index = i, item = item }
        end
    end
    if options.recent ~= false then
        for _, book in ipairs(data.recent or {}) do
            if #recent == 3 then break end
            for i, item in ipairs(self.item_table) do
                if item.id == "recent:" .. book.path then
                    recent[#recent + 1] = { book = book, index = i }
                    self.recent_indices[#recent] = i
                    break
                end
            end
        end
    end
    local has_recent = #recent > 0
    local stats = options.stats ~= false and data.stats_text
    local available = math.max(1, self.height - self.header_height)
    local nav_height = math.min(scale(64), math.max(scale(48), math.floor(available * 0.085)))
    nav_height = math.min(nav_height, math.floor(available / math.max(1, #nav)))
    local natural = 16 + 26 + 8 + 202 + 16
        + (has_recent and (22 + 26 + 8 + 124) or 0)
        + (#nav > 0 and 22 or 0) + (stats and 46 or 0)
    local ratio = math.min(1, math.max(0.1, (available - #nav * nav_height) / scale(natural)))
    local unit = function(n) return math.max(1, math.floor(scale(n) * ratio)) end
    local featured_height, recent_height = unit(202), unit(124)
    local featured_cover_height = math.max(1, featured_height - 2 * unit(16))
    local featured_cover_width = math.min(unit(134), math.floor(width * 0.25))
    local card_gap = unit(18)
    local card_width = math.floor((width - 2 * card_gap) / 3)
    local recent_cover_height = math.max(1, recent_height - 2 * math.max(5, unit(9)))
    local recent_cover_width = math.max(1, math.min(unit(58), math.floor(card_width * 0.31)))
    local requests = {}
    if self.show_covers then
        if self.book and continue_index and self.book.path then
            requests[#requests + 1] = { path = self.book.path, height = featured_cover_height, width = featured_cover_width }
        end
        for _, entry in ipairs(recent) do
            requests[#requests + 1] = { path = entry.book.path, height = recent_cover_height, width = recent_cover_width }
        end
    end
    self:prepareCovers(requests)
    local body = canvas(self.width, available)
    local y = unit(16)
    local label_height = unit(26)
    local section = text(_("Continue reading"), 16, false, width * 0.48, label_height)
    place(body, section, margin, y)
    if self.book and self.show_metadata and self.book.last_read_text then
        local last = text(self.book.last_read_text, 15, false, math.floor(width * 0.48), label_height)
        place(body, last, margin + width - last:getWidth(), y)
    end
    y = y + label_height + unit(8)
    if self.book and continue_index then
        place(body, self:bookCard(self.book, width, featured_height, continue_index, nil,
            featured_cover_height, featured_cover_width, ratio), margin, y)
    else
        local empty = canvas(width, featured_height)
        place(empty, title(_("No recently opened book. Choose Library to begin."), 24,
            width - 2 * unit(16), featured_height - 2 * unit(16)), unit(16), unit(16))
        place(body, frame(empty, Blitbuffer.COLOR_WHITE), margin, y)
    end
    y = y + featured_height
    if has_recent then
        y = y + unit(22)
        place(body, text(_("Recently read"), 16, false, width, label_height), margin, y)
        y = y + label_height + unit(8)
        for n, entry in ipairs(recent) do
            place(body, self:bookCard(entry.book, card_width, recent_height, entry.index, n,
                recent_cover_height, recent_cover_width, ratio), margin + (n - 1) * (card_width + card_gap), y)
        end
        y = y + recent_height
    end
    if #nav > 0 then y = y + unit(22) end
    local badges = { library = "L", history = "H", browser = "F" }
    for _, entry in ipairs(nav) do
        local item, index = entry.item, entry.index
        local row = canvas(width, nav_height)
        place(row, LineWidget:new{
            dimen = Geom:new{ w = width, h = Size.line.medium }, background = Blitbuffer.COLOR_GRAY,
        }, 0, 0)
        local pad, x = unit(10), unit(10)
        local line_height = math.max(1, nav_height - 2 * unit(10))
        if self.keyboard then
            local badge_size = math.min(unit(29), line_height)
            local badge = canvas(badge_size, badge_size)
            local label = text(badges[item.id], 16, false, badge_size, badge_size)
            place(badge, label, math.max(0, math.floor((badge_size - label:getWidth()) / 2)), 0)
            place(row, frame(badge, nil, Size.line.medium), x, math.floor((nav_height - badge_size) / 2))
            x = x + badge_size + unit(15)
        end
        local detail
        if options.counts ~= false then
            if item.id == "library" then detail = data.library_count ~= nil and tostring(data.library_count) or "documents"
            elseif item.id == "history" and data.history_count ~= nil then detail = tostring(data.history_count)
            elseif item.id == "browser" then detail = data.browser_path end
        end
        local arrow = text("›", 22, false, unit(18), line_height)
        place(row, arrow, width - pad - arrow:getWidth(), math.floor((nav_height - arrow:getSize().h) / 2))
        local usable = width - x - 2 * pad - arrow:getWidth()
        local detail_width = detail and math.floor(usable * 0.48) or 0
        local label_width = usable - (detail and detail_width + unit(12) or 0)
        local label = text(item.text, 22, false, label_width, line_height)
        place(row, label, x, math.floor((nav_height - label:getSize().h) / 2))
        if detail then
            local value = text(detail, 16, false, detail_width, line_height, nil,
                item.id == "browser")
            place(row, value, width - pad - arrow:getWidth() - unit(10) - value:getWidth(),
                math.floor((nav_height - value:getSize().h) / 2))
        end
        local row_frame = frame(row, Blitbuffer.COLOR_WHITE)
        row_frame.invert = self.selected == index
        self.rows[index], self.focus_frames[index] = row_frame, row_frame
        place(body, row_frame, margin, y)
        y = y + nav_height
    end
    if #nav > 0 then
        place(body, LineWidget:new{
            dimen = Geom:new{ w = width, h = Size.line.medium }, background = Blitbuffer.COLOR_GRAY,
        }, margin, y)
    end
    if stats then
        y = y + unit(22)
        place(body, text(stats, 15, false, width, unit(24)), margin, y)
    end
    self.body = body
    local view = canvas(self.width, self.height)
    place(view, self.header, 0, 0)
    place(view, body, 0, self.header_height)
    return view
end

-- One BB8 body plus a header strip; BB4 uses one smaller packed full-screen
-- buffer including the header, with matching native rotation and inverse.
-- Native widgets paint at actual screen coordinates on misses. Every paint
-- restores the surface, including areas exposed by closing overlapping menus.
function Home:freePaintCache()
    if self.body_bb then self.body_bb:free(); self.body_bb = nil end
    if self.header_bb then self.header_bb:free(); self.header_bb = nil end
    self.header_cached = nil
end

function Home:paintTo(bb, x, y)
    if self.disposed or self.skip_paint then return end
    local inverse, night = bb:getInverse(), Screen.night_mode
    local bbtype, rotation = bb:getType(), bb:getRotation()
    local packed = bbtype == Blitbuffer.TYPE_BB4
    if self.paint_inverse ~= inverse or self.paint_night ~= night
            or self.paint_type ~= bbtype or self.paint_rotation ~= rotation
            or self.paint_x ~= x or self.paint_y ~= y then
        self:freePaintCache()
    end
    self.paint_inverse, self.paint_night = inverse, night
    self.paint_type, self.paint_rotation = bbtype, rotation
    self.paint_x, self.paint_y = x, y
    self.dimen.x, self.dimen.y = x, y
    local body_y, body_height = y + self.header_height, self.height - self.header_height
    local body_offset = packed and self.header_height or 0
    if not self.body_bb then
        bb:paintRect(x, body_y, self.width, body_height, Blitbuffer.COLOR_WHITE)
        local selected = self.focus_frames[self.selected]
        if selected then selected.invert = false end
        self.body:paintTo(bb, x, body_y)
        if selected then selected.invert = true end
        self.body_bb = paintBuffer(self.width, packed and self.height or body_height, bb)
        copyPaint(self.body_bb, bb, 0, body_offset, x, body_y, self.width, body_height)
    else
        copyPaint(bb, self.body_bb, x, body_y, 0, body_offset, self.width, body_height)
    end
    local status = self.header.status_widget.text
    local focused = self.header.menu_button and self.header.menu_button.focused
    if self.paint_status ~= status or self.paint_header_focus ~= focused then self.header_cached = nil end
    if not self.header_cached then
        bb:paintRect(x, y, self.width, self.header_height, Blitbuffer.COLOR_WHITE)
        self.header:paintTo(bb, x, y)
        if not packed and not self.header_bb then self.header_bb = paintBuffer(self.width, self.header_height, bb) end
        copyPaint(packed and self.body_bb or self.header_bb, bb, 0, 0, x, y, self.width, self.header_height)
        self.paint_status, self.paint_header_focus = status, focused
        self.header_cached = true
    else
        copyPaint(bb, packed and self.body_bb or self.header_bb, x, y, 0, 0, self.width, self.header_height)
    end
    local focus = self.focus_frames[self.selected]
    if focus and focus.dimen then
        local rect, border = focus.dimen, focus.bordersize
        invertFocus(bb, rect.x + border, rect.y + border, rect.w - 2 * border, rect.h - 2 * border)
        -- These layers were painted after the original invertible frame. Restore
        -- them verbatim instead of inverting covers or recent-key badges.
        for _, widget in ipairs(self.focus_exclusions[self.selected] or {}) do
            local area = widget.dimen
            if area then
                copyPaint(bb, self.body_bb, area.x, area.y, area.x - x, area.y - body_y + body_offset, area.w, area.h)
            end
        end
    end
    -- A BB8 snapshot must not desaturate covers on color displays. Only the
    -- existing (at most four) decoded image buffers are composited in that case.
    if bb:isRGB() then
        for _, image in ipairs(self.cover_widgets) do
            image:paintTo(bb, image.dimen.x, image.dimen.y)
        end
        -- These badges are above covers in the native tree as well.
        for _, badge in ipairs(self.badge_widgets) do
            local area = badge.dimen
            copyPaint(bb, self.body_bb, area.x, area.y, area.x - x, area.y - body_y + body_offset, area.w, area.h)
        end
    end
end

function Home:getFocusId()
    return self.item_table[self.selected] and self.item_table[self.selected].id
end

function Home:setSelection(index)
    index = math.max(1, math.min(index, #self.item_table))
    if self.selected == index then return true end
    local old, new = self.rows[self.selected], self.rows[index]
    local old_frame, new_frame = self.focus_frames[self.selected], self.focus_frames[index]
    if old_frame then old_frame.invert = false end
    if new_frame then new_frame.invert = true end
    self.selected = index
    for _, recent in ipairs(self.recent_indices) do
        if recent == index then self.recent_cursor = index; break end
    end
    UIManager:setDirty(self, function()
        return "ui", old and old.dimen and new and new.dimen and old.dimen:combine(new.dimen) or self.dimen
    end)
    return true
end

function Home:onMinimalUp()
    if not Device:hasFewKeys() and #self.recent_indices > 0 then
        local first, last = self.recent_indices[1], self.recent_indices[#self.recent_indices]
        if self.selected >= first and self.selected <= last then return self:setSelection(first - 1) end
        if self.selected == last + 1 then return self:setSelection(math.max(first, math.min(last, self.recent_cursor or first))) end
    end
    return self:setSelection(self.selected - 1)
end

function Home:onMinimalDown()
    if not Device:hasFewKeys() and #self.recent_indices > 0 then
        local first, last = self.recent_indices[1], self.recent_indices[#self.recent_indices]
        if self.selected >= first and self.selected <= last then return self:setSelection(last + 1) end
    end
    return self:setSelection(self.selected + 1)
end

function Home:onMinimalLeft()
    for i, index in ipairs(self.recent_indices) do
        if index == self.selected then return self:setSelection(self.recent_indices[math.max(1, i - 1)]) end
    end
    return true
end

function Home:onMinimalRight()
    for i, index in ipairs(self.recent_indices) do
        if index == self.selected then return self:setSelection(self.recent_indices[math.min(#self.recent_indices, i + 1)]) end
    end
    return true
end

function Home:onMinimalActivate()
    local item = self.item_table[self.selected]
    if item and item.callback then item.callback() end
    return true
end

function Home:activateId(id)
    for i, item in ipairs(self.item_table) do
        if item.id == id then
            self:setSelection(i)
            return self:onMinimalActivate()
        end
    end
    return true
end

function Home:onMinimalLibrary() return self:activateId("library") end
function Home:onMinimalHistory() return self:activateId("history") end
function Home:onMinimalBrowser() return self:activateId("browser") end

function Home:onMinimalRecent(index)
    local selected = self.recent_indices[index]
    if selected then
        self:setSelection(selected)
        return self:onMinimalActivate()
    end
    return true
end

function Home:onMinimalContext()
    local book = self.row_books[self.selected]
    if book then return LibraryActions.show(self, { file = book.path, text = book.title or book.path }) end
    return true
end

function Home:onInvalidateMetadataCache(path)
    self.controller.home_source_cache = nil
    for key, entry in pairs(self.cover_cache or {}) do
        if type(path) == "string" and key:sub(1, #path + 1) == path .. "\0" then entry.invalid = true end
    end
end

function Home:onBookMetadataChanged()
    self.controller.home_source_cache = nil
    if self.controller.screen == self then LibraryActions.queueRefresh(self) end
end

function Home:onMinimalMenu()
    return self.controller:showNativeMenu()
end

function Home:onMinimalBack()
    return self.controller:back()
end

function Home:onHome()
    return true
end

function Home:rowAt(pos)
    for i = 1, #self.item_table do
        local row = self.rows[i]
        if row and row.dimen and row.dimen:contains(pos) then return i end
    end
end

function Home:onMinimalTap(_, ges)
    if ges.pos.y < self.header_height then return self:onMinimalMenu() end
    local index = self:rowAt(ges.pos)
    if index then
        self:setSelection(index)
        return self:onMinimalActivate()
    end
    return true
end

function Home:onMinimalHold(_, ges)
    local index = ges and self:rowAt(ges.pos)
    if index then self:setSelection(index) end
    if index then return self:onMinimalContext() end
    return true
end

Home.onHold = Home.onMinimalContext

function Home:onMinimalSwipe(_, ges)
    if ges.direction == "south" and ges.pos.y < self.header_height then return self:onMinimalMenu() end
    return true
end

local book_fields = { "path", "title", "authors", "fraction", "status", "chapter", "chapter_time_text", "last_read_text" }
local home_fields = { "history_count", "library_count", "browser_path", "stats_text" }
local option_fields = { "recent", "covers", "metadata", "stats", "counts" }

local function sameFields(a, b, fields)
    if a == b then return true end
    if not a or not b then return false end
    for _, field in ipairs(fields) do if a[field] ~= b[field] then return false end end
    return true
end

local function sameHome(screen, items, book, data)
    if not sameFields(screen.book, book, book_fields) or #screen.item_table ~= #items then return false end
    local previous = screen.home_data
    if not sameFields(previous, data, home_fields)
            or not sameFields(previous.options, data.options, option_fields)
            or #previous.recent ~= #data.recent then return false end
    for i, item in ipairs(items) do
        local old = screen.item_table[i]
        if old.id ~= item.id or old.text ~= item.text or old.file ~= item.file then return false end
    end
    for i, recent in ipairs(data.recent) do
        if not sameFields(previous.recent[i], recent, book_fields) then return false end
    end
    for _, cover in pairs(screen.cover_cache or {}) do if cover.invalid then return false end end
    return true
end

function Home:layoutChanged()
    return self.width ~= Screen:getWidth() or self.height ~= Screen:getHeight()
        or self.has_keys ~= Device:hasKeys() or self.few_keys ~= Device:hasFewKeys()
        or self.keyboard ~= Device:hasKeyboard() or self.touch ~= Device:isTouchDevice()
end

function Home:setContent(items, book, index, home_data)
    LibraryActions.cancelRefresh(self)
    if self.show_covers then
        for _, entry in pairs(self.cover_cache or {}) do
            local signature = Cover.signature(entry.path)
            if not signature or signature ~= entry.signature then entry.invalid = true end
        end
    end
    if not self:layoutChanged() and home_data and self.home_data.recent
            and sameHome(self, items, book, home_data) then
        self.item_table, self.book, self.home_data = items, book, home_data
        self.header:refreshStatus()
        self:setSelection(index)
        return
    end
    self.item_table, self.book, self.selected = items, book, index
    self.home_data = home_data or {}
    self:rebuild(true)
end

function Home:rebuild(content_changed)
    if not content_changed and not self:layoutChanged() then return false end
    self:freePaintCache()
    self:free(true)
    self[1] = nil
    self:init()
    UIManager:setDirty(self, "ui")
    return true
end

function Home:onSetDimensions()
    self.controller:queueLayout()
end
Home.onScreenResize = Home.onSetDimensions
Home.onPhysicalKeyboardConnected = Home.onSetDimensions
Home.onPhysicalKeyboardDisconnected = Home.onSetDimensions

function Home:onSetRotationMode(rotation)
    if self.controller:isLive() then
        self.controller.ui:onSetRotationMode(rotation)
        self.controller:queueLayout()
    end
    return true
end

function Home:dispose()
    if self.disposed then return end
    self.disposed = true
    LibraryActions.cancelRefresh(self)
    self:freePaintCache()
    self:free(true)
    self[1] = nil
    for _, entry in pairs(self.cover_cache or {}) do
        if entry.bb then entry.bb:free() end
    end
    self.cover_cache = nil
    self.cover_bb, self.cover_widget, self.title_widget, self.featured_title = nil, nil, nil, nil
    self.body, self.header = nil, nil
    self.rows, self.focus_frames, self.row_books = nil, nil, nil
    self.focus_exclusions, self.cover_widgets, self.badge_widgets = nil, nil, nil
    self.item_table, self.book, self.home_data = nil, nil, nil
end

function Home:propagateEvent(event)
    -- Native text/image children free themselves on CloseWidget. Home owns
    -- their lifetime while parked and frees the whole subtree only in dispose.
    if event.handler == "onCloseWidget" then return false end
    return InputContainer.propagateEvent(self, event)
end

function Home:onCloseWidget()
    LibraryActions.cancelRefresh(self)
    self.controller:screenClosed(self)
    -- The controller owns one off-stack Home. Native close only parks it;
    -- teardown clears ownership first, then reaches the idempotent disposer.
    if self.controller.home_screen ~= self then self:dispose() end
end

return Home
