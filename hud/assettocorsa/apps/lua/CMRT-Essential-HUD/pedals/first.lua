local mod = {} -- will be filled with public functions

local settings = require('common.settings')
local players  = require('common.players')
local fonts = settings.fonts
local colors = settings.colors

function mod.draw_pedals(corner_tl, rect_size, is_flipped, scale)
    local arc_radius = rect_size.y / 2
    local circle_center = corner_tl + vec2(rect_size.x - arc_radius, arc_radius)
    if is_flipped then
        circle_center = corner_tl + arc_radius
    end
    ui.pathClear()
    if is_flipped then
        ui.pathArcTo(circle_center, arc_radius, math.pi / 2, math.pi * 3 / 2, 20)
        ui.pathLineTo(corner_tl + vec2(rect_size.x, 0))
        ui.pathLineTo(corner_tl + rect_size)
    else
        ui.pathLineTo(corner_tl)
        ui.pathLineTo(corner_tl + vec2(rect_size.x - arc_radius, 0))
        ui.pathArcTo(circle_center, arc_radius, -math.pi / 2, math.pi / 2, 20)
        ui.pathLineTo(corner_tl + vec2(0, rect_size.y))
    end
    ui.pathFillConvex(colors.LIGHT_BG)
    
    local my_car = ac.getCar(0)
    if my_car == nil then return end -- SHUT UP IDE ERRORS
    
    -- steering wheel
    local empty_bar_color = rgbm(colors.BG.r, colors.BG.g, colors.BG.b, 0.4)
    local empty_circle_color = rgbm(colors.BG.r, colors.BG.g, colors.BG.b, 0.4)
    local arc_color = colors.WHITE
    local steer_angle_width = math.rad(7)
    local steer_value = math.rad(my_car.steer)
    if ac.getCar(0).speedKmh < 1 and math.abs(steer_value) > math.rad(270) then
        empty_circle_color = rgbm(colors.WARNING_RED.r, colors.WARNING_RED.g, colors.WARNING_RED.b, 0.4)
        arc_color = colors.WARNING_RED
    end
    ui.pathClear()
    ui.pathArcTo(circle_center, arc_radius - 11 * scale, -math.pi, math.pi-0.04, 30)
    ui.pathStroke(empty_circle_color, true, 7 * scale)
    ui.pathClear()
    ui.pathArcTo(
        circle_center, 
        arc_radius - 11 * scale,
        -math.pi/2 + steer_value + steer_angle_width,
        -math.pi/2 + steer_value - steer_angle_width
    )
    ui.pathStroke(arc_color, false, 7 * scale)
    
    local bar_padding_hor = 8 * scale
    local bar_padding_ver = 8 * scale
    local bar_space = 2 * scale
    local small_rect_height = 6 * scale
    local small_rect_dist = 1 * scale
    local bar_pad = vec2(bar_padding_hor, bar_padding_ver)
    local bar_size = vec2(13 * scale, rect_size.y - 2 * bar_padding_ver - small_rect_height - small_rect_dist)
    
    
    -- clutch
    
    local bar_tl = corner_tl + bar_pad + vec2(0, small_rect_height + small_rect_dist)
    if is_flipped then bar_tl = bar_tl + vec2(arc_radius * 2 - bar_pad.x, 0) end
    local clutch_height = bar_size.y * (1 - my_car.clutch)
    ui.drawRectFilled(bar_tl, bar_tl + bar_size, empty_bar_color)
    ui.drawRectFilled(bar_tl + vec2(0, bar_size.y - clutch_height), bar_tl + bar_size, colors.BLUE)
    if my_car.clutch <= 0 then
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), colors.BLUE)
    else
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), empty_bar_color)
    end
    
    -- brake
    bar_tl = bar_tl + vec2(bar_size.x + bar_space)
    local brake_height = bar_size.y * (my_car.brake)
    ui.drawRectFilled(bar_tl, bar_tl + bar_size, empty_bar_color)
    ui.drawRectFilled(bar_tl + vec2(0, bar_size.y - brake_height), bar_tl + bar_size, colors.RED)
    if my_car.brake >= 1 then
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), colors.RED)
    else
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), empty_bar_color)
    end
    
    -- gas
    bar_tl = bar_tl + vec2(bar_size.x + bar_space)
    local gas_height = bar_size.y * (my_car.gas)
    ui.drawRectFilled(bar_tl, bar_tl + bar_size, empty_bar_color)
    ui.drawRectFilled(bar_tl + vec2(0, bar_size.y - gas_height), bar_tl + bar_size, colors.GREEN)
    if my_car.gas >= 1 then
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), colors.GREEN)
    else
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), empty_bar_color)
    end
    
    -- maybe handbrake
    if Pedals_ShowHandbrake then
        bar_tl = bar_tl + vec2(bar_size.x + bar_space)
        local gas_height = bar_size.y * (my_car.handbrake)
        ui.drawRectFilled(bar_tl, bar_tl + bar_size, empty_bar_color)
        ui.drawRectFilled(bar_tl + vec2(0, bar_size.y - gas_height), bar_tl + bar_size, colors.YELLOW)
        if my_car.handbrake >= 1 then
            ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), colors.YELLOW)
        else
            ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), empty_bar_color)
        end
    end
    
    -- ffb
    bar_tl = bar_tl + vec2(bar_size.x + bar_space)
    local ffb_height = bar_size.y * math.clamp(math.abs(my_car.ffbFinal), 0, 1)
    ui.drawRectFilled(bar_tl, bar_tl + bar_size, empty_bar_color)
    if math.abs(my_car.ffbFinal) >= 1 then
        ui.drawRectFilled(bar_tl + vec2(0, bar_size.y - ffb_height), bar_tl + bar_size, colors.RED)
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), colors.RED)
    else
        ui.drawRectFilled(bar_tl + vec2(0, bar_size.y - ffb_height), bar_tl + bar_size, colors.LIGHT_GRAY)
        ui.drawRectFilled(bar_tl + vec2(0, -small_rect_height - small_rect_dist), bar_tl + vec2(bar_size.x, -small_rect_dist), empty_bar_color)
    end
    
    -- DEBUG(cogno): area visualization
    -- ui.drawRect(draw_top_left, draw_top_left + draw_size, colors.WHITE)
end

local seconds_of_telemetry = 5
local telemetry_framerate = 60
local telemetry_info_gas    = table.new(seconds_of_telemetry * telemetry_framerate, 0)
local telemetry_info_brake  = table.new(seconds_of_telemetry * telemetry_framerate, 0)
local telemetry_info_clutch = table.new(seconds_of_telemetry * telemetry_framerate, 0)
local telemetry_info_ffb    = table.new(seconds_of_telemetry * telemetry_framerate, 0)
local telemetry_info_handbrake = table.new(seconds_of_telemetry * telemetry_framerate, 0)
local update_time = 0
local telemetry_index = 0

function mod.update()
    local my_car = ac.getCar(0)
    if my_car == nil then return end -- SHUT UP IDE ERRORS
    
    if update_time <= 0 then
        update_time = update_time + 1 / telemetry_framerate -- next update
        
        local gas = my_car.gas
        local brake = my_car.brake
        local clutch = 1 - my_car.clutch
        local ffb = math.clamp(math.abs(my_car.ffbFinal), 0, 1)
        
        local current_telemetry_count = table.nkeys(telemetry_info_brake)
        if current_telemetry_count <= seconds_of_telemetry * telemetry_framerate then
            -- we still need to fill it up
            telemetry_info_brake[current_telemetry_count] = brake
            telemetry_info_clutch[current_telemetry_count] = clutch
            telemetry_info_gas[current_telemetry_count] = gas
            telemetry_info_ffb[current_telemetry_count] = ffb
            telemetry_info_handbrake[current_telemetry_count] = my_car.handbrake
        else
            -- already full, circularly replace
            telemetry_info_brake[telemetry_index] = brake
            telemetry_info_clutch[telemetry_index] = clutch
            telemetry_info_gas[telemetry_index] = gas
            telemetry_info_ffb[telemetry_index] = ffb
            telemetry_info_handbrake[telemetry_index] = my_car.handbrake
            telemetry_index = (telemetry_index + 1) % (seconds_of_telemetry * telemetry_framerate)
        end
    end
    update_time = update_time - Dt
end

local button_press_time = -10
local button_pressed = true
local pedals_storage = nil

function mod.init()
    pedals_storage = ac.storage("pedals_button_state", true)
    button_pressed = pedals_storage:get()
end

local to_avoid_gc = vec2()
local function draw_path(list, data_count, max_data_count, min_corner, max_corner)
    ui.pathClear()
    for curr=0, data_count-2 do
        local i1 = (curr + telemetry_index) % max_data_count
        local curr_width1  = settings.remap(data_count - curr, 0, max_data_count, max_corner.x, min_corner.x)
        local curr_height_brk1 = settings.remap(1-list[i1], 0, 1, min_corner.y, max_corner.y)
        to_avoid_gc:set(curr_width1, curr_height_brk1) -- TAG: GarbageSucks this single line saves us 14.1KB of garbage
        ui.pathLineTo(to_avoid_gc)
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


function mod.main()
    local draw_top_left = vec2(0, 22)
    local draw_size = ui.windowSize() - draw_top_left
    local rect_size = vec2(140, 72) * PedalsScale
    if Pedals_ShowHandbrake then rect_size.x = 155 * PedalsScale end
    local telemetry_area = vec2(200 * PedalsScale, rect_size.y)
    local pedals_flipped = false
    local button_size = vec2(20 * PedalsScale, rect_size.y)
    local telemetry_padding = 8 * PedalsScale
    local bar_distance = 1 * PedalsScale
    local one_bar_height = (rect_size.y - telemetry_padding * 2 - bar_distance * 3) / 4
    local fontsize = settings.fontsize(6.5) * PedalsScale
    
    local area_width = 0
    local anim_length = 0.1
    if button_pressed then
        area_width = math.clamp(settings.remap(Time - button_press_time, 0, anim_length, 0, telemetry_area.x), 0, telemetry_area.x)
    else
        area_width = telemetry_area.x - math.clamp(settings.remap(Time - button_press_time, 0, anim_length, 0, telemetry_area.x), 0, telemetry_area.x)
    end
    
    local button_tl = draw_top_left
    local telemetry_tl = button_tl + vec2(button_size.x, 0)
    local pedals_corner_tl = telemetry_tl + vec2(area_width, 0)
    
    local screensize = settings.get_screensize()
    local window_center = ui.windowPos() + ui.windowSize() / 2
    if window_center.x > screensize.x / 2 then
        pedals_flipped = true
        local draw_tr = draw_top_left + vec2(draw_size.x, 0)
        button_tl = draw_tr - vec2(button_size.x, 0)
        telemetry_tl = button_tl - vec2(area_width, 0)
        pedals_corner_tl = telemetry_tl - vec2(rect_size.x, 0)
    end
    
    if settings.is_inside(ui.mouseLocalPos(), button_tl + button_size / 2, button_size / 2) then
        if ui.mouseClicked(ui.MouseButton.Left) then
            button_pressed = not button_pressed
            button_press_time = Time
            if pedals_storage ~= nil then pedals_storage:set(button_pressed) end
        end
    end
    local app_size = rect_size + vec2(button_size.x + telemetry_area.x, 0)
    players.play_intro_anim_setup(draw_top_left + app_size / 2, app_size, on_show_animation_start, is_showing)
    
    -- button bg
    ui.drawRectFilled(button_tl, button_tl + button_size, colors.LIGHT_BG)
    ui.drawRectFilled(button_tl, button_tl + button_size, rgbm(colors.BG.r, colors.BG.g, colors.BG.b, 0.4))
    
    -- telemetry bg
    ui.pushClipRect(telemetry_tl, telemetry_tl + vec2(area_width, rect_size.y + 3 * PedalsScale))
    ui.drawRectFilled(telemetry_tl, telemetry_tl + telemetry_area, colors.LIGHT_BG)
    local one_bar_width = telemetry_area.x - 2 * telemetry_padding
    for i=0, 3 do
        local current_pos = telemetry_tl + telemetry_padding + vec2(0, (one_bar_height+bar_distance) * i )
        ui.drawRectFilled(current_pos, current_pos + vec2(one_bar_width, one_bar_height), rgbm(colors.BG.r, colors.BG.g, colors.BG.b, 0.4))
    end
    
    --
    -- draw telemetry graph
    --
    local min_corner = telemetry_tl + telemetry_padding
    local max_corner = telemetry_tl + telemetry_area - telemetry_padding
    local data_count = table.nkeys(telemetry_info_gas)
    local max_data_count = telemetry_framerate * seconds_of_telemetry
    if Pedals_ShowFfb then
        draw_path(telemetry_info_ffb, data_count, max_data_count, min_corner, max_corner)
        ui.pathSimpleStroke(colors.LIGHT_GRAY, false, 2 * PedalsScale)
    end
    if Pedals_ShowClutch then
        draw_path(telemetry_info_clutch, data_count, max_data_count, min_corner, max_corner)
        ui.pathSimpleStroke(colors.BLUE, false, 2 * PedalsScale)
    end
    if Pedals_ShowGas then
        draw_path(telemetry_info_gas, data_count, max_data_count, min_corner, max_corner)
        ui.pathSimpleStroke(colors.GREEN, false, 2 * PedalsScale)
    end
    if Pedals_ShowHandbrake then
        draw_path(telemetry_info_handbrake, data_count, max_data_count, min_corner, max_corner)
        ui.pathSimpleStroke(colors.YELLOW, false, 2 * PedalsScale)
    end
    if Pedals_ShowBrake then
        draw_path(telemetry_info_brake, data_count, max_data_count, min_corner, max_corner)
        ui.pathSimpleStroke(colors.RED, false, 2 * PedalsScale)
    end
    ui.popClipRect()
    mod.draw_pedals(pedals_corner_tl, rect_size, pedals_flipped, PedalsScale)
    
    if pedals_flipped == false then
        ui.beginRotation()
        ui.pushDWriteFont(fonts.archivo_medium)
        ui.dwriteDrawText("TELEMETRY", fontsize, button_tl)
        ui.popDWriteFont()
        ui.endRotation(-180, vec2(-21, 32) * PedalsScale)
    else
        ui.beginRotation()
        ui.pushDWriteFont(fonts.archivo_medium)
        local text_size = ui.measureDWriteText("TELEMETRY", fontsize)
        ui.dwriteDrawText("TELEMETRY", fontsize, button_tl + vec2(-text_size.x, 0))
        ui.popDWriteFont()
        ui.endRotation(-180, vec2(40, 32) * PedalsScale)
    end
    settings.lock_app(ui.windowSize() / 2, ui.windowSize(), APPNAMES.pedals, PedalsScale)
    settings.auto_scale_window(app_size * 1.01, APPNAMES.pedals)
    settings.auto_place_once(app_size, APPNAMES.pedals)
    players.play_intro_anim(draw_top_left + app_size / 2, app_size, on_show_animation_start, PedalsScale)
end

return mod -- expose functions to the outside