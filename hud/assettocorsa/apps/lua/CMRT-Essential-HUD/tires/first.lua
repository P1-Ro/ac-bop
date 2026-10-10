local tires = {} -- will be filled with public functions

local settings = require('common.settings')
local colors = settings.colors
local fonts = settings.fonts
local players = require('common.players')
local pedals = require('pedals.first')

local old_tire_wear = 0
local lapcount_when_you_changed_tires = 0

function tires.on_session_start()
    lapcount_when_you_changed_tires = 0
end

-- runs even if app is hidder, use it only if needed
function tires.update()
    local my_car = ac.getCar(0)
    
    -- to know if we've changed tyre we keep track of their wear,
    -- because you can go into pits and not change them
    local max_tyre_wear = 0
    for i=0, 3 do
        local tire_wear = my_car.wheels[i].tyreWear
        if tire_wear > max_tyre_wear then
            max_tyre_wear = tire_wear
        end
    end
    if max_tyre_wear < old_tire_wear then
        -- tyre wear got reset, reset lapcount too
        lapcount_when_you_changed_tires = players.get_lapcount(0)
    end
    
    old_tire_wear = max_tyre_wear
end

local function get_ideal_temp_range(temperature_table_data)
    local min_temp = 9999999
    local max_temp = 0
    local current_lut_idx = 0
    local current_highest_grip = 0
    if temperature_table_data ~= nil then
        while true do
            local lut_input = temperature_table_data:getPointInput(current_lut_idx)
            if math.isnan(lut_input) then break end
            
            local lut_output = temperature_table_data:getPointOutput(current_lut_idx)
            if lut_output > current_highest_grip and lut_output > 0 then
                -- the new grip is higher than the old value, min range starts here
                current_highest_grip = lut_output
                min_temp = lut_input
            end
            if lut_output == current_highest_grip and lut_output ~= 0 then
                -- the grip is the same as the peak, max range ends here
                max_temp = lut_input
            end
            
            current_lut_idx = current_lut_idx + 1
        end
    end
    if min_temp == 9999999 or max_temp == 0 then return nil, nil end -- no data!
    return min_temp, max_temp
end

local function get_lut_from_name(name)
    local temperature_table_data = nil
    if name ~= nil then
        temperature_table_data = ac.DataLUT11.carData(0, name)
        -- if the lut is empty (aka the file doesn't exist), then fall back into "no table" territory
        if temperature_table_data:bounds().y == 0 then temperature_table_data = nil end
    end
    return temperature_table_data
end

local lut_tables = table.new(0, 10)

function tires.init()
    local config = ac.INIConfig.carData(0, "tyres.ini")
    -- ac.debug("config", config)
    if config ~= nil then
        local sections = config['sections']
        for section_name, section_data in pairs(sections) do
            -- since we want to find data by tyre shortname look that up first
            local tyre_shortname_data = section_data['SHORT_NAME']
            -- TODO(cogno): sometimes we get the data sometimes we don't, it's random, figure out why...
            if tyre_shortname_data ~= nil then
                local tyre_shortname = tyre_shortname_data[1]
                
                -- we want to get ideal pressure and wear curve
                -- if we find them, good, else ignore them (they won't be displayed)
                local ideal_pressure_data = section_data['PRESSURE_IDEAL']
                local wear_curve_data = section_data['WEAR_CURVE']
                
                local to_update = lut_tables[tyre_shortname]
                if to_update == nil then to_update = {} end

                if     string.startsWith(section_name, "REAR")  then
                    if ideal_pressure_data ~= nil then to_update.rear_ideal_pressure  = ideal_pressure_data[1] end
                    if wear_curve_data     ~= nil then to_update.rear_wear_curve_name = wear_curve_data[1]     end
                elseif string.startsWith(section_name, "FRONT") then
                    if ideal_pressure_data ~= nil then to_update.front_ideal_pressure  = ideal_pressure_data[1] end
                    if wear_curve_data     ~= nil then to_update.front_wear_curve_name = wear_curve_data[1]     end
                end
                
                lut_tables[tyre_shortname] = to_update
            end
            
            -- usually thermal lut tables are in the section called THERMAL_<tyre section name>, like
            -- THERMAL_FRONT_1, or THERMAL_REAR_3, but other times some cars can use their own format,
            -- like __CM_THERMAL_FRONT_ORIGINAL (instead of THERMAL__CM_FRONT_ORIGINAL).
            -- To avoid problems with those, we go the other way around, every time we're in a section
            -- that has a thermal loot table, we get the section name, we remove THERMAL_ and we look
            -- up that section to know to which tyre this thermal lut comes from
            local section_thermal = section_data['PERFORMANCE_CURVE']
            if section_thermal ~= nil then
                -- we found a thermal, get the section tyre name
                local tyre_section_name = string.replace(section_name, "THERMAL_", "")
                local data_in_that_section = sections[tyre_section_name]
                if data_in_that_section ~= nil then
                    local tyre_shortname_data = data_in_that_section['SHORT_NAME']
                    if tyre_shortname_data ~= nil then
                        local tyre_shortname = tyre_shortname_data[1]
                        local to_update = lut_tables[tyre_shortname]
                        if to_update == nil then to_update = {} end
                        
                        local lut_name = section_thermal[1]
                        local lut_data = get_lut_from_name(lut_name)
                        local min_temp, max_temp = get_ideal_temp_range(lut_data) -- calculate ideal temperature range so we don't calculate this multiple times per frame
    
                        if     string.startsWith(tyre_section_name, "REAR") then
                            to_update.rear_temp_curve_name = lut_name
                            to_update.rear_min_ideal_temp  = min_temp
                            to_update.rear_max_ideal_temp  = max_temp
                        elseif string.startsWith(tyre_section_name, "FRONT") then
                            to_update.front_temp_curve_name = lut_name
                            to_update.front_min_ideal_temp  = min_temp
                            to_update.front_max_ideal_temp  = max_temp
                        end
                        
                        lut_tables[tyre_shortname] = to_update
                    end
                end
            end
        end
    end
    -- ac.debug("tables", lut_tables)
end

local color_red = rgbm(203 / 255, 33 / 255, 33 / 255, 1)
local color_blue = rgbm(33 / 255, 81 / 255, 203 / 255, 1)
local color_green = rgbm(33 / 255, 203 / 255, 41 / 255, 1)
local color_yellow = rgbm(203 / 255, 201 / 255, 33 / 255, 1)

local can_show_info_panel = true
local showing_info_panel = false
local info_disappear_time = 10
local info_time_to_disappear = 0
local click_priority = false
local animation_start_time = -10

local function get_wheel_color(current_temp, min_optimum_temp, max_optimum_temp, lut_table, blue_color, default_color)
    if lut_table == nil then return default_color end
    if min_optimum_temp == nil or max_optimum_temp == nil then return default_color end
    local grip_at_current_temperature = lut_table:get(current_temp)
    local peak_grip                   = lut_table:get(min_optimum_temp)
    local color_t = math.clamp(settings.remap(grip_at_current_temperature, peak_grip - 0.02, peak_grip, 0, 1), 0, 1)
    if current_temp >= min_optimum_temp and current_temp <= max_optimum_temp then
        -- we're in the ideal temp range, definitely green
        return color_green
    elseif current_temp > max_optimum_temp then
        -- we go from green (grip at 100%) to red (grip at 98%)
        return settings.color_lerp_hsv(color_red, color_green, color_t)
    elseif current_temp < min_optimum_temp then
        -- we go from green (grip at 100%) to blue (grip at 98%)
        return settings.color_lerp_hsv(blue_color, color_green, color_t)
    end
end

local function draw_tire(tire_pos, tire_height, tire_piece_width, tire_padding, tire_index, show_on_right, ideal_pressure)
    local piece_size = vec2(tire_piece_width, tire_height)
    local left_center  = tire_pos + vec2(-tire_piece_width - tire_padding, 0)
    local right_center = tire_pos + vec2( tire_piece_width + tire_padding, 0)
    
    local my_car_info = ac.getCar(0)
    local wheel = my_car_info.wheels[tire_index]
    local is_broken = false
    if wheel.isBlown or wheel.tyreWear >= 1 then
        is_broken = true
    end
    
    
    local wear_string = string.format("%d%%", (1 - wheel.tyreWear) * 100)
    if wheel.tyreWear < -0.1 then
        wear_string = '-'
    end

    local coretemp_string = ''
    if Tyres_ShowFah then
        coretemp_string = string.format("%d°F", 32 + (wheel.tyreCoreTemperature * 9 / 5))
    else
        coretemp_string = string.format("%d°C", wheel.tyreCoreTemperature)
    end
    
    local pressure_string = string.format("%d psi", wheel.tyrePressure)
    if Tyres_PressureDelta and ideal_pressure ~= nil then
        local pressure_delta = wheel.tyrePressure - ideal_pressure
        if pressure_delta >= 0 then
            pressure_string = string.format("+%.1f psi", math.clamp(pressure_delta, 0, 9.9))
        else
            pressure_string = string.format("-%.1f psi", math.clamp(-pressure_delta, 0, 9.9))
        end
    end
    
    if is_broken then
        pressure_string = '- psi'
        if Tyres_ShowFah then 
            coretemp_string = '-°F'
        else
            coretemp_string = '-°C'
        end
    end
    
    local optimum_temp = wheel.tyreOptimumTemperature
    local mid_temp     = wheel.tyreMiddleTemperature
    local in_temp      = wheel.tyreInsideTemperature
    local out_temp     = wheel.tyreOutsideTemperature
    local fontsize = settings.fontsize(10) * TyresScale
    ui.pushDWriteFont(fonts.archivo_medium)
    
    -- tyre pressure
    local coretemp_text_size = ui.measureDWriteText(pressure_string, fontsize)
    local pos_offset = vec2(20, -24) * TyresScale
    if show_on_right == false then
        pos_offset = vec2(-pos_offset.x - coretemp_text_size.x, pos_offset.y)
    end
    ui.dwriteDrawText(pressure_string, fontsize, tire_pos + pos_offset, colors.TEXT_GRAY)
    
    -- tyre core temperature
    local coretemp_text_size = ui.measureDWriteText(coretemp_string, fontsize)
    local pos_offset = vec2(20 * TyresScale, -coretemp_text_size.y / 2)
    if show_on_right == false then
        pos_offset = vec2(-pos_offset.x - coretemp_text_size.x, pos_offset.y)
    end
    
    local current_tirename = ac.getTyresName(0)
    local lut_data = lut_tables[current_tirename]
    local temperature_table_data = nil
    local min_ideal_temp, max_ideal_temp = nil, nil
    if lut_data ~= nil then
        if tire_index < 2 then
            -- front tyres
            temperature_table_data = get_lut_from_name(lut_data.front_temp_curve_name)
            min_ideal_temp = lut_data.front_min_ideal_temp
            max_ideal_temp = lut_data.front_max_ideal_temp
        else -- rear tyres
            temperature_table_data = get_lut_from_name(lut_data.rear_temp_curve_name)
            min_ideal_temp = lut_data.rear_min_ideal_temp
            max_ideal_temp = lut_data.rear_max_ideal_temp
        end
    end
    if min_ideal_temp == nil or max_ideal_temp == nil then
        min_ideal_temp = optimum_temp
        max_ideal_temp = optimum_temp
    end
    
    -- sections colors
    -- NOTE(cogno): for some reason assettocorsa already flips temperatures but still calls them "inside" and "outside"... they should be called "left" and "right" you morons!
    local center_color = get_wheel_color(mid_temp, min_ideal_temp, max_ideal_temp, temperature_table_data, color_blue, colors.GRAY)
    local left_color   = get_wheel_color(in_temp , min_ideal_temp, max_ideal_temp, temperature_table_data, color_blue, colors.GRAY)
    local right_color  = get_wheel_color(out_temp, min_ideal_temp, max_ideal_temp, temperature_table_data, color_blue, colors.GRAY)
    
    local temp_font_color = colors.WHITE
    if Tyres_TempColored then
        temp_font_color = get_wheel_color(wheel.tyreCoreTemperature, min_ideal_temp, max_ideal_temp, temperature_table_data, colors.INDICATOR_BLUE, colors.TEXT_GRAY)
    end
    ui.dwriteDrawText(coretemp_string, fontsize, tire_pos + pos_offset, temp_font_color)
    
    -- tyre wear
    local tire_wear_text_size = ui.measureDWriteText(wear_string, fontsize)
    local pos_offset = vec2(20, 8) * TyresScale
    if show_on_right == false then
        pos_offset = vec2(-pos_offset.x - tire_wear_text_size.x, pos_offset.y)
    end
    ui.dwriteDrawText(wear_string, fontsize, tire_pos + pos_offset, colors.TEXT_GRAY)
    ui.popDWriteFont()
    
    if is_broken then
        center_color = colors.LIGHT_BG
        left_color   = colors.LIGHT_BG
        right_color  = colors.LIGHT_BG
    end
    
    ui.drawRectFilled(tire_pos - piece_size / 2, tire_pos + piece_size / 2, center_color)
    ui.drawRectFilled(left_center - piece_size / 2, left_center + piece_size / 2, left_color, 10, ui.CornerFlags.Left)
    ui.drawRectFilled(right_center - piece_size / 2, right_center + piece_size / 2, right_color, 10, ui.CornerFlags.Right)
    
    
    local dots_width = 32 * TyresScale
    local blown_rect_size = vec2(dots_width, tire_height + 8)
    if is_broken then
        ui.drawImageQuad(
            settings.get_asset("puncture"),
            tire_pos - blown_rect_size / 2,
            tire_pos + vec2(blown_rect_size.x, -blown_rect_size.y) / 2,
            tire_pos + blown_rect_size / 2,
            tire_pos + vec2(-blown_rect_size.x, blown_rect_size.y) / 2
        )
    end
    
    local slip_rect_size = vec2(dots_width, 22 * TyresScale)
    if wheel.ndSlip > 1.5 and is_broken == false then
        ui.drawImageQuad(
            settings.get_asset("slip"),
            tire_pos - slip_rect_size / 2,
            tire_pos + vec2(slip_rect_size.x, -slip_rect_size.y) / 2,
            tire_pos + slip_rect_size / 2,
            tire_pos + vec2(-slip_rect_size.x, slip_rect_size.y) / 2
        )
    end
end

local on_show_animation_start = 0
local is_showing = true
local is_paused = false
function tires.on_open()
    if is_paused == false then
        on_show_animation_start = Time
        is_showing = true
    end
    is_paused = false
end

function tires.on_close()
    is_paused = ac.getSim().isPaused
    if is_paused == false then
        is_showing = false
    end
end

function tires.main()
    local draw_top_left = vec2(0, 22)
    local draw_size = ui.windowSize() - vec2(0, 22)
    local draw_center = draw_top_left + draw_size / 2
    
    local rect_width = 200 * TyresScale
    if Tyres_PressureDelta then
        rect_width = 220 * TyresScale
    end
    
    local my_car_info = ac.getCar(0)
    local tyres_wear_max = 0
    local index_of_worst_tire = 0
    local tyre_current_vkm = 0
    for i=0, 3 do
        local wheel_wear = my_car_info.wheels[i].tyreWear
        if wheel_wear > tyres_wear_max then
            tyres_wear_max = wheel_wear
            index_of_worst_tire = i
            tyre_current_vkm = my_car_info.wheels[i].tyreVirtualKM * 10
        end
    end
    
    local current_tirename = ac.getTyresName(0)
    local lut_data = lut_tables[current_tirename]
    local lutname_of_current_tire = nil
    if lut_data ~= nil then
        -- NOTE(cogno): here we could easily use one of the wear curves if
        -- the other is not available, that would be a mistake. Since that data
        -- is missing also for AC, that tyre will not behave properly, so using that
        -- data would be disingenuous. It would be like coloring a tyre green when it's
        -- actually blue.
        lutname_of_current_tire = lut_data.front_wear_curve_name
        if index_of_worst_tire >= 2 then
            lutname_of_current_tire = lut_data.rear_wear_curve_name
        end
    end
    
    local inverted_lut = ac.DataLUT11()
    if lutname_of_current_tire ~= nil then
        local wear_lut_data = ac.DataLUT11.carData(0, lutname_of_current_tire)
        local current_lut_index = 0
        local old_output = wear_lut_data:getPointInput(0)
        while true do
            local lut_input = wear_lut_data:getPointInput(current_lut_index)
            if math.isnan(lut_input) then break end
            
            local lut_output = wear_lut_data:getPointOutput(current_lut_index)
            if lut_output <= old_output then
                inverted_lut:add(lut_output, lut_input)
            end
            
            old_output = lut_output
            current_lut_index = current_lut_index + 1
        end
    end
    
    local wear_levels = { [0]=94, 96, 98, 100 }
    local levels = {}
    for i=0, 3 do
        levels[i] = 10 * inverted_lut:get(wear_levels[i])
    end
    
    local percentages = {}
    for i=0,2 do
        percentages[i] = -(levels[i+1]-levels[0]) / levels[0]
    end
    
    -- text we draw on info panel
    ui.pushDWriteFont(fonts.archivo_medium)
    
    local fontsize = settings.fontsize(10) * TyresScale

    local long_tirename = ac.getTyresLongName(0)
    local pressure_string = "No data"
    local min_temp = nil
    local max_temp = nil
    if lut_data ~= nil then
        local ideal_pressure_front = lut_data.front_ideal_pressure
        local ideal_pressure_rear = lut_data.rear_ideal_pressure
        if ideal_pressure_front ~= nil then
            pressure_string = string.format("%d psi", ideal_pressure_front)
        end
        if ideal_pressure_rear ~= nil then
            pressure_string = string.format("%d psi", ideal_pressure_rear)
        end
        if ideal_pressure_front ~= nil and ideal_pressure_rear ~= nil then
            pressure_string = string.format("%d psi  /  %d psi", ideal_pressure_front, ideal_pressure_rear)
        end
        min_temp, max_temp = lut_data.front_min_ideal_temp, lut_data.front_max_ideal_temp
    end
    
    local temp_range_string = "No data"
    if min_temp ~= nil and max_temp ~= nil then
        if min_temp == max_temp then
            if Tyres_ShowFah then
                temp_range_string = string.format("%d °F", 32 + (min_temp * 9 / 5))
            else
                temp_range_string = string.format("%d °C", min_temp)
            end
        else
            if Tyres_ShowFah then
                temp_range_string = string.format("%d °F - %d °F", 32 + (min_temp * 9 / 5), 32 + (max_temp * 9 / 5))
            else
                temp_range_string = string.format("%d °C - %d °C", min_temp, max_temp)
            end
        end
    end
    
    
    local sim_info = ac.getSim()
    local tire_consumption_rate = sim_info.tyreConsumptionRate
    local eol_level  = inverted_lut:get(94)
    local low_level  = inverted_lut:get(96)
    local mid_level  = inverted_lut:get(98)
    local high_level = inverted_lut:get(100)
    local eol_value_km  = 10 * eol_level  / tire_consumption_rate
    local low_value_km  = 10 * low_level  / tire_consumption_rate
    local mid_value_km  = 10 * mid_level  / tire_consumption_rate
    local high_value_km = 10 * high_level / tire_consumption_rate
    
    local track_length_km = sim_info.trackLengthM / 1000
    local high_lapcount = high_value_km / track_length_km
    local mid_lapcount = mid_value_km / track_length_km
    local low_lapcount = low_value_km / track_length_km
    local eol_lapcount = eol_value_km / track_length_km
    
    
    local high_grip_string = string.format("%.1f Laps (%.1f Km)", high_lapcount, high_value_km)
    local  mid_grip_string = string.format("%d Laps (%.1f Km)", mid_lapcount, mid_value_km)
    local  low_grip_string = string.format("%d Laps (%.1f Km)", low_lapcount, low_value_km)
    local  eol_grip_string = string.format("%d Laps (%.1f Km)", eol_lapcount, eol_value_km)
    if high_lapcount > 1 then
        high_grip_string = string.format("%d Laps (%.1f Km)", high_lapcount, high_value_km)
    end
    
    if Tyres_ShowMph then
        high_grip_string = string.format("%.1f Laps (%.1f Mi)", high_lapcount, high_value_km * 0.621371)
        mid_grip_string = string.format("%d Laps (%.1f Mi)", mid_lapcount, mid_value_km * 0.621371)
        low_grip_string = string.format("%d Laps (%.1f Mi)", low_lapcount, low_value_km * 0.621371)
        eol_grip_string = string.format("%d Laps (%.1f Mi)", eol_lapcount, eol_value_km * 0.621371)
        if high_lapcount > 1 then
            high_grip_string = string.format("%d Laps (%.1f Mi)", high_lapcount, high_value_km * 0.621371)
        end
    end
    

    -- NOTE(cogno): because the lut gets inverted bounds().y will be always be 0, but x shouldn't
    if lut_data == nil or inverted_lut:bounds().x == 0 then
        high_grip_string = "No data"
        mid_grip_string = "No data"
        low_grip_string = "No data"
        eol_grip_string = "No data"
    end

    if sim_info.tyreConsumptionRate == 0 then
        high_grip_string = "No tyre wear"
        mid_grip_string  = "No tyre wear"
        low_grip_string  = "No tyre wear"
        eol_grip_string  = "No tyre wear"
    end
    
    local size_of_tirename = ui.measureDWriteText(long_tirename, fontsize)
    local size_of_ideal_pressure = ui.measureDWriteText(pressure_string, fontsize)
    local size_of_temp = ui.measureDWriteText(temp_range_string, fontsize)
    local size_of_high_grip = ui.measureDWriteText(high_grip_string, fontsize)
    local size_of_mid_grip = ui.measureDWriteText(mid_grip_string, fontsize)
    local size_of_low_grip = ui.measureDWriteText(low_grip_string, fontsize)
    local size_of_eol_grip = ui.measureDWriteText(eol_grip_string, fontsize)
    
    local max_size_needed = math.max(
        size_of_tirename.x,
        size_of_ideal_pressure.x,
        size_of_temp.x,
        size_of_high_grip.x,
        size_of_mid_grip.x,
        size_of_low_grip.x,
        size_of_eol_grip.x
    )
    
    ui.popDWriteFont()
    
    local text_padding = 12 * TyresScale
    local text_pad = vec2(text_padding, text_padding)
    local horizontal_info_spacing = 125 * TyresScale
    local wanted_info_rect_size = math.max(220 * TyresScale, horizontal_info_spacing + max_size_needed + text_padding * 2)

    
    -- clicking on main area opens/closes the info panel
    local corner_tl = draw_center - draw_size / 2
    local main_rect_size  = vec2(rect_width, 82 * TyresScale)
    local screensize = settings.get_screensize()
    local window_center = ui.windowPos() + ui.windowSize() / 2
    local main_click_center = corner_tl + main_rect_size / 2
    if window_center.x > screensize.x / 2 then
        main_click_center = draw_center + vec2(draw_size.x - main_rect_size.x, main_rect_size.y-draw_size.y) / 2
    end
    if ui.mouseClicked(ui.MouseButton.Left) and settings.is_inside(ui.mouseLocalPos(), main_click_center, main_rect_size / 2) then
        if showing_info_panel then
            showing_info_panel  = false
            can_show_info_panel = false
            click_priority = false
            animation_start_time = Time
        else
            showing_info_panel = true
            can_show_info_panel = true
            click_priority = true
            animation_start_time = Time
        end
    end
    
    local current_info_rect_size = 0
    local animation_elapsed_time = math.clamp(Time - animation_start_time, 0, 10)
    local anim_duration = 0.1
    local t = math.clamp(settings.remap(animation_elapsed_time, 0, anim_duration, 0, 1), 0, 1)
    if showing_info_panel then
        current_info_rect_size = wanted_info_rect_size * t
    else
        current_info_rect_size = wanted_info_rect_size * (1 - t)
    end
    
    -- if holding inside the window show the info panel, so player can adjust the window accordingly
    -- but not if he clicked to open/close the info panel, that starts the opening/closing animation,
    -- you don't want to override it!
    
    local tires_rect_size = vec2(rect_width, 150 * TyresScale)
    local rect_size = vec2(rect_width, main_rect_size.y + tires_rect_size.y)
    local info_size = vec2(current_info_rect_size, 160 * TyresScale)
    local info_corner_tl = corner_tl + vec2(rect_width, 0)
    if ui.mouseDown(ui.MouseButton.Left) and settings.is_inside(ui.mouseLocalPos(), ui.windowSize() / 2, ui.windowSize() / 2) then
        local main_panel_tl = corner_tl
        local info_panel_tl = info_corner_tl
        local info_panel_size = vec2(wanted_info_rect_size, info_size.y)
        if window_center.x > screensize.x / 2 then
            main_panel_tl = draw_center + vec2(draw_size.x / 2 - rect_size.x, -draw_size.y / 2)
            info_panel_tl = main_panel_tl - vec2(info_panel_size.x, 0)
        end
        
        local inside_main_panel = settings.is_inside(ui.mouseLocalPos(), main_panel_tl + main_rect_size / 2, main_rect_size / 2)
        local inside_info_panel = settings.is_inside(ui.mouseLocalPos(), info_panel_tl + info_panel_size / 2, info_panel_size / 2)
        if not inside_main_panel then
            -- clicked outside main panel
            if not inside_info_panel then
                -- clicked outside both panels, or inside info panel while it's closed/closing/opening, immediately show
                current_info_rect_size = wanted_info_rect_size
                info_size.x = current_info_rect_size
            else
                -- clicked on the info panel
                if not showing_info_panel and t >= 1 then
                    -- clicked on info panel while closed, immediately show
                    current_info_rect_size = wanted_info_rect_size
                    info_size.x = current_info_rect_size
                else
                    -- clicked on info panel while it's open/opening/closing, ignore, play the anim
                end
            end
        else
            -- if we click on the main panel we just show the opening/closing animation (done later, do nothing here)
        end
    end
    
    local pedals_corner_tl = info_corner_tl + vec2(0, info_size.y)
    local pedals_rect_size = vec2(140, 72) * TyresScale
    if Pedals_ShowHandbrake then pedals_rect_size.x = 155 * TyresScale end
    local pedals_flipped = false
    
    local main_area_tl = vec2(math.floor(corner_tl.x), math.floor(corner_tl.y))
    local main_area_br = corner_tl + main_rect_size + vec2(current_info_rect_size, 0)
    if window_center.x > screensize.x / 2 then
        corner_tl = draw_center + vec2(draw_size.x / 2 - rect_size.x, -draw_size.y / 2)
        info_corner_tl = corner_tl - vec2(info_size.x, 0)
        pedals_corner_tl = corner_tl + vec2(-pedals_rect_size.x, info_size.y)
        pedals_flipped = true
        main_area_tl = corner_tl - vec2(current_info_rect_size, 0)
        main_area_br = corner_tl + main_rect_size
    end
    main_area_tl = vec2(math.round(main_area_tl.x), math.round(main_area_tl.y))
    main_area_br = vec2(math.round(main_area_br.x), math.round(main_area_br.y))
    local corner_br = corner_tl + rect_size
    local tyres_center = corner_br - tires_rect_size / 2
    
    local entire_app_size = vec2(tires_rect_size.x + wanted_info_rect_size, corner_br.y - main_area_tl.y)
    local entire_app_center = main_area_tl + entire_app_size / 2
    if window_center.x > screensize.x / 2 then
        entire_app_center = corner_tl - vec2(wanted_info_rect_size, 0) + entire_app_size / 2
    end
    players.play_intro_anim_setup(entire_app_center, entire_app_size, on_show_animation_start, is_showing)

    ui.drawRectFilled(main_area_tl, main_area_br, colors.BG, 5 * TyresScale, ui.CornerFlags.Top)
    ui.drawRectFilled(corner_br - tires_rect_size, corner_br, colors.LIGHT_BG)
    
    ui.drawImage(
        settings.get_asset("tyres_dot"),
        corner_tl,
        corner_tl + vec2(220, 82) * TyresScale, -- we don't want to change them if app resizes
        rgbm(1, 1, 1, 0.6)
    )
    
    
    --
    -- tyre name
    --
    local text_spacing = 4 * TyresScale
    ui.pushDWriteFont(fonts.archivo_bold)
    local comp_text = "Comp:"
    local comp_textsize = ui.measureDWriteText(comp_text, fontsize)
    local comp_text_pos = corner_tl + text_pad
    local comp_number_pos = comp_text_pos + vec2(comp_textsize.x + text_spacing, 0)
    ui.dwriteDrawText(comp_text, fontsize, comp_text_pos, colors.TEXT_GRAY)
    ui.dwriteDrawText(current_tirename, fontsize, comp_number_pos, colors.WHITE)
    ui.popDWriteFont()
    
    --
    -- stint text
    --
    ui.pushDWriteFont(fonts.archivo_bold)
    local stint_text = "Laps:"
    local stint_textsize = ui.measureDWriteText(stint_text, fontsize)
    local stint_text_pos = corner_tl + text_pad + vec2(0, 19) * TyresScale
    local stint_number_pos = stint_text_pos + vec2(stint_textsize.x + text_spacing, 0)
    ui.dwriteDrawText(stint_text, fontsize, stint_text_pos, colors.TEXT_GRAY)
    ui.dwriteDrawText(string.format("%d", players.get_lapcount(0) - lapcount_when_you_changed_tires + 1), fontsize, stint_number_pos, colors.WHITE)
    ui.popDWriteFont()
    
    
    
    --
    -- tyre wear percentage bar
    --
    local color_low  = color_green
    local color_high = color_green
    local lerp_percentage = 1
    if tyre_current_vkm > levels[1] then -- below red symbol
        color_low  = color_red
        color_high = color_red
        lerp_percentage = 1
        if (Time * 2) % 2 <= 1 then
            color_low = rgbm(0,0,0,0)
            color_high = rgbm(0,0,0,0)
        end
    elseif tyre_current_vkm > levels[2] then -- between red and yellow
        color_low = color_red
        color_high = color_yellow
        lerp_percentage = (tyre_current_vkm - levels[2]) / (levels[1] - levels[2])
    elseif tyre_current_vkm > levels[3] then -- between yellow and blue
        color_low = color_yellow
        lerp_percentage = (tyre_current_vkm - levels[3]) / (levels[2] - levels[3])
    else -- above blue
        lerp_percentage = 1
    end
    
    local tyre_wear_percentage = math.clamp(1 - tyres_wear_max, 0, 1)
    if inverted_lut:bounds().x == 0 then
        color_low = color_red
        color_high = color_green
        lerp_percentage = tyre_wear_percentage
    end

    local bar_width = rect_width - text_padding * 2 - 2 * TyresScale
    local bar_height = 8 * TyresScale
    local bar_radius = 4 * TyresScale
    local bar_size = vec2(bar_width, bar_height)
    local bar_center = corner_tl + vec2(rect_width, main_rect_size.y) / 2 + vec2(0, 24) * TyresScale
    local bar_pos_tl = bar_center - bar_size / 2
    local bar_color = settings.color_lerp_hsv(color_high, color_low, lerp_percentage)
    local bar_fill_percentage = 1 - math.clamp(settings.remap(tyre_current_vkm, 0, eol_value_km, 0, 1), 0, 1) -- NEW
    if inverted_lut:bounds().x == 0 then bar_fill_percentage = 1 - tyre_wear_percentage end
    ui.drawRectFilled(bar_pos_tl, bar_center + bar_size / 2, colors.GRAY, bar_radius)
    ui.pushClipRect(bar_pos_tl, bar_pos_tl + vec2(bar_width * bar_fill_percentage, bar_height))
    ui.drawRectFilled(bar_pos_tl, bar_pos_tl + vec2(bar_width, bar_height), bar_color, bar_radius)
    ui.popClipRect()
    
    
    local line_width = 2 * TyresScale
    local triangle_height = 7 * TyresScale
    local triangle_width = 10 * TyresScale
    for i=0,2 do
        local width_px = bar_width * percentages[i]
        local line_start = bar_pos_tl + vec2(math.floor(width_px), 0)
        local line_end   = line_start + vec2(line_width, bar_height)
        
        local level_color = colors.RED
        if i == 1 then level_color = colors.INDICATOR_YLLW end
        if i == 2 then level_color = colors.INDICATOR_BLUE end
        
        ui.drawRectFilled(line_start, line_end, level_color)
        local triangle_tip_pos = line_start + vec2(line_width / 2, 0)
        ui.drawTriangleFilled(triangle_tip_pos, triangle_tip_pos + vec2(triangle_width / 2, -triangle_height), triangle_tip_pos + vec2(-triangle_width / 2, -triangle_height), level_color)
    end
    
    --
    -- tyre graphics
    --
    local front_ideal_pressure = nil -- tonumber(lut_data.front_ideal_pressure)
    local rear_ideal_pressure  = nil -- tonumber(lut_data.rear_ideal_pressure)
    if lut_data ~= nil then
        if lut_data.front_ideal_pressure ~= nil then
            front_ideal_pressure = tonumber(lut_data.front_ideal_pressure)
        end
        if lut_data.rear_ideal_pressure ~= nil then
            rear_ideal_pressure  = tonumber(lut_data.rear_ideal_pressure)
        end
    end
    local tire_height = 52 * TyresScale
    local tire_piece_width = 8 * TyresScale
    local tire_padding = 1 * TyresScale
    local tire_to_tire_hor = 80 * TyresScale - 3 * tire_piece_width
    local tire_to_tire_ver = 122 * TyresScale - tire_height
    local tire_tl_pos = tyres_center + vec2(-tire_to_tire_hor, -tire_to_tire_ver) / 2
    local tire_tr_pos = tyres_center + vec2( tire_to_tire_hor, -tire_to_tire_ver) / 2
    local tire_bl_pos = tyres_center + vec2(-tire_to_tire_hor,  tire_to_tire_ver) / 2
    local tire_br_pos = tyres_center + vec2( tire_to_tire_hor,  tire_to_tire_ver) / 2
    draw_tire(tire_tl_pos, tire_height, tire_piece_width, tire_padding, 0, false, front_ideal_pressure)
    draw_tire(tire_tr_pos, tire_height, tire_piece_width, tire_padding, 1, true, front_ideal_pressure)
    draw_tire(tire_bl_pos, tire_height, tire_piece_width, tire_padding, 2, false, rear_ideal_pressure)
    draw_tire(tire_br_pos, tire_height, tire_piece_width, tire_padding, 3, true, rear_ideal_pressure)
    
    --
    -- tyres stats panel
    --
    if my_car_info.isInPitlane == false then
        can_show_info_panel = true
    end
    if my_car_info.isInPitlane then
        click_priority = false
        info_time_to_disappear = Time + info_disappear_time
        if can_show_info_panel and showing_info_panel == false then
            showing_info_panel = true
            can_show_info_panel = false
            animation_start_time = Time
        end
    end
    
    if Time > info_time_to_disappear and my_car_info.isInPitlane == false and click_priority == false and showing_info_panel then
        showing_info_panel = false
        animation_start_time = Time
    end
    
    -- when you click on the info panel you hide it
    if ui.mouseClicked(ui.MouseButton.Left) and showing_info_panel and settings.is_inside(ui.mouseLocalPos(), info_corner_tl + info_size / 2, info_size / 2) then
        showing_info_panel = false
        can_show_info_panel = false
        click_priority = false
        animation_start_time = Time
    end
    
    -- background
    local t = info_corner_tl + vec2(0, main_rect_size.y)
    ui.drawRectFilled(t, info_corner_tl + info_size, colors.BG)
    ui.pushClipRect(info_corner_tl, info_corner_tl + info_size)
    
    ui.pushDWriteFont(fonts.archivo_medium)
    
    local line_height = 18 * TyresScale
    local moving_position = info_corner_tl + text_pad + vec2(11, 0) * TyresScale
    ui.dwriteDrawText("Compound:", fontsize, moving_position, colors.TEXT_GRAY)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText("Pressure F/R:", fontsize, moving_position, colors.TEXT_GRAY)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText("Temp Range:", fontsize, moving_position, colors.TEXT_GRAY)
    moving_position = moving_position + vec2(0, 32) * TyresScale
    
    ui.drawTriangleFilled(
        moving_position + vec2(-6, 7) * TyresScale,
        moving_position + vec2(-6, 7) * TyresScale + vec2(-triangle_height,  triangle_width / 2),
        moving_position + vec2(-6, 7) * TyresScale + vec2(-triangle_height, -triangle_width / 2),
        colors.INDICATOR_BLUE
    )
    ui.dwriteDrawText("High Grip:", fontsize, moving_position, colors.TEXT_GRAY)
    moving_position = moving_position + vec2(0, line_height)
    ui.drawTriangleFilled(
        moving_position + vec2(-6, 7) * TyresScale,
        moving_position + vec2(-6, 7) * TyresScale + vec2(-triangle_height,  triangle_width / 2),
        moving_position + vec2(-6, 7) * TyresScale + vec2(-triangle_height, -triangle_width / 2),
        colors.INDICATOR_YLLW
    )
    ui.dwriteDrawText("Medium Grip:", fontsize, moving_position, colors.TEXT_GRAY)
    moving_position = moving_position + vec2(0, line_height)
    ui.drawTriangleFilled(
        moving_position + vec2(-6, 7) * TyresScale,
        moving_position + vec2(-6, 7) * TyresScale + vec2(-triangle_height,  triangle_width / 2),
        moving_position + vec2(-6, 7) * TyresScale + vec2(-triangle_height, -triangle_width / 2),
        colors.RED
    )
    ui.dwriteDrawText("Low Grip:", fontsize, moving_position, colors.TEXT_GRAY)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText("End of Life:", fontsize, moving_position, colors.TEXT_GRAY)
    
    -- reset moving position for right column
    moving_position = info_corner_tl + text_pad + vec2(horizontal_info_spacing, 0)
    -- ui.dwriteDrawText(ac.getTyresLongName(0), fontsize, colors.WHITE)
    
    ui.dwriteDrawText(long_tirename, fontsize, moving_position, colors.WHITE)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText(pressure_string, fontsize, moving_position, colors.WHITE)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText(temp_range_string, fontsize, moving_position, colors.WHITE)
    moving_position = moving_position + vec2(0, 32) * TyresScale
    
    ui.dwriteDrawText(high_grip_string, fontsize, moving_position, colors.WHITE)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText(mid_grip_string, fontsize, moving_position, colors.WHITE)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText(low_grip_string, fontsize, moving_position, colors.WHITE)
    moving_position = moving_position + vec2(0, line_height)
    ui.dwriteDrawText(eol_grip_string, fontsize, moving_position, colors.WHITE)
    
    ui.popDWriteFont()
    ui.popClipRect()

    if Tyres_ShowPedals then
        pedals.draw_pedals(pedals_corner_tl, pedals_rect_size, pedals_flipped, TyresScale)
    end
    -- ui.drawRect(draw_top_left, draw_top_left + draw_size, colors.WHITE)
    players.play_intro_anim(entire_app_center, entire_app_size, on_show_animation_start, TyresScale)
    settings.lock_app(entire_app_center, entire_app_size, APPNAMES.tyres, TyresScale)
    settings.auto_scale_window(entire_app_size * 1.01, APPNAMES.tyres)
    settings.auto_place_once(entire_app_size, APPNAMES.tyres)
end

return tires -- expose functions to the outside