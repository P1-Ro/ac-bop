local gearbox = {} -- will be filled with public functions

local settings = require('common.settings')
local players  = require('common.players')
local colors = settings.colors
local fonts = settings.fonts

-- kmh and rpm number text is 17px
-- gear number text is 33px
-- kmh/rpm/FUEL/EST.LAP/fuel number/estimated lap number/ texts are 9px

-- gear green circle diameter is 87px
-- gear green circle padding is 6px
-- gear green circle width is 6px
-- green gots diameter is 10px (also the gray one at the bottom)
-- gray outline below is 2px
-- pillola with gray outline is 248x27 px

local function make_pillola_path(left_center, right_center, radius, segments)
    ui.pathClear()
    ui.pathArcTo(left_center, radius, math.pi/2, math.pi*3/2, segments)
    ui.pathArcTo(right_center, radius, -math.pi/2, math.pi/2, segments)
end

local on_show_animation_start = 0
local is_showing = true
local is_paused = false
function gearbox.on_open()
    if is_paused == false then
        on_show_animation_start = Time
        is_showing = true
    end
    is_paused = false
end

function gearbox.on_close()
    is_paused = ac.getSim().isPaused
    if is_paused == false then
        is_showing = false
    end
end

local previous_fuel_estimate = nil
function gearbox.init()
    -- check if we have fuel estimate
    -- we have a proper estimate, save it so next time we can get it immediately
    local trackname = ac.getTrackFullID("|||")
    local carname = ac.getCarName(0)
    local access_string = trackname .. " - " .. carname
    local fuel_estimate = ac.storage(access_string .. " :> fuel estimate", nil)
    previous_fuel_estimate = fuel_estimate:get()
end

function gearbox.on_game_close()
    local estimated_fuel = ac.getCar(0).fuelPerLap
    if estimated_fuel > 0 then
        -- we have a proper estimate, save it so next time we can get it immediately
        local trackname = ac.getTrackFullID("|||")
        local carname = ac.getCarName(0)
        local access_string = trackname .. " - " .. carname
        local fuel_estimate = ac.storage(access_string .. " :> fuel estimate", nil)
        fuel_estimate:set(estimated_fuel)
    end
end

function gearbox.main()
    local my_car = ac.getCar(0)
    if my_car == nil then return end -- should never happen
    local rpm_percentage_limiter = my_car.rpm / my_car.rpmLimiter -- fallback, if we don't have the lut table use the rpm limiter
    
    local top_bar_height = 22
    local draw_top_left = vec2(0, top_bar_height)
    
    local region_width = 260 * GearboxScale
    local region_radius = 10 * GearboxScale
    local bg_size = vec2(365,100) * GearboxScale
    local region_border = 3 * GearboxScale
    local circle_radius = bg_size.y / 2
    
    local bg_top = draw_top_left + vec2(bg_size.x / 2, 0)
    local bg_center = bg_top + vec2(0, circle_radius)
    
    -- setup for later since we use the colors
    local max_dots = 14
    local window_top = bg_center - vec2(0, bg_size.y) / 2
    local dots_start = window_top + vec2(-68, 20) * GearboxScale
    local dots_offset = vec2(14, 0) * GearboxScale
    local dot_radius = 5 * GearboxScale
    local green_to_yellow = 12
    local light_dot_count = settings.remap(my_car.rpm, 0, my_car.rpmLimiter, 0, max_dots) -- 0 dots = 0 rpm, full dots = rpm limiter
    if Gearbox_DotsWindow then
        light_dot_count = settings.remap(my_car.rpm, my_car.rpmLimiter - 1500, my_car.rpmLimiter - 300, 0, max_dots) -- 0 dots = limiter - 1500 rpm, full dots = rpm limiter
    end
    local dot_color = colors.LIGHT_GREEN
    if my_car.rpm >= my_car.rpmLimiter * green_to_yellow / max_dots then
        dot_color = colors.YELLOW
    end
    if my_car.rpm >= my_car.rpmLimiter - 300 then
        dot_color = colors.RED
    end
    
    local entire_app_size = bg_size + vec2(0, region_border + region_radius)
    local entire_app_center = draw_top_left + entire_app_size / 2
    players.play_intro_anim_setup(entire_app_center, entire_app_size, on_show_animation_start, is_showing)
    
    --
    -- background
    --
    local segments = 30
    local left_circle_center = draw_top_left + vec2(circle_radius, circle_radius)
    
    -- we change background color when it's time to switch
    local new_range = math.clamp(settings.remap(my_car.rpm, my_car.rpmLimiter - 1300, my_car.rpmLimiter - 300, 0, 1), 0, 1)
    local bg_color_norm = colors.BG
    local bg_color_red = colors.RED:clone()
    bg_color_red.mult = bg_color_norm.mult
    local dots_bg_color = settings.color_lerp(colors.GRAY, rgbm(27 / 255, 27 / 255, 27 / 255, 0.55), new_range)

    local bg_color = settings.color_lerp(bg_color_norm, bg_color_red, new_range)
    if my_car.rpm >= my_car.rpmLimiter - 300 then
        local blah = 10 * Time
        if blah % 2 >= 1 then bg_color = bg_color_norm
        else bg_color = bg_color_red end
    end
    
    local end_width = dots_start + dots_offset * (max_dots - 1) + 22 * GearboxScale
    local bottom_center = bg_center + vec2(0, circle_radius)
    local right_region_center = vec2(end_width.x + 2 * GearboxScale, bottom_center.y)
    local left_region_center = right_region_center - vec2(region_width - region_radius * 2, 0)
    
    local gearbox_bg = settings.get_asset("GEARBOX")
    ui.drawImage(
        gearbox_bg,
        bg_center - bg_size / 2,
        bg_center + bg_size / 2,
        bg_color
    )
    local bg_texture = settings.get_asset("rpm_gauge_gradient")
    ui.drawImageQuad(
        bg_texture,
        bg_center + vec2(-bg_size.x, -bg_size.y) / 2,
        bg_center + vec2(bg_size.x, -bg_size.y) / 2,
        bg_center + vec2(bg_size.x, bg_size.y) / 2,
        bg_center + vec2(-bg_size.x, bg_size.y) / 2
    )
    
    local car_gear = my_car.gear
    local gear_string = string.format("%d", car_gear)
    if car_gear == 0 then gear_string = 'N' end
    if car_gear == -1 then gear_string = 'R' end
    
    local speed = my_car.speedKmh
    if Gearbox_ShowMph then speed = speed * 0.621371 end
    local kmh_string = string.format("%.0f", speed)
    local rpm_string = string.format("%.0f", my_car.rpm)
    
    
    --
    -- green circle
    --
    local green_circle_padding = 6 * GearboxScale
    local green_circle_width = 6 * GearboxScale
    local green_circle_radius = bg_size.y / 2 - green_circle_padding - green_circle_width / 2
    local empty_angle = math.pi * 0.06
    local top_angle = 0 + empty_angle / 2
    local end_angle = math.lerp(0, top_angle + math.pi * 2 - empty_angle, math.clamp(rpm_percentage_limiter, 0, 1))
    
    ui.pathClear()
    ui.pathArcTo(left_circle_center, green_circle_radius, top_angle, top_angle + math.pi * 2 - empty_angle, 60)
    ui.pathStroke(dots_bg_color, false, green_circle_width)
    ui.pathClear()
    ui.pathArcTo(left_circle_center, green_circle_radius, top_angle, end_angle, 60)
    ui.pathStroke(dot_color, false, green_circle_width)
    
    --
    -- gear kmh and rpm texts
    --
    local gear_fontsize = settings.fontsize(30 * GearboxScale)
    local kmh_fontsize = settings.fontsize(16 * GearboxScale)
    local text_fontsize = settings.fontsize(10 * GearboxScale)
    local lowtext_fontsize = settings.fontsize(10 * GearboxScale)
    ui.pushDWriteFont(fonts.opti_edgar)
    local gear_textsize = ui.measureDWriteText(gear_string, gear_fontsize)
    ui.dwriteDrawText(gear_string, gear_fontsize, left_circle_center - gear_textsize / 2)
    
    --
    -- dots
    --
    for i = 0, max_dots - 1 do
        local dot_pos = dots_start + dots_offset * i
        local t = math.clamp(i - light_dot_count, 0, 1)
        t = 1 - math.pow(t, 4);
        if i > light_dot_count then
            dot_color = settings.color_lerp(dots_bg_color, dot_color, t)
        end
        ui.drawCircleFilled(dot_pos, dot_radius, dot_color)
        ui.drawImage(
            settings.get_asset("bloom"),
            dot_pos + -4 * dot_radius,
            dot_pos +  4 * dot_radius,
            rgbm(dot_color.r, dot_color.g, dot_color.b, t)
        )
    end
    
    
    -- KMH and RPM texts
    -- we also keep the font for later
    -- top of number text is aligned with center line of shape
    local kmh_x_offset = 60 * GearboxScale
    local rpm_x_offset = 150 * GearboxScale
    local text_vertical_offset = 3 * GearboxScale
    local kmh_number_pos = left_circle_center + vec2(kmh_x_offset, -text_vertical_offset)
    local rpm_number_pos = left_circle_center + vec2(rpm_x_offset, -text_vertical_offset)
    ui.dwriteDrawText(kmh_string, kmh_fontsize, kmh_number_pos)
    ui.dwriteDrawText(rpm_string, kmh_fontsize, rpm_number_pos)
    ui.popDWriteFont()
    
    
    local text_offset = vec2(0, 10) * GearboxScale
    ui.pushDWriteFont(fonts.archivo_medium)
    local kmh_text = "KMH"
    if Gearbox_ShowMph then kmh_text = "MPH" end
    ui.dwriteDrawText(kmh_text, text_fontsize, kmh_number_pos - text_offset, colors.TEXT_GRAY)
    ui.dwriteDrawText("RPM", text_fontsize, rpm_number_pos - text_offset, colors.TEXT_GRAY)
    
    
    local warning_liter_level = my_car.maxFuel * 0.1
    local mega_warning_liter_level = my_car.maxFuel * 0.05
    local fuel_indicator_color = colors.LIGHT_GRAY
    local area_border_color = rgbm(90 / 255, 90 / 255, 90 / 255, 0.75)
    local draw_fuel_bloom = false
    if my_car.fuel < warning_liter_level then
        fuel_indicator_color = colors.WARNING_RED
        area_border_color = colors.WARNING_RED
        draw_fuel_bloom = true
    end
    if my_car.fuel < mega_warning_liter_level then
        if (3 * Time) % 2 <= 1 then
            fuel_indicator_color = colors.WARNING_RED
            area_border_color = colors.WARNING_RED
            draw_fuel_bloom = true
        else
            fuel_indicator_color = colors.LIGHT_GRAY
            area_border_color = rgbm(65 / 255, 65 / 255, 65 / 255, 0.8)
            draw_fuel_bloom = false
        end
    end
    
    --
    -- bottom region background
    --
    make_pillola_path(left_region_center, right_region_center, region_radius + region_border / 2, segments)
    ui.pathStroke(area_border_color, true, region_border)
    make_pillola_path(left_region_center, right_region_center, region_radius, segments)
    ui.pathFillConvex(colors.BG)
    
    
    --
    -- fuel dot
    --
    local dot_offset = vec2(2, 0) * GearboxScale
    local dot_radius = 6 * GearboxScale
    local dot_center = dot_offset + left_region_center
    ui.drawCircleFilled(dot_center, dot_radius, fuel_indicator_color)
    if draw_fuel_bloom then
        ui.drawImage(
            settings.get_asset("bloom"),
            dot_center - 5 * vec2(dot_radius, dot_radius),
            dot_center + 5 * vec2(dot_radius, dot_radius),
            colors.WARNING_RED
        )
    end
    
    --
    -- fuel stuff
    --
    local region_text_size = ui.measureDWriteText("FUEL", lowtext_fontsize)
    local fuel_text_offset = vec2(15 * GearboxScale, -region_text_size.y/2)
    local fuel_text = string.format("%.1fL", my_car.fuel)
    if Gearbox_ShowGal then
        fuel_text = string.format("%.1fgal", my_car.fuel / 3.785)
    end
    ui.setCursor(left_region_center + fuel_text_offset)
    ui.dwriteText("FUEL", lowtext_fontsize, colors.TEXT_GRAY)
    ui.sameLine()
    ui.pushDWriteFont(fonts.archivo_bold)
    ui.dwriteText(fuel_text, lowtext_fontsize, colors.WHITE)
    ui.popDWriteFont()
    
    
    --
    -- estimated stuff
    --
    local estimated_fuel = my_car.fuelPerLap
    local lap_text = ''
    if estimated_fuel == 0 then
        lap_text = '-'
        if previous_fuel_estimate ~= nil then -- recover fuel estimate from old session so we have a jumping off point.
            lap_text = string.format("%.1f", my_car.fuel / previous_fuel_estimate)
        end
    else
        lap_text = string.format("%.1f", my_car.fuel / estimated_fuel)
    end
    local lap_text_offset = vec2(125 * GearboxScale, -region_text_size.y/2)
    ui.setCursor(left_region_center + lap_text_offset)
    ui.dwriteText("EST. LAP", lowtext_fontsize, colors.TEXT_GRAY)
    ui.sameLine()
    ui.pushDWriteFont(fonts.archivo_bold)
    ui.dwriteText(lap_text, lowtext_fontsize, colors.WHITE)
    ui.popDWriteFont()
    
    ui.popDWriteFont()
    players.play_intro_anim(entire_app_center, entire_app_size, on_show_animation_start, GearboxScale)
    settings.lock_app(entire_app_center, entire_app_size, APPNAMES.gearbox, GearboxScale)
    settings.auto_scale_window(entire_app_size * 1.01, APPNAMES.gearbox)
    settings.auto_place_once(entire_app_size, APPNAMES.gearbox)
end

return gearbox -- expose functions to the outside