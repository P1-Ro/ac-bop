local mod = {} -- will be filled with public functions

local settings = require('common.settings')
local colors = settings.colors
local players = require('common.players')

local function get_alpha(car_dist, dot, dist_scale)
    local alpha_val = settings.remap(car_dist, 12, 9, 0, 1.1)
    local alpha_scaler = settings.remap(math.clamp(dot, 0, 1), 0, 1, 0, 1.2)
    return math.clamp(alpha_val - alpha_scaler, 0, 1)
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

local radar_lines_left  = table.new(2, 0)
local radar_lines_right = table.new(2, 0)

local function add_to_array(array, index, total_alpha, other_screenheight, warn_color, bar_height, threat_screendist)
    local to_add = table.new(0, 5)
    to_add.alpha = total_alpha
    to_add.threat_y = other_screenheight
    to_add.color = warn_color
    to_add.bar_height = bar_height
    to_add.screen_dist = threat_screendist
    array[index] = to_add
end

function mod.main()
    local draw_top_left = vec2(0, 22)
    local draw_size = ui.windowSize() - vec2(0, 22)
    local draw_center = draw_top_left + draw_size / 2

    -- get info on closest car to choose alpha value
    local dist_scale = 32.25
    local leaderboard = players.get_leaderboard()
    local my_car_info = ac.getCar(0)
    local player_pos = my_car_info.position
    local player_forw = my_car_info.look
    local player_angle = math.atan2(player_forw.z, player_forw.x)
    local rotator = quat():setAngleAxis(player_angle + math.pi / 2, 0, 1, 0)
    local alpha_val = 0
    local my_carsize = vec2(my_car_info.aabbSize.x, my_car_info.aabbSize.z)
    local radar_size = 300 * RadarScale
    local player_size = vec2(settings.remap(my_carsize.x, 0, dist_scale, 0, radar_size), settings.remap(my_carsize.y, 0, dist_scale, 0, radar_size))
    local bar_min_height = 40 * RadarScale
    if settings.is_inside(ui.mouseLocalPos(), ui.windowSize() / 2, ui.windowSize() / 2) then
        alpha_val = 1
    end
    
    table.clear(radar_lines_left)
    table.clear(radar_lines_right)
    for i=0, #leaderboard-1 do
        local car_info = leaderboard[i].car
        local carpos = car_info.position
        
        -- ignore the player duh
        if car_info.index ~= 0 and car_info.isInPitlane == false and car_info.isActive then
            local this_carsize = vec2(car_info.aabbSize.x, car_info.aabbSize.z)
            local this_car_screensize = vec2(
                settings.remap(this_carsize.x, 0, dist_scale, 0, radar_size),
                settings.remap(this_carsize.y, 0, dist_scale, 0, radar_size)
            )
            local car_offset = (carpos - player_pos)
            local car_dist = car_offset:length()
            
            local scaler = settings.remap(car_dist, 0, dist_scale, 0, 1)
            car_offset = car_offset:normalize():rotate(rotator)
            local screen_offset = vec2(car_offset.x, car_offset.z) * scaler
            
            local dot = math.dot(screen_offset:clone():normalize(), vec2(0, -1))
            local total_alpha = get_alpha(car_dist, dot, dist_scale)
            if total_alpha > alpha_val then alpha_val = total_alpha end
            
            local is_aligned = true
            local other_screenpos = draw_center + screen_offset * radar_size
            local player_top = draw_center.y + this_car_screensize.y / 2
            local player_bot = draw_center.y - this_car_screensize.y / 2
            local other_top  = other_screenpos.y + this_car_screensize.y / 2
            local other_bot  = other_screenpos.y - this_car_screensize.y / 2
            
            if player_top < other_bot or player_bot > other_top then
                is_aligned = false
            end
            
            local dot_value = 1
            local screen_dist = screen_offset:length()
            if dot < dot_value and dot > -dot_value and car_dist <= 8 then
                local warn_color = colors.TEXT_YELLOW
                if is_aligned then warn_color = colors.RED end
                local bar_height = math.max(bar_min_height, this_car_screensize.y)
                
                if screen_offset.x > 0 then
                    if Radar_MultiWarningLines == false then
                        -- only save the closest one
                        if radar_lines_right[0] == nil or screen_dist < radar_lines_right[0].screen_dist then
                            add_to_array(radar_lines_right, 0, total_alpha, other_screenpos.y, warn_color, bar_height, screen_dist)
                        end
                    else
                        -- save the TWO closest (aka if we have a new closest get him first)
                        if radar_lines_right[0] == nil or screen_dist < radar_lines_right[0].screen_dist then
                            if radar_lines_right[0] ~= nil then radar_lines_right[1] = table.clone(radar_lines_right[0], false) end
                            add_to_array(radar_lines_right, 0, total_alpha, other_screenpos.y, warn_color, bar_height, screen_dist)
                        elseif radar_lines_right[1] == nil or screen_dist < radar_lines_right[1].screen_dist then
                            -- further than the first but closer than the second, replace only him
                            add_to_array(radar_lines_right, 1, total_alpha, other_screenpos.y, warn_color, bar_height, screen_dist)
                        end
                    end
                else
                    if Radar_MultiWarningLines == false then
                        -- only save the closest one
                        if radar_lines_left[0] == nil or screen_dist < radar_lines_left[0].screen_dist then
                            add_to_array(radar_lines_left, 0, total_alpha, other_screenpos.y, warn_color, bar_height, screen_dist)
                        end
                    else
                        -- save the TWO closest (aka if we have a new closest get him first)
                        if radar_lines_left[0] == nil or screen_dist < radar_lines_left[0].screen_dist then
                            if radar_lines_left[0] ~= nil then radar_lines_left[1] = table.clone(radar_lines_left[0], false) end
                            add_to_array(radar_lines_left, 0, total_alpha, other_screenpos.y, warn_color, bar_height, screen_dist)
                        elseif radar_lines_left[1] == nil or screen_dist < radar_lines_left[1].screen_dist then
                            -- further than the first but closer than the second, replace only him
                            add_to_array(radar_lines_left, 1, total_alpha, other_screenpos.y, warn_color, bar_height, screen_dist)
                        end
                    end
                end
            end
        end
    end
    
    --
    -- yellow/red warning indicators
    -- 
    players.play_intro_anim_setup(draw_center, vec2(radar_size, radar_size), on_show_animation_start, is_showing)
    local texture_scale = 0.7
    for i=0, table.nkeys(radar_lines_left)-1 do
        local data = radar_lines_left[i]
        local threat_y = data.threat_y
        local bar_height = data.bar_height
        local alpha = data.alpha
        local color = data.color
        ui.drawRectFilledMultiColor(
            vec2(draw_center.x, threat_y - bar_height / 2),
            vec2(draw_center.x - texture_scale * draw_size.x / 2, threat_y + bar_height / 2),
            rgbm(color.r, color.g, color.b, alpha),
            rgbm(color.r, color.g, color.b, 0),
            rgbm(color.r, color.g, color.b, 0),
            rgbm(color.r, color.g, color.b, alpha)
        )
    end
    for i=0, table.nkeys(radar_lines_right)-1 do
        local data = radar_lines_right[i]
        local threat_y = data.threat_y
        local bar_height = data.bar_height
        local alpha = data.alpha
        local color = data.color
        ui.drawRectFilledMultiColor(
            vec2(draw_center.x, threat_y - bar_height / 2),
            vec2(draw_center.x + texture_scale * draw_size.x / 2, threat_y + bar_height / 2),
            rgbm(color.r, color.g, color.b, alpha),
            rgbm(color.r, color.g, color.b, 0),
            rgbm(color.r, color.g, color.b, 0),
            rgbm(color.r, color.g, color.b, alpha)
        )
    end
    
    local white_alpha = rgbm(1, 1, 1, alpha_val)
    if Radar_ShowDots then
        ui.drawImage(
            settings.get_asset("radar_bg"),
            draw_center - 300 / 2 * RadarScale,
            draw_center + 300 / 2 * RadarScale,
            rgbm(1, 1, 1, alpha_val)
        )
    end
    
    local bg_lines_scale = 0.733
    local bg_lines_lateral = 0.533
    ui.drawRectFilledMultiColor(
        draw_center + vec2(1, -radar_size * bg_lines_scale / 2),
        draw_center + vec2(-1, -player_size.y/2),
        rgbm(1,1,1,0),
        rgbm(1,1,1,0),
        white_alpha,
        white_alpha
    )
    ui.drawRectFilledMultiColor(
        draw_center + vec2(-1, player_size.y/2),
        draw_center + vec2(1, bg_lines_scale * radar_size / 2),
        white_alpha,
        white_alpha,
        rgbm(1,1,1,0),
        rgbm(1,1,1,0)
    )
    
    if Radar_ShowDoubleLines then
        -- lines on top/bottom of car
        ui.drawRectFilledMultiColor(
            draw_center - vec2(-1 + bg_lines_lateral * radar_size / 2, 1 - player_size.y / 2),
            draw_center + vec2(0, 1 + player_size.y / 2),
            rgbm(1,1,1,0),
            white_alpha,
            white_alpha,
            rgbm(1,1,1,0)
        )
        ui.drawRectFilledMultiColor(
            draw_center + vec2(0, 1 + player_size.y / 2),
            draw_center + vec2(-1 + bg_lines_lateral * radar_size / 2, -1 + player_size.y / 2),
            white_alpha,
            rgbm(1,1,1,0),
            rgbm(1,1,1,0),
            white_alpha
        )
        ui.drawRectFilledMultiColor(
            draw_center - vec2(-1 + bg_lines_lateral * radar_size / 2, 1 + player_size.y / 2),
            draw_center + vec2(0, 1 - player_size.y / 2),
            rgbm(1,1,1,0),
            white_alpha,
            white_alpha,
            rgbm(1,1,1,0)
        )
        ui.drawRectFilledMultiColor(
            draw_center + vec2(0, 1 - player_size.y / 2),
            draw_center + vec2(-1 + bg_lines_lateral * radar_size / 2, -1 - player_size.y / 2),
            white_alpha,
            rgbm(1,1,1,0),
            rgbm(1,1,1,0),
            white_alpha
        )
    else
        -- centered horizontal lines
        ui.drawRectFilledMultiColor(
            draw_center - vec2(-1 + bg_lines_lateral * radar_size / 2, 1),
            draw_center + vec2(-player_size.x/2, 1),
            rgbm(1,1,1,0),
            white_alpha,
            white_alpha,
            rgbm(1,1,1,0)
        )
        ui.drawRectFilledMultiColor(
            draw_center + vec2(player_size.x/2, 1),
            draw_center + vec2(-1 + bg_lines_lateral * radar_size / 2, -1),
            white_alpha,
            rgbm(1,1,1,0),
            rgbm(1,1,1,0),
            white_alpha
        )
    end

    local player_radius = 4 * RadarScale
    ui.drawRectFilled(
        draw_center - player_size / 2,
        draw_center + player_size / 2,
        white_alpha,
        player_radius
    )
    
    
    if Radar_ShowPlayers then
        for i=0, #leaderboard-1 do
            local car_info = leaderboard[i].car
            local carpos = car_info.position
            
            -- ignore the player duh
            if car_info.index ~= 0 and car_info.isInPitlane == false and car_info.isActive then
                local this_carsize = vec2(car_info.aabbSize.x, car_info.aabbSize.z)
                local this_car_screensize = vec2(
                    settings.remap(this_carsize.x, 0, dist_scale, 0, radar_size),
                    settings.remap(this_carsize.y, 0, dist_scale, 0, radar_size)
                )
                local car_offset = (carpos - player_pos)
                local car_dist = car_offset:length()
                if car_dist < dist_scale then
                    local scaler = settings.remap(car_dist, 0, dist_scale, 0, 1)
                    car_offset = car_offset:normalize():rotate(rotator)
                    local screen_offset = vec2(car_offset.x, car_offset.z) * scaler
                    
                    local dot = math.dot(screen_offset:clone():normalize(), vec2(0, -1))
                    local total_alpha = get_alpha(car_dist, dot, dist_scale)
                    local other_screenpos = draw_center + screen_offset * radar_size
                    
                    if Radar_RotateCars then ui.beginRotation() end
                    ui.drawRectFilled(
                        other_screenpos - this_car_screensize / 2,
                        other_screenpos + this_car_screensize / 2,
                        rgbm(1, 1, 1, total_alpha),
                        player_radius
                    )
                    if Radar_RotateCars then
                        local driver_forw = car_info.look
                        local driver_angle = math.atan2(driver_forw.z, driver_forw.x)
                        ui.endRotation(math.deg(player_angle - driver_angle) + 90)
                    end
                end
            end
        end
    end
    
    players.play_intro_anim(draw_center, vec2(radar_size, radar_size), on_show_animation_start, RadarScale)
    settings.lock_app(draw_center, vec2(radar_size, radar_size), APPNAMES.radar, RadarScale)
    settings.auto_scale_window(vec2(radar_size, radar_size) * 1.01, APPNAMES.radar)
    settings.auto_place_once(vec2(radar_size, radar_size), APPNAMES.radar)
    -- DEBUG(cogno): area visualization
    -- ui.drawRect(draw_top_left, draw_top_left + draw_size, colors.WHITE)
end

return mod -- expose functions to the outside