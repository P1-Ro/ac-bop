local module = {}

---@class lap
---@field time integer
---@field stints table
local lap = nil

-- TAG: LuaArraysSuckAss
-- arrays in lua are actually hastables in disguise with the index starting at 1
-- to get the len of an array you use #array and it returns you the length
-- except that if you make an array starting from 0 the count will be 1 less than expected
-- that's because when you make an array from 0 to n, you're actually creating a table with 
-- value 0 AND THEN an array from 1 to n, so when you ask the length it returns n-1, because
-- the 0 is part of the TABLE not the ARRAY.
-- 
-- as if this wasn't enough, the assettocorsa api basically returns tables/arrays which 
-- DO start from 0 and where the length operator returns the correct number
--
-- since having half arrays start from 0 and half start from 1 is only asking for problems,
-- I've decided to use the api tables every time I can, so it's easier for me to use
--
--                             - Cogno 2024/03/25

local players = require("common.players")

---@param lap_stints? nil|integer[]
function module.make_new(lap_stints)
    local sim_info = ac.getSim()
    local sector_count = #players.get_sector_splits()
    local out = {
        stints = table.new(sector_count*8, 0),
    }
    
    if lap_stints == nil then
        for i=0, #players.get_sector_splits()*8 -1 do
            out.stints[i] = 0
        end
    end
    
    return out
end

function module.get_stint_index(current_spline)
    local spline_splits = players.get_sector_splits()
    
    if ac.getTrackName() == "Nordschleife - Tourist" then
        -- input spline goes from 0 to 1 because we remap it.
        -- This GREATELY simplifies calculations
        if current_spline == 0 then return -1 end
        return math.floor(current_spline * 8) -- see? MUCH simpler!
    end

    -- for each sector
    for i=0, #spline_splits-1 do
        local spline_low = spline_splits[i]
        local spline_high = 1
        if i+1 < #spline_splits then spline_high = spline_splits[i+1] end
        
        --if i'm in this sector
        if current_spline > spline_low and current_spline < spline_high then
            local spline_offset = (spline_high - spline_low) / 8
            
            -- for each stint (8 per sector)
            for stint=0, 7 do
                local spline_current = spline_low + stint * spline_offset
                local spline_next = spline_low + (stint + 1) * spline_offset
                
                -- if i'm in this stint return the index
                if current_spline > spline_current and current_spline < spline_next then
                    return i*8 + stint
                end
            end
        end
    end
    
    return -1
end

---@param lap lap
---@param stint_index integer
local function time_for_old_stints(lap, stint_index)
    local time = 0
    for i=0, stint_index-1 do
        local stint_time = lap.stints[i]
        if stint_time ~= nil then time = time + stint_time end
    end
    return time
end

---@param lap lap
function module.update(lap, current_time, current_spline)
    local stint_index = module.get_stint_index(current_spline)
    if stint_index == -1 then return end
    
    -- time took for this stint = current time - time for all stints before this one
    local time_for_stints = time_for_old_stints(lap, stint_index)
    local time_in_this_stint = current_time - time_for_stints
    lap.stints[stint_index] = time_in_this_stint
end

function module.time_to_string(time_ms)
    if time_ms == nil then return "<nil>" end
    if time_ms == 0 then return "-:--.---" end
    local time_s = time_ms / 1000
    local minutes = math.floor(time_s / 60)
    time_s = time_s - minutes * 60
    local out = string.format("%d:%06.3f", minutes, time_s)
    return out
end

function module.time_delta_to_string(time_ms)
    if time_ms == nil then return '+0.00' end
    if time_ms == 0 then return '+0.00' end
    if time_ms > 99990 then time_ms = 99990 end
    if time_ms < -99990 then time_ms = -99990 end
    local time_s = time_ms / 1000
    local sign = '+'
    if time_ms < 0 then sign = '-' end
    local out = string.format("%s%.2f", sign, math.abs(time_s))
    return out
end

function module.time_positive_delta_to_string(time_ms)
    if time_ms == nil then return "<nil>" end
    if time_ms == 0 then return "-" end
    local time_s = time_ms / 1000
    if time_s > 99.999 then time_s = 99.999 end
    local out = string.format("+%.3f", time_s)
    return out
end

---@param lap lap
---@return lap
function module.copy(lap)
    local out = {}
    out.stints = table.clone(lap.stints, true)
    return out
end

function module.get_best_time(t1, t2)
    if t1 == nil and t2 == nil then return 0 end
    if t1 == nil then return t2 end
    if t2 == nil then return t1 end
    if t2 == 0 then return t1 end -- t2 invalid, let's not screw up t1
    if t1 == 0 then return t2 end -- t1 was never set, let's update with t2 (which is valid because of the check above)
    return math.min(t1, t2) -- both valid, keep the best
end

---@param cumulative lap
---@param new lap
---@param stint_index integer
function module.aggregate(cumulative, new, stint_index)
    if stint_index ~= -1 then -- we don't want to risk saving invalid times
        for i=0,table.nkeys(cumulative.stints)-1 do
            if i ~= stint_index then
                cumulative.stints[i] = module.get_best_time(cumulative.stints[i], new.stints[i])
            end
        end
    end
end

return module