-- Instance-owned counterpart of KOReader v2026.07.1 CoverMenu's deferred
-- extraction/poll lifecycle. The manager still owns extraction and PID reaping.
local FFIUtil = require("ffi/util")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ViewJobs = {}
local current_jobs = setmetatable({}, { __mode = "k" })

local function current(menu, state)
    return state.active and menu._minimal_view_jobs == state and menu.items_to_update == state.items
end

local function stopOwned(state)
    local manager = state.manager
    if current_jobs[manager] ~= state then return end
    current_jobs[manager] = nil
    -- extractInBackground cancels the previous native batch when starting a
    -- new one. Cancel only PIDs added by this particular launch, never the
    -- manager-wide set (which may now contain another menu's newer batch).
    for _, pid in ipairs(state.pids or {}) do
        for _, tracked in ipairs(manager.subprocesses_pids or {}) do
            if tracked == pid then FFIUtil.terminateSubProcess(pid); break end
        end
    end
    state.pids = nil
end

function ViewJobs.cancel(menu, close)
    local state = menu._minimal_view_jobs
    menu._minimal_view_jobs = nil
    if state then
        state.active, state.closed = false, close == true
        if state.launch then UIManager:unschedule(state.launch); state.launch = nil end
        if state.poll then UIManager:unschedule(state.poll) end
        stopOwned(state)
        state.items, state.files = nil, nil
    end
    -- Adopt and retract a tracked native poll if ownership is acquired after
    -- an earlier native population. Anonymous native launches cannot be safely
    -- identified here: the caller must adapt before native updateItems runs.
    if menu.items_update_action then UIManager:unschedule(menu.items_update_action) end
    menu.items_update_action = nil
    menu.items_to_update = {}
end

function ViewJobs.start(menu, manager)
    local pending = menu.items_to_update or {}
    ViewJobs.cancel(menu)
    menu.items_to_update = pending
    if #pending == 0 then return end
    local state = { active = true, manager = manager, items = pending, pids = {}, files = {} }
    menu._minimal_view_jobs = state
    for _, item in ipairs(pending) do
        state.files[#state.files + 1] = { filepath = item.filepath, cover_specs = item.cover_specs }
    end
    local function finish()
        if not current(menu, state) then return end
        if menu.items_update_action == state.poll then menu.items_update_action = nil end
        state.poll = nil
    end
    state.poll = function()
        if not current(menu, state) then return end
        local extracting = manager:isExtractingInBackground()
        local i = 1
        while current(menu, state) and i <= #state.items do
            local item = state.items[i]
            item:update()
            -- Updating an item can synchronously replace/release the menu.
            if not current(menu, state) then return end
            if item.bookinfo_found then
                local parent = menu.show_parent or menu
                parent.dithered = item._has_cover_image
                local refresh = "ui"
                if item._has_cover_image and manager:getSetting("flash_ui_cover_images") then refresh = "flashui" end
                local area = item.refresh_dimen or (item[1] and item[1].dimen) or item.dimen
                UIManager:setDirty(parent, function() return refresh, area, parent.dithered end)
                if not current(menu, state) then return end
                table.remove(state.items, i)
            else i = i + 1 end
        end
        if not current(menu, state) then return end
        if #state.items > 0 and (extracting or state.launch) then
            UIManager:scheduleIn(1, state.poll)
        else finish() end
    end
    state.launch = function()
        if not current(menu, state) then return end
        state.launch = nil
        local before = {}
        for _, pid in ipairs(manager.subprocesses_pids or {}) do before[pid] = true end
        local launched = manager:extractInBackground(state.files)
        for _, pid in ipairs(manager.subprocesses_pids or {}) do
            if not before[pid] then state.pids[#state.pids + 1] = pid end
        end
        if launched then current_jobs[manager] = state end
        state.files = nil
        if not current(menu, state) then stopOwned(state); return end
        if not launched then
            if state.poll then UIManager:unschedule(state.poll) end
            finish()
            UIManager:show(InfoMessage:new{
                text = _("Start-up of background extraction job failed.\nPlease restart KOReader or your device."),
            })
        end
    end
    menu.items_update_action = state.poll
    UIManager:nextTick(state.launch)
    UIManager:scheduleIn(1, state.poll)
end

-- CoverMenu:onCloseWidget also terminates every manager-owned subprocess.
-- Managed pages must keep its other cleanup without killing a newer page's
-- extraction. Leave reaping/standby accounting to the native collector.
function ViewJobs.close(menu, manager)
    ViewJobs.cancel(menu, true)
    local Menu = require("ui/widget/menu")
    if not manager then return Menu.onCloseWidget(menu) end
    if menu._covermenu_onclose_done then return end
    menu._covermenu_onclose_done = true
    manager:closeDbConnection()
    manager:cleanUp() -- defers temporary-cache removal while any PID lives
    menu.item_group:free()
    UIManager:scheduleIn(0.2, function()
        collectgarbage()
        collectgarbage()
    end)
    return Menu.onCloseWidget(menu)
end

return ViewJobs
