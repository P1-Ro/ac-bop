local mod = {} -- will be filled with public functions

local settings = require('common.settings')
local colors = settings.colors
local fonts = settings.fonts
local players = require('common.players')
local lapmod = require('deltabar.lap')


-- TAG: SectorsJumpsWhenImproved
-- basically if you have -0.2s in the first sector, and you surpass it, previously we
-- would immediately replace the old time with the new time, so you would immediately see
-- the timer jump from -0.2s to 0.0s (because the optimal you can do is what you are doing NOW).
-- Since that kind of sucks now we instead replace the times in the background and only show them when
-- you complete a proper lap, so they appear in the only real jump.
--              Cogno 2024/06/08

local last_session_index = -1
local session_splits_real = table.new(3, 0) -- REAL data on current session
local fastest_splits_real = table.new(3, 0) -- REAL data on fastest session ever recorded
local session_splits_toshow = table.new(3, 0) -- data on current session that we can show now
local fastest_splits_toshow = table.new(3, 0) -- data on fastest session ever recorded that we can show now

local all_players_laps = table.new(40, 0) -- array of laps for each player (including main player, aka car_index == 0) by car index
local all_players_old_sectors = table.new(40, 0) -- keeps track of which sectors players *were* in the last frame
local all_players_old_laps = table.new(40, 0) -- array of LAST laps for each player (including main player, aka car_index == 0) by car index

local fastest_lap = nil
local session_lap = nil
local previous_lap = nil
local multiplayer_lap = nil
local barmode = Deltabar_Modes.SESSION_LAP
local bardata = {
    time_delta = nil,
    speed_delta = 0,
    star = ''
}

local notification_types = {
    new_record = 0,
    new_sector = 1,
    new_lap = 2,
}
local notification1_info = table.new(0, 5)
local notification2_info = table.new(0, 5)
local movement_start_time = 0
local function make_notification_new_record(driver_name)
    local new = table.new(0, 5)
    new.type = notification_types.new_record
    new.anim_time = Time
    new.name = driver_name
    movement_start_time = Time
    notification2_info = table.clone(notification1_info, true) -- move 1 up
    notification1_info = new
end

local function make_notification_new_sector(sector_index, sector_time, sector_delta, is_valid)
    local new = table.new(0, 5)
    new.type = notification_types.new_sector
    new.anim_time = Time
    new.sector_index = sector_index
    new.sector_time = sector_time
    new.sector_delta = sector_delta
    new.is_valid = is_valid
    movement_start_time = Time
    notification2_info = table.clone(notification1_info, true) -- move 1 up
    notification1_info = new
end

local function make_notification_new_lap(lap_number, laptime, lap_delta, is_valid)
    local new = table.new(0, 5)
    new.type = notification_types.new_lap
    new.anim_time = Time
    new.lap_number = lap_number
    new.laptime = laptime
    new.lap_delta = lap_delta
    new.is_valid = is_valid
    movement_start_time = Time
    notification2_info = table.clone(notification1_info, true) -- move 1 up
    notification1_info = new
end

function mod.get_player_previous_lap_data(car_index)
    return all_players_old_laps[car_index]
end

local function clear_screen_data(lap_invalid)
    bardata.time_delta = nil
    if lap_invalid then bardata.star = '*' else bardata.star = '' end
end

function mod.on_session_start()
    table.clear(all_players_laps)
    table.clear(all_players_old_laps)
    table.clear(all_players_old_sectors)
    table.clear(session_splits_toshow)
    table.clear(session_splits_real)
    table.clear(fastest_splits_toshow)
    table.clear(fastest_splits_real)
    table.clear(notification1_info)
    table.clear(notification2_info)
    fastest_lap = nil
    session_lap = nil
    previous_lap = nil
    multiplayer_lap = nil
    clear_screen_data(false)
    mod.init()
end

local color_red = rgbm(228 / 255, 43 / 255, 43 / 255, 1)
local fast_storage_filepath = ""
local sector_storage_filepaths = table.new(3, 0)
local last_bar_mode_storage = nil

---comment
---@param car_index integer
---@return Lap
function mod.get_player_current_lap_data(car_index)
    return all_players_laps[car_index]
end

local function fix_lap_arrays(lap)
    -- lua arrays are saved weirdly, they loose index 0 for some reason...
    -- we don't care about those anyway so we can fake that data
    -- API(cogno): a better way might be to use metatables to offset the index, i don't know if it will work, but if it does it avoids useless copies.
    lap.elapsed_seconds[0] = 0
    lap.offset[0] = 0
    lap.speed_ms[0] = 0
    local lap_sector_count = #lap.splits
    for i=0, lap_sector_count-1 do
        lap.splits[i] = lap.splits[i+1]
        lap.invalid_sectors[i] = lap.invalid_sectors[i+1]
    end
    lap.splits[lap_sector_count] = nil
    lap.invalid_sectors[lap_sector_count] = nil
end

local function save_fast_lap(lap)
    io.save(fast_storage_filepath, stringify.binary(lap))
end
    
local function save_sector_piece(lap, sector_index)
    io.save(sector_storage_filepaths[sector_index], stringify.binary(lap))
end

function mod.init()
    local sim_info = ac.getSim()
    last_session_index = sim_info.currentSessionIndex
    
    local leaderboard = players.get_leaderboard()
    for i=0, #leaderboard-1 do
        local car_info = leaderboard[i].car
        all_players_old_sectors[car_info.index] = car_info.currentSector
    end
    
    -- init gets called also on session change/reset, so this will be called again
    -- 1. recover the last thing the user had
    last_bar_mode_storage = ac.storage('last_barmode_storage_v1', Deltabar_Modes.SESSION_LAP)
    local user_wanted = last_bar_mode_storage:get()
    
    -- 2. override with what the user set he wants in settings (unless it's "don't change")
    local current_session = players.get_current_session()
    local barmode_choice = 0 -- default on don't change
    if current_session.type == ac.SessionType.Practice then
        barmode_choice = Deltabar_PracMode
    elseif current_session.type == ac.SessionType.Qualify then
        barmode_choice = Deltabar_QualMode
    elseif current_session.type == ac.SessionType.Race then
        barmode_choice = Deltabar_RaceMode
    end
    
    if barmode_choice == 0 then
        barmode = user_wanted
    else
        if     barmode_choice == 1 then barmode = Deltabar_Modes.SESSION_LAP
        elseif barmode_choice == 2 then barmode = Deltabar_Modes.SESSION_OPTIMAL
        elseif barmode_choice == 3 then barmode = Deltabar_Modes.FASTEST_LAP
        elseif barmode_choice == 4 then barmode = Deltabar_Modes.FASTEST_OPTIMAL
        elseif barmode_choice == 5 then barmode = Deltabar_Modes.PREVIOUS_LAP
        elseif barmode_choice == 6 then barmode = Deltabar_Modes.MULTIPLAYER_LAP
        end -- ignore unknown values
    end
    
    local sector_count = #players.get_sector_splits()

    -- recover fast lap (if available)
    -- The weird symbols like [], [#] and [vn] are to easily split file name into components.
    -- Remember they must be valid filename characters!
    -- Also windows has a bug where it tells you the symbol | is a valid character but it's not...
    -- The [v1] is an incremental versioning number if new versions are made, making future changes easier.
    local trackname = ac.getTrackFullID("[]")
    local carname = ac.getCarName(0)
    local access_string = trackname .. "[#]" .. carname .. "[v1]"
    access_string = string.replace(access_string, "\"", "_") -- replace characters windows doens't allow as file name
    access_string = string.replace(access_string, "*", "_")
    access_string = string.replace(access_string, "?", "_")
    access_string = string.replace(access_string, "<", "_")
    access_string = string.replace(access_string, ">", "_")
    access_string = string.replace(access_string, "|", "_")
    access_string = string.replace(access_string, ":", "_")
    access_string = string.replace(access_string, "\\", "_")
    access_string = string.replace(access_string, "/", "_")
    local folderpath = ac.getFolder(ac.FolderID.ACDocuments) .. "/CMRT-Essential-HUD/"
    fast_storage_filepath = folderpath .. access_string .. "fast.lap"
    for i=0, sector_count-1 do
        sector_storage_filepaths[i] = folderpath .. access_string .. "s" .. (i+1) .. ".lap"
    end

    if io.dirExists(folderpath) == false then io.createDir(folderpath) end -- so when we save files we KNOW it WILL exist

    -- recover entire lap
    local fast_path_data = io.load(fast_storage_filepath, nil)
    if fast_path_data ~= nil then
        fastest_lap = stringify.binary.parse(fast_path_data)
    end

    -- recover sectors
    for i=0, sector_count-1 do
        local sector_data = io.load(sector_storage_filepaths[i], nil)
        if sector_data ~= nil then
            fastest_splits_real[i] = stringify.binary.parse(sector_data)
        end
    end

    --
    -- move old storage data to new kind and then delete it
    --
    local trackname = ac.getTrackFullID("|||")
    local carname = ac.getCarName(0)
    local access_string = trackname .. " - " .. carname
    local fast_lap_storage = ac.storage(access_string .. " :> fast lap", nil)
    local to_parse = fast_lap_storage:get()
    -- if old fast lap exists, move into the new one binary format then delete it
    if to_parse ~= nil then
        local to_convert = stringify.parse(to_parse)
        if to_convert ~= nil then
            fix_lap_arrays(to_convert)
            if io.fileExists(fast_storage_filepath) == false then save_fast_lap(to_convert) end
            if fastest_lap == nil then fastest_lap = to_convert end -- if we didn't have the data use the new one
            fast_lap_storage:set(nil) -- delete the new one
        end
    end
    
    for i=1, sector_count do
        local sector_storage = ac.storage(access_string .. " :> fast splits sector " .. i, nil)
        to_parse = sector_storage:get()
        if to_parse ~= nil then
            local to_convert = stringify.parse(to_parse)
            if to_convert ~= nil then
                fix_lap_arrays(to_convert)
                if io.fileExists(sector_storage_filepaths[i-1]) == false then save_sector_piece(to_convert, i-1) end -- convert to new format
                if fastest_splits_real[i] == nil then fastest_splits_real[i] = to_convert end -- if we didn't have the data use the new one
                sector_storage:set(nil) -- delete old storage
            end
        end
    end
end

function mod.on_game_close()
    if Deltabar_SaveOnClose then
        save_fast_lap(fastest_lap)

        for i=0, #fastest_splits_real do
            save_sector_piece(fastest_splits_real[i], i)
        end
    end
end

---comment
---@param lap Lap
local function finalize_lap(lap, car_index)
    local sim_info = ac.getSim()
    local car_info = ac.getCar(car_index)
    if car_info == nil then return end
    
    local lapdata_valid = true
    local previous_laptime = players.get_previous_laptime(car_index)
    if previous_laptime ~= nil and previous_laptime ~= 0 then
        lap.complete = true
        lap.laptime = previous_laptime
    end
    
    lap.timestamp = sim_info.timestamp
    
    -- some protections against definitely wrongly formed laps, to avoid saving improper laps (some are saved to file, we must avoid problems!)
    if lap.next_index <= 100 then lapdata_valid = false end -- too few points!
    if lap.offset[lap.next_index - 1] < 0.5 then lapdata_valid = false end -- the last point we have is from less than 50% of the lap? invalid!
    if car_index ~= 0 then
        -- we don't let other cars make stupid laps (because if you join a session and they are already on track
        -- we risk saving stupid data). It doesn't matter for the player because these stupid laps only happen
        -- when he starts from pitlane, so we don't need to check.
        if lap.splits[0] == 0 then lapdata_valid = false end -- we don't have some sector times? invalid. we might need to check more sectors but testing showed that the first is usually enough
        if lap.elapsed_seconds[0] > 1000 then lapdata_valid = false end -- the first recorded frame is at more than 1s of lap? we missed the ENTIRE first second? definitely a weird cut
    end
    
    -- save data we want to show on screen, THEN we can update laps
    if car_index == 0 then
        local laptime = 0
        if     barmode == Deltabar_Modes.PREVIOUS_LAP    then
            if previous_lap ~= nil then
                laptime = previous_lap.laptime
            end
        elseif barmode == Deltabar_Modes.SESSION_LAP     then
            if session_lap ~= nil then
                laptime = session_lap.laptime
            end
        elseif barmode == Deltabar_Modes.FASTEST_LAP     then
            if fastest_lap ~= nil then
                laptime = fastest_lap.laptime
            end
        elseif barmode == Deltabar_Modes.MULTIPLAYER_LAP then
            if multiplayer_lap ~= nil then
                laptime = multiplayer_lap.laptime
            end
        elseif barmode == Deltabar_Modes.SESSION_OPTIMAL then
            local sector_count = #players.get_sector_splits()
            for i=0, sector_count-1 do
                if session_splits_toshow[i] ~= nil then
                    laptime = laptime + session_splits_toshow[i].splits[i]
                end
            end
        elseif barmode == Deltabar_Modes.FASTEST_OPTIMAL then
            local sector_count = #players.get_sector_splits()
            for i=0, sector_count-1 do
                if fastest_splits_toshow[i] ~= nil then
                    laptime = laptime + fastest_splits_toshow[i].splits[i]
                end
            end
        end
        
        local show_per_sector = Deltabar_ShowSectorsPerMode[barmode]
        if show_per_sector == false then
            make_notification_new_lap(lap.lap_number, lap.laptime, lap.laptime - laptime, not lap.invalid)
        end
    
        -- player has completed a lap, update his data
        if lap.complete and lap.invalid == false and lapdata_valid then
            if fastest_lap == nil or lap.laptime < fastest_lap.laptime then
                fastest_lap = lap
                -- storage doesn't support tables, so we convert to string and parse when we load
                if Deltabar_SaveOnClose == false then
                    save_fast_lap(lap)
                end
            end
            if session_lap == nil or lap.laptime < session_lap.laptime then
                session_lap = lap
            end
        end
        if lap.complete then
            previous_lap = lap -- use it even if invalid, this is a consistency mode!
        end
    end
    
    -- someone completed a lap (player included), maybe he did a new best, save it
    if multiplayer_lap == nil or lap.laptime < multiplayer_lap.laptime then
        if lap.complete and lap.invalid == false and lapdata_valid then
            multiplayer_lap = lap
            if barmode == Deltabar_Modes.MULTIPLAYER_LAP then
                make_notification_new_record(lap.playername)
            end
        end
    end
end

-- we want the bar to be colored red when you're *actively loosing time*, meaning you go from -1.0 to -0.8, you're still in the green but loosing, so we draw it red!
local function delta_stripe_color(speed_delta)
    -- NOTE: Scale from 0.0 meters/sec = 1.0  to  5.0 meters/sec = 0.0
    local max_speed = 5.0
    local x = 1.0 - (math.min(math.abs(speed_delta), max_speed) / max_speed)
    local target_color = colors.LIGHT_GREEN
    if speed_delta < 0 then target_color = color_red end
    local color = settings.color_lerp(target_color, colors.WHITE, x)
    return color
end

local function update_bar_data(lap, pos, elapsed_seconds, speed_ms, min1, min2)
    local idx = lapmod.index_for_offset(lap, pos)
    if idx >= 0 then
        bardata.time_delta = elapsed_seconds - min1 - lap.elapsed_seconds[idx] + min2
        bardata.speed_delta = speed_ms - lap.speed_ms[idx]
        -- no need to check for nil because we create a new one just before this function gets called
        if all_players_laps[0].invalid then bardata.star = '*' else bardata.star = '' end
    end
end

local function update_sector(new_sector, pos, lap, car_index)
    local car_info = ac.getCar(car_index)
    if car_info == nil then return end
    local sector_time = car_info.previousSectorTime
    if new_sector == 0 then
        local last_splits, splits_count = players.get_last_splits(car_index)
        sector_time = last_splits[splits_count - 1]
    end
    if sector_time == nil then sector_time = 0 end
    
    local sector_number = new_sector - 1
    if sector_number == -1 then
        sector_number = #players.get_sector_splits()-1
    end
    
    lap.splits[sector_number] = sector_time -- record sector time
    
    local benchmark_sector_time = 0
    local lap_piece = nil
    if     barmode == Deltabar_Modes.FASTEST_LAP     and car_index == 0 then lap_piece = fastest_lap 
    elseif barmode == Deltabar_Modes.SESSION_LAP     and car_index == 0 then lap_piece = session_lap
    elseif barmode == Deltabar_Modes.FASTEST_OPTIMAL and car_index == 0 then lap_piece = fastest_splits_toshow[sector_number]
    elseif barmode == Deltabar_Modes.SESSION_OPTIMAL and car_index == 0 then lap_piece = session_splits_toshow[sector_number]
    elseif barmode == Deltabar_Modes.PREVIOUS_LAP    and car_index == 0 then lap_piece = previous_lap
    elseif barmode == Deltabar_Modes.MULTIPLAYER_LAP                    then lap_piece = multiplayer_lap
    end
    
    if lap_piece ~= nil then
        local idx = lapmod.index_for_offset(lap_piece, pos)
        if idx == -1 then
            benchmark_sector_time = lap_piece.elapsed_seconds[lap_piece.next_index-1]
        else
            benchmark_sector_time = lap_piece.elapsed_seconds[idx]
        end
        for i=0, sector_number-1 do
            benchmark_sector_time = benchmark_sector_time - lap_piece.splits[i]
        end
    end
    
    if benchmark_sector_time > 0 and car_index == 0 then
        local show_per_sector = Deltabar_ShowSectorsPerMode[barmode]
        if show_per_sector then
            make_notification_new_sector(sector_number, sector_time, sector_time - benchmark_sector_time, not lap.invalid_sectors[sector_number])
        end
    end
    
    -- do not check for fastest when invalid
    if car_index ~= 0 then return end -- the following modes are only for the player
    if lap.invalid_sectors[sector_number] then return end -- invalid sector, ignore the lap, if we don't we save to file an invalid lap!
    if sector_time <= 0 or sector_time == nil then return end -- safety check for session reset
    
    -- replace optimal times depending on how sectors went
    local fastest = fastest_splits_real
    if fastest[sector_number] == nil or fastest[sector_number].splits[sector_number] <= 0 or sector_time < fastest[sector_number].splits[sector_number] then
        fastest_splits_real[sector_number] = lap
        if Deltabar_SaveOnClose == false then
            save_sector_piece(lap, sector_number)
        end
    end
    
    local session = session_splits_real
    if session[sector_number] == nil or session[sector_number].splits[sector_number] <= 0 or sector_time < session[sector_number].splits[sector_number] then
        session_splits_real[sector_number] = lap
    end
end

local function check_sector(lap, current_lap, current_sector, pos, car_index)
    -- since each track has the finish line *not* at spline 0 we have
    -- to wait for it to get correct, it's only a couple of frames since the player
    -- is moving forward but who knows, so we stop everything until we're sure we can
    -- if current_sector ~= 0 and current_lap ~= lap.lap_number then return false end
    
    -- TAG: S3PopsOutOfNowere. It's happened that the first lap we don't get s1 and s2 but we do get s3
    -- This is easily checkable in North Wilkesboro.
    -- NOTE(cogno): at the start of the FIRST lap, AC does some fucked up shit, so it kind of
    -- screws all our data, but only for the first lap. Basically if you're in pitlane *before* the
    -- finish line, AC (correctly) tells you're on sector 3. If while you're moving through the
    -- pit lane you pass the finish line, AC doesn't count the new lap, it still says you
    -- are in the first lap and in the last sector.
    -- API(cogno): maybe if we keep track of sectors in our own way we avoid this problem? Since we
    -- already have our way to handle lapcount...
    if lapmod.is_next_offset_ok(lap, pos) and current_sector ~= all_players_old_sectors[car_index] then
        all_players_old_sectors[car_index] = current_sector
        update_sector(current_sector, pos, lap, car_index)
    end
    
    if lap.lap_number ~= current_lap then
        update_sector(0, pos, lap, car_index)
        all_players_old_sectors[car_index] = 0
        
        -- TAG: SectorsJumpsWhenImproved, we just finished a lap, we can finally show the real data
        for i=0, table.nkeys(session_splits_real)-1 do
            session_splits_toshow[i] = session_splits_real[i]
        end
        for i=0, table.nkeys(fastest_splits_real)-1 do
            fastest_splits_toshow[i] = fastest_splits_real[i]
        end
        
        return false -- just crossed the finish line, stop everything until we're sure we can go on
    end
    
    return true
end

local function update_lap_for_car(car_index)
    local sim_info = ac.getSim()
    local car_info = ac.getCar(car_index)
    if car_info == nil then return false end -- nothing we can do anyway
        
    local sectors = players.get_sector_splits()
    local sector_count = #sectors
    local spline = car_info.splinePosition
    local trackname = ac.getTrackName()
    
    local lap = all_players_laps[car_index]
    if lap == nil then
        if car_info.lapTimeMs <= 0 then return false end -- record once the clock is ticking
        if spline > sectors[0] + 0.01 then return false end -- we definitely haven't reached the start line yet
        lap = lapmod.init(trackname, sector_count, car_index)
    end
    
    local current_lapcount = players.get_lapcount(car_index)
    local current_sector = car_info.currentSector
    
    -- exceptional cases that we need to handle first
    if current_lapcount < lap.lap_number or sim_info.currentSessionIndex ~= last_session_index then
        -- lap number decreased or session changed
        last_session_index = sim_info.currentSessionIndex
        
        -- abandon the lap and start over
        if car_index == 0 then clear_screen_data(lap.invalid) end
        all_players_laps[car_index] = nil
        return false
    end
    
    local use_sector = check_sector(lap, current_lapcount, current_sector, spline, car_index)
    
    if lap.lap_number ~= current_lapcount then
        -- lap finished
        finalize_lap(lap, car_index)
        all_players_old_laps[car_index] = all_players_laps[car_index]
        all_players_laps[car_index] = nil
        if car_index == 0 then clear_screen_data(false) end -- lap valid, we are starting now!
        return false
    end
    
    -- # correct pos for Nordschleife tourist setup
    if ac.getTrackName() == "Nordschleife - Tourist" then
        spline = players.normalize_spline_for_nordschleife_turist(spline)
    end

    local laptime = car_info.lapTimeMs
    local speed = car_info.speedMs
    lapmod.add_info(lap, spline, laptime, speed)
    
    if car_info.wheelsOutside >= 3 then
        lap.invalid = true
        if use_sector then
            lap.invalid_sectors[current_sector] = true
        end
    end
    
    all_players_laps[car_index] = lap
    return true -- all good, we can finally draw something!
end

function mod.update()
    local sim_info = ac.getSim()
    if sim_info.isLive == false then return end
    
    local leaderboard = players.get_leaderboard()
    for i=0, #leaderboard-1 do
        local car_info = leaderboard[i].car
        local car_index = car_info.index
        update_lap_for_car(car_index)
        
        local car_current_sector = car_info.currentSector
        all_players_old_sectors[car_index] = car_current_sector
    end

    -- if player hasn't started a lap yet, we don't have the data to compare to a lap, so we can't draw anything anyway
    if all_players_laps[0] == nil then return end
    
    --
    -- main bar modes
    --
    local my_car_info = ac.getCar(0)
    if my_car_info == nil then return end -- shut up ide errors
    local spline = my_car_info.splinePosition
    local laptime = my_car_info.lapTimeMs
    local speed = my_car_info.speedMs
    local current_sector = my_car_info.currentSector
    if barmode == Deltabar_Modes.FASTEST_LAP then
        if fastest_lap ~= nil then
            update_bar_data(fastest_lap, spline, laptime, speed, 0, 0)
        else
            clear_screen_data(all_players_laps[0].invalid)
        end
    elseif barmode == Deltabar_Modes.SESSION_LAP then
        if session_lap ~= nil then
            update_bar_data(session_lap, spline, laptime, speed, 0, 0)
        else
            clear_screen_data(all_players_laps[0].invalid)
        end
    elseif barmode == Deltabar_Modes.MULTIPLAYER_LAP then
        if multiplayer_lap ~= nil then
            update_bar_data(multiplayer_lap, spline, laptime, speed, 0, 0)
        else
            clear_screen_data(all_players_laps[0].invalid)
        end
    elseif barmode == Deltabar_Modes.PREVIOUS_LAP then
        if previous_lap ~= nil then
            update_bar_data(previous_lap, spline, laptime, speed, 0, 0)
        else
            clear_screen_data(all_players_laps[0].invalid)
        end
    elseif barmode == Deltabar_Modes.FASTEST_OPTIMAL then
        -- draw anything only if we have the FULL data.
        local sector_count = #players.get_sector_splits()
        for i=0, sector_count - 1 do
            if fastest_splits_toshow[i] == nil then
                clear_screen_data(all_players_laps[0].invalid)
                return
            end
        end
        
        local fastest = fastest_splits_toshow[current_sector]
        local min1 = 0
        local min2 = 0
        for i=0, current_sector-1 do
            local sector_lap = fastest_splits_toshow[i]
            min1 = min1 + sector_lap.splits[i]
            min2 = min2 + fastest.splits[i]
        end
        update_bar_data(fastest, spline, laptime, speed, min1, min2)
    elseif barmode == Deltabar_Modes.SESSION_OPTIMAL then
        -- draw anything only if we have the FULL data.
        local sector_count = #players.get_sector_splits()
        for i=0, sector_count - 1 do
            if session_splits_toshow[i] == nil then
                clear_screen_data(all_players_laps[0].invalid)
                return
            end
        end

        local fastest = session_splits_toshow[current_sector]
        local min1 = 0
        local min2 = 0
        for i=0, current_sector-1 do
            local sector_lap = session_splits_toshow[i]
            min1 = min1 + sector_lap.splits[i]
            min2 = min2 + fastest.splits[i]
        end
        update_bar_data(fastest, spline, laptime, speed, min1, min2)
    end
end

local function get_delta_sign(delta, fontsize)
    ui.pushDWriteFont(fonts.archivo_black)
    local sizeof_plus = ui.measureDWriteText('+', fontsize)
    local sizeof_minus = ui.measureDWriteText('-', fontsize)
    ui.popDWriteFont()
    if delta >= 0 then
        return '+', sizeof_plus
    else
        return '-', sizeof_minus
    end
end

local function draw_pillola(corner_tl, size, color)
    local radius = size.y / 2
    local left_center = corner_tl + vec2(radius, radius)
    local right_center = corner_tl + vec2(size.x - radius, radius)
    
    ui.pathClear()
    ui.pathArcTo(left_center,  radius,  math.pi / 2, math.pi * 3 / 2, 12)
    ui.pathArcTo(right_center, radius, -math.pi / 2, math.pi / 2,     12)
    ui.pathFillConvex(color)
end

local function show_notification(notification, top_center_pos, bar_height, bar_dist)
    if notification == nil or notification.anim_time == nil then return end -- no notification to draw
    local small_fontsize = settings.fontsize(13) * DeltabarScale
    local top_text_spacing = 15 * DeltabarScale
    local elapsed = Time - notification.anim_time
    local open_close_duration = 0.2
    local movement_duration = 0.2
    local move_t = math.clamp(settings.remap(Time - movement_start_time, 0, movement_duration, 0, 1), 0, 1)
    local open_t = math.clamp(settings.remap(elapsed, movement_duration, movement_duration + open_close_duration, 0, 1), 0, 1)
    local close_t = math.clamp(settings.remap(elapsed, Deltabar_AnimDuration - open_close_duration, Deltabar_AnimDuration, 0, 1), 0, 1)
    if elapsed > Deltabar_AnimDuration then return end -- animation ended, no need to draw
    
    -- TODO(cogno): at some scales the notifications can get bigger than the app width, we should auto scale them down!
    local height = settings.remap(move_t, 0, 1, bar_height + bar_dist, 0)
    local top_center = top_center_pos + vec2(0, height)
    if notification.type == notification_types.new_sector then
        local best_sector_times = players.get_best_sector_times()
        local best_sector_time = best_sector_times[notification.sector_index]
        
        local sector_number_string = string.format("%d:", notification.sector_index + 1)
        local sector_time_string = lapmod.time_to_string(notification.sector_time)
        if notification.is_valid == false then sector_time_string = sector_time_string .. '*' end
        local sector_delta_string = lapmod.time_delta_to_string(notification.sector_delta)
        local sector_number_textsize = ui.measureDWriteText(sector_number_string, small_fontsize)
        local sector_time_textsize = ui.measureDWriteText(sector_time_string, small_fontsize)
        local sector_delta_textsize = ui.measureDWriteText(sector_delta_string, small_fontsize)
        local sector_delta_sign, sector_delta_sizeof_sign = get_delta_sign(notification.sector_delta, small_fontsize)
        sector_delta_textsize.x = sector_delta_textsize.x + sector_delta_sizeof_sign.x
        local top_size = bar_height + sector_number_textsize.x + sector_time_textsize.x + sector_delta_textsize.x + 2 * top_text_spacing
        
        local topbar_tl = top_center + vec2(-top_size / 2, 0)
        local width = settings.remap(open_t - close_t, 0, 1, 0, top_size)
        ui.pushClipRect(topbar_tl, topbar_tl + vec2(width, bar_height))
        draw_pillola(topbar_tl, vec2(top_size, bar_height), colors.BG)
        
        local sector_time_color = colors.WHITE
        local best_lap_splits = players.get_player_best_sector_times(0)
        local current_sector_time = best_lap_splits[notification.sector_index]
        if notification.is_valid then
            if current_sector_time ~= nil and current_sector_time > 0 and notification.sector_time <= current_sector_time then sector_time_color = colors.LIGHT_GREEN end
            if best_sector_time ~= nil and best_sector_time > 0 and notification.sector_time <= best_sector_time then sector_time_color = colors.PURPLE end
        end
        local sector_delta_color = colors.LIGHT_GREEN
        if notification.sector_delta >= 0 then sector_delta_color = color_red end
        
        local text_pos = topbar_tl + vec2(bar_height, bar_height - sector_number_textsize.y) / 2 
        ui.dwriteDrawText(sector_number_string, small_fontsize, text_pos, colors.TEXT_YELLOW)
        text_pos.x = text_pos.x + sector_number_textsize.x + top_text_spacing
        ui.dwriteDrawText(sector_time_string, small_fontsize, text_pos, sector_time_color)
        text_pos.x = text_pos.x + sector_time_textsize.x + top_text_spacing
        ui.pushDWriteFont(fonts.archivo_black)
        ui.dwriteDrawText(sector_delta_sign, small_fontsize, text_pos + vec2(0, sector_delta_textsize.y - sector_delta_sizeof_sign.y)/2, sector_delta_color)
        ui.popDWriteFont()
        ui.dwriteDrawText(sector_delta_string, small_fontsize, text_pos + vec2(sector_delta_sizeof_sign.x, 0), sector_delta_color)
        ui.popClipRect()
    elseif notification.type == notification_types.new_lap then
        local best_laptime = players.get_best_laptime()
        
        local lapcount_string = string.format("%d:", notification.lap_number + 1)
        local laptime_string = lapmod.time_to_string(notification.laptime)
        if notification.is_valid == false then laptime_string = laptime_string .. '*' end
        local lapdelta_string = lapmod.time_delta_to_string(notification.lap_delta)
        local lapcount_textsize = ui.measureDWriteText(lapcount_string, small_fontsize)
        local laptime_textsize = ui.measureDWriteText(laptime_string, small_fontsize)
        local lapdelta_textsize = ui.measureDWriteText(lapdelta_string, small_fontsize)
        local lapdelta_sign, lapdelta_sizeof_sign = get_delta_sign(notification.lap_delta, small_fontsize)
        lapdelta_textsize.x = lapdelta_textsize.x + lapdelta_sizeof_sign.x
        local top_size = bar_height + lapcount_textsize.x + laptime_textsize.x + lapdelta_textsize.x + 2 * top_text_spacing
        
        local topbar_tl = top_center + vec2(-top_size / 2, 0)
        local width = settings.remap(open_t - close_t, 0, 1, 0, top_size)
        ui.pushClipRect(topbar_tl, topbar_tl + vec2(width, bar_height))
        draw_pillola(topbar_tl, vec2(top_size, bar_height), colors.BG)
        
        local laptime_color = colors.WHITE
        local my_leaderboard_index = players.get_player_leaderboard_index()
        local player_best_laptime = players.get_car_best_laptime(my_leaderboard_index)
        if notification.is_valid then
            if player_best_laptime ~= nil and player_best_laptime > 0 and notification.laptime <= player_best_laptime then laptime_color = colors.LIGHT_GREEN end
            if best_laptime ~= nil and best_laptime > 0 and notification.laptime <= best_laptime then laptime_color = colors.PURPLE end
        end
        local lapdelta_color = colors.LIGHT_GREEN
        if notification.lap_delta >= 0 then lapdelta_color = color_red end
        
        local text_pos = topbar_tl + vec2(bar_height, bar_height - lapcount_textsize.y) / 2 
        ui.dwriteDrawText(lapcount_string, small_fontsize, text_pos, colors.TEXT_YELLOW)
        text_pos.x = text_pos.x + lapcount_textsize.x + top_text_spacing
        ui.dwriteDrawText(laptime_string, small_fontsize, text_pos, laptime_color)
        text_pos.x = text_pos.x + laptime_textsize.x + top_text_spacing
        ui.pushDWriteFont(fonts.archivo_black)
        ui.dwriteDrawText(lapdelta_sign, small_fontsize, text_pos + vec2(0, lapdelta_textsize.y - lapdelta_sizeof_sign.y)/2, lapdelta_color)
        ui.popDWriteFont()
        ui.dwriteDrawText(lapdelta_string, small_fontsize, text_pos + vec2(lapdelta_sizeof_sign.x, 0), lapdelta_color)
        ui.popClipRect()
    elseif notification.type == notification_types.new_record then
        ui.pushDWriteFont(fonts.archivo_bold)
        local name_text = notification.name
        local pre_text_size = ui.measureDWriteText("NEW BEST:", small_fontsize)
        local name_text_size = ui.measureDWriteText(name_text, small_fontsize)
        local inbetween_size = 10 * DeltabarScale
        local top_size = bar_height + pre_text_size.x + name_text_size.x + inbetween_size + 2 * top_text_spacing
        
        local topbar_tl = top_center + vec2(-top_size / 2, 0)
        local width = settings.remap(open_t - close_t, 0, 1, 0, top_size)
        ui.pushClipRect(topbar_tl, topbar_tl + vec2(width, bar_height))
        draw_pillola(topbar_tl, vec2(top_size, bar_height), colors.BG)
        
        local left_text_pos = topbar_tl + vec2(bar_height + top_text_spacing * 2, bar_height - pre_text_size.y) / 2 
        local right_text_pos = left_text_pos + vec2(inbetween_size + pre_text_size.x, 0)
        ui.dwriteDrawText("NEW BEST:", small_fontsize, left_text_pos, colors.TEXT_YELLOW)
        ui.dwriteDrawText(name_text, small_fontsize, right_text_pos, colors.WHITE)
        ui.popDWriteFont()
        
        ui.popClipRect()
    end
end

local on_show_animation_start = 0
local is_showing = true
local is_paused = false
function mod.on_open()
    if is_paused == false then
        on_show_animation_start = Time
        is_showing = true
    end
    is_paused = false
end

function mod.on_close()
    is_paused = ac.getSim().isPaused
    if is_paused == false then
        is_showing = false
    end
end

local function draw_notifications(extend_up, mouse_in_area, top_center, bar_height, bar_dists)
    if mouse_in_area == false then
        local p1 = top_center
        local p2 = top_center + vec2(0, bar_height + bar_dists)
        if extend_up == false then -- we want the notifications to go DOWN, swap them!
            p1 = top_center + vec2(0, bar_height + bar_dists)
            p2 = top_center
        end
        show_notification(notification2_info, p1, bar_height, bar_dists)
        show_notification(notification1_info, p2, bar_height, bar_dists)
    end
end

local function draw_deltabar_background(mouse_in_area, bar_tl, bar_length, bar_height)
    -- deltabar background and dots texture
    if Deltabar_Minimized == false or mouse_in_area then
        draw_pillola(bar_tl, vec2(bar_length, bar_height), colors.BG)
        ui.pushClipRect(bar_tl + vec2(bar_height / 2, 0), bar_tl + vec2(bar_length - bar_height / 2, bar_height))
        local bar_wanted_width = 280 * DeltabarScale
        local bar_wanted_height = 30 * DeltabarScale
        ui.drawImage(
            settings.get_asset("delta_dot"),
            bar_tl + vec2(bar_length / 2 - bar_wanted_width / 2, bar_height / 2 - bar_wanted_height / 2),
            bar_tl + vec2(bar_length / 2 + bar_wanted_width / 2, bar_height / 2 + bar_wanted_height / 2)
        )
        ui.popClipRect()
    end
end

local function draw_deltabar_foreground(mouse_in_area, bar_tl, bar_length, bar_height, time_delta, delta_width, delta_pad)
    if mouse_in_area == false and Deltabar_Minimized == false then
        -- deltabar moving bar with color (red to white to green)
        local bar_color = delta_stripe_color(bardata.speed_delta)
        local bar_top_center = bar_tl + vec2(bar_length / 2, 0)
        if time_delta < 0 then
            ui.pushClipRect(bar_top_center, bar_top_center + vec2(delta_width, bar_height))
        else
            ui.pushClipRect(bar_top_center + vec2(-delta_width, 0), bar_top_center + vec2(0, bar_height))
        end
        draw_pillola(bar_tl + delta_pad, vec2(bar_length, bar_height) - delta_pad * 2, bar_color)
        ui.popClipRect()
    end
end

local function draw_delta(lowbar_top_center, lowbar_width, lowbar_height, time_delta, delta_textsize, lowbar_sign, big_fontsize, lowbar_sizeof_sign, delta_text)
    local lowbar_tl = lowbar_top_center - vec2(lowbar_width/2, 0)
    local lowbar_center = lowbar_tl + vec2(lowbar_width, lowbar_height) / 2
    draw_pillola(lowbar_tl, vec2(lowbar_width, lowbar_height), colors.BG)
    
    local text_color = colors.LIGHT_GREEN
    if time_delta >= 0 then text_color = color_red end
    
    local lowbar_text_tl = lowbar_center - delta_textsize / 2
    ui.pushDWriteFont(fonts.archivo_black)
    ui.dwriteDrawText(lowbar_sign, big_fontsize, lowbar_text_tl + vec2(0, delta_textsize.y - lowbar_sizeof_sign.y)/2, text_color)
    ui.popDWriteFont()
    ui.dwriteDrawText(delta_text, big_fontsize, lowbar_text_tl + vec2(lowbar_sizeof_sign.x, 0), text_color)
end

function mod.main()
    local my_car_data = ac.getCar(0)
    if my_car_data == nil then return end -- SHUT UP IDE ERRORS
    local draw_top_left = vec2(0, 22)
    local draw_size = ui.windowSize() - vec2(0, 22)
    local draw_center = draw_top_left + draw_size / 2
    
    local deltabar_full_size = ui.windowSize()
    local deltabar_full_center = ui.windowSize() / 2
    players.play_intro_anim_setup(deltabar_full_center, deltabar_full_size, on_show_animation_start, is_showing)

    local arrow_width = 40 * DeltabarScale
    local arrow_spacing = 10 * DeltabarScale
    local bar_length = draw_size.x - arrow_width * 2 - arrow_spacing * 2
    local bar_height = 30 * DeltabarScale
    local lowbar_height = 38 * DeltabarScale
    local bar_dists = 5 * DeltabarScale
    local lowbar_dists = 3 * DeltabarScale
    local delta_pad = 2 * DeltabarScale
    local big_fontsize = settings.fontsize(20) * DeltabarScale
    local fontsize = settings.fontsize(16) * DeltabarScale
    local top_center = draw_center -vec2(0, draw_size.y / 2)
    local bar_tl = top_center + vec2(-bar_length / 2, 2 * (bar_height + bar_dists))
    local mouse_in_area = settings.is_inside(ui.mouseLocalPos(), draw_center, draw_size / 2)
    
    local notifications_top_center = top_center
    local notifications_extend_up = true
    if Deltabar_Position == 0 then
        -- deltabar on top of everything
        bar_tl = top_center + vec2(-bar_length / 2, 0)

        -- notifications go on the bottom and move DOWN
        notifications_top_center = top_center + vec2(0, bar_height + lowbar_height + bar_dists * 2)
        notifications_extend_up = false
    elseif Deltabar_Position == 1 then
        -- everything as normal (notification then bar then delta), nothing to do
    elseif Deltabar_Position == 2 then
        -- notifications still on top, nothing to change there

        -- deltabar bottom of everything
        bar_tl = top_center + vec2(-bar_length / 2, 2 * (bar_height + bar_dists) + bar_dists + lowbar_height)
    end
    local bar_top_center = bar_tl + vec2(bar_length / 2, 0)
    local bar_center = bar_tl + vec2(bar_length, bar_height) / 2

    local text_horizontal_pad = 10 * DeltabarScale
    ui.pushDWriteFont(fonts.opti_edgar)
    local time_delta = bardata.time_delta
    if time_delta == nil then
        draw_deltabar_background(mouse_in_area, bar_tl, bar_length, bar_height)
        if mouse_in_area == false then
            ui.pushDWriteFont(fonts.archivo_bold)
            ui.pushDWriteFont(fonts.opti_edgar)
            local star_size = ui.measureDWriteText('*', fontsize)
            ui.popDWriteFont()
            local no_time_text = "COMPLETE A CLEAN LAP"
            local no_time_textsize = ui.measureDWriteText(no_time_text, fontsize)
            local text_scale = 1
            local total_textsize = no_time_textsize.x + 2 * text_horizontal_pad
            if all_players_laps[0] ~= nil and all_players_laps[0].invalid then total_textsize = total_textsize + star_size.x end
            
            -- if text doesn't fit, scale it down!
            if total_textsize > bar_length then
                text_scale = bar_length / (total_textsize)
                -- also recalculate it's size (because the font scales in step, not smootly)
                no_time_textsize = ui.measureDWriteText(no_time_text, fontsize * text_scale)
            end
            
            local no_time_textpos = bar_center - no_time_textsize / 2
            if all_players_laps[0] ~= nil and all_players_laps[0].invalid then
                no_time_textpos = no_time_textpos - vec2(star_size.x * text_scale, 0) / 2
            end
            
            if Deltabar_Minimized == true then
                local micro_tl = bar_tl + vec2(bar_length - no_time_textsize.x - star_size.x - 2 * text_horizontal_pad, 0) / 2
                draw_pillola(micro_tl, vec2((no_time_textsize.x + star_size.x + 2 * text_horizontal_pad), bar_height), colors.BG)
            end
            ui.dwriteDrawText(no_time_text, fontsize * text_scale, no_time_textpos, colors.WHITE)
            if all_players_laps[0] ~= nil and all_players_laps[0].invalid then
                ui.pushDWriteFont(fonts.opti_edgar)
                ui.dwriteDrawText('*', fontsize * text_scale, no_time_textpos + vec2(no_time_textsize.x, -4 * DeltabarScale), colors.WHITE)
                ui.popDWriteFont()
            end
            
            ui.popDWriteFont()
        end
    else
        local time_delta_s = time_delta / 1000
        local delta_text = string.format("%s%s", lapmod.time_delta_to_string(time_delta), bardata.star)
        local delta_textsize = ui.measureDWriteText(delta_text, big_fontsize)
        local lowbar_sign, lowbar_sizeof_sign = get_delta_sign(time_delta, big_fontsize)
        delta_textsize.x = delta_textsize.x + lowbar_sizeof_sign.x
        local lowbar_width = lowbar_height + delta_textsize.x
        local center_lowbar = false
        if lowbar_width > bar_length then center_lowbar = true end
        
        local delta_bar_half_width = (bar_length - delta_pad * 2) / 2
        local delta_width = math.clamp(settings.remap(math.abs(time_delta_s), 0, 2, 0, delta_bar_half_width), 0, delta_bar_half_width)
        local bar_endpos = bar_top_center.x - delta_width
        if time_delta < 0 then bar_endpos = bar_top_center.x + delta_width end
        
        local lowbar_top_center = vec2(bar_endpos, bar_top_center.y) + vec2(0, bar_height + lowbar_dists)
        if center_lowbar then lowbar_top_center = bar_top_center + vec2(0, bar_height + lowbar_dists) end
        if Deltabar_Minimized and mouse_in_area == false then
            lowbar_top_center = bar_center - vec2(0, lowbar_height / 2 - lowbar_dists)
        end
        if center_lowbar == false then lowbar_top_center.x = math.clamp(lowbar_top_center.x, bar_top_center.x - bar_length / 2 + lowbar_width / 2, bar_top_center.x + bar_length / 2 - lowbar_width / 2) end
        
        if Deltabar_Position == 0 then
            -- delta goes second
            lowbar_top_center.y = top_center.y + bar_height + bar_dists
        elseif Deltabar_Position == 1 then
            -- everything as normal (notification then bar then delta), nothing to do
        elseif Deltabar_Position == 2 then
            -- notifications still on top, nothing to change there
            -- delta in the middle
            lowbar_top_center.y = top_center.y + 2 * (bar_height + bar_dists)
        end

        draw_notifications(notifications_extend_up, mouse_in_area, notifications_top_center, bar_height, bar_dists)
        draw_deltabar_background(mouse_in_area, bar_tl, bar_length, bar_height)
        draw_deltabar_foreground(mouse_in_area, bar_tl, bar_length, bar_height, time_delta, delta_width, delta_pad)
        draw_delta(lowbar_top_center, lowbar_width, lowbar_height, time_delta, delta_textsize, lowbar_sign, big_fontsize, lowbar_sizeof_sign, delta_text)
    end
    if mouse_in_area then
        ui.pushDWriteFont(fonts.archivo_bold)
        local button_bg_size = vec2(arrow_width, bar_height)
        local left_button_tl = bar_tl - vec2(arrow_spacing + arrow_width, 0)
        local right_button_tl = bar_tl + vec2(arrow_spacing + bar_length, 0)
        
        local left_arrow_color = colors.BG
        local right_arrow_color = colors.BG
        if settings.is_inside(ui.mouseLocalPos(), left_button_tl + button_bg_size / 2, button_bg_size / 2) then
            left_arrow_color = colors.LIGHT_BG
            if ui.mouseDown(ui.MouseButton.Left) then
                left_arrow_color = colors.DARK_BG
            end
        end
        if settings.is_inside(ui.mouseLocalPos(), right_button_tl + button_bg_size / 2, button_bg_size / 2) then
            right_arrow_color = colors.LIGHT_BG
            if ui.mouseDown(ui.MouseButton.Left) then
                right_arrow_color = colors.DARK_BG
            end
        end
        
        draw_pillola(left_button_tl, button_bg_size, left_arrow_color)
        draw_pillola(right_button_tl, button_bg_size, right_arrow_color)
        local arrow_pad = 7 * DeltabarScale
        local arrow_path = settings.get_asset("arrow")
        local corner_offset_tl = vec2(17, 0) * DeltabarScale
        local corner_offset_tr = vec2(9, 0) * DeltabarScale
        ui.drawImage(
            arrow_path,
            left_button_tl + arrow_pad + corner_offset_tl,
            left_button_tl + arrow_pad + corner_offset_tl + vec2(-14, 20) * 0.8 * DeltabarScale
        )
        ui.drawImage(
            arrow_path,
            right_button_tl + arrow_pad + corner_offset_tr,
            right_button_tl + arrow_pad + corner_offset_tr + vec2(14, 20) * 0.8 * DeltabarScale
        )
        
        local modescount = table.nkeys(Deltabar_Modes)
        if ui.mouseClicked(ui.MouseButton.Left) then
            if settings.is_inside(ui.mouseLocalPos(), left_button_tl + button_bg_size / 2, button_bg_size / 2) then
                -- clicked on left button
                barmode = barmode - 1
                if barmode < 0 then barmode = modescount - 1 end
            end
            if settings.is_inside(ui.mouseLocalPos(), right_button_tl + button_bg_size / 2, button_bg_size / 2) then
                -- clicked on right button
                barmode = (barmode + 1) % modescount
            end
            if last_bar_mode_storage ~= nil then last_bar_mode_storage:set(barmode) end -- save for next time we open the game
        end
        
        local barmode_text = "UNKN BAR MODE"
        if barmode == Deltabar_Modes.FASTEST_LAP then barmode_text = "RECORD  BEST" end
        if barmode == Deltabar_Modes.SESSION_LAP then barmode_text = "SESSION  BEST" end
        if barmode == Deltabar_Modes.FASTEST_OPTIMAL then barmode_text = "RECORD  OPTIMAL" end
        if barmode == Deltabar_Modes.SESSION_OPTIMAL then barmode_text = "SESSION  OPTIMAL" end
        if barmode == Deltabar_Modes.MULTIPLAYER_LAP then barmode_text = "SESSION  RECORD" end
        if barmode == Deltabar_Modes.PREVIOUS_LAP    then barmode_text = "PREVIOUS  LAP" end
        local barmode_textsize = ui.measureDWriteText(barmode_text, fontsize)
        local total_textsize = barmode_textsize.x + text_horizontal_pad * 2
        local text_scale = 1
        if total_textsize > bar_length then
            text_scale = bar_length / (total_textsize)
        end
        local barmode_text_tl = bar_center - barmode_textsize * text_scale / 2
        ui.dwriteDrawText(barmode_text, fontsize * text_scale, barmode_text_tl, colors.WHITE)
        
        local dotsize = 5 * DeltabarScale
        local dotspace = 5 * DeltabarScale
        local dot_height = 6 * DeltabarScale
        local dot_tl = bar_top_center - vec2((dotsize + dotspace) * (modescount - 1) / 2, dot_height)
        if Deltabar_Position == 2 then dot_tl.y = dot_tl.y + bar_height + bar_dists + dot_height end
        for i=0, modescount-1 do
            local dotpos = dot_tl + vec2(dotsize + dotspace, 0) * i
            local dot_color = colors.BG
            if barmode == i then dot_color = colors.WHITE end
            ui.drawCircleFilled(dotpos, dotsize / 2, dot_color)
        end
        
        ui.popDWriteFont()
    end
    ui.popDWriteFont()
    players.play_intro_anim(deltabar_full_center, deltabar_full_size, on_show_animation_start, DeltabarScale)
    settings.lock_app(deltabar_full_center, deltabar_full_size, APPNAMES.deltabar, DeltabarScale)
    
    -- because we auto resize orizontally we let the user control it (sometimes)
    -- NOTE(cogno): due to a bug in csp, if you resize from the corner ui.windowResizing() correctly returns true,
    -- but by resizing using borders ui.windowResizing() INCORRECTLY returns false, so we approximate that
    -- by checking if mouse_down and near the window (as in at most 10px away)
    local area_half_size = draw_size / 2 + vec2(20, 40)
    local interacting_near_window = ui.mouseDown(ui.MouseButton.Left) and settings.is_inside(ui.mouseLocalPos(), draw_center, area_half_size)
    local deltabar_size = vec2(ui.windowWidth(), lowbar_height + bar_height * 3 + bar_dists * 3)
    if ui.windowResizing() == false and interacting_near_window == false then
        settings.auto_scale_window(deltabar_size, APPNAMES.deltabar)
    end
    settings.auto_place_once(deltabar_size, APPNAMES.deltabar)

    -- DEBUG(cogno): area visualization
    -- ui.drawRect(draw_top_left, draw_top_left + draw_size, colors.WHITE)
end

return mod -- expose functions to the outside