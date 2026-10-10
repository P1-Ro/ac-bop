-- keep the filename of this file the same as the folder that contains it
-- global variables accessible by any module we import
Dt = 0
Time = 0
DEV_IntroAnimOff     = false -- DEBUG: set to false in release! Dev only value to temporarily disable intro animation for every app
DEV_GarbageCollector = false -- DEBUG: set to false in release! Dev only value to temporarily enable garbage collection (ruins performance in general, but helps during optimization phases)

DEV_GC_LEVELS = {
    UpdateOnly = 0,
    UpdatePerApp = 1,
    UpdatePlusMain = 2,
    UpdateMainAndOneInit = 3,
    UpdateMainAndInitAll = 4,
}
DEV_GarbageCollector_Level = DEV_GC_LEVELS.UpdatePlusMain -- DEBUG: used to have different levels of GC

APPNAMES = {
    deltabar    = "CMRT deltabar",
    gearbox     = "CMRT gearbox",
    leaderboard = "CMRT leaderboard",
    map         = "CMRT map",
    local_time  = "CMRT local time",
    real_time   = "CMRT real time",
    pedals      = "CMRT pedals",
    radar       = "CMRT radar",
    sectors     = "CMRT sectors",
    tyres       = "CMRT tyres",
}

-- TAG: GarbageSucks, since many things create garbage and the garbage collector takes a ton of time, we try to avoid it.
local settings = require('settings.first')
local gearbox = require('gearbox.first')
local sectors = require('sectors.first')
local tires = require('tires.first')
local leaderboard = require('leaderboard.first')
local player_data = require('common.players')
local common_settings = require('common.settings')
local map = require('map.first')
local time = require('time.first')
local pctime = require('pctime.first')
local radar = require('radar.first')
local pedals = require('pedals.first')
local deltabar = require('deltabar.first')
local fullscreen = require('fullscreen.first')
local acbop = require('common.acbop')

local init = false

local gcCounter = 0
local function runGC(funcname)
    if not DEV_GarbageCollector then return end
    if funcname[1]:match("%d") then
        local level = stringify.parse(funcname[1])
        if level > DEV_GarbageCollector_Level then return end
    else if DEV_GarbageCollector_Level == DEV_GC_LEVELS.UpdateOnly then return end
    end
    local before = collectgarbage('count')
    collectgarbage()
    gcCounter = gcCounter + 1
    local gc = before - collectgarbage('count')
    ac.debug("Run | gc (KB) | " .. funcname, gc)
end

local session_time = -999999
local err_count = 1
local function call_protected_function(func)
    xpcall(func, function(err)
        ac.debug("ERROR: " .. err_count, err .. "\n" .. debug.traceback())
        err_count = err_count + 1
    end)
end

local function session_start(session_index, restarted)
    call_protected_function(fullscreen.on_session_start) -- before each app so we setup intro anim
    call_protected_function(player_data.on_session_start)
    call_protected_function(acbop.on_session_start)
    call_protected_function(sectors.on_session_start)
    call_protected_function(deltabar.on_session_start) -- before leaderboard so he gets the correct data
    call_protected_function(leaderboard.on_session_start)
    call_protected_function(deltabar.on_session_start)
    call_protected_function(tires.on_session_start)
    call_protected_function(map.on_session_start)
end

local function on_game_close(nothing)
    call_protected_function(deltabar.on_game_close)
    call_protected_function(gearbox.on_game_close)
end

