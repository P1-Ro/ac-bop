local mod = {} -- will be filled with public functions

local settings = require('common.settings')
local colors = settings.colors
local fonts = settings.fonts
local players = require('common.players')

local players_movement_info = table.new(50, 0)
local map_pointcount = 560
local map_points = table.new(map_pointcount, 0)
local drivers_laps = table.new(50, 0)
local rotator = quat(0, 0, 0, 1)
local map_center = vec3()
local is_clockwise = false

local min_pos = vec2(99999999999, 9999999999)
local max_pos = vec2(-99999999999, -9999999999)
local canvas = nil
local player_canvas = nil;
local final_canvas = nil

local canvas_mapsize = 0              -- TAG: MakeTheLoopQuickAgain
local mapvec = vec2()                 -- TAG: MakeTheLoopQuickAgain
local sectors_table = table.new(3, 0) -- TAG: MakeTheLoopQuickAgain

local canvas_size = 500
local canvas_old_size = 310 -- NOTE(cogno): do not change this! TAG: CanvasResScaling
local map_padding = 40
-- TAG: CanvasResScaling, we wanted to improve graphics,
-- to do so we simply changed the canvas size. Resolution improved but many things
-- became much smaller, so we decided (rightfully) to scale them up.
-- To do so as easily as possible we resize depending on the new canvas size.
-- If the old canvas size was 100 and the new 200, each element would need to double,
-- aka increase by canvas_size / canvas_old_size
--                   Cogno 2024/07/16

local DriverType = {
    -- we don't need the player, he's so special we don't need to check anything
    Leader = 1,
    Normal = 2,
    LappedByPlayer = 3,
    HasLappedPlayer = 4,
}

-- runs even if app is hidden, use it only if needed
function mod.update()
    local leaderboard = players.get_leaderboard()
    for i = 0, #leaderboard - 1 do
        local car_info = leaderboard[i].car
        local carpos = car_info.position
        local car_index = car_info.index
        local old_info = players_movement_info[car_index]
        if old_info == nil then old_info = table.new(0, 2) end

        local oldpos = old_info.old_carpos
        if oldpos ~= nil then
            local offset = (carpos - oldpos)
            local dist_diff = offset:length()
            if dist_diff > 0.5 then
                old_info.movement_change_time = Time
                old_info.old_carpos = carpos:clone()
            end
        else
            old_info.movement_change_time = Time
            old_info.old_carpos = carpos:clone()
        end

        players_movement_info[car_index] = old_info
    end
end

local function world_point_3d_remap(to_remap)
    return vec2(
        settings.remap(to_remap.x, min_pos.x, max_pos.x, 0, 1),
        settings.remap(to_remap.z, min_pos.y, max_pos.y, 0, 1)
    )
end

local function rotate_mappos(mappos)
    local offset = mappos - map_center
    local rotated_offset = offset:rotate(rotator)
    return map_center + rotated_offset
end

-- TAG: MakeTheLoopQuickAgain, since this is a hot loop (meaning it's done A LOT),
-- we want to keep this QUICK. Some info is common for the entire frame,
-- so instead of calculating it every time we can skip it and only do it sometimes.
--                         Cogno 2024/06/11

-- normalized goes from 0,0 (map screen bottom left) to 1,1 (map screen top right)
-- at least I think, it might have the y axis flipped, I don't remember
local function center_to_map(normalized, map_screen_center)
    -- calculate screen pos if we show the whole map, if it's time to show it return immediately
    local corner_tl = map_screen_center - mapvec / 2
    local absolute_screenpos = corner_tl + normalized * mapvec
    return absolute_screenpos
end

local function draw_map_path(center, map_start, map_end)
    ui.pathClear()
    local list_len = table.nkeys(map_points)
    local idx_start = math.floor(map_start * list_len)
    local idx_end = math.ceil(map_end * list_len)
    local pathline = ui.pathLineTo -- TAG: MakeTheLoopQuickAgain
    local rmp = settings.remap     -- TAG: MakeTheLoopQuickAgain
    for i = idx_start, idx_end - 1 do
        local point_curr = map_points[i]
        local norm_curr = vec2(
            rmp(point_curr.x, min_pos.x, max_pos.x, 0, 1),
            rmp(point_curr.y, min_pos.y, max_pos.y, 0, 1)
        )
        local point_curr = center_to_map(norm_curr, center)
        pathline(point_curr)
    end
end

local function draw_normal_behaviour(lerp_t, is_in_pitlane, center, size, bg_color, radius, is_outlined, fontsize,
                                     string_color, show_text, car_racepos, wheels_outside, border_radius, is_low_profile,
                                     racepos_dist)
    -- normal behaviour is:
    -- if not moving animate until small
    -- if in pitlane and moving then square
    -- if not in pitlane and moving then big circle with number
    -- if outside track also add a yellow ring (except player but we don't draw him here)

    -- lerp_t 0 = pallino grande / quadrato, lerp_t 1 = pallino piccolo
    if lerp_t == 0 then
        -- when we are here we have either big ones or square ones
        if is_in_pitlane then
            -- square, don't outline them
            if is_outlined then return end

            ui.drawRectFilled(center - size, center + size, bg_color, radius)
        else
            -- big, always outline them
            if not is_outlined then return end

            ui.drawCircleFilled(center, radius, bg_color, 20) -- HIGH RES
        end

        if wheels_outside >= 4 and not is_in_pitlane then
            ui.drawCircle(center, radius + border_radius / 2, colors.TEXT_YELLOW, 12, border_radius)
        end

        if show_text then
            local number_size = ui.measureDWriteText(car_racepos, fontsize)
            ui.dwriteDrawText(car_racepos, fontsize, center - number_size / 2, string_color)
        end
    else
        -- here we have all stuff animating and small, never draw outlines
        if is_outlined then return end

        ui.drawRectFilled(center - size, center + size, bg_color, radius)

        if wheels_outside >= 4 and not is_in_pitlane then
            ui.drawCircle(center, radius + border_radius / 2, colors.TEXT_YELLOW, 12, border_radius)
        end
    end
end

local function draw_driver_dot(center, size, radius, lerp_t, car_racepos, is_in_pitlane, wheels_outside,
                               border_radius, is_outlined, dot_kind, is_low_profile, racepos_dist, small_radius)
    local bg_color = colors.BLACK      -- if you see this there's a problem!
    local string_color = colors.PURPLE -- if you see this there's a problem!
    local show_text = true
    if dot_kind == DriverType.Leader then
        bg_color = colors.PURPLE
        string_color = colors.WHITE
    elseif dot_kind == DriverType.Normal then
        bg_color = colors.LIGHT_GREEN
        string_color = colors.DARK_BG
    elseif dot_kind == DriverType.HasLappedPlayer then
        bg_color = rgbm(0 / 255, 156 / 255, 255 / 255, 1)
        string_color = colors.WHITE
    elseif dot_kind == DriverType.LappedByPlayer then
        bg_color = rgbm(0 / 255, 94 / 255, 159 / 255, 1)
        string_color = colors.WHITE
        show_text = false -- we don't need to!
    end

    local fontsize = settings.fontsize(9) * canvas_size / canvas_old_size -- TAG: CanvasResScaling
    if is_low_profile then
        if racepos_dist <= 2 or dot_kind == DriverType.Leader then
            draw_normal_behaviour(lerp_t, is_in_pitlane, center, size, bg_color, radius, is_outlined, fontsize,
                string_color, show_text, car_racepos, wheels_outside, border_radius, is_low_profile, racepos_dist)
        else
            -- too far, only the small ones here
            if not is_outlined then
                ui.drawRectFilled(center - small_radius, center + small_radius, bg_color, radius)
            end
        end
    else
        draw_normal_behaviour(lerp_t, is_in_pitlane, center, size, bg_color, radius, is_outlined, fontsize, string_color,
            show_text, car_racepos, wheels_outside, border_radius, is_low_profile, racepos_dist)
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

local function get_flag_color_and_width(flagtype)
    local map_color = colors.WHITE
    local width = 10
    if flagtype == nil then
        map_color = colors.WHITE
    elseif flagtype == ac.FlagType.Caution then
        map_color = colors.YELLOW
        width = 14
    elseif flagtype == ac.FlagType.Stop then
        map_color = colors.BLACK
        width = 14
    elseif flagtype == ac.FlagType.ReturnToPits then
        map_color = colors.RED
        width = 14
    elseif flagtype == ac.FlagType.FasterCar then
        map_color = colors.BLUE
        width = 14
    elseif flagtype == ac.FlagType.OneLapLeft then
        map_color = colors.WHITE
    elseif flagtype == ac.FlagType.Finished then
        map_color = colors.WHITE
    end
    return map_color, width
end

function mod.on_session_start()
    table.clear(drivers_laps)
end

local map_anim_start_time = Time
local old_flag_type = nil
local old_map_color = colors.WHITE
local old_width = 0

local function players_render(is_outlined)
    local draw_center               = ui.windowSize() / 2
    local map_center                = draw_center

    local leaderboard               = players.get_leaderboard()
    local players_circle_radius     = 11 * canvas_size / canvas_old_size -- TAG: CanvasResScaling
    local players_circle_radius_min = 6 * canvas_size / canvas_old_size  -- TAG: CanvasResScaling
    local players_stopped_radius    = 4 * canvas_size / canvas_old_size  -- TAG: CanvasResScaling
    ui.pushDWriteFont(fonts.archivo_medium)
    local my_car_info = ac.getCar(0)
    local player_lapcount = players.get_lapcount(0)
    local player_spline_total = player_lapcount + my_car_info.splinePosition
    local border_radius = 2

    local player_lb_index = players.get_player_leaderboard_index()
    local player_racepos = players.get_racepos(player_lb_index)

    local session = players.get_current_session()
    if session.type ~= ac.SessionType.Practice and session.type ~= ac.SessionType.Qualify then

        -- first draw lapped people
        for i = 0, #leaderboard - 1 do
            local car_info = leaderboard[i].car
            if car_info.isConnected then
                local driver_lapcount = players.get_lapcount(car_info.index)
                local current_driver_lapcount = players.get_lapcount(car_info.index)
                local sp = car_info.splinePosition
                local splits = players.get_sector_splits()
                local traguardo = splits[0]

                if drivers_laps[i] == nil then
                    drivers_laps[i] = driver_lapcount
                end
                if sp > traguardo then
                    drivers_laps[i] = driver_lapcount
                end

                if sp < traguardo and drivers_laps[i] ~= driver_lapcount then
                    driver_lapcount = driver_lapcount - 1
                end

                if sp < traguardo then
                    driver_lapcount = driver_lapcount + 1
                end

                if my_car_info.splinePosition < traguardo then
                    driver_lapcount = driver_lapcount - 1
                end

                local car_spline_total = driver_lapcount + car_info.splinePosition
                local spline_delta     = player_spline_total - car_spline_total
               

                if (math.abs(spline_delta) >= 1) and car_info.index ~= 0 then
                    local dot_kind = nil
                    if spline_delta <= -1 then
                        dot_kind = DriverType.HasLappedPlayer
                    else
                        dot_kind = DriverType.LappedByPlayer
                    end



                    local player_move_data = players_movement_info[car_info.index]
                    local elapsed = Time - player_move_data.movement_change_time
                    local lerp_t = math.clamp(settings.remap(elapsed, 3, 3.1, 0, 1), 0, 1)
                    local radius = math.lerp(players_circle_radius, players_stopped_radius, lerp_t)
                    local size = math.lerp(players_circle_radius, players_stopped_radius, lerp_t)
                    if car_info.isInPitlane and lerp_t <= 0 then
                        radius = players_circle_radius_min / 2
                        size = players_circle_radius_min
                    end

                    local car_worldpos = rotate_mappos(car_info.position)
                    local player_normalized_trackpos = world_point_3d_remap(car_worldpos)
                    local adjusted_pos = center_to_map(player_normalized_trackpos, map_center)
                    local car_racepos = players.get_racepos(i)
                    local pos_dist = math.abs(car_racepos - player_racepos)
                    draw_driver_dot(adjusted_pos, size, radius, lerp_t, car_racepos, car_info.isInPitlane,
                        car_info.wheelsOutside, border_radius, is_outlined, dot_kind, Map_LowProfile, pos_dist,
                        players_stopped_radius)
                end
            end
        end
    end

    -- then normal people!
    for i = 0, #leaderboard - 1 do
        local car_info = leaderboard[i].car
        if car_info.isConnected == true and car_info.index ~= 0 then
            local car_racepos     = players.get_racepos(i)
            local driver_lapcount = players.get_lapcount(car_info.index)
            local current_driver_lapcount = players.get_lapcount(car_info.index)
            local sp = car_info.splinePosition
            local splits = players.get_sector_splits()
            local traguardo = splits[0]

            if sp < traguardo and drivers_laps[i] ~= driver_lapcount then
                driver_lapcount = driver_lapcount - 1
            end

            if sp < traguardo then
                driver_lapcount = driver_lapcount + 1
            end

            if my_car_info.splinePosition < traguardo then
                driver_lapcount = driver_lapcount - 1
            end

            local car_spline_total = driver_lapcount + car_info.splinePosition
            local spline_delta     = player_spline_total - car_spline_total

            local to_draw = (math.abs(spline_delta) <= 1) and car_info.index ~= 0 and car_racepos ~= 1
            if session.type == ac.SessionType.Practice or session.type == ac.SessionType.Qualify then
                to_draw = true
            end
            local player_move_data = players_movement_info[car_info.index]
            if to_draw and player_move_data ~= nil then
                local elapsed = Time - player_move_data.movement_change_time
                local lerp_t = math.clamp(settings.remap(elapsed, 3, 3.1, 0, 1), 0, 1)
                local radius = math.lerp(players_circle_radius, players_stopped_radius, lerp_t)
                local size = math.lerp(players_circle_radius, players_stopped_radius, lerp_t)
                if car_info.isInPitlane and lerp_t <= 0 then
                    radius = players_circle_radius_min / 2
                    size = players_circle_radius_min
                end

                local car_worldpos = rotate_mappos(car_info.position)
                local player_normalized_trackpos = world_point_3d_remap(car_worldpos)
                local adjusted_pos = center_to_map(player_normalized_trackpos, map_center)
                local pos_dist = math.abs(car_racepos - player_racepos)
                draw_driver_dot(adjusted_pos, size, radius, lerp_t, car_racepos, car_info.isInPitlane,
                    car_info.wheelsOutside, border_radius, is_outlined, DriverType.Normal, Map_LowProfile, pos_dist,
                    players_stopped_radius)
            end
        end
    end

    -- then the first one of the race
    ui.pushDWriteFont(fonts.archivo_bold) -- both first person and player are important
    for i = 0, #leaderboard - 1 do
        local car_info = leaderboard[i].car
        if car_info.index ~= 0 and car_info.isConnected == true then -- find the first real leader, then draw him
            local player_move_data = players_movement_info[car_info.index]
            if player_move_data ~= nil then
                local elapsed = Time - player_move_data.movement_change_time
                local lerp_t = math.clamp(settings.remap(elapsed, 3, 3.1, 0, 1), 0, 1)
                local radius = math.lerp(players_circle_radius, players_stopped_radius, lerp_t)
                local size = math.lerp(players_circle_radius, players_stopped_radius, lerp_t)
                if car_info.isInPitlane and lerp_t <= 0 then
                    radius = players_circle_radius_min / 2
                    size = players_circle_radius_min
                end

                local car_worldpos = rotate_mappos(car_info.position)
                local player_normalized_trackpos = world_point_3d_remap(car_worldpos)
                local adjusted_pos = center_to_map(player_normalized_trackpos, map_center)
                local car_racepos = players.get_racepos(i)
                local pos_dist = math.abs(car_racepos - player_racepos)
                draw_driver_dot(adjusted_pos, size, radius, lerp_t, car_racepos, car_info.isInPitlane,
                    car_info.wheelsOutside, border_radius, is_outlined, DriverType.Leader, Map_LowProfile, pos_dist,
                    players_stopped_radius)
            end
            break -- no need to continue
        end
    end

    -- we never do the player here because he's always big, so he always needs the outline
end


local function player_canvas_update()
    local draw_center  = ui.windowSize() / 2
    local map_center   = draw_center
    local leaderboard  = players.get_leaderboard()
    local big_fontsize = settings.fontsize(10) * canvas_size / canvas_old_size -- TAG: CanvasResScaling
    ui.pushDWriteFont(fonts.archivo_medium)

    players_render(true)

    -- then the player!
    local players_main_size = 22 * canvas_size / canvas_old_size -- TAG: CanvasResScaling
    for i = 0, #leaderboard - 1 do
        local car_info = leaderboard[i].car

        if car_info.index == 0 then
            local car_worldpos = rotate_mappos(car_info.position)
            local player_normalized_trackpos = world_point_3d_remap(car_worldpos)
            local adjusted_pos = center_to_map(player_normalized_trackpos, map_center)
            local car_racepos = players.get_racepos(i)
            ui.drawCircleFilled(adjusted_pos, players_main_size / 2, colors.TEXT_YELLOW, 20)
            local number_size = ui.measureDWriteText(car_racepos, big_fontsize)
            ui.dwriteDrawText(car_racepos, big_fontsize, adjusted_pos - number_size / 2, colors.DARK_BG)
            -- NOTE(cogno): no need to draw the yellow circle for yourself, we don't care!
            break -- no need to continue...
        end
    end
    ui.popDWriteFont()
    ui.popDWriteFont()
end



local function map_canvas_update()
    local draw_center          = ui.windowSize() / 2
    local map_center           = draw_center

    local sim_info             = ac.getSim()
    local flagtype             = sim_info.raceFlagType
    local map_color, new_width = get_flag_color_and_width(flagtype)
    if old_flag_type == nil or old_flag_type ~= flagtype then
        old_map_color, old_width = get_flag_color_and_width(old_flag_type)
        old_flag_type = flagtype
        map_anim_start_time = Time
    end
    local black_width = 6
    local w1 = new_width * canvas_size / canvas_old_size   -- TAG: CanvasResScaling
    local w2 = old_width * canvas_size / canvas_old_size   -- TAG: CanvasResScaling
    local w3 = black_width * canvas_size / canvas_old_size -- TAG: CanvasResScaling

    -- DEBUG(cogno): map area
    -- ui.drawRect(map_center - mapsize / 2, map_center + mapsize / 2, colors.BLUE)
    local start_p = ac.trackCoordinateToWorld(vec3(0, 0, 0))
    local end_p   = ac.trackCoordinateToWorld(vec3(0, 0, 0.99))
    local dist = math.distance(start_p, end_p)
    local is_connected = true
    if dist > 100 then
        is_connected = false
    end

    local anim_t = math.clamp(Time - map_anim_start_time, 0, 0.5) * 2
    local can_loop = false
    if anim_t >= 1 then can_loop = true end

    draw_map_path(map_center, 0, anim_t)
    ui.pathStroke(map_color, can_loop and is_connected, w1)
    if anim_t < 1 then
        draw_map_path(map_center, anim_t, 1)
        ui.pathStroke(old_map_color, false, w2)
    end
    draw_map_path(map_center, 0, 1)
    ui.pathStroke(rgbm(43 / 255, 43 / 255, 43 / 255, 1), is_connected, w3)
    
    -- DEBUG(cogno): to see how many points we draw
    if false then
        local map_points_len = table.nkeys(map_points)
        local idx_start = math.floor(0 * map_points_len)
        local idx_end = math.ceil(1 * map_points_len)
        for i = idx_start, idx_end - 1 do
            local point_curr = map_points[i]
            local point_3d_curr = vec3(point_curr.x, 0, point_curr.y)
            local norm_curr = world_point_3d_remap(point_3d_curr)
            local point_curr = center_to_map(norm_curr, map_center)
            ui.drawCircle(point_curr, 1, colors.RED)
        end
    end

    -- sectors lines
    local flag_size = vec2(8, 16) * canvas_size / canvas_old_size -- TAG: CanvasResScaling
    for i = 0, table.nkeys(sectors_table) - 1 do
        local data           = sectors_table[i]

        -- PERF(cogno): I'm sure this can be made faster (I don't think left/right need to go
        -- through the whole chain, we just need the direction), so maybe this can get faster,
        -- but most tracks only have 3 sectors so I don't think it's that much gain...
        local road_right     = data.road_right
        local road_left      = data.road_left
        local road_center    = data.road_center
        local line_left      = world_point_3d_remap(rotate_mappos(road_left))
        local line_right     = world_point_3d_remap(rotate_mappos(road_right))
        local line_center    = world_point_3d_remap(rotate_mappos(road_center))
        local adjusted_left  = center_to_map(line_left, map_center)
        local adjusted_right = center_to_map(line_right, map_center)
        local adj_center     = center_to_map(line_center, map_center)
        local adj_dir        = (adjusted_right - adjusted_left):normalize()

        local sector_color   = map_color
        local line_width     = 3
        local line_len       = 4
        if i == 0 then
            sector_color = colors.WARNING_RED
            line_width = 5
            line_len = new_width
        end
        line_width = line_width * canvas_size / canvas_old_size -- TAG: CanvasResScaling
        line_len = line_len * canvas_size / canvas_old_size     -- TAG: CanvasResScaling

        local p1 = adj_center + adj_dir * line_len
        local p2 = adj_center - adj_dir * line_len
        if i == 0 then
            local rotated_vec = vec2(adj_dir.y, -adj_dir.x)
            local flag_pos = (p2 + adj_dir * -2) - rotated_vec * flag_size.x + rotated_vec * line_width / 2
            local flag_dir = -adj_dir
            if (map_points[0] - map_points[1]).x < 0 then
                flag_dir = -flag_dir
                rotated_vec = -rotated_vec
                flag_pos = (p1 + adj_dir * 2) - rotated_vec * line_width / 2
            end

            local p01 = flag_pos
            local p02 = flag_pos + rotated_vec * flag_size.x
            local p03 = flag_pos + (flag_dir * flag_size.y) + rotated_vec * flag_size.x
            local p04 = flag_pos + (flag_dir * flag_size.y)

            ui.drawImageQuad(settings.get_asset("check"), p01, p02, p03, p04)
        end

        ui.drawLine(p1, p2, sector_color, line_width)
    end

    -- then all the players as normal, but only the ones without the outline (we're in the no-outline texture!)
    players_render(false)
end

function mod.init()
    canvas_mapsize = canvas_size - map_padding * 2 * canvas_size / canvas_old_size

    canvas = ui.ExtraCanvas(canvas_size, 1, render.AntialiasingMode.None, render.TextureFormat.R8G8B8A8.UNorm,
        render.TextureFlags.None)
    canvas:setName("map canvas")

    player_canvas = ui.ExtraCanvas(canvas_size, 1, render.AntialiasingMode.None, render.TextureFormat.R8G8B8A8.UNorm,
        render.TextureFlags.None)
    player_canvas:setName("player canvas")

    -- PERF(cogno): right now we only need a second one to have a shader on top, can we avoid?
    final_canvas = ui.ExtraCanvas(canvas_size, 1, render.AntialiasingMode.None, render.TextureFormat.R8G8B8A8.UNorm,
        render.TextureFlags.None)
    final_canvas:setName("canvas 2")

    local sim_info = ac.getSim()
    local track_length = sim_info.trackLengthM
    if track_length > 7000 then
        map_pointcount = math.max(math.floor(track_length / 20), map_pointcount)
    end

    local track_start_spline = players.get_sector_splits()[0]
    local worldpos1 = ac.trackCoordinateToWorld(vec3(0, 0, track_start_spline))
    local worldpos2 = ac.trackCoordinateToWorld(vec3(0, 0, track_start_spline + 0.01))
    local worldpos1_2d = vec2(worldpos1.x, worldpos1.z)
    local worldpos2_2d = vec2(worldpos2.x, worldpos2.z)
    local world_dir = (worldpos2_2d - worldpos1_2d):normalize()
    MapAngle = math.atan2(world_dir.y, world_dir.x) -- will be off, we'll fix it later

    local max_3d = vec3()
    local min_3d = vec3()
    local to_avoid_gc1 = vec3()                    -- TAG: GarbageSucks
    for i = 0, map_pointcount - 1 do
        to_avoid_gc1:set(0, 0, i / map_pointcount) -- TAG: GarbageSucks reduces by 16KB of GC
        local world_point_pos = ac.trackCoordinateToWorld(to_avoid_gc1)

        if world_point_pos.x > max_3d.x then max_3d.x = world_point_pos.x end
        if world_point_pos.y > max_3d.y then max_3d.y = world_point_pos.y end
        if world_point_pos.z > max_3d.z then max_3d.z = world_point_pos.z end
        if world_point_pos.x < min_3d.x then min_3d.x = world_point_pos.x end
        if world_point_pos.y < min_3d.y then min_3d.y = world_point_pos.y end
        if world_point_pos.z < min_3d.z then min_3d.z = world_point_pos.z end
    end

    map_center = (max_3d + min_3d) / 2

    -- some tracks are run clockwise and others counterclockwise, the angle above
    -- will be off by 180 degrees in one of those 2 cases!
    -- to fix it we check in which case we are and add 180 degrees if needed
    -- solution source: answer by Sean the Bean: https://stackoverflow.com/questions/1165647/how-to-determine-if-a-list-of-polygon-points-are-in-clockwise-order
    local the_sum = 0
    local to_avoid_gc2 = vec3()                                             -- TAG: GarbageSucks
    for i = 0, map_pointcount - 1 do
        to_avoid_gc1:set(0, 0, i / map_pointcount)                          -- TAG: GarbageSucks reduces by 11KB of GC
        to_avoid_gc2:set(0, 0, ((i + 1) % map_pointcount) / map_pointcount) -- TAG: GarbageSucks reduces by 10KB of GC
        local worldpos_curr = ac.trackCoordinateToWorld(to_avoid_gc1)
        local worldpos_next = ac.trackCoordinateToWorld(to_avoid_gc2)
        the_sum = the_sum + (worldpos_curr.x * worldpos_next.z - worldpos_next.x * worldpos_curr.z)
    end
    if the_sum > 0 then is_clockwise = true end
    if is_clockwise then
        rotator = quat():setAngleAxis(MapAngle + math.pi, 0, 1, 0)
        MapAngle = MapAngle + math.pi
    else
        rotator = quat():setAngleAxis(MapAngle, 0, 1, 0)
    end

    -- now that we can rotate correctly we can store map data pre-rotated (so we don't to these calculations every frame!)
    local threshold = 0.04
    local add_index = 0
    local last_angle = 0
    for i = 0, map_pointcount - 1 do
        to_avoid_gc1:set(0, 0, i / map_pointcount)                          -- TAG: GarbageSucks reduces by 17KB of GC
        to_avoid_gc2:set(0, 0, ((i + 1) % map_pointcount) / map_pointcount) -- TAG: GarbageSucks reduces by 10KB of GC
        local world_point_pos = ac.trackCoordinateToWorld(to_avoid_gc1)
        local world_point_pos_next = ac.trackCoordinateToWorld(to_avoid_gc2)

        local d = (world_point_pos_next - world_point_pos)
        local angle = math.atan2(d.z, d.x)
        if math.abs(angle - last_angle) > threshold then
            local offset = world_point_pos - map_center
            local rotated = offset:rotate(rotator)
            local new_pos = map_center + rotated

            -- recalculate bounds after rotation as if we never rotated anything
            if new_pos.x > max_pos.x then max_pos.x = new_pos.x end
            if new_pos.z > max_pos.y then max_pos.y = new_pos.z end
            if new_pos.x < min_pos.x then min_pos.x = new_pos.x end
            if new_pos.z < min_pos.y then min_pos.y = new_pos.z end
            map_points[add_index] = vec2(new_pos.x, new_pos.z)
            add_index = add_index + 1
            last_angle = angle
        end
    end

    local map_full_width   = max_pos.x - min_pos.x
    local map_full_height  = max_pos.y - min_pos.y
    local map_aspect_ratio = (map_full_width / map_full_height)
    local aspect_x         = math.min(1, map_aspect_ratio)
    local aspect_y         = math.min(1, 1 / map_aspect_ratio)
    mapvec                 = vec2(aspect_x, aspect_y) * canvas_mapsize

    local sectors          = players.get_sector_splits()
    for i = 0, #sectors - 1 do
        local sector_percentage = sectors[i]
        local road_right        = ac.trackCoordinateToWorld(vec3(1, 0, sector_percentage))
        local road_left         = ac.trackCoordinateToWorld(vec3(-1, 0, sector_percentage))
        local road_center       = ac.trackCoordinateToWorld(vec3(0, 0, sector_percentage))
        sectors_table[i]        = { road_right = road_right, road_left = road_left, road_center = road_center }
    end
end

function mod.main()
    local my_car = ac.getCar(0)
    local world_dir = my_car.look
    local angle = math.atan2(world_dir.z, world_dir.x) - MapAngle + math.pi / 2
    if angle < 0 then angle = angle + math.pi * 2 end

    canvas:clear()
    canvas:update(map_canvas_update)

    player_canvas:clear()
    player_canvas:update(player_canvas_update)

    final_canvas:updateWithShader({
        textures = { c1in = canvas, c2in = player_canvas },
        values = { lerp_t = 0 },
        shader = [[
        #define DIV_SQRT_2 0.70710678118

        SamplerState NoWrapSampler{
            Filter = MIN_MAG_MIP_LINEAR;
            AddressU = NoWrap;
            AddressV = NoWrap;
        };

        float2 uvPerWorldUnit(float2 uv, float2 space){
            float2 uvPerPixelX = abs(ddx(uv));
            float2 uvPerPixelY = abs(ddy(uv));
            float unitsPerPixelX = length(ddx(space));
            float unitsPerPixelY = length(ddy(space));
            float2 uvPerUnitX = uvPerPixelX / unitsPerPixelX;
            float2 uvPerUnitY = uvPerPixelY / unitsPerPixelY;
            return (uvPerUnitX + uvPerUnitY);
        }


        float4 main(PS_IN pin){
            //Player canvas with outline
            float4 col = c2in.Sample(NoWrapSampler, pin.Tex);

            float thickness = 0.01;

            float2 directions[8] = {float2(1, 0), float2(0, 1), float2(-1, 0), float2(0, -1),
            float2(DIV_SQRT_2, DIV_SQRT_2), float2(-DIV_SQRT_2, DIV_SQRT_2),
            float2(-DIV_SQRT_2, -DIV_SQRT_2), float2(DIV_SQRT_2, -DIV_SQRT_2)};

            float maxAlpha = 0;
            for(uint index = 0; index<8; index++){
                float2 sampleUV = pin.Tex + directions[index] * 0.011/*magic number*/;
                maxAlpha = max(maxAlpha, c2in.Sample(NoWrapSampler, sampleUV).a);
            }

            float distfromcenter=distance(float2(0.5f, 0.5f), pin.Tex);
            float4 rColor = lerp(float4(0,0,0,1), float4(1,1,1,1), distfromcenter);
            float radius = 0.4;
            float4 clamped = clamp((rColor - radius) * 15, 0, 1);
            float4 map = c1in.Sample(NoWrapSampler, pin.Tex);
            float4 lerped = lerp(float4(0,0,0,1), clamped, lerp_t);
            //return lerped;

            col.rgb = lerp(float3(43.0 / 255.0, 43.0 / 255.0, 43.0 / 255.0), col.rgb, col.a);
            col.a = max(col.a, maxAlpha);
            float t = saturate(map.a * (1 - col.a));

            //WTF WHY
            return float4(map.rgb * t + col.rgb * col.a, (1 - lerped.r) * saturate(map.a + col.a));

            //return float4(float3(maxAlpha,maxAlpha,maxAlpha),1);
            //return float4(col.rgb, 1);
        }
        ]]
    })

    local draw_top_left = vec2(0, 22)
    local draw_size = ui.windowSize() - vec2(0, 22)
    local draw_center = draw_top_left + draw_size / 2

    local corner_tl = draw_center - draw_size / 2
    local mapsize = 270 * MapScale + map_padding * 2 * MapScale
    local dotsize = 300 * MapScale

    local map_center = corner_tl + mapsize / 2
    players.play_intro_anim_setup(map_center, vec2(dotsize, dotsize) * 1.4, on_show_animation_start, is_showing)
    ui.drawImage(
        settings.get_asset("map_bg"),
        map_center - dotsize / 2,
        map_center + dotsize / 2
    )

    -- draw the map render texture
    ui.drawImage(final_canvas, map_center - mapsize / 2, map_center + mapsize / 2)
    local app_size = vec2(mapsize, mapsize)
    players.play_intro_anim(map_center, app_size, on_show_animation_start, MapScale)
    settings.lock_app(map_center, app_size, APPNAMES.map, MapScale)
    settings.auto_scale_window(app_size * 1.02, APPNAMES.map)
    settings.auto_place_once(app_size, APPNAMES.map)

    -- DEBUG(cogno): draw area
    -- ui.drawRect(draw_top_left, draw_top_left + draw_size, colors.WHITE)
end

return mod -- expose functions to the outside
