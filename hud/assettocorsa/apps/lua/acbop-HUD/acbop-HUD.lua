-- acbop HUD: the leaderboard from CMRT Essential HUD (CMRT Group), cut down to
-- just that, plus acbop's ballast/restrictor column, safety car flag and
-- rebindable safety car button. Keep this file named after its folder.

-- global variables accessible by any module we import
Dt = 0
Time = 0

APPNAMES = {
    leaderboard = "acbop leaderboard",
}

local settings = require('settings.first')
local common_settings = require('common.settings')
local players = require('common.players')
local acbop = require('common.acbop')
local recorder = require('leaderboard.recorder')
local leaderboard = require('leaderboard.first')

local init = false

local session_time = -999999
local err_count = 1
local function call_protected_function(func)
    xpcall(func, function(err)
        ac.debug("ERROR: " .. err_count, err .. "\n" .. debug.traceback())
        err_count = err_count + 1
    end)
end

local function session_start(session_index, restarted)
    call_protected_function(players.on_session_start)
    call_protected_function(acbop.on_session_start)
    call_protected_function(recorder.on_session_start)
    call_protected_function(leaderboard.on_session_start)
end

function script.update(dt)
    err_count = 1
    Dt = dt
    Time = Time + Dt

    local sim_info = ac.getSim()
    if init == false then
        init = true
        if sim_info.isOnlineRace == false then
            ac.onSessionStart(session_start)
        end
        call_protected_function(common_settings.init)
        call_protected_function(settings.init)
        call_protected_function(players.init)
        call_protected_function(acbop.init)
        call_protected_function(leaderboard.init)
    end

    -- online there is no session start callback: a session clock that went
    -- backwards means a new session
    if sim_info.isOnlineRace then
        if sim_info.currentSessionTime < session_time then
            session_start(-1, -1)
        end
    end
    session_time = sim_info.currentSessionTime

    call_protected_function(players.update)
    call_protected_function(acbop.update)
    call_protected_function(leaderboard.update)
    call_protected_function(recorder.update)
end

function settingsMain(dt) call_protected_function(settings.main) end

function leaderboardMain(dt) call_protected_function(leaderboard.main) end
function leaderboardShow(dt) call_protected_function(leaderboard.on_open) end
function leaderboardHide(dt) call_protected_function(leaderboard.on_close) end