function script.update(dt)
    err_count = 1
    Dt = dt
    Time = Time + Dt
    gcCounter = 0
    
    local sim_info = ac.getSim()
    if init == false then
        init = true
        ac.onRelease(on_game_close, nil)
        if sim_info.isOnlineRace == false then
            ac.onSessionStart(session_start)
        end
        runGC("ign")
        call_protected_function(common_settings.init)
        runGC("4 common init")
        call_protected_function(settings.init)
        runGC("4 settings init")
        call_protected_function(player_data.init)
        runGC("4 player data init")
        call_protected_function(acbop.init)
        runGC("4 acbop init")
        call_protected_function(sectors.init)
        runGC("4 sectors init")
        call_protected_function(tires.init)
        runGC("4 tyres init")
        call_protected_function(map.init)
        runGC("4 map init")
        call_protected_function(deltabar.init) -- before leaderboard so we have proper data on players' laps
        runGC("4 deltabar init")
        call_protected_function(leaderboard.init)
        runGC("4 leaderboard init")
        call_protected_function(gearbox.init)
        runGC("4 gearbox init")
        call_protected_function(pedals.init)
        runGC("4 pedals init")
        runGC("3 init all")
    end
    
    if sim_info.isOnlineRace then
        if sim_info.currentSessionTime < session_time then
            session_start(-1, -1)
        end
    end
    session_time = sim_info.currentSessionTime
    
    
    runGC("ign")
    call_protected_function(player_data.update)
    runGC("1 update player data")
    call_protected_function(acbop.update)
    runGC("1 update acbop")
    call_protected_function(tires.update)
    runGC("1 update tyres")
    call_protected_function(sectors.update)
    runGC("1 update sectors")
    call_protected_function(leaderboard.update)
    runGC("1 update leaderboard")
    call_protected_function(map.update)
    runGC("1 update map")
    call_protected_function(deltabar.update)
    runGC("1 update deltabar")
    call_protected_function(pedals.update)
    runGC("1 update pedals")
    runGC("0 update all")
end

function settingsMain(dt) runGC("ign") call_protected_function(settings.main) runGC("2 main settings") end

function maptimeMain(dt) runGC("ign") call_protected_function(time.main) runGC("2 main maptime") end
function maptimeShow(dt) call_protected_function(time.on_open) end
function maptimeHide(dt) call_protected_function(time.on_close) end

function pctimeMain(dt) runGC("ign") call_protected_function(pctime.main) runGC("2 main pctime") end
function pctimeShow(dt) call_protected_function(pctime.on_open) end
function pctimeHide(dt) call_protected_function(pctime.on_close) end

function pedalsMain(dt) runGC("ign") call_protected_function(pedals.main) runGC("2 main pedals") end
function pedalsShow(dt) call_protected_function(pedals.on_open) end
function pedalsHide(dt) call_protected_function(pedals.on_close) end

function deltabarMain(dt) runGC("ign") call_protected_function(deltabar.main) runGC("2 main deltabar") end
function deltabarShow(dt) call_protected_function(deltabar.on_open) end
function deltabarHide(dt) call_protected_function(deltabar.on_close) end

function radarMain(dt) runGC("ign") call_protected_function(radar.main) runGC("2 main radar") end
function radarShow(dt) call_protected_function(radar.on_open) end
function radarHide(dt) call_protected_function(radar.on_close) end

function tiresMain(dt) runGC("ign") call_protected_function(tires.main) runGC("2 main tyres") end
function tyresShow(dt) call_protected_function(tires.on_open) end
function tyresHide(dt) call_protected_function(tires.on_close) end

function gearboxMain(dt) runGC("ign") call_protected_function(gearbox.main) runGC("2 main gearbox") end
function gearboxShow(dt) call_protected_function(gearbox.on_open) end
function gearboxHide(dt) call_protected_function(gearbox.on_close) end

function sectorsMain(dt) runGC("ign") call_protected_function(sectors.main) runGC("2 main sectors") end
function sectorsShow(dt) call_protected_function(sectors.on_open) end
function sectorsHide(dt) call_protected_function(sectors.on_close) end

function leaderboardMain(dt) runGC("ign") call_protected_function(leaderboard.main) runGC("2 main leaderboard") end
function leaderboardShow(dt) call_protected_function(leaderboard.on_open) end
function leaderboardHide(dt) call_protected_function(leaderboard.on_close) end

function mapMain(dt) runGC("ign") call_protected_function(map.main) runGC("2 main map") end
function mapShow(dt) call_protected_function(map.on_open) end
function mapHide(dt) call_protected_function(map.on_close) end

function fullscreenMain(dt) runGC("ign") call_protected_function(fullscreen.main) runGC("2 fullscreen") end