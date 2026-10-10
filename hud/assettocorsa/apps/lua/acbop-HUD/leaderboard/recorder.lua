-- Records where every car has been during its current lap and its previous
-- one. The leaderboard turns those traces into time intervals between cars.
-- (CMRT's deltabar did this alongside its own display; this is just the
-- recording half.)
local mod = {}

local players = require('common.players')
local lapmod = require('leaderboard.lap')

local current_laps = table.new(40, 0)  -- by car index
local previous_laps = table.new(40, 0) -- by car index
local last_session_index = -1

function mod.on_session_start()
    table.clear(current_laps)
    table.clear(previous_laps)
end

---@return Lap?
function mod.get_player_current_lap_data(car_index)
    return current_laps[car_index]
end

---@return Lap?
function mod.get_player_previous_lap_data(car_index)
    return previous_laps[car_index]
end

local function record(car_index)
    local sim_info = ac.getSim()
    local car_info = ac.getCar(car_index)
    if car_info == nil then return end

    local sectors = players.get_sector_splits()
    local spline = car_info.splinePosition

    local lap = current_laps[car_index]
    if lap == nil then
        if car_info.lapTimeMs <= 0 then return end -- record once the clock is ticking
        if spline > sectors[0] + 0.01 then return end -- we haven't reached the start line yet
        lap = lapmod.init(ac.getTrackName(), #sectors, car_index)
    end

    local current_lapcount = players.get_lapcount(car_index)
    if current_lapcount < lap.lap_number or sim_info.currentSessionIndex ~= last_session_index then
        -- lap count went backwards or the session changed: start over
        last_session_index = sim_info.currentSessionIndex
        current_laps[car_index] = nil
        return
    end

    if lap.lap_number ~= current_lapcount then
        -- crossed the line: this lap becomes the previous one
        previous_laps[car_index] = lap
        current_laps[car_index] = nil
        return
    end

    if ac.getTrackName() == "Nordschleife - Tourist" then
        spline = players.normalize_spline_for_nordschleife_turist(spline)
    end
    lapmod.add_info(lap, spline, car_info.lapTimeMs, car_info.speedMs)
    current_laps[car_index] = lap
end

function mod.update()
    if ac.getSim().isLive == false then return end
    local leaderboard = players.get_leaderboard()
    for i=0, #leaderboard-1 do
        record(leaderboard[i].car.index)
    end
end

return mod
