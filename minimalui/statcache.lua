-- One read-only observer per FileManager. Never cache by file time/size: SQLite
-- data_version detects same-second commits, including changes in a WAL.
local lfs = require("libs/libkoreader-lfs")
local Cache = {}

function Cache.close(cache)
    if not cache then return end
    local conn = cache.conn
    for key in pairs(cache) do cache[key] = nil end
    -- SQ3 retains connections in its statement registry. GC is not a close.
    if conn then pcall(conn.close, conn) end
end

local function identity(path)
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" and type(attr.dev) == "number"
            and type(attr.ino) == "number" and attr.ino > 0 then
        return attr.dev, attr.ino
    end
end

local function sameFile(path, dev, ino)
    local current_dev, current_ino = identity(path)
    return dev ~= nil and dev == current_dev and ino == current_ino
end

local function queryKey()
    local now = os.time()
    local t = os.date("*t", now)
    -- Match the native eight-day query, including local DST/clock changes.
    local begin = now - 7 * 86400 - t.hour * 3600 - t.min * 60 - t.sec
    return os.date("%Y-%m-%d %z", now) .. ":" .. begin
end

local function version(conn)
    local value = tonumber(conn:rowexec("PRAGMA data_version"))
    assert(value and value == value and value >= 0 and value < math.huge, "unsupported data_version")
    return value
end

-- Caller validates/formats the native rows as before; cache only numeric/string
-- query results, never formatted text. No transaction or statement stays open.
function Cache.get(statistics, path, cache)
    if not cache then return statistics:getReadingProgressStats(8) end
    local ok, before, key = pcall(function()
        local dev, ino = identity(path)
        assert(dev ~= nil, "unavailable database identity")
        if cache.path ~= path or cache.dev ~= dev or cache.ino ~= ino
                or cache.owner ~= statistics or cache.getter ~= statistics.getReadingProgressStats then
            Cache.close(cache)
        end
        if not cache.conn then
            cache.conn = require("lua-ljsqlite3/init").open(path, "ro")
            cache.conn:set_busy_timeout(0)
            cache.conn:exec("PRAGMA cache_size=-64")
            cache.path, cache.dev, cache.ino = path, dev, ino
            cache.owner, cache.getter = statistics, statistics.getReadingProgressStats
        end
        local v = version(cache.conn)
        assert(sameFile(path, dev, ino), "database replaced during validation")
        return v, queryKey()
    end)
    if not ok then
        Cache.close(cache)
        return statistics:getReadingProgressStats(8)
    end
    if cache.rows and cache.version == before and cache.key == key then return cache.rows end
    cache.rows = nil
    local fetched, rows = pcall(statistics.getReadingProgressStats, statistics, 8)
    if not fetched then Cache.close(cache); error(rows, 0) end
    local stable, after = pcall(function()
        local v = version(cache.conn)
        assert(sameFile(path, cache.dev, cache.ino) and key == queryKey(), "database or calendar changed")
        return v
    end)
    if not stable then
        Cache.close(cache)
    elseif before == after and type(rows) == "table" then
        cache.rows, cache.version, cache.key = rows, after, key
    end
    return rows
end

return Cache
