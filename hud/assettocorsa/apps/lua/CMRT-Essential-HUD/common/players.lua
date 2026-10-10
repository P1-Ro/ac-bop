local settings = require("common.settings")
local fullscreen = require("fullscreen.first")

--[[
    Dedicated into keeping track of various info for every player in session.
    Stuff like current lap time for each player, best lap time, race position,
    sector times, minisector times, etc.
    
    We try to get as much info as possible from assetto corsa directly, but we
    have to estimate / track some info manually.
]]

--[[
    TAG: OnlineIsFuckingBroken
    Here's the full list of stuff that work offline but don't online 
    
    VERSION 0.2.2
    > ac.getCar(<any>).bestLapSplits is always 0
    > ac.getCar(<only 0>).lastSplits is 0 ONLY FOR INDEX 0 (yourself)
    > ac.getCar(<except 0>).bestLapTimeMs is always 0 EXCEPT FOR INDEX 0 (but leaderboard[<any>].bestLapTimeMs still works)
    > ac.getCar(<except 0>).lapCount is always 0 EXCEPT FOR INDEX 0
    > ac.getCar(<except 0>).previousLapTimeMs is always 0, EXCEPT FOR INDEX 0 (but ac.getCar(0).lastSplits still work which makes this mega fucked up)
    > session.hasAdditionalLap is always false, even when set (it should be true in that case)
    > ac.onSessionStart(...) doesn't get called (in online only)
    > session.leaderboard can become empty when going from practice to qualify (ac.iterateCars.leaderboard() works)
    > ac.getCar(<any>).bestLapTimeMs also considers invalid laps, same for leaderboard[<any>].bestLapTimeMs
    
    VERSION 0.2.3 preview227
    > session.hasAdditionaLap to solve yet
    > ac.onSessionStart(...) to confirm it's been solved
    > ac.getCar(<any>).bestLapTimeMs also considers invalid laps, same for leaderboard[<any>].bestLapTimeMs
    ALL OTHER ISSUES ARE SOLVED. YIPPIE!!
    
    VERSION 0.2.3 preview225
    IDENTICAL to VERSION 0.2.2 (for now)
    
    VERSION 0.2.3 preview211
    LIKE V0.2.2 BUT WITH 2 extra problems
    > (same as 0.2.2) ac.getCar(<any>).bestLapSplits is always 0
    > (same as 0.2.2) ac.getCar(<only 0>).lastSplits is 0 ONLY FOR INDEX 0 (yourself)
    > (new regression, previously for index 0 they would work, now they don't) ac.getCar(<any>).bestLapTimeMs is always 0 (but leaderboard[<any>].bestLapTimeMs still works)
    > (new regression, previously for index 0 they would work, now they don't) ac.getCar(<any>).lapCount is always 0
    > (same as 0.2.2) ac.getCar(<except 0>).previousLapTimeMs is always 0, EXCEPT FOR INDEX 0 (but ac.getCar(0).lastSplits still work which makes this mega fucked up)
    
                - Cogno 2024/04/17
]]

local mod = {}

function mod.get_current_session()
    local sim_info = ac.getSim()
    local session_index = sim_info.currentSessionIndex
    local sess = ac.getSession(session_index)
    return sess
end

function mod.is_time_valid(time) return time ~= nil and time > 0 end

-- TAG: StupidDumbCopyBullshit
-- I don't know why but if I sort manually somehow I duplicate values
-- I think it's because of the pass-by-ref vs pass-by-value thingy
-- to avoid this I use a sort function which works. But since that stupid function
-- goes from 1 to n instead of 0 to n-1, I need to copy the table into a temporary
-- stupid one, only to move indeces up by 1, the sort, then copy back into 
-- the real one
-- TL;DR this code is stupid but it works. If you can figure how to not 
-- have it stupid then I would be grateful. But for now this is the best I have.
-- To actually see the copies you have to have a car gain or loose a lot of positions,
-- else you won't really see it...
--                       Cogno 2024/04/04
--
-- UPDATE: I tried some stuff but they all didn't work:
-- 1. using metatables to reindex. It didn't work because the leaderboard is cdata,
--    to actually make it work you would have to copy all the data manually,
--    so you would be back at square 1
-- 2. my sort function. Lua is too fucking slow, sorting manually in lua is too slow,
--    performance sucks
-- 3. reindex + table.clone, nope, you still get cdata out of the clone, so you can't
--    use metatables...
-- 
-- for now we will keep the stupid clone...
--              - Cogno 2024/05/08

local players_lapcount_info = table.new(40, 0)
local player_sector_times = table.new(3, 0)
local player_last_lap_sector_times = table.new(3, 0)
local players_best_sector_times = table.new(40, 0) -- holds sector times for each player regardless of valid or invalid laps
local players_best_laptimes = table.new(40, 0)
local leaderboard_to_return = table.new(40, 0)

function mod.get_sector_splits()
    local sim_info = ac.getSim()
    local splits = sim_info.lapSplits
    if splits[0] ~= nil then return splits end
    
    -- no splits found, make it so the entire lap is just one giant sector
    local fake_splits = table.new(1, 0)
    fake_splits[0] = 0.9525
    local mt = {}
    mt.__len = function(input) return table.nkeys(input) end
    setmetatable(fake_splits, mt)
    return fake_splits
end

function mod.normalize_spline_for_nordschleife_turist(spline)
    -- since nordschleife turist is different for all other tracks (for SOME reason),
    -- we need to do this to avoid problems... yuck...
    if spline > 0.9525 then -- bridge
        spline = spline - 0.9525
    else
        spline = spline + 0.0475 -- (1 - 0.9525)
    end
    -- normalize between 0 and 1
    spline = spline / 0.9165 -- 1 / (0.8690 + (1.0 - 0.9525))
    if spline > 1 then spline = 0 end
    return spline
end

local function sort_table(to_sort)
    local session = mod.get_current_session()
    
    -- TAG: StupidDumbCopyBullshit
    local sort_len = table.nkeys(to_sort)
    local temp = table.new(sort_len, 0)
    for i=0, sort_len-1 do
        temp[i+1] = to_sort[i]
    end
    
    
    local lambda = nil
    if session.type == ac.SessionType.Practice or session.type == ac.SessionType.Qualify then
        -- complex sort, by best time and then by player name
        -- oh yeah we can *not* have the best race time...
        lambda = function(a, b)
            if b == nil then return false end
            if a == nil then return false end
            local a_time = mod.get_best_time(a)
            local b_time = mod.get_best_time(b)
            local a_valid = a_time ~= nil and a_time > 0
            local b_valid = b_time ~= nil and b_time > 0
            local a_is_useless = a_valid == false and a.car.isConnected == false
            local b_is_useless = b_valid == false and b.car.isConnected == false
            
            -- one is valid and the other is not, immediate swap
            if a_valid and b_valid == false then return true  end
            if a_valid == false and b_valid then return false end
            
            -- if both times are cool sort by fastest
            if a_valid and b_valid then
                return a_time < b_time
            end
            
            -- both invalid times, sort by offline
            if a_is_useless and b_is_useless == false then return false end
            if a_is_useless == false and b_is_useless then return true end
            
            -- sort by name
            return ac.getDriverName(a.car.index) < ac.getDriverName(b.car.index)
        end
    elseif session.type == ac.SessionType.Race then
        -- easy sort, race position (without offlines)
        lambda = function(a, b)
            if b == nil then return false end
            if a == nil then return false end
            if a.car.isActive and b.car.isActive == false then return true end
            if a.car.isActive == false and b.car.isActive then return false end
            return a.car.racePosition < b.car.racePosition
        end
    end
    table.sort(temp, lambda)
    
    local out = table.new(sort_len, 0)
    for i=0, sort_len-1 do
        out[i] = temp[i+1]
    end
    local mt = {}
    mt.__len = function(input) return table.nkeys(input) end -- overload #input so it calls table.nkeys(input), so we get the correct amount
    setmetatable(out, mt)
    return out
end

local function simple_sort(to_sort)
    -- oh but in practice/qualify the raceposition is wrong and the
    -- leaderboard is already sorted so we can skip it there
    local session = mod.get_current_session()
    if session.type == ac.SessionType.Practice or session.type == ac.SessionType.Qualify then
        return to_sort
    end
    
    -- TAG: StupidDumbCopyBullshit
    local table_len = #to_sort
    local temp = table.new(table_len, 0)
    for i=0, table_len-1 do
        temp[i+1] = to_sort[i]
    end
    
    local lambda = function(a, b)
        if b == nil then return false end
        if a == nil then return false end
        return a.car.racePosition < b.car.racePosition
    end
    table.sort(temp, lambda)
    
    local out = table.new(table_len, 0)
    for i=0, table_len-1 do
        out[i] = temp[i+1]
    end
    local mt = {}
    mt.__len = function(input) return table.nkeys(input) end
    setmetatable(out, mt)
    return out
end

local function update_leaderboard()
    local session = mod.get_current_session()
    if session.leaderboard[0] ~= nil then
        -- since assettocorsa is stupid the leaderboard is sorted
        -- only at the end of a lap, so we need to sort it immediately
        -- also in some servers you can have fake people joining and leaving every other frame, 
        -- so we filter them out, if we don't the leaderboard is gonna flicker which is bad!
        leaderboard_to_return = simple_sort(session.leaderboard)
    end
    
    local out = {}
    local index = 0
    for i, c in ac.iterateCars.leaderboard() do
        local t = {}
        t.car = c
        t.bestLapTimeMs = c.bestLapTimeMs
        out[index] = t
        index = index + 1
    end
    
    -- and since it can be FUCKING WASTED we need to sort it manually...
    leaderboard_to_return = sort_table(out)
end

function mod.get_leaderboard()
    return leaderboard_to_return
end

function mod.get_racepos(leaderboard_index)
    local leaderboard = mod.get_leaderboard()
    local session = mod.get_current_session()
    local session_type = session.type
    local leaderboard_info = leaderboard[leaderboard_index]
    if leaderboard_info == nil then return -1 end
    if session_type == ac.SessionType.Practice or session_type == ac.SessionType.Qualify then
        -- NOTE(cogno): it turns out that during qualify, racePosition is wrong, but the leaderboard is sorted by best times, so we use that instead.
        return leaderboard_index + 1 -- we add 1 because the leaderboard goes from 0 to n-1, we want the race position from 1 to n
    end
    return leaderboard_info.car.racePosition
end

function mod.get_player_leaderboard_index()
    local leaderboard = mod.get_leaderboard()
    for i=0, #leaderboard-1 do
        if leaderboard[i].car.index == 0 then return i end
    end
    return -1
end

function mod.get_best_time(leaderboard_entry)
    if leaderboard_entry == nil then return 0 end

    -- TAG: OnlineIsFuckingBroken
    -- leaderboard_entry.bestLapTimeMs and car.bestLapTimeMs always consider invalid laps, go with our own so we can track it ourselves...
    -- this is actually a pretty big problem, other functions if csp data works they return that, but we can't do that here because we 
    -- don't have an automatic way to check if it works. So if our manual data is wrong we will always report a wrong value... ouch...
    local best_time = players_best_laptimes[leaderboard_entry.car.index]
    if best_time == nil then best_time = 0 end
    return best_time
end

local function make_lapcount_info(car_index)
    local out = {
        lap_count=0,
        old_sector=ac.getCar(car_index).currentSector,
    }
    return out
end

function mod.init()
    update_leaderboard()

    -- first time we join a server, get each car's best laptime, even if it might be invalid,
    -- some data is better than no data
    local sim_info = ac.getSim()
    if sim_info.isOnlineRace then
        local leaderboard = mod.get_leaderboard()
        for i=0, #leaderboard-1 do
            local car_index = leaderboard[i].car.index
            players_best_laptimes[car_index] = leaderboard[i].bestLapTimeMs
        end
    end
end

function mod.on_session_start(session_index, restarted)
    -- reset lapcounts
    table.clear(players_lapcount_info)
    table.clear(player_sector_times)
    table.clear(player_last_lap_sector_times)
    table.clear(players_best_sector_times)
    table.clear(players_best_laptimes)
end

local function maybe_update_sector_time(car_index, sector_index, new_sector_time)
    local old_sector_best = players_best_sector_times[car_index][sector_index]
    if new_sector_time ~= nil and new_sector_time ~= 0 then
        if old_sector_best == nil or old_sector_best == 0 or new_sector_time < old_sector_best then
            players_best_sector_times[car_index][sector_index] = new_sector_time
        end
    end
end

function mod.update()
    update_leaderboard()
    local leaderboard = mod.get_leaderboard()
    -- track each car position so we can estimate the lapcount
    local sim_info = ac.getSim()
    local sector_count = #mod.get_sector_splits()
    if sim_info.isOnlineRace == false then
        -- gather best laptimes so we can use them. We're offline so thankfully we have ALL the data
        for lb_idx=0, #leaderboard-1 do
            local car_data = leaderboard[lb_idx].car
            local car_index = car_data.index
            local car_best_splits = car_data.bestLapSplits
            local car_current_splits = car_data.currentSplits
            
            if players_best_sector_times[car_index] == nil then players_best_sector_times[car_index] = table.new(sector_count, 0) end
            if car_data.isLastLapValid then
                local old_best = players_best_laptimes[car_index]
                if old_best == nil or old_best <= 0 or car_data.previousLapTimeMs < old_best then
                    players_best_laptimes[car_index] = car_data.previousLapTimeMs
                end
            end
            for sector_index=0, sector_count-1 do
                maybe_update_sector_time(car_index, sector_index, car_best_splits[sector_index])
                maybe_update_sector_time(car_index, sector_index, car_current_splits[sector_index])
            end
        end
    else
        -- TAG: OnlineIsFuckingBroken
        for lb_idx=0, #leaderboard-1 do
            local car_data = leaderboard[lb_idx].car
            local player_sector = car_data.currentSector
            local car_index = car_data.index
            
            -- DEBUG(cogno): checking for bugs in online
            -- if car_data.isActive == true then
            --     ac.debug("car " .. car_index .. ": 1 name", ac.getDriverName(car_index))
            --     ac.debug("car " .. car_index .. ": 2 best lap splits", car_data.bestLapSplits)
            --     ac.debug("car " .. car_index .. ": 3 last splits", car_data.lastSplits)
            --     ac.debug("car " .. car_index .. ": 4 best laptime", car_data.bestLapTimeMs)
            --     ac.debug("car " .. car_index .. ": 4b best laptime (from the leaderboard)", leaderboard[i].bestLapTimeMs)
            --     ac.debug("car " .. car_index .. ": 5 lapcount", car_data.lapCount)
            --     ac.debug("car " .. car_index .. ": 6 session lapcount", car_data.sessionLapCount)
            --     ac.debug("car " .. car_index .. ": 7 previous laptime", car_data.previousLapTimeMs)
            --     ac.debug("car " .. car_index .. ": 8 current splits", car_data.currentSplits)
            -- end
            
            if players_best_sector_times[car_index] == nil then players_best_sector_times[car_index] = table.new(sector_count, 0) end
            if players_best_laptimes[car_index] == nil then players_best_laptimes[car_index] = 0 end
            
            local lapcount_info = players_lapcount_info[car_index] 
            if lapcount_info == nil then lapcount_info = make_lapcount_info(car_index) end
            
            -- when spline resets the player has finished a lap
            local sector_counts = #mod.get_sector_splits()
            if player_sector ~= lapcount_info.old_sector and player_sector == 0 and lapcount_info.old_sector == sector_counts-1 then
                lapcount_info.lap_count = lapcount_info.lap_count + 1
                if car_index == 0 then
                    -- we might not have the time of the last sector of the lap just finished, calculate it
                    local laptime = car_data.previousLapTimeMs -- only works for the player so this is safe TAG: OnlineIsFuckingBroken
                    local sector_times_sum = 0
                    for sector_index=0, table.nkeys(player_sector_times)-1 do
                        sector_times_sum = sector_times_sum + player_sector_times[sector_index]
                        player_last_lap_sector_times[sector_index] = player_sector_times[sector_index]
                    end
                    local last_sector_time = laptime - sector_times_sum
                    player_last_lap_sector_times[sector_count - 1] = last_sector_time
                    
                    -- now that we have the time of the last sector check if he made a new best and save it
                    maybe_update_sector_time(car_index, sector_count - 1, last_sector_time)
                else
                    -- other players (thankfully) have getCar(<any>).lastSplits, use that to check sector time and save it
                    local last_sector_time = car_data.lastSplits[sector_count - 1]
                    maybe_update_sector_time(car_index, sector_count - 1, last_sector_time)
                end
                
                -- now check if the last laptime is a new pb (only if the lap was valid!)
                if car_data.isLastLapValid then
                    -- try with the previous laptime
                    local prev = car_data.previousLapTimeMs
                    if mod.is_time_valid(prev) then
                        -- previous laptime valid, maybe it's a new best
                        local old_player_best = players_best_laptimes[car_index]
                        if mod.is_time_valid(old_player_best) == false or prev < old_player_best then
                            players_best_laptimes[car_index] = prev
                        end
                    else
                        -- previous laptime invalid, try with the splits
                        local last_sector_times, table_length = mod.get_last_splits(car_index)
                        local last_laptime = 0
                        for last_sector_index=0, table_length-1 do
                            last_laptime = last_laptime + last_sector_times[last_sector_index]
                        end
                        local old_player_best = players_best_laptimes[car_index]
                        if mod.is_time_valid(old_player_best) == false or last_laptime < old_player_best then
                            players_best_laptimes[car_index] = last_laptime
                        end
                    end
                end
            end

            -- getCar(0).lastSplits is always (), we record the current splits so we can calculate it later
            local current_splits = car_data.currentSplits
            if car_index == 0 then
                if current_splits[0] ~= nil then
                    for split_index=0, #current_splits-1 do
                        player_sector_times[split_index] = current_splits[split_index]
                    end
                end
            end
            
            -- getCar(<any>).bestLapSplits is always (), we keep track of it ourselves as players make laps.
            -- We miss the last sector but we do it when a lap finishes.
            -- Also we do it regardless of valid/invalid laps, so we can correctly draw purple sectors
            for split_index=0, #current_splits-1 do
                maybe_update_sector_time(car_index, split_index, current_splits[split_index])
            end
            lapcount_info.old_sector = player_sector
            players_lapcount_info[car_index] = lapcount_info
        end
    end
end

function mod.get_lapcount(car_index) -- TAG: OnlineIsFuckingBroken
    local car_data = ac.getCar(car_index)
    if car_data == nil then return 0 end
    
    -- so we don't risk wrongfully using our data, offline we know for sure it works
    local ac_lapcount = car_data.lapCount
    if ac.getSim().isOnlineRace == false then return ac_lapcount end
    
    if ac_lapcount ~= 0 then return ac_lapcount end -- we can trust him
    -- if it's 0 we can't trust him, fallback into hand calculated
    local entry = players_lapcount_info[car_index]
    if entry == nil then return 0 end
    return entry.lap_count
end

function mod.get_car_best_laptime(leaderboard_index)
    local leaderboard = mod.get_leaderboard()
    return mod.get_best_time(leaderboard[leaderboard_index])
end

function mod.get_best_laptime()
    local best_laptime = 0
    local leaderboard = mod.get_leaderboard()
    for i=0, #leaderboard-1 do
        local car_best_laptime = mod.get_car_best_laptime(i)
        if car_best_laptime ~= nil and car_best_laptime > 0 then
            if best_laptime == 0 or car_best_laptime < best_laptime then
                best_laptime = car_best_laptime
            end
        end
    end
    return best_laptime
end

function mod.get_player_best_sector_times(car_index)
    local ac_best_sector_times = ac.getCar(car_index).bestSplits
    local sector_count = #mod.get_sector_splits()
    
    local data_available = true
    for i=0, sector_count-1 do
        local sector_time = ac_best_sector_times[i]
        if sector_time == nil or sector_time <= 0 then
            data_available = false
        end
    end
    
    if data_available then return ac_best_sector_times end
    
    return players_best_sector_times[car_index]
end

function mod.get_best_sector_times()
    local sector_count = #mod.get_sector_splits()
    local out = table.new(sector_count, 0)
    
    local people_count = table.nkeys(players_best_sector_times)
    for i=0, people_count-1 do
        local sector_times = mod.get_player_best_sector_times(i)
        if sector_times ~= nil then
            for sector_index=0, sector_count-1 do
                local sector_time = sector_times[sector_index]
                if sector_time ~= nil and sector_time > 0 then
                    if out[sector_index] == nil or out[sector_index] <= 0 or sector_time < out[sector_index] then
                        out[sector_index] = sector_time
                    end
                end
            end
        end
    end
    
    return out
end

function mod.get_last_splits(car_index)
    local ac_last_splits = ac.getCar(car_index).lastSplits
    if ac_last_splits ~= nil and ac_last_splits[0] ~= nil and ac_last_splits[0] > 0 then return ac_last_splits, #ac_last_splits end -- we can trust the data
    if car_index ~= 0 then return ac_last_splits, #ac_last_splits end -- other players work (for what we've seen)
    
    -- we can't trust player laptimes... sigh... return our own TAG: OnlineIsFuckingBroken
    return player_last_lap_sector_times, table.nkeys(player_last_lap_sector_times)
end

function mod.get_previous_laptime(car_index)
    local ac_last_laptime = ac.getCar(car_index).previousLapTimeMs
    if ac_last_laptime ~= nil and ac_last_laptime > 0 then return ac_last_laptime end -- we can trust the data
    
    -- we can't trust the data... sigh... calculate it from lastSplits, hope it works. If it doesn't we can't do anything anyway...
    local last_splits = ac.getCar(car_index).lastSplits
    local last_laptime = 0
    for i=0, #last_splits-1 do
        local split_time = last_splits[i]
        if split_time ~= nil and split_time > 0 then
            last_laptime = last_laptime + split_time
        end
    end
    return last_laptime
end

function mod.play_intro_anim_setup(center, size, anim_start, is_showing, disable)
    if DEV_IntroAnimOff then return end
    if disable ~= nil and disable == true and fullscreen.intro_anim_played() then return end -- pctime and maptime don't want this animation to always play, so they control it here
    local clip_anim_t = 1 - math.clamp(settings.remap(Time - anim_start, 0.6, 0.8, 0, 1), 0, 1)
    if is_showing == false then clip_anim_t = 1 end -- so we avoid first frame of flicker
    local real_size = size * 1.5 -- make it larger so we don't accidentally cut anything important
    local clip_tl = center - real_size / 2 - vec2(clip_anim_t * real_size.x, 0)
    ui.pushClipRect(clip_tl, clip_tl + real_size) -- open the clip for the whole app
end


local intro_logo_size = vec2(1024, 217) * 0.11 -- resolution of image scaled down
function mod.play_intro_anim(center, size, anim_start, app_scale)
    if DEV_IntroAnimOff then return end
    ui.popClipRect() -- close the clip for the whole app
    if not fullscreen.intro_anim_played() then return end -- we don't play our per app animation if the fullscreen one is playing now
    if anim_start + 2 <= Time then return end -- so we don't loose time drawing stuff never visible
    
    local anim_t = math.clamp(settings.remap(Time - anim_start, 0.8, 1.0, 0, 1), 0, 1)
    local logo_clip_pos = center - size / 2 + vec2(size.x * anim_t, 0)
    ui.pushClipRect(logo_clip_pos, logo_clip_pos + size)
    ui.drawImage(
        settings.get_asset("cmrt_logo"),
        center - intro_logo_size * app_scale,
        center + intro_logo_size * app_scale
    )
    ui.popClipRect()
end


return mod