-- Read-only Home data: only the featured book and three recent sidecars.
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local datetime = require("datetime")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local HomeSource = {}
local snapshot_key = "minimalui_home_snapshot"

local function isFinite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function text(value)
    return type(value) == "string" and value:find("%S") and value or nil
end

local function isFile(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode == "file"
end

local function options()
    local result = {}
    for _, name in ipairs({ "recent", "covers", "metadata", "stats", "counts" }) do
        -- readSetting's default argument would write the default to settings.
        result[name] = G_reader_settings:readSetting("minimalui_home_" .. name) ~= false
    end
    return result
end

local function duration(seconds)
    return datetime.secondsToClockDuration(
        G_reader_settings:readSetting("duration_format") or "classic", seconds, true)
end

local function snapshotMatches(snapshot, settings)
    if type(snapshot) ~= "table" then return false end
    local saved_xpointer = settings:readSetting("last_xpointer")
    if text(snapshot.last_xpointer) then
        if snapshot.last_xpointer ~= saved_xpointer then return false end
    elseif isFinite(snapshot.page) then
        if snapshot.page ~= settings:readSetting("last_page") then return false end
    else
        return false
    end
    local saved_fraction = settings:readSetting("percent_finished")
    if isFinite(snapshot.fraction) then
        if not isFinite(saved_fraction) or snapshot.fraction ~= saved_fraction then return false end
    elseif isFinite(saved_fraction) then
        return false
    end
    return true
end

local function fileFingerprint(path)
    if not path then return false end
    local ok, attr = pcall(lfs.attributes, path)
    return ok and type(attr) == "table" and attr.mode == "file" and attr or false
end

local function sameFingerprint(a, b)
    if not a or not b then return a == b end
    return a.modification == b.modification and a.size == b.size
        and a.change == b.change and a.ino == b.ino and a.dev == b.dev
end

local function readBook(book, show_metadata, previous, current)
    book.title = text(book.title) or (book.path:match("([^/]+)$") or book.path):gsub("%.[^.]+$", "")
    book.authors, book.chapter, book.chapter_time_text, book.last_read_text = nil, nil, nil, nil
    -- Resolve again even on cache hits: a newly preferred sidecar or custom
    -- metadata file must take effect without reopening the document.
    local sidecar_ok, sidecar = pcall(DocSettings.findSidecarFile, DocSettings, book.path)
    local custom_ok, custom = pcall(DocSettings.findCustomMetadataFile, DocSettings, book.path)
    if not sidecar_ok then
        logger.warn("MinimalUI: unable to find Home metadata", book.path, sidecar)
        sidecar = nil
    end
    if not custom_ok then
        logger.warn("MinimalUI: unable to find custom Home metadata", book.path, custom)
        custom = nil
    end
    local sidecar_stamp = current and fileFingerprint(sidecar)
    local custom_stamp = current and fileFingerprint(custom)
    local cached = previous and previous[book.path]
    local metadata
    if sidecar_ok and custom_ok and cached
            and cached.sidecar == sidecar and cached.custom == custom
            and sameFingerprint(cached.sidecar_stamp, sidecar_stamp)
            and sameFingerprint(cached.custom_stamp, custom_stamp) then
        metadata = cached.metadata
    else
        metadata = {}
        local ok, err = pcall(function()
            -- Unlike DocSettings:open, this read-only API never deletes
            -- corrupt candidates and never opens the document itself.
            if not sidecar then return end
            local settings = DocSettings.openSettingsFile(sidecar)
            metadata.has_sidecar = true
            local props = settings:readSetting("doc_props")
            if type(props) == "table" then
                metadata.title = text(props.display_title) or text(props.title)
                metadata.authors = text(props.authors) or text(props.author)
            end
            local fraction = settings:readSetting("percent_finished")
            if isFinite(fraction) then metadata.fraction = math.max(0, math.min(1, fraction)) end
            local summary = settings:readSetting("summary")
            metadata.status = type(summary) == "table" and text(summary.status) or nil
            local snapshot = settings:readSetting(snapshot_key)
            if snapshotMatches(snapshot, settings) then
                metadata.chapter = text(snapshot.chapter)
                if isFinite(snapshot.chapter_seconds) and snapshot.chapter_seconds >= 0 then
                    metadata.chapter_seconds = snapshot.chapter_seconds
                end
            end
        end)
        if not ok then logger.warn("MinimalUI: unable to read Home metadata", book.path, err) end
        local props_ok, props_err = pcall(function()
            if not custom then return end
            local props = DocSettings.openSettingsFile(custom):readSetting("custom_props")
            if type(props) ~= "table" then return end
            metadata.title = text(props.title) or metadata.title
            metadata.authors = text(props.authors) or metadata.authors
        end)
        if not props_ok then logger.warn("MinimalUI: unable to read custom Home metadata", book.path, props_err) end
        -- Do not retain failed parses or races between discovery and stat.
        if current and sidecar_ok and custom_ok and ok and props_ok
                and (not sidecar or sidecar_stamp) and (not custom or custom_stamp) then
            cached = {
                sidecar = sidecar, sidecar_stamp = sidecar_stamp,
                custom = custom, custom_stamp = custom_stamp,
                metadata = metadata,
            }
        else
            cached = nil
        end
    end
    if current then current[book.path] = cached end
    book.title = metadata.title or book.title
    if metadata.fraction ~= nil then book.fraction = metadata.fraction end
    if metadata.has_sidecar then book.status = metadata.status end
    if show_metadata then
        book.authors, book.chapter = metadata.authors, metadata.chapter
        if metadata.chapter_seconds then book.chapter_time_text = duration(metadata.chapter_seconds) end
    end
end

local function lastRead(book, timestamp, show_metadata)
    if show_metadata and isFinite(timestamp) and timestamp > 0 then
        local ok, formatted = pcall(datetime.secondsToDateTime, timestamp)
        if ok then book.last_read_text = text(formatted) end
    end
end

local function statisticsText(ui)
    local statistics = ui and ui.statistics
    if not (statistics and statistics.settings and statistics.settings.is_enabled == true
            and type(statistics.getReadingProgressStats) == "function") then return end
    -- Native getters open the database themselves, so never call them when
    -- it does not already exist (SQLite open could otherwise create it).
    if not isFile(DataStorage:getSettingsDir() .. "/statistics.sqlite3") then return end
    local now = os.date("*t")
    local today = os.date("%Y-%m-%d")
    local start_day = statistics.settings.calendar_start_day_of_week
    if not isFinite(start_day) or start_day < 1 or start_day > 7 then start_day = 2 end
    local week_start = os.date("%Y-%m-%d", os.time{
        year = now.year, month = now.month,
        day = now.day - (now.wday - start_day) % 7, hour = 12,
    })
    local ok, today_seconds, week_seconds = pcall(function()
        -- getDaysFromPeriod returns display text, not durations. An extra
        -- day covers native fixed-86400 boundaries across DST changes.
        local rows = statistics:getReadingProgressStats(8)
        if type(rows) ~= "table" then return end
        local today_total, week_total = 0, 0
        for _, row in ipairs(rows) do
            if type(row) ~= "table" then return end
            local seconds, date = row[2], row[3]
            if date ~= nil then
                if not (isFinite(seconds) and seconds >= 0 and type(date) == "string"
                        and date:match("^%d%d%d%d%-%d%d%-%d%d$")) then return end
                if date == today then today_total = today_total + seconds end
                if date >= week_start and date <= today then week_total = week_total + seconds end
            end
        end
        return today_total, week_total
    end)
    if not ok then
        logger.warn("MinimalUI: unable to read Home statistics", today_seconds)
        return
    end
    if today_seconds == nil then return end
    return T(_("Today %1 · This week %2"), duration(today_seconds), duration(week_seconds))
end

-- The controller owns this optional cache and clears it on metadata/save
-- events, including same-timestamp writes. No history existence checks are
-- cached; books retains only this collection's featured + three recent items.
function HomeSource.collect(ui, book, library_count, cache)
    local opts = options()
    local previous = cache and cache.books
    local current = cache and {}
    local data = {
        recent = {},
        history_count = 0,
        library_count = library_count,
        browser_path = ui and ui.file_chooser and ui.file_chooser.path or nil,
        options = opts,
    }
    if book then readBook(book, opts.metadata, previous, current) end
    local seen = {}
    for _, entry in ipairs(ReadHistory.hist or {}) do
        local path = entry.file
        if type(path) == "string" and not seen[path] then
            seen[path] = true
            if isFile(path) then
                data.history_count = data.history_count + 1
                if book and path == book.path then
                    lastRead(book, entry.time, opts.metadata)
                elseif opts.recent and #data.recent < 3 then
                    local recent = { path = path }
                    readBook(recent, opts.metadata, previous, current)
                    lastRead(recent, entry.time, opts.metadata)
                    data.recent[#data.recent + 1] = recent
                end
            end
        end
    end
    if cache then cache.books = current end
    if opts.stats then
        data.stats_text = statisticsText(ui)
    end
    return data
end

function HomeSource.capture(reader)
    if not (reader and reader.document and reader.doc_settings) then return false end
    local ok, snapshot = pcall(function()
        local page
        if reader.paging and type(reader.paging.getTopPage) == "function" then
            page = reader.paging:getTopPage() -- same page that native paging saves
        elseif type(reader.getCurrentPage) == "function" then
            page = reader:getCurrentPage()
        end
        if not isFinite(page) or page < 1 then return end
        local result = { page = page }
        if reader.rolling then
            result.last_xpointer = text(reader.rolling.xpointer)
                or text(reader.doc_settings:readSetting("last_xpointer"))
            if not result.last_xpointer then return end
        end
        local footer = reader.view and reader.view.footer
        local fraction = footer and footer.percent_finished
            or reader.doc_settings:readSetting("percent_finished")
        if isFinite(fraction) then result.fraction = fraction end
        local toc = reader.toc
        if toc and type(toc.getTocTitleByPage) == "function" then
            result.chapter = text(toc:getTocTitleByPage(page))
        end
        local statistics = reader.statistics
        -- Native stats initialize avg_time to a heuristic for unread books.
        -- Do not expose that default as a measured reading-time estimate.
        if result.chapter and toc and type(toc.getChapterPagesLeft) == "function"
                and statistics and statistics.settings and statistics.settings.is_enabled == true
                and isFinite(statistics.avg_time) and statistics.avg_time > 0
                and isFinite(statistics.book_read_pages) and statistics.book_read_pages > 0 then
            local left = toc:getChapterPagesLeft(page, true)
            if left == nil and type(reader.document.getTotalPagesLeft) == "function" then
                left = reader.document:getTotalPagesLeft(page)
            end
            if isFinite(left) and left >= 0 then
                local seconds = left * statistics.avg_time
                if isFinite(seconds) then result.chapter_seconds = seconds end
            end
        end
        return result
    end)
    if not ok then
        logger.warn("MinimalUI: unable to capture Home metadata", snapshot)
        return false
    end
    if not snapshot then return false end
    -- No flush: the reader owns native SaveSettings ordering and persistence.
    reader.doc_settings:saveSetting(snapshot_key, snapshot)
    return true
end

return HomeSource
