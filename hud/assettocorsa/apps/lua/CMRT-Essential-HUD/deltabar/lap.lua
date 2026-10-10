local mod = {}

local players = require('common.players')

---@class Lap
---@field playername string
---@field carname string
---@field trackname string
---@field timestamp number
---@field lap_number number
---@field complete boolean
---@field invalid boolean
---@field invalid_sectors boolean[]
---@field laptime number
---@field splits integer[]
---@field from_file boolean
---@field next_index integer
---@field offset number[]
---@field elapsed_seconds number[]
---@field speed_ms number[]

---comment
---@param trackname string
---@param sector_count integer
---@return Lap
function mod.init(trackname, sector_count, car_index)
    local out = {
        playername = ac.getDriverName(car_index),
        carname = ac.getCarName(car_index),
        trackname = trackname,
        timestamp = 0,
        lap_number = players.get_lapcount(car_index),
        
        -- may not need these...
        complete = false,
        invalid = false,
        invalid_sectors = table.new(sector_count, 0),
        laptime = 0,
        splits = table.new(sector_count, 0),
        from_file = false,
        
        next_index = 0,
        
        offset = table.new(10000, 0),
        elapsed_seconds = table.new(10000, 0),
        speed_ms = table.new(10000, 0),
    }
    
    for i=0, sector_count-1 do
        out.invalid_sectors[i] = false
        out.splits[i] = 0
    end
    
    return out
end

function mod.bisect_right(arr, to_find, lo, hi)
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if to_find < arr[mid] then
            hi = mid
        else
            lo = mid+1
        end
    end
    return lo
end

---@param lap Lap
---@param offset number
function mod.index_for_offset(lap, offset)
    return mod.bisect_right(lap.offset, offset, 0, lap.next_index) - 1
end

---@param lap Lap
---@param offset number
function mod.is_next_offset_ok(lap, offset)
    if lap.next_index > 0 then
        local last = lap.offset[lap.next_index - 1]
        if last == nil then return false end -- out of bounds, definitely not ok
        if offset <= last or offset >= last + 0.10 then return false end -- car returned back or jumped forward, definitely invalid
    end
    return true
end

---@param lap Lap
---@param offset number
---@param elapsed_seconds number
---@param speed number
function mod.add_info(lap, offset, elapsed_seconds, speed)
    if mod.is_next_offset_ok(lap, offset) == false then
        -- we jumped. do not record it! example: Vallelunga pit exit.
        return
    end
    lap.offset[lap.next_index] = offset
    lap.elapsed_seconds[lap.next_index] = elapsed_seconds
    lap.speed_ms[lap.next_index] = speed
    lap.next_index = lap.next_index + 1
end

function mod.time_delta_to_string(time_ms)
    if time_ms == 0 then return '0.00' end
    if time_ms > 99990 then time_ms = 99990 end
    if time_ms < -99990 then time_ms = -99990 end
    local time_s = time_ms / 1000
    local out = string.format("%.2f", math.abs(time_s))
    return out
end

function mod.time_to_string(time_ms)
    if time_ms == nil then return "--.---" end
    if time_ms == 0 then return "--.---" end
    local time_s = time_ms / 1000
    local minutes = math.floor(time_s / 60)
    time_s = time_s - minutes * 60
    local out = string.format("%d:%06.3f", minutes, time_s)
    if minutes <= 0 then
        out = string.format("%06.3f", time_s)
    end
    return out
end

return mod