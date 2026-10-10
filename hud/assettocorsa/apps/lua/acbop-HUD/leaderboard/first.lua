local module = {}

local settings = require('common.settings')
local fonts = settings.fonts
local colors = settings.colors

local lap = require("leaderboard.lap")
local players = require('common.players')
local deltabar = require('leaderboard.recorder')
local deltabar_lap = require('leaderboard.lap')
local acbop = require('common.acbop')

---@param position integer
---@param pos_diff integer
---@param interval string
---@param sector_times integer[]
---@param last_lap_sector_times integer[]
---@param car_index integer
---@return table
local function make_info(position, pos_diff, interval, sector_times, last_lap_sector_times, car_index, leaderboard_index)
    local out = {
        position=position,
        pos_diff=pos_diff,
        car_index=car_index,
        leaderboard_index=leaderboard_index,
        interval=interval
    }
    
    if sector_times ~= nil then
        if #sector_times == 0 then
            out.sector_times = last_lap_sector_times
        else
            out.sector_times = sector_times
        end
    end
    
    return out
end

local max_people = 6
local to_draw = table.new(max_people, 0) -- we keep this sorted
local positions_when_session_started = table.new(0, 10) -- if there's more people it's not a problem, it resizes automatically. We just don't expect more than 10 in general *except rare cases*
local positions_when_race_started = table.new(0, 10) -- if there's more people it's not a problem, it resizes automatically. We just don't expect more than 10 in general *except rare cases*
local interval_to_each_player = table.new(40, 0) -- the interval the player has to this player (and himself (aka '-'), for simplicity)

local animation_times_per_player = table.new(40, 0)
local player_lapcount_tracker = table.new(40, 0)
local show_overtime = false

local last_refresh_counter = -100 -- force the first update
local notification_timer = 40 -- in seconds
local show_leader_final_lap = false

local show_banner = true
local is_showing_banner = false
local animation_start_time = 0
local green_flag_banner_show_time = 5
local old_flag_state = nil
local old_flag_time = 0 -- when we started to track the old flag so we can change only when we are sure we can
local real_flag_background = colors.BG
local real_flag_text = nil

local long_names_scroll_timers = table.new(50, 0) ---@type table<number, number?>


local function make_racepos_info(racepos)
    return {
        start_racepos = racepos,
        current_racepos = racepos,
        update_time = Time + notification_timer
    }
end

function module.on_session_start()
    table.clear(long_names_scroll_timers)
    table.clear(positions_when_session_started)
    table.clear(positions_when_race_started)
    table.clear(animation_times_per_player)
    table.clear(player_lapcount_tracker)
    table.clear(to_draw)
    table.clear(interval_to_each_player)
    show_leader_final_lap = false
end

function module.init()end

local function estimate_interval_number(speed, spline_diff, negative_sign)
    local sim_info = ac.getSim()
    local track_length = sim_info.trackLengthM
    local speedclamp = 18 -- in m/s, aka 65 kmh
    local distance_to_make = spline_diff * track_length
    if math.abs(speed) < speedclamp then speed = speedclamp * math.sign(speed) end
    if negative_sign then speed = speed * -1 end
    return 1000 * distance_to_make / speed
end

local function estimate_interval(speed, spline_diff, negative_sign)
    return lap.time_delta_to_string(estimate_interval_number(speed, spline_diff, negative_sign))
end

local function get_interval(front_pos, front_lapdata, front_spline, front_speed, front_leaderboard_index, back_pos, back_lapdata, back_spline, back_speed, back_leaderboard_index, negative_sign)
    -- it should always be > 0 but it can get < 0 if in a race start one person
    -- is behind the finish line and the other in front, I know it sucks but for
    -- the game they are in the same lap but one is at < 10% of the track and the other at > 90%
    local spline_diff = front_pos - back_pos
    if spline_diff < 0 then spline_diff = spline_diff + 1 end
    
    -- if there's more than 1 lap of difference count the number of laps, this gets priority over other methods
    if spline_diff > 1 then
        local sign = '+'
        if negative_sign then sign = '-' end
        return string.format("L %s%d", sign, math.floor(spline_diff))
    end
    
    -- when one of them surpasses the other the leaderboard doesn't instantly change... sigh...
    -- at least if they are too close we can just estimate using their velocity
    local back_car_index = players.get_leaderboard()[back_leaderboard_index].car.index
    local front_car_index = players.get_leaderboard()[front_leaderboard_index].car.index
    local back_car_worldpos = ac.getCar(back_car_index).position
    local front_car_worldpos = ac.getCar(front_car_index).position
    local back_pos_v2  = vec2(back_car_worldpos.x, back_car_worldpos.z)
    local front_pos_v2 = vec2(front_car_worldpos.x, front_car_worldpos.z)
    local car_dist = (front_pos_v2 - back_pos_v2):length()
    if car_dist <= 20 then
        if front_spline < 0.5 and back_spline > 0.5 then
            -- front person crossed the finish line and back person didn't
            local time_to_finish_line = estimate_interval_number(back_speed, 1 - back_spline, negative_sign)
            local time_from_finish_line = estimate_interval_number(back_speed, front_spline, negative_sign)
            return lap.time_delta_to_string(time_to_finish_line + time_from_finish_line)
        end
        
        if back_pos > front_pos then spline_diff = 1 - spline_diff end
        return estimate_interval(back_speed, spline_diff, negative_sign)
    end
    
    -- if we don't have lap data, estimate
    if back_lapdata == nil or front_lapdata == nil then
        return estimate_interval(back_speed, spline_diff, negative_sign)
    end
    
    -- we have both lap data, maybe we can calculate precisely?
    -- first, using the lap furthest on, check how much the back person has to recover
    local back_idx = deltabar_lap.index_for_offset(front_lapdata, back_spline)
    if back_idx < 0 then -- if we have no data we can only estimate
        return estimate_interval(back_speed, spline_diff, negative_sign)
    end
    
    if back_idx == front_lapdata.next_index - 1 then
        -- either the front player teleported, meaning we have a hole in the data,
        -- or they are SO close they are basically touching.
        -- run an estimate, so we don't show '+0.0s' by mystake
        return estimate_interval(back_speed, spline_diff, negative_sign)
    end

    -- time of person in front is the latest entry (technically currentLapTime),
    -- time of person in back is how much time the front person had when he was behind
    -- the difference is how much time the person in front took to make the given distance
    -- aka how much you need to recover to surpass him, aka the time we are looking for
    local time_of_front_person = front_lapdata.elapsed_seconds[front_lapdata.next_index - 1]
    local time_of_back_person  = front_lapdata.elapsed_seconds[back_idx]

    -- if they are in the same lap, their interval is just the difference between their times
    if back_spline <= front_spline then
        if negative_sign then
            return lap.time_delta_to_string(time_of_back_person - time_of_front_person)
        else
            return lap.time_delta_to_string(time_of_front_person - time_of_back_person)
        end
    end
    
    -- since the back person has yet to cross the finish line (while the person in front already has),
    -- the total interval time between them is how much it takes the back person to cross the finish line
    -- plus the current lap time of the person who already crossed it
    -- the second one is trivial to get, but we have to estimate the first one.
    -- to estimate it we check the time the player took in his last lap.
    local back_person_last_lap = deltabar.get_player_previous_lap_data(back_car_index)
    if back_person_last_lap == nil then
        -- no data on last lap, nothing to do, we must estimate
        -- at least we can improve the estimate, we don't need the full distance between them,
        -- just up to the finish line
        local time_to_finish_line = estimate_interval_number(back_speed, 1 - back_spline, negative_sign)
        return lap.time_delta_to_string(time_to_finish_line + time_of_front_person)
    end
    
    -- back person has a lap, use that to estimate
    local back_last_lap_idx = deltabar_lap.index_for_offset(back_person_last_lap, back_spline)
    if back_last_lap_idx < 0 then
        -- still not good enough, run the estimate
        local time_to_finish_line = estimate_interval_number(back_speed, 1 - back_spline, negative_sign)
        return lap.time_delta_to_string(time_to_finish_line + time_of_front_person)
    end
    
    local time_to_reach_this_point_in_last_lap = back_person_last_lap.elapsed_seconds[back_last_lap_idx]
    local time_of_last_lap = back_person_last_lap.elapsed_seconds[back_person_last_lap.next_index-1]
    local time_to_finish_line = time_of_last_lap - time_to_reach_this_point_in_last_lap
    local interval_numb = time_to_finish_line + time_of_front_person
    if negative_sign then interval_numb = interval_numb * -1 end
    return lap.time_delta_to_string(interval_numb)
end

local function update_info(racepos_to_draw, draw_index)
    local session = players.get_current_session()
    local leaderboard = players.get_leaderboard()
    local leaderboard_index = racepos_to_draw - 1
    local leaderboard_info = leaderboard[leaderboard_index]
    if leaderboard_info == nil then return false end -- if we're outiside of the leaderboard we can't do anything
    
    -- in prac/qual we don't draw people offline UNLESS they have a leaderboard time
    -- in race we still draw them (they will have OFF in their data, since they are offline, that's ok!)
    local car_info = leaderboard_info.car
    if session.type == ac.SessionType.Practice or session.type == ac.SessionType.Qualify then
        local person_best_laptime = players.get_car_best_laptime(leaderboard_index)
        local is_valid = car_info.isConnected or (person_best_laptime ~= nil and person_best_laptime > 0)
        if is_valid == false then return false end
    end
    
    -- he's still connecting, ignore him. ALSO some servers have fake people connecting and disconnecting,
    -- we MUST ignore them, if we don't the leaderboard flickers every other frame!
    local drivername = ac.getDriverName(car_info.index)
    if drivername == nil or drivername == '' then return false end -- ignore data we don't have!
    
    -- get it's initial position so we can draw the up/down green/red arrow
    local position_info = positions_when_session_started[car_info.index]
    if car_info.isRaceFinished then position_info = positions_when_race_started[car_info.index] end
    local started_at = position_info.start_racepos
    
    local interval = interval_to_each_player[car_info.index]
    local pos_diff = started_at - racepos_to_draw
    local sector_times = car_info.currentSplits
    local last_sector_times, last_sector_count = players.get_last_splits(car_info.index)
    to_draw[draw_index] = make_info(racepos_to_draw, pos_diff, interval, sector_times, last_sector_times, car_info.index, leaderboard_index)
    return true
end

local on_show_animation_start = 0
local is_showing = true
local is_paused = false
function module.on_open()
    if is_paused == false then
        on_show_animation_start = Time
        is_showing = true
    end
    is_paused = false
end

function module.on_close()
    is_paused = ac.getSim().isPaused
    if is_paused == false then
        is_showing = false
    end
end

function module.update()
    local leaderboard = players.get_leaderboard()
    -- find your entry in the leaderboard
    local my_leaderboard_index = players.get_player_leaderboard_index()
    
    local session = players.get_current_session()
    local sim_info = ac.getSim()
    local race_started = true
    if session.type == ac.SessionType.Race and sim_info.raceFlagType == ac.FlagType.None then
        -- race hasn't started yet
        race_started = false
    end
    
    for i=0, #leaderboard-1 do
        local car_data = leaderboard[i].car
        local car_index = car_data.index
        local position_info = positions_when_session_started[car_index]
        local car_racepos = i + 1 --players.get_racepos(i)
        if position_info == nil then
            position_info = make_racepos_info(car_racepos)
        end
        
        if car_racepos ~= position_info.current_racepos then
            position_info.update_time = Time + notification_timer
            position_info.current_racepos = car_racepos
        end
        
        if position_info.update_time <= Time then
            position_info = make_racepos_info(car_racepos)
        end
        
        -- forcefully save it's position if the race is started, but also if we've connected AFTER the race start
        if race_started == false or positions_when_race_started[car_index] == nil then
            position_info = make_racepos_info(car_racepos)
            positions_when_race_started[car_index] = make_racepos_info(car_racepos)
        end
        
        positions_when_session_started[car_index] = position_info
    end
    
    -- animation controller
    for i=0, #leaderboard-1 do
        local car_index = leaderboard[i].car.index
        local player_lapcount = players.get_lapcount(car_index)
        
        if player_lapcount_tracker[car_index] == nil then player_lapcount_tracker[car_index] = 0 end
        if animation_times_per_player[car_index] == nil then animation_times_per_player[car_index] = 0 end
        
        if player_lapcount_tracker[car_index] ~= player_lapcount and leaderboard[i].car.isLastLapValid then
            -- player finished a lap, start his animation, worst case we don't draw the gradient anyway
            animation_times_per_player[car_index] = Time
        end
        
        -- the fucking special case of the special case of the special case this is yuck
        if i == 0 then
            if session.type == ac.SessionType.Race and session.isTimedRace then
                if session.hasAdditionalLap and session.overtimeMs > 0 then
                    if player_lapcount_tracker[car_index] ~= player_lapcount then
                        show_leader_final_lap = true
                    end
                end
            end
        end
        
        player_lapcount_tracker[car_index] = player_lapcount
    end
    
    -- calculate intervals to each car, updated as player wants
    local refresh_counter = math.floor(Time * 1000 / Leaderboard_RefreshRate)
    if refresh_counter ~= last_refresh_counter or interval_to_each_player[0] == nil or interval_to_each_player[0] == ''  then
        last_refresh_counter = refresh_counter
        local player_lapcount = players.get_lapcount(0)
        local player_spline = ac.getCar(0).splinePosition
        local player_pos = player_lapcount + player_spline
        local player_current_lap_data = deltabar.get_player_current_lap_data(0)
        local player_speed = ac.getCar(0).speedMs
        
        for i=0, #leaderboard-1 do
            local car_info = leaderboard[i].car
            local car_index = car_info.index
            local driver_lapcount = players.get_lapcount(car_index)
            local driver_spline = car_info.splinePosition
            local driver_pos = driver_lapcount + driver_spline
            local driver_current_lap_data = deltabar.get_player_current_lap_data(car_index)
            
            -- player never has an interval
            -- and also we don't show it until the race is ACTUALLY started
            -- and if the race is finished we don't update it anymore, so you can see how far away you where when it ended
            local race_finished = car_info.isRaceFinished
            if not session.isTimedRace then -- timed races are harder to handle because of the lap they have to finish, so I'll just ignore them for now...
                race_finished = race_finished or player_lapcount >= session.laps
            end
            if not race_finished then
                local interval = ''
                if car_index == 0 or (session.type == ac.SessionType.Race and sim_info.raceFlagType == ac.FlagType.None) then
                    interval = '-'
                else
                    local driver_speed = car_info.speedMs
                    if i < my_leaderboard_index then
                        -- player is behind
                        interval = get_interval(
                            driver_pos, driver_current_lap_data, driver_spline, driver_speed, i,
                            player_pos, player_current_lap_data, player_spline, player_speed, my_leaderboard_index,
                            false
                        )
                    elseif i > my_leaderboard_index then
                        -- player is in front
                        interval = get_interval(
                            player_pos, player_current_lap_data, player_spline, player_speed, i,
                            driver_pos, driver_current_lap_data, driver_spline, driver_speed, my_leaderboard_index,
                            true
                        )
                    end
                end
                
                interval_to_each_player[car_index] = interval
            end
        end
    end
    
    table.clear(to_draw)
    local car_count = #leaderboard
    local draw_index = 0
    if car_count <= 6 then
        -- we have enough space to draw all of them ALWAYS
        for i=0, car_count-1 do
            local added = update_info(i+1, draw_index)
            if added then draw_index = draw_index + 1 end
        end
    else
        -- first of all, calculate how many people are valid BEFORE the player and how many are valid AFTER the player
        local valid_people_before_player = 0
        local valid_people_after_player = 0
        for i=0, #leaderboard-1 do
            local is_valid = true
            if leaderboard[i] ~= nil then
                -- COPYPASTE(cogno): from update_info(...)
                local driver_name = ac.getDriverName(leaderboard[i].car.index)
                local name_valid = driver_name ~= nil and driver_name ~= ''
                if name_valid == false then is_valid = false end
                
                if session.type == ac.SessionType.Practice or session.type == ac.SessionType.Qualify then
                    local person_best_laptime = players.get_car_best_laptime(i)
                    local is_to_draw = leaderboard[i].car.isConnected or (person_best_laptime ~= nil and person_best_laptime > 0)
                    if is_to_draw == false then is_valid = false end
                end
                
                if is_valid then
                    if i < my_leaderboard_index then
                        valid_people_before_player = valid_people_before_player + 1
                    end
                    if i > my_leaderboard_index then
                        valid_people_after_player = valid_people_after_player + 1
                    end
                    -- ignore the player, aka i == my_leaderboard_index
                end
            end
        end
        
        if valid_people_before_player + valid_people_after_player <= 5 then -- plus the player 6
            -- simple case, there are at most 6 valid people TOTAL, just draw them all!
            for i=0, #leaderboard-1 do
                local added = update_info(i+1, draw_index)
                if added then draw_index = draw_index + 1 end
            end
        else
            -- complex case, we have more than 6 (valid) people to draw, we must balance between how many to draw before and after the player
            
            -- if before the player we can't draw anything, then the player is the first, duh
            local player_first = valid_people_before_player == 0
            
            -- now, how many do we draw before/after the spot of the player?
            if player_first then
                -- if the player is first, then we know we should draw 5 persons after him, just do that!
                local valids_added = 0
                for i=my_leaderboard_index, #leaderboard-1 do
                    if valids_added < 6 then
                        local added = update_info(i+1, draw_index)
                        if added then
                            draw_index = draw_index + 1
                            valids_added = valids_added + 1
                        end
                    end
                end
            else
                -- the first is NOT the player, how much do we split?
                local people_we_can_draw_before = 2
                local people_we_can_draw_after  = 2
                if valid_people_before_player == 1 then people_we_can_draw_after  = 4 people_we_can_draw_before = 0 end -- leader + 0 + player + 4 = 6
                if valid_people_before_player == 2 then people_we_can_draw_after  = 3 people_we_can_draw_before = 1 end -- leader + 1 + player + 3 = 6
                if valid_people_after_player  == 0 then people_we_can_draw_before = 4 people_we_can_draw_after  = 0 end -- leader + 4 + player + 0 = 6
                if valid_people_after_player  == 1 then people_we_can_draw_before = 3 people_we_can_draw_after  = 1 end -- leader + 3 + player + 1 = 6
                
                -- now just draw them!
                -- first the leader
                local index_of_leader = -1
                for i=0, my_leaderboard_index-1 do
                    local added = update_info(i+1, draw_index)
                    if added then
                        index_of_leader = i
                        draw_index = draw_index + 1
                        break
                    end
                end

                -- draw people before me
                local valids_added = 0
                for i=my_leaderboard_index-1, index_of_leader+1, -1 do
                    if valids_added < people_we_can_draw_before then
                        local added = update_info(i+1, draw_index)
                        if added then
                            draw_index = draw_index + 1
                            valids_added = valids_added + 1
                        end
                    end
                end
                
                -- now that we've added them reverse their order so they are drawn correctly
                for i=1, math.floor(valids_added / 2) do
                    local tmp = table.clone(to_draw[i], true)
                    to_draw[i] = table.clone(to_draw[valids_added - i + 1], true)
                    to_draw[valids_added - i + 1] = tmp
                end
                
                -- draw me
                update_info(my_leaderboard_index+1, draw_index)
                draw_index = draw_index + 1 -- we surely add ourselves right?
                
                -- draw people after me
                local valids_added = 0
                for i=my_leaderboard_index+1, #leaderboard-1 do
                    if valids_added < people_we_can_draw_after then
                        local added = update_info(i+1, draw_index)
                        if added then
                            draw_index = draw_index + 1
                            valids_added = valids_added + 1
                        end
                    end
                end
            end
        end
    end
end

local function reduce_jitter(old_width)
    -- since time text changes a lot, using it to set elements will 
    -- make them vibrate a lot, so we set it inside a little extra space, but
    -- you can't just add a value, it will still vibrate!
    return math.ceil(old_width / 10) * 10
end

local function maybe_start_banner_animation(flag_state)
    -- if we immediately change we might need to go back the next frame, since it jumps back
    -- and forth too much we actually wait to be sure, about 100ms of the same flag with no interruption
    local changed = false
    if old_flag_state == nil or (old_flag_state == flag_state and old_flag_time + 0.1 <= Time) then
        changed = true
    end
    
    if old_flag_state == nil or old_flag_state ~= flag_state or old_flag_time == 0 then
        old_flag_time = Time
        old_flag_state = flag_state
    end
    return changed
end

local function convert_temp(temp_celsius)
    if Leaderboard_ShowFah then
        return string.format("%d° F", 32 + (temp_celsius * 9 / 5))
    else
        return string.format("%d° C", temp_celsius)
    end
end

function module.main()
    local draw_top_left = vec2(0, 22)
    local draw_size = ui.windowSize() - vec2(0, 22)
    local draw_center = draw_top_left + draw_size / 2
    local sim_info = ac.getSim()
    local session = players.get_current_session()
    local leaderboard = players.get_leaderboard()
    local normal_fontsize = settings.fontsize(10) * LeaderboardScale
    
    -- we have automatic scaling / positioning of some elements, here the are:
    -- > we calculate lap text so we can position correctly.
    --   we want the L to be aligned one after the other vertically, so we want:
    --   L 2
    --   L 8
    --   but also
    --   L   7 <- notice the extra whitespaces
    --   L 132
    -- > we calculate the width of intervals so we can center them correctly
    -- > in practice we show the gap between peoples best time and first person's best times,
    --   since that changes sizes we need to know it
    -- > in practice we show the best time, that takes space
    -- > if enabled we show the tyre compound (short name), we need to consider that also for spacing!
    local line_count = table.nkeys(to_draw)
    local longest_number_width = 0
    local lapcount_font = fonts.archivo_medium
    local nametext_font = fonts.archivo_bold
    local longest_gap_width  = 35 * LeaderboardScale -- NOT RANDOM: if there's nothing to draw we have some default space so they don't overlap
    local longest_best_width = 55 * LeaderboardScale -- NOT RANDOM: if there's nothing to draw we have some default space so they don't overlap
    local longest_compound_shortname = 0
    local longest_bop_width = 0
    ui.pushDWriteFont(lapcount_font)
    local best_of_first = players.get_car_best_laptime(0)
    for i=0, line_count-1 do
        local data_to_draw = to_draw[i]
        if data_to_draw ~= nil then
            -- lap text
            local lap_count = players.get_lapcount(data_to_draw.car_index)
            local text_size = ui.measureDWriteText(lap_count + 1, normal_fontsize)
            longest_number_width = math.max(longest_number_width, text_size.x)
            
            -- gap to best time
            local best_of_this  = players.get_car_best_laptime(data_to_draw.leaderboard_index)
            local gap_string = '-'
            if best_of_this ~= nil and best_of_this > 0 and best_of_first ~= nil and best_of_first > 0 then
                gap_string = lap.time_positive_delta_to_string(best_of_this - best_of_first)
            end
            text_size = ui.measureDWriteText(gap_string, normal_fontsize)
            longest_gap_width = math.max(longest_gap_width, text_size.x)
            
            -- width of best time
            local best_laptime_string = lap.time_to_string(best_of_this)
            text_size = ui.measureDWriteText(best_laptime_string, normal_fontsize)
            longest_best_width = math.max(longest_best_width, text_size.x)
            
            local comp_name = ac.getTyresName(data_to_draw.car_index)
            text_size = ui.measureDWriteText(comp_name, normal_fontsize)
            longest_compound_shortname = math.max(longest_compound_shortname, text_size.x)
            
            -- ballast and restrictor, from acbop
            if Leaderboard_ShowBop then
                local bop_text = acbop.bop_text(data_to_draw.car_index)
                if bop_text ~= nil then
                    text_size = ui.measureDWriteText(bop_text, normal_fontsize)
                    longest_bop_width = math.max(longest_bop_width, text_size.x)
                end
            end
        end
    end
    local longest_playername_width = 0
    if Leaderboard_ScrollLongNames == false then
        ui.pushDWriteFont(nametext_font)
        for i=0, #leaderboard-1 do
            local playername = ""
            if Leaderboard_ShowCarNames then
                playername = ac.getCarName(leaderboard[i].car.index)
            else
                playername = ac.getDriverName(leaderboard[i].car.index)
            end
            local text_size = ui.measureDWriteText(playername, normal_fontsize)
            longest_playername_width = math.max(longest_playername_width, text_size.x)
        end
        ui.popDWriteFont()
    end
    
    -- session type
    local session_state = sim_info.raceSessionType
    local session_text = "UNDF"
    if session_state == ac.SessionType.Practice   then session_text = 'PRAC' end
    if session_state == ac.SessionType.Qualify    then session_text = 'QUAL' end
    if session_state == ac.SessionType.Race       then session_text = 'RACE' end
    if session_state == ac.SessionType.Hotlap     then session_text = 'HOTL' end
    if session_state == ac.SessionType.TimeAttack then session_text = 'TIME' end
    if session_state == ac.SessionType.Drift      then session_text = 'DRFT' end
    if session_state == ac.SessionType.Drag       then session_text = 'DRAG' end
    local letter_size = ui.measureDWriteText(session_text, normal_fontsize)
    
    -- lap texts (or times, depends on session type)
    ui.pushDWriteFont(fonts.archivo_bold)
    local lap_text = "Lap:"
    local lap_text_size = ui.measureDWriteText(lap_text, normal_fontsize)
    local time_text = "Time:"
    local time_text_size = ui.measureDWriteText(time_text, normal_fontsize)
    
    -- time and lap count strings
    local time_string = ''
    local time_s = math.abs(sim_info.sessionTimeLeft) / 1000
    local time_min = math.floor(time_s / 60)
    time_s = time_s - time_min * 60
    local time_hour = math.floor(time_min / 60)
    time_min = time_min - time_hour * 60
    time_string = string.format("%d:%02d:%02d", time_hour, time_min, time_s)
    if sim_info.sessionTimeLeft > 0 then show_overtime = true end
    if show_overtime and sim_info.sessionTimeLeft < 0 then time_string = "Overtime" end
    
    local index_of_first_person = -1
    if leaderboard[0] ~= nil then
        index_of_first_person = leaderboard[0].car.index
    end
    local lap_string = string.format("%d", players.get_lapcount(0)+1)
    local lapcount_of_leader = players.get_lapcount(index_of_first_person)
    local race_lap_string = string.format("%d / %d", math.clamp(lapcount_of_leader + 1, 0, session.laps), session.laps)
    
    local hide_lap = false
    if session.isTimedRace then
        race_lap_string = string.format("%d", lapcount_of_leader + 1)
        local final_lap = session.hasAdditionalLap == false and sim_info.sessionTimeLeft < 0
        if show_leader_final_lap then final_lap = true end
        -- TAG(cogno): 
        if final_lap then
            time_string = "Overtime"
            hide_lap = true
        end
    end
    
    local time_number_size = ui.measureDWriteText(time_string, normal_fontsize)
    local lap_number_size = ui.measureDWriteText(lap_string, normal_fontsize)
    local race_lap_size = ui.measureDWriteText(race_lap_string, normal_fontsize)
    
    ui.popDWriteFont()
    local session_info_padding = vec2(10, 14) * LeaderboardScale
    local line_width = 2 * LeaderboardScale
    local temptexts_pad = 5 * LeaderboardScale

    -- since time text cahnges a lot, using it to set elements will 
    -- make them vibrate a lot, so we set it inside a little extra space, but
    -- you can't just add a value, it will still vibrate!
    time_number_size.x = reduce_jitter(time_number_size.x)
    
    local session_min_width = session_info_padding.x * 2 + letter_size.x + line_width
    if session_state == ac.SessionType.Practice or session_state == ac.SessionType.Qualify or session_state == ac.SessionType.Hotlap then
        session_min_width = session_min_width + time_number_size.x + time_text_size.x + lap_number_size.x + lap_text_size.x + session_info_padding.x * 3 + temptexts_pad * 2
    elseif session_state == ac.SessionType.Race then
        session_min_width = session_min_width + session_info_padding.x * 2
        if hide_lap == false then
            session_min_width = session_min_width + lap_text_size.x + race_lap_size.x + temptexts_pad
        end
        if session.isTimedRace then
            session_min_width = session_min_width + temptexts_pad + session_info_padding.x + time_number_size.x + time_text_size.x
        end
    end
    
    -- we also write "Air: 26°C Tarmac: 24°C" so we need to fit that
    local second_line_horizontal_offset = 11 * LeaderboardScale
    local air_tarmac_font = fonts.archivo_medium
    local airtext  = convert_temp(sim_info.ambientTemperature)
    local roadtext = convert_temp(sim_info.roadTemperature)
    
    ui.pushDWriteFont(air_tarmac_font)
    local air_textsize = ui.measureDWriteText('Air:', normal_fontsize)
    local airtemp_textsize = ui.measureDWriteText(airtext, normal_fontsize)
    local tarmac_textsize = ui.measureDWriteText('Tarmac:', normal_fontsize)
    local roadtemp_textsize = ui.measureDWriteText(roadtext, normal_fontsize)
    ui.popDWriteFont()
    local air_tarmac_size = second_line_horizontal_offset * 2 + air_textsize.x + temptexts_pad * 5 + airtemp_textsize.x + tarmac_textsize.x + roadtemp_textsize.x
    session_min_width = math.max(session_min_width, air_tarmac_size)
    -- NOTE(cogno): here's how we handle different sessions
    -- PRACTICE (PRAC):
    -- top left hast Time (decreasing) then your Laps (from 0)
    -- right side is Sectors (squares that show sectors), 
    -- Gap (from person to first) and Best lap time (for that person)
    -- leaderboard is in order of best lap times (alphabetic if best lap time == 0)
    -- QUALIFY (QUAL): identic to PRAC
    -- RACE:
    -- top left is Lap of first car / session total (starting from 1)
    -- leaderboard in order of race position
    -- right side is Pos (arrows that show positions gained / lost),
    -- Int (interval from player to people in front / back) and Last 
    -- lap time (of that person)
    --
    -- as of now we don't do any other session
    --                     - Cogno 2024/04/09
    
    
    
    -- calculate the minimum line length we need
    local quad_padding = 2 * LeaderboardScale
    local line_height = settings.line_height * LeaderboardScale
    local rect_pad = vec2(quad_padding, quad_padding)
    local rect_size = vec2(line_height, line_height) - rect_pad * 2
    local text_pad = vec2(7,7) * LeaderboardScale
    local textsize_L = ui.measureDWriteText('L', normal_fontsize)
    ui.popDWriteFont()
    local border_pad = 12
    local max_space_for_drivernames = longest_playername_width
    if Leaderboard_ScrollLongNames then
        max_space_for_drivernames = 150 * LeaderboardScale
    end
    local max_leftside_width = rect_size.x + quad_padding * 2 + text_pad.x * 2 + max_space_for_drivernames + longest_number_width + textsize_L.x + border_pad
    
    if Leaderboard_ShowTyres then
        max_leftside_width = max_leftside_width + longest_compound_shortname + text_pad.x * 6
    end
    if Leaderboard_ShowBop and longest_bop_width > 0 then
        max_leftside_width = max_leftside_width + longest_bop_width + text_pad.x * 4
    end
    
    local resize_width = math.max(max_leftside_width, session_min_width)
    -- ui.drawRectFilled(draw_top_left, draw_top_left + vec2(max_leftside_width, 350), colors.RED)
    
    local flag_height = 33 * LeaderboardScale -- height of 'green flag' zone
    local title_height = 37 * LeaderboardScale -- height of space with 'Pos Int Last' texts
    local default_board_width = 190 * LeaderboardScale -- default width of left side of leaderboard (the one with R | Lap 25 / 44)
    local board_width = math.max(default_board_width, math.floor(resize_width)) -- we stretch the size to fit the text (if needed)
    
    --
    -- automatic resize of right side of leatherboard (called "info side")
    --
    local pad = 8 * LeaderboardScale
    local sector_rect_pad = 4 * LeaderboardScale
    local big_rect_height = 6 * LeaderboardScale
    local small_rect_height = 3 * LeaderboardScale
    local vertical_offset = 1 * LeaderboardScale
    local rect_width = 22 * LeaderboardScale
    local sec_gap_padding = 20 * LeaderboardScale
    
    local sectors_count = #players.get_sector_splits()
    local min_space_for_race_info = 190 * LeaderboardScale
    local sectors_space = math.max(sectors_count, 3) * (sector_rect_pad + rect_width)
    local min_space_for_quali_info = pad * 2 + sectors_space + sec_gap_padding * 2 + longest_gap_width + longest_best_width
    
    local info_width = min_space_for_race_info
    if session_state == ac.SessionType.Practice or session_state == ac.SessionType.Qualify or  session_state == ac.SessionType.Hotlap then
        info_width = min_space_for_quali_info
    end
    
    
    local header_height = flag_height + title_height
    local header_size = vec2(board_width, header_height)
    local banner_size = vec2(board_width + info_width, 30 * LeaderboardScale) -- notification of important flags at the bottom with scrolling text
    
    local corner_tl = draw_center - draw_size / 2
    
    local window_center = ui.windowPos() + ui.windowSize() / 2
    local screensize = settings.get_screensize()
    if window_center.x > screensize.x / 2 then
        corner_tl = draw_center + vec2(draw_size.x / 2 - banner_size.x, -draw_size.y / 2)
    end

    local top_center = corner_tl + vec2(board_width)
    local info_start = top_center + vec2(0, flag_height)

    local flagtype = sim_info.raceFlagType
    local flag_text = "GREEN FLAG"
    local flag_background = colors.GREEN
    local flagtext_color = colors.BLACK
    if flagtype == ac.FlagType.None then
        flag_text = ''
        flag_background = colors.BG
        -- for practice / qualify no flag is actually green flag
        if session_state == ac.SessionType.Qualify or session_state == ac.SessionType.Practice then
            flag_text = "GREEN FLAG"
            flag_background = colors.GREEN
        end
    elseif flagtype == ac.FlagType.Caution then
        flag_text = "YELLOW FLAG"
        flag_background = colors.YELLOW
    elseif flagtype == ac.FlagType.Stop then
        flag_text = "BLACK FLAG"
        flag_background = colors.BLACK
        flagtext_color = colors.WHITE
    elseif flagtype == ac.FlagType.ReturnToPits then
        flag_text = "PENALTY"
        flag_background = colors.RED
        flagtext_color = colors.WHITE
    elseif flagtype == ac.FlagType.FasterCar then
        flag_text = "BLUE FLAG"
        flag_background = colors.BLUE
        flagtext_color = colors.WHITE
    elseif flagtype == ac.FlagType.OneLapLeft then
        flag_text = "WHITE FLAG"
        flag_background = colors.WHITE
    elseif flagtype == ac.FlagType.Finished then
        flag_text = "RACE OVER"
        if session_state == ac.SessionType.Practice then
            flag_text = "PRACTICE OVER"
        elseif session_state == ac.SessionType.Qualify then
            flag_text = "QUALIFY OVER"
        end
        flag_background = colors.WHITE
    end
    -- a virtual safety car from acbop takes over the flag while it runs
    local flag_key = flagtype
    if acbop.get_vsc() ~= nil then
        flag_text = "VIRTUAL SAFETY CAR"
        flag_background = colors.YELLOW
        flagtext_color = colors.BLACK
        flag_key = -1
    end
    if flag_text == '' then
        show_banner = false
        real_flag_background = colors.BG
        real_flag_text = flag_text
    else
        local changed = maybe_start_banner_animation(flag_key)
        if changed then
            if real_flag_text ~= flag_text then -- so it doesn't get called every frame
                show_banner = true
                is_showing_banner = false
                animation_start_time = Time
            end
            real_flag_background = flag_background
            real_flag_text = flag_text
        end
    end
    if real_flag_text == 'GREEN FLAG' then
        if Time - animation_start_time > green_flag_banner_show_time then
            show_banner = false
            animation_start_time = Time
        end
    end
    local table_width = board_width + info_width
    local total_size = vec2(table_width, line_height * 6 + banner_size.y + header_height)
    local total_center = corner_tl + total_size / 2

    -- backgrounds
    local pixel_aligned = vec2(math.floor(top_center.x), math.floor(top_center.y))
    ui.drawRectFilled(corner_tl, corner_tl + header_size, colors.DARK_BG, 5 * LeaderboardScale, ui.CornerFlags.TopLeft)
    ui.drawRectFilled(pixel_aligned, pixel_aligned + vec2(info_width, flag_height), real_flag_background, 5 * LeaderboardScale, ui.CornerFlags.TopRight)
    ui.drawRectFilled(info_start, info_start + vec2(info_width, title_height), colors.BG)
    
    local dots_texture_string = settings.get_asset("leaderboard_dot")
    local dots_size = vec2(default_board_width, header_height)
    ui.drawImageQuad(
        dots_texture_string,
        corner_tl,
        corner_tl + vec2(dots_size.x, 0),
        corner_tl + dots_size,
        corner_tl + vec2(0, dots_size.y),
        rgbm(1, 1, 1, 0.7)
    )
    
    --
    -- top texts
    --
    ui.pushDWriteFont(fonts.archivo_bold)
    
    local letter_pos = corner_tl + session_info_padding
    ui.dwriteDrawText(session_text, normal_fontsize, letter_pos)
    
    -- vertical separator bar
    local line_center = letter_pos + vec2(letter_size.x + session_info_padding.x, letter_size.y / 2)
    local separator_height = 25 * LeaderboardScale
    local line_pos = line_center - vec2(line_width, separator_height) / 2
    ui.drawRectFilled(line_pos, line_pos + vec2(line_width, separator_height), colors.WHITE)
    
    -- lap texts (or times, depends on session type)
    local lap_text_startpos = line_center + vec2(session_info_padding.x, 0)
    local top_text_pos = lap_text_startpos - vec2(0, lap_text_size.y / 2)
    if session_state == ac.SessionType.Practice or session_state == ac.SessionType.Qualify or session_state == ac.SessionType.Hotlap then
        -- PRAC | Time 20:00.000 Lap 0
        ui.dwriteDrawText(time_text, normal_fontsize, top_text_pos, colors.TEXT_GRAY)
        top_text_pos = top_text_pos + vec2(time_text_size.x + temptexts_pad, 0)
        ui.dwriteDrawText(time_string, normal_fontsize, top_text_pos, colors.WHITE)
        top_text_pos = top_text_pos + vec2(time_number_size.x + session_info_padding.x, 0)
        ui.dwriteDrawText(lap_text, normal_fontsize, top_text_pos, colors.TEXT_GRAY)
        top_text_pos = top_text_pos + vec2(lap_text_size.x + temptexts_pad, 0)
        ui.dwriteDrawText(lap_string, normal_fontsize, top_text_pos, colors.WHITE)
    elseif session_state == ac.SessionType.Race then
        if session.isTimedRace then
            ui.dwriteDrawText(time_text, normal_fontsize, top_text_pos, colors.TEXT_GRAY)
            top_text_pos = top_text_pos + vec2(time_text_size.x + temptexts_pad, 0)
            ui.dwriteDrawText(time_string, normal_fontsize, top_text_pos, colors.WHITE)
            top_text_pos = top_text_pos + vec2(time_number_size.x + session_info_padding.x, 0)
        end
        if hide_lap == false then
            ui.dwriteDrawText(lap_text, normal_fontsize, top_text_pos, colors.TEXT_GRAY)
            top_text_pos = top_text_pos + vec2(lap_text_size.x + temptexts_pad, 0)
            ui.dwriteDrawText(race_lap_string, normal_fontsize, top_text_pos, colors.WHITE)
        end
    end
    
    -- air and tarmac
    local second_line_vertical_offset = 11 * LeaderboardScale
    local temps_pos = corner_tl + vec2(0, flag_height) + vec2(second_line_horizontal_offset, second_line_vertical_offset)
    ui.pushDWriteFont(air_tarmac_font)
    ui.dwriteDrawText('Air:', normal_fontsize, temps_pos, colors.TEXT_GRAY)
    temps_pos = temps_pos + vec2(temptexts_pad + air_textsize.x, 0)
    ui.dwriteDrawText(airtext, normal_fontsize, temps_pos, colors.WHITE)
    temps_pos = temps_pos + vec2(temptexts_pad * 3 + airtemp_textsize.x, 0)
    ui.dwriteDrawText('Tarmac:', normal_fontsize, temps_pos, colors.TEXT_GRAY)
    temps_pos = temps_pos + vec2(temptexts_pad + tarmac_textsize.x, 0)
    ui.dwriteDrawText(roadtext, normal_fontsize, temps_pos, colors.WHITE)
    ui.popDWriteFont()
    
    -- flag text
    local flag_textsize = settings.fontsize(10) * LeaderboardScale
    local flag_text_size = ui.measureDWriteText(real_flag_text, flag_textsize)
    local flag_text_pos = top_center + vec2(7 * LeaderboardScale, flag_text_size.y / 2 + 6 * LeaderboardScale)
    ui.dwriteDrawText(real_flag_text, flag_textsize, flag_text_pos, flagtext_color)
    
    if session_state == ac.SessionType.Practice or session_state == ac.SessionType.Qualify or session_state == ac.SessionType.Hotlap then
        -- 'Sec Gap Best'
        local info_text_pad = vec2(pad, second_line_vertical_offset)
        local sec_text_pos  = info_start + info_text_pad + vec2(-2, 0) * LeaderboardScale
        local gap_text_pos  = info_start + info_text_pad + vec2(sectors_space + sec_gap_padding, 0)
        local best_text_pos = info_start + info_text_pad + vec2(sectors_space + sec_gap_padding * 2 + longest_gap_width, 0)
        ui.dwriteDrawText('Sectors', normal_fontsize, sec_text_pos, colors.WHITE)
        ui.dwriteDrawText('Gap', normal_fontsize, gap_text_pos, colors.WHITE)
        ui.dwriteDrawText('Best', normal_fontsize, best_text_pos, colors.WHITE)
    elseif session_state == ac.SessionType.Race then
        -- 'Pos Int Last'
        local info_text_pad = vec2(8 * LeaderboardScale, second_line_vertical_offset)
        local pos_text_pos  = info_start + info_text_pad
        local int_text_pos  = info_start + info_text_pad + vec2(53,0) * LeaderboardScale
        local last_text_pos = info_start + info_text_pad + vec2(108,0) * LeaderboardScale
        ui.dwriteDrawText('Pos', normal_fontsize, pos_text_pos, colors.WHITE)
        ui.dwriteDrawText('Int', normal_fontsize, int_text_pos, colors.WHITE)
        ui.dwriteDrawText('Last', normal_fontsize, last_text_pos, colors.WHITE)
    end

    --
    -- calculate all players best sectors (the best first sector ever, the best second etc.)
    --
    local session_best_lap = players.get_best_laptime()
    local mp_best_sector_times = players.get_best_sector_times()
    
    -- if someone moves the ui we show him the full leaderboard so he can balance it accordingly
    local force_seen = false
    if ui.mouseDown(ui.MouseButton.Left) and settings.is_inside(ui.mouseLocalPos(), ui.windowSize() / 2, ui.windowSize() / 2) then
        line_count = 6
        force_seen = true
    end
    
    -- draw every line with info inside
    local rect_radius = 5 * LeaderboardScale
    for player_index=0, line_count-1 do
        local line_tl = corner_tl + vec2(0, player_index * line_height + header_height)
        local left_color = colors.DARK_BG
        local right_color = colors.BG
        if player_index % 2 == 1 then
            left_color = colors.BG
            right_color = colors.LIGHT_BG
        end
        local data_to_draw = to_draw[player_index]
        if force_seen then
            -- we're forcefully drawing the leaderboard so the user can know how much space it uses on screen
            local line_top_center = line_tl + vec2(board_width, 0)
            local line_bot_right  = line_tl + vec2(board_width + info_width, line_height)
            -- backgrounds (left then right)
            if player_index == line_count - 1 then
                ui.drawRectFilled(line_tl, line_tl + vec2(board_width, line_height), left_color)
                ui.drawRectFilled(line_top_center, line_bot_right, right_color)
            else
                ui.drawRectFilled(line_tl, line_tl + vec2(board_width, line_height), left_color)
                ui.drawRectFilled(line_top_center, line_bot_right, right_color)
            end
            ui.drawRectFilled(line_tl + rect_pad, line_tl + rect_pad + rect_size, colors.WHITE, rect_radius, ui.CornerFlags.BottomRight)
        end
        if data_to_draw ~= nil then
            -- data available, draw it
            local to_draw_car_info = ac.getCar(data_to_draw.car_index)
            local lap_count = players.get_lapcount(data_to_draw.car_index)
            
            local highlight_color = colors.WHITE
            local square_color = highlight_color
            if to_draw_car_info.isConnected == false then
                highlight_color = colors.TEXT_LIGHT_GRAY
                square_color = colors.WHITE
            end
            if data_to_draw.car_index == 0 then
                highlight_color = colors.TEXT_YELLOW
                square_color = colors.TEXT_YELLOW
            end
            
            local texture_color = nil
            
            local last_laptime = players.get_previous_laptime(data_to_draw.car_index)
            local best_laptime = players.get_car_best_laptime(data_to_draw.leaderboard_index)
            local last_lap_text = ''
            if to_draw_car_info.isRetired then
                last_lap_text = 'RET'
            else
                last_lap_text = lap.time_to_string(last_laptime)
            end
            local laptime_color = highlight_color
            local curve_t = settings.get_curve_t(animation_times_per_player[data_to_draw.car_index], true, Leaderboard_AnimDuration)
            if last_laptime > 0 and last_laptime ~= nil and to_draw_car_info.isLastLapValid then
                if best_laptime ~= nil and best_laptime > 0 and last_laptime <= best_laptime then
                    texture_color = colors.GREEN
                end
                if session_best_lap ~= nil and session_best_lap > 0 and last_laptime <= session_best_lap then
                    texture_color = colors.PURPLE
                end
            end
            
            -- backgrounds (left then right)
            local line_top_center = line_tl + vec2(board_width, 0)
            local line_bot_right  = line_tl + vec2(board_width + info_width, line_height)
            if force_seen == false then
                if player_index == line_count - 1 then
                    ui.drawRectFilled(line_tl, line_tl + vec2(board_width, line_height), left_color)
                    ui.drawRectFilled(line_top_center, line_bot_right, right_color)
                else
                    ui.drawRectFilled(line_tl, line_tl + vec2(board_width, line_height), left_color)
                    ui.drawRectFilled(line_top_center, line_bot_right, right_color)
                end
            end
            ui.drawRectFilled(line_tl + rect_pad, line_tl + rect_pad + rect_size, square_color, rect_radius, ui.CornerFlags.BottomRight)
            
            if texture_color ~= nil then
                ui.drawImageQuad(
                    settings.get_asset("white"),
                    line_top_center + vec2(80, 0) * LeaderboardScale,
                    vec2(line_bot_right.x, line_top_center.y),
                    line_bot_right,
                    vec2(line_top_center.x, line_bot_right.y) + vec2(80, 0) * LeaderboardScale,
                    rgbm(texture_color.r, texture_color.g, texture_color.b, settings.remap(curve_t, 0, 1, 0, 0.55))
                )
            end
            
            -- position number
            local rect_center = line_tl + rect_pad + rect_size / 2
            local number_textsize = ui.measureDWriteText(data_to_draw.position, normal_fontsize)
            local number_pos = rect_center - number_textsize / 2
            ui.dwriteDrawText(data_to_draw.position, normal_fontsize, number_pos, colors.BLACK)
            
            -- player name
            local name_text_pos = line_tl + vec2(quad_padding * 2 + rect_size.x, 0) + text_pad
            -- player name
            ui.pushDWriteFont(nametext_font)
            do
                local driver_name = ac.getDriverName(data_to_draw.car_index)
                local driver_name_size = ui.measureDWriteText(driver_name, normal_fontsize)
                local space_for_text = max_space_for_drivernames
                
                local scroll_timer = long_names_scroll_timers[data_to_draw.car_index]
                if driver_name_size.x > space_for_text then
                    -- if the text doesn't have enough space, create the data we need
                    if scroll_timer == nil then scroll_timer = 0
                    else                        scroll_timer = scroll_timer + Dt
                    end
                else
                    -- if we have enough space, and we were animating we don't need to anymore
                    if scroll_timer ~= nil then
                        scroll_timer = nil
                    end
                end
                long_names_scroll_timers[data_to_draw.car_index] = scroll_timer
                
                if scroll_timer == nil or Leaderboard_ScrollLongNames == false then
                    -- simple text, we have enough space, no need to scroll it
                    ui.dwriteDrawText(driver_name, normal_fontsize, name_text_pos, highlight_color)
                else
                    -- complex text, scroll it back and forth as explained above
                    local gradient_width = 30 * LeaderboardScale
                    local scroll_length = driver_name_size.x - space_for_text + gradient_width
                    local scroll_duration = scroll_length / 20 -- velocity = 20px/s
                    local total_anim_length = 1 + scroll_duration + 3 + scroll_duration + 3
                    local animation_looptime = scroll_timer % total_anim_length
                    
                    local lerp_forward  = settings.animate_lerp(animation_looptime, 1, scroll_duration) -- 1s of NOTHING, then moves forward
                    local lerp_backward = settings.animate_lerp(animation_looptime, 1 + scroll_duration + 3, scroll_duration) -- after moving forward, 3s of nothing then comes back at the same speed
                    
                    local text_pos = name_text_pos - vec2(scroll_length * (lerp_forward - lerp_backward), 0)
                    ui.beginGradientShade()
                    ui.pushClipRect(name_text_pos, name_text_pos + vec2(500, 500))
                    ui.dwriteDrawText(driver_name, normal_fontsize, text_pos, colors.WHITE)
                    ui.popClipRect()
                    ui.endGradientShade(name_text_pos + vec2(space_for_text - gradient_width, 0), name_text_pos + vec2(space_for_text, 0), highlight_color, colors.TRANSP, true)
                end
            end
            ui.popDWriteFont()
            
            -- lapcount per player
            ui.pushDWriteFont(lapcount_font)
            local line_tr = line_tl + vec2(board_width, 0)
            local lap_text_tl = line_tr + vec2(-text_pad.x - border_pad - longest_number_width, text_pad.y)
            if to_draw_car_info.isConnected == false then
                local off_textsize = ui.measureDWriteText("OFF", normal_fontsize)
                local off_text_tl = line_tr + vec2(-off_textsize.x - text_pad.x, text_pad.y)
                ui.dwriteDrawText("OFF", normal_fontsize, off_text_tl, highlight_color)
            elseif to_draw_car_info.isRaceFinished then
                local fin_textsize = ui.measureDWriteText("FIN", normal_fontsize)
                local fin_text_tl = line_tr + vec2(-fin_textsize.x - text_pad.x, text_pad.y)
                ui.dwriteDrawText("FIN", normal_fontsize, fin_text_tl, highlight_color)
            elseif to_draw_car_info.isRetired then
                local pit_textsize = ui.measureDWriteText("RET", normal_fontsize)
                local pit_text_tl = line_tr + vec2(-pit_textsize.x - text_pad.x, text_pad.y)
                ui.dwriteDrawText("RET", normal_fontsize, pit_text_tl, highlight_color)
            elseif to_draw_car_info.isInPitlane then
                local pit_textsize = ui.measureDWriteText("PIT", normal_fontsize)
                local pit_text_tl = line_tr + vec2(-pit_textsize.x - text_pad.x, text_pad.y)
                ui.dwriteDrawText("PIT", normal_fontsize, pit_text_tl, highlight_color)
            else
                local lapcount_textsize = ui.measureDWriteText(lap_count + 1, normal_fontsize)
                local number_text_tl = line_tr + vec2(-lapcount_textsize.x - text_pad.x, text_pad.y)
                ui.dwriteDrawText("L", normal_fontsize, lap_text_tl, highlight_color)
                ui.dwriteDrawText(lap_count + 1, normal_fontsize, number_text_tl, highlight_color)
            end
            
            if Leaderboard_ShowTyres then
                local tire_shortname = ac.getTyresName(data_to_draw.car_index)
                local tire_pos = lap_text_tl + vec2(-text_pad.x * 3 - longest_compound_shortname, 0)
                ui.dwriteDrawText(tire_shortname, normal_fontsize, tire_pos, highlight_color)
            end
            
            -- ballast and restrictor, coloured while a safety car holds them
            if Leaderboard_ShowBop then
                local bop_text = acbop.bop_text(data_to_draw.car_index)
                if bop_text ~= nil then
                    local bop_right = lap_text_tl
                    if Leaderboard_ShowTyres then
                        bop_right = bop_right + vec2(-text_pad.x * 3 - longest_compound_shortname, 0)
                    end
                    local bop_pos = bop_right + vec2(-text_pad.x * 3 - longest_bop_width, 0)
                    local bop_color = highlight_color
                    local role = acbop.vsc_role(data_to_draw.car_index)
                    if role == 'held' then
                        bop_color = colors.YELLOW
                    elseif role == 'caller' then
                        bop_color = colors.LIGHT_GREEN
                    end
                    ui.dwriteDrawText(bop_text, normal_fontsize, bop_pos, bop_color)
                end
            end
            
            -- position with arrow
            if session_state == ac.SessionType.Race then
                local pos_tl = line_tr + vec2(6,0) * LeaderboardScale + text_pad
                if to_draw_car_info.isRetired then
                    ui.dwriteDrawText('RET', normal_fontsize, pos_tl, highlight_color)
                else
                    local pos_diff = data_to_draw.pos_diff
                    if pos_diff == 0 then
                        ui.dwriteDrawText('-', normal_fontsize, pos_tl, highlight_color)
                    else
                        local pos_center_left = line_tr + vec2(9 * LeaderboardScale, line_height / 2)
                        local arrow_width = 12 * LeaderboardScale
                        if pos_diff > 0 then
                            -- green arrow up
                            local offset = vec2(0, 3) * LeaderboardScale
                            ui.pathClear()
                            ui.pathLineTo(pos_center_left + offset)
                            ui.pathLineTo(pos_center_left + offset + vec2(arrow_width, -arrow_width)/2)
                            ui.pathLineTo(pos_center_left + offset + vec2(arrow_width, 0))
                            ui.pathStroke(colors.GREEN, false, 3 * LeaderboardScale)
                        else
                            -- red arrow down
                            local offset = vec2(0, -3) * LeaderboardScale
                            ui.pathClear()
                            ui.pathLineTo(pos_center_left + offset)
                            ui.pathLineTo(pos_center_left + offset + vec2(arrow_width, arrow_width)/2)
                            ui.pathLineTo(pos_center_left + offset + vec2(arrow_width, 0))
                            ui.pathStroke(colors.RED, false, 3 * LeaderboardScale)
                        end
                        pos_tl = pos_tl + vec2(arrow_width + 3 * LeaderboardScale, 0)
                        ui.dwriteDrawText(math.abs(data_to_draw.pos_diff), normal_fontsize, pos_tl, highlight_color)
                    end
                end
                
                -- intervals
                local interval_center_pos = line_tr + vec2(74 * LeaderboardScale, line_height / 2)
                if to_draw_car_info.isRetired then
                    local interval_text_size = ui.measureDWriteText('RET', normal_fontsize)
                    ui.dwriteDrawText('RET', normal_fontsize, interval_center_pos - interval_text_size / 2, highlight_color)
                else
                    local interval_text_size = ui.measureDWriteText(data_to_draw.interval, normal_fontsize)
                    ui.dwriteDrawText(data_to_draw.interval, normal_fontsize, interval_center_pos - interval_text_size / 2, highlight_color)
                end
                
                -- last lap time
                local laptime_size = ui.measureDWriteText(last_lap_text, normal_fontsize)
                local laptime_pos = line_tr + vec2(info_width, 0) - vec2(text_pad.x,-text_pad.y) - vec2(laptime_size.x + 6, 0)
                ui.dwriteDrawText(last_lap_text, normal_fontsize, laptime_pos, laptime_color)
            elseif session_state == ac.SessionType.Practice or session_state == ac.SessionType.Qualify or session_state == ac.SessionType.Hotlap then
                -- draw sector squares
                local to_draw_best_sector_times = players.get_player_best_sector_times(data_to_draw.car_index)
                for sector_index=0, sectors_count-1 do
                    local current_pos_cl = line_tr + vec2(pad + (rect_width + sector_rect_pad) * sector_index, line_height / 2)
                    local rect_size = vec2(rect_width, small_rect_height)
                    local sector_color = colors.GRAY
                    local personal_best_sector_time = nil
                    local mp_best_sector_time = mp_best_sector_times[sector_index]
                    local current_sector_time = data_to_draw.sector_times[sector_index]
                    if to_draw_best_sector_times ~= nil then personal_best_sector_time = to_draw_best_sector_times[sector_index] end
                    
                    if current_sector_time ~= nil and current_sector_time > 0 then
                        -- we have a sector time, compare it your best and multiplayer best
                        rect_size.y = big_rect_height
                        sector_color = colors.LIGHT_GRAY
                        if personal_best_sector_time ~= nil and personal_best_sector_time > 0 and current_sector_time <= personal_best_sector_time  then
                            sector_color = colors.GREEN
                        end
                        if mp_best_sector_time ~= nil and mp_best_sector_time > 0 and current_sector_time <= mp_best_sector_time then
                            sector_color = colors.PURPLE
                        end
                    end
                    
                    local pos_tl = current_pos_cl + vec2(0, big_rect_height / 2 + vertical_offset - rect_size.y)
                    ui.drawRectFilled(pos_tl, pos_tl + rect_size, sector_color)
                end
                
                -- gap between this time and the first one
                local best_of_this = players.get_car_best_laptime(data_to_draw.leaderboard_index)
                local gap_string = '-'
                if best_of_this ~= nil and best_of_this > 0 and best_of_first ~= nil and best_of_first > 0 then
                    gap_string = lap.time_positive_delta_to_string(best_of_this - best_of_first)
                end
                local gap_size = ui.measureDWriteText(gap_string, normal_fontsize)
                local end_of_sectors_pos = line_tr + vec2(pad + sectors_space, 0)
                local gap_pos = end_of_sectors_pos + vec2(sec_gap_padding, line_height / 2 - gap_size.y / 2)
                ui.dwriteDrawText(gap_string, normal_fontsize, gap_pos, highlight_color)
                
                -- best lap time text
                local end_of_gap_pos = gap_pos + vec2(longest_gap_width, 0)
                local best_lap_string = lap.time_to_string(best_of_this)
                local best_lap_pos = end_of_gap_pos + vec2(sec_gap_padding, 0)
                ui.dwriteDrawText(best_lap_string, normal_fontsize, best_lap_pos, highlight_color)
            end
            
            ui.popDWriteFont()
        end
    end

    local banner_current_size = banner_size:clone()
    local current_time = Time - animation_start_time
    local show = true
    local from_right = true
    local banner_start_pos = corner_tl + vec2(0, header_height + line_count * line_height)
    if show_banner and is_showing_banner then
        -- nothing to do
    elseif show_banner then
        local banner_appear_time = 0.4
        local anim_percent = current_time / banner_appear_time
        if anim_percent >= 1 then is_showing_banner = true end
        banner_current_size.x = math.lerp(0, table_width, math.clamp(anim_percent, 0, 1))
    elseif is_showing_banner then
        local banner_hide_time = 0.4
        local anim_percent = current_time / banner_hide_time
        if anim_percent >= 1 then is_showing_banner = false end
        banner_current_size.x = math.lerp(table_width, 0, math.clamp(anim_percent, 0, 1))
        from_right = false
    else
        show = false -- hide everything
    end
    
    local banner_pos_tl = banner_start_pos + vec2(table_width - banner_current_size.x, 2 * LeaderboardScale)
    if from_right == false then
        banner_pos_tl = banner_start_pos + vec2(0, 2) * LeaderboardScale
    end

    local left_color = colors.DARK_BG
    local right_color = colors.BG
    if line_count % 2 == 0 then
        left_color = colors.BG
        right_color = colors.LIGHT_BG
    end
    
    local line_top_center = banner_start_pos + vec2(board_width, 0)
    
    if show or force_seen then
        ui.pushDWriteFont(fonts.archivo_bold)
        
        -- we have 2 pixels of padding that we make appear/disappear with the notification flag, so we 
        -- can properly space the banner from the squares of the player. If we don't you would see the
        -- last player square with 2 pixels of distance (instead of 4), which kind of sucks
        if from_right == false then
            ui.drawRectFilled(banner_pos_tl, banner_start_pos + banner_current_size, real_flag_background)
            ui.pushClipRect(banner_pos_tl + vec2(0, -2) * LeaderboardScale, banner_start_pos + banner_current_size)
        else
            ui.drawRectFilled(banner_pos_tl, banner_start_pos + banner_size, real_flag_background)
            ui.pushClipRect(banner_pos_tl + vec2(0, -2) * LeaderboardScale, banner_start_pos + banner_size)
        end
        
        ui.drawRectFilled(banner_start_pos, banner_start_pos + vec2(board_width, 2 * LeaderboardScale), left_color)
        ui.drawRectFilled(line_top_center, line_top_center + vec2(info_width, 2 * LeaderboardScale), right_color)
        local chunk_fontsize = settings.fontsize(16) * LeaderboardScale
        local chunk_textwidth = ui.measureDWriteText(real_flag_text, chunk_fontsize)
        local chunk_width = chunk_textwidth.x + 30 * LeaderboardScale
        local banner_textpos = banner_start_pos + vec2((-math.floor(Time * 120 * LeaderboardScale)) % chunk_width, banner_size.y / 2 - chunk_textwidth.y / 2 + 2 * LeaderboardScale)
        local chunks_we_fit = math.ceil(banner_size.x / chunk_width)
        for i=-1, chunks_we_fit-1 do
            local chunk_pos = banner_textpos + vec2(chunk_width * i, 0)
            ui.dwriteDrawText(real_flag_text, chunk_fontsize, chunk_pos, flagtext_color)
        end
        ui.popClipRect()
        ui.popDWriteFont()
    end
    ui.popDWriteFont()
    
    settings.lock_app(total_center, total_size, APPNAMES.leaderboard, LeaderboardScale)
    settings.auto_scale_window(total_size * 1.01, APPNAMES.leaderboard)
    settings.auto_place_once(total_size, APPNAMES.leaderboard)
    -- DEBUG(cogno): limit rect so I know if I'm outside the window
    -- ui.drawRect(draw_top_left, draw_top_left + draw_size, colors.WHITE)
    -- ui.drawRect(draw_center - vec2(2,2), draw_center + vec2(2,2), colors.RED)
    -- ui.drawLine(draw_top_left, draw_top_left + draw_size, colors.RED)
    -- ui.drawLine(draw_top_left + vec2(draw_size.x, 0), draw_top_left + vec2(0, draw_size.y), colors.RED)
end


return module