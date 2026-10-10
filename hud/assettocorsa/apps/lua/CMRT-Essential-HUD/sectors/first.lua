local sectors = {}

local settings = require('common.settings')
local colors = settings.colors
local fonts = settings.fonts
local lap = require('sectors.lap')
local players = require('common.players')

-- all times are in milliseconds
-- TAG: LuaArraysSuckAss
local times = {
    current_lap = lap.make_new(),
    last_lap    = lap.make_new(),
    aggregated_best_lap = lap.make_new(), -- aggregated best you could do in this session (aka the best first sector you ewver did, the best 18th stint you ever did etc.)
    multiplayer_best_lap = lap.make_new(), -- same as personal best but for every player in the session (best first sector was done by playern 5, best 18th stint was done by player 2, etc)
    
    personal_record_time = 0, -- since we don't need to track the full data we only care about the lap time
    
    old_lap_count = 0,
    other_players_laps = table.new(1, 0), -- array of laps, each one for one player. we then aggregate into multiplayer_best_lap. does NOT include current player lap (id 0), that's personal_best_lap
    previous_best_laptime = 0,
    player_previous_best = 0,
    
    -- the following are the laps we draw for some seconds when we complete a lap
    display_lap = lap.make_new(),
    display_aggregated = lap.make_new(),
    display_multiplayer = lap.make_new(),
    
    old_sector_times = table.new(3, 0)
}

local sector_animation_start_times = table.new(3, 0)

local best_time_start_time = 0
local pb_time_start_time = 0
local mp_best_start_time = 0
local show_new_session_best = false
local show_new_personal_record = false

function sectors.on_session_start()
    times.current_lap = lap.make_new()
    times.last_lap    = lap.make_new()
    times.aggregated_best_lap = lap.make_new()
    times.multiplayer_best_lap = lap.make_new()
    times.old_lap_count = 0
    table.clear(times.other_players_laps)
    times.display_lap = lap.make_new()
    times.display_aggregated = lap.make_new()
    times.display_multiplayer = lap.make_new()
    table.clear(times.old_sector_times)
    sectors.init()
end

function sectors.init()
    local sect = string.upper(ac.getCarID(0).."@"..ac.getTrackID())
    if ac.getTrackLayout() ~= "" then
        sect = string.upper(sect.."-"..ac.getTrackLayout())
    end
    local fullpath = ac.getFolder(ac.FolderID.Documents) .. "/Assetto Corsa/personalbest.ini"
    local pb = ac.INIConfig.load(fullpath, ac.INIFormat.Extended):get(sect, "TIME", -1)
    if pb ~= nil and pb > 0 then -- pb on maps you haven't a pb on is -1
        times.personal_record_time = pb
    end
end

-- called even if window is hidden
function sectors.update()
    local my_car = ac.getCar(0)
    if my_car == nil then return end -- nothing we can do anyway
    
    -- update times for each player
    local leaderboard = players.get_leaderboard()
    local my_leaderboard_index = 0
    for i=0, #leaderboard-1 do
        local leaderboard_info = leaderboard[i]
        local car_index = leaderboard_info.car.index
        local car_data = ac.getCar(car_index)
        if car_data == nil then break end -- finished, should never happen anyway
        
        if car_index ~= 0 then -- skip yourself
            -- reserve spots if not already there
            local arr_index = car_index - 1
            local lap_data_check = times.other_players_laps[arr_index]
            if lap_data_check == nil then
                times.other_players_laps[arr_index] = lap.make_new()
            end
            
            -- update his values into multiplayer aggregate
            local spline = car_data.splinePosition
            if ac.getTrackName() == "Nordschleife - Tourist" then
                spline = players.normalize_spline_for_nordschleife_turist(spline)
            end
            local lap_data = times.other_players_laps[arr_index]
            local car_stint = lap.get_stint_index(spline)
            lap.update(lap_data, car_data.lapTimeMs, spline)
            lap.aggregate(times.multiplayer_best_lap, lap_data, car_stint)
        else
            my_leaderboard_index = i
        end
        -- stuff we update for EVERY player online
    end
    
    -- aggregate values in real time (except the ones we're still updating)
    local stint_index = lap.get_stint_index(my_car.splinePosition)
    lap.aggregate(times.aggregated_best_lap,  times.current_lap, stint_index)
    lap.aggregate(times.multiplayer_best_lap, times.current_lap, stint_index)
    
    local player_current_best = players.get_car_best_laptime(my_leaderboard_index)
    if player_current_best ~= nil and player_current_best > 0 then
        if times.player_previous_best == nil or times.player_previous_best <= 0 or player_current_best < times.player_previous_best then
            times.player_previous_best = player_current_best
            best_time_start_time = Time
            show_new_session_best = true
        end
        if times.personal_record_time == nil or times.personal_record_time <= 0 or player_current_best < times.personal_record_time then
            times.personal_record_time = player_current_best
            pb_time_start_time = Time
            show_new_personal_record = true
        end
    end
    
    -- when we've completed each lap update old values
    local lap_count = players.get_lapcount(0)
    if times.old_lap_count ~= lap_count then
        -- since we want to draw the lap we just completed for a couple of seconds, clone data so we don't loose it
        -- assettocorsa has better data than us, use it!
        times.display_lap = lap.copy(times.current_lap)
        times.display_aggregated = lap.copy(times.aggregated_best_lap)
        times.display_multiplayer = lap.copy(times.multiplayer_best_lap)
        
        times.last_lap = lap.copy(times.current_lap)
        times.current_lap = lap.make_new()
    end
    
    lap.update(times.current_lap, my_car.lapTimeMs, my_car.splinePosition)
    
    local sim_state = ac.getSim()
    local sector_count = #players.get_sector_splits()
    local sector_times = my_car.currentSplits
    local current_sector = my_car.currentSector
    local last_sector_times = players.get_last_splits(0)
    
    for i=0, sector_count-1 do
        local old_sector_time = times.old_sector_times[i]
        local current_sector_time = sector_times[i]
        if current_sector == 0 and i == sector_count -1 then
            -- we must get split of last sector from last lap!
            current_sector_time = last_sector_times[i]
        end
        
        if current_sector_time ~= nil and current_sector_time ~= 0 then
            if old_sector_time == nil or old_sector_time == 0 or current_sector_time ~= old_sector_time then
                times.old_sector_times[i] = current_sector_time
                sector_animation_start_times[i] = Time
            end
        end
    end
    times.old_lap_count = lap_count
end

local on_show_animation_start = 0
local is_showing = true
local is_paused = false
function sectors.on_open()
    if is_paused == false then
        on_show_animation_start = Time
        is_showing = true
    end
    is_paused = false
end

function sectors.on_close()
    is_paused = ac.getSim().isPaused
    if is_paused == false then
        is_showing = false
    end
end

function sectors.main()
    local my_car = ac.getCar(0)
    if my_car == nil then return end -- nothing we can do anyway
    
    local screensize = settings.get_screensize()
    ui.pushDWriteFont(fonts.archivo_bold)
    -- get best lap time done by any person
    local mp_best_laptime = 0
    local name_of_person_with_best_lap = ''
    local racepos_of_person_with_best_lap = 0
    local leaderboard = players.get_leaderboard()
    local my_leaderboard_index = 0
    for i=0, #leaderboard-1 do
        local leaderboard_info = leaderboard[i]
        local car_index = leaderboard_info.car.index
        local person_best_laptime = players.get_car_best_laptime(i)
        if person_best_laptime ~= nil and person_best_laptime ~= 0 then
            if mp_best_laptime == nil or mp_best_laptime == 0 or person_best_laptime < mp_best_laptime then
                mp_best_laptime = person_best_laptime
                name_of_person_with_best_lap = ac.getDriverName(car_index)
                racepos_of_person_with_best_lap = players.get_racepos(i)
            end
        end
        if car_index == 0 then my_leaderboard_index = i end
    end
    
    local window_center = ui.windowPos() + ui.windowSize() / 2
    local top_bar_height = 22
    local draw_top_left = vec2(0, top_bar_height)
    local draw_size = ui.windowSize() - draw_top_left
    local text_padding = 12 * SectorsScale
    local padding = vec2(text_padding, text_padding)
    local text_top_adjust = vec2(0, -4) * SectorsScale
    local text_bot_adjust = vec2(0, -4) * SectorsScale
    local text_size = settings.fontsize(10) * SectorsScale
    local number_size = settings.fontsize(10) * SectorsScale
    local left_numb_adjust = 5 * SectorsScale
    
    local default_stint_width = 12 * SectorsScale
    local sector_padding = 2 * SectorsScale
    local sector_height = 20 * SectorsScale
    local squares_height = 6 * SectorsScale
    local window_width = ((default_stint_width * 8 + sector_padding * 9) * 3 + 2 * SectorsScale)
    local window_size = vec2(window_width, 2 * settings.line_height * SectorsScale)
    
    -- we want to resize the window to fit the name and other elements, calculate wanted size
    local square_padding = 2 * SectorsScale
    local notification_offset = 70 * SectorsScale
    local notific_default_width = 213 * SectorsScale
    local notification_size = vec2(notific_default_width, settings.line_height * 2 * SectorsScale)
    local square_size = notification_size.y / 2 - square_padding * 2
    local text_padding_vec = vec2(10, 5) * SectorsScale
    local name_size = ui.measureDWriteText(name_of_person_with_best_lap, text_size)
    local text_string = lap.time_to_string(mp_best_laptime)
    local text_size_v = ui.measureDWriteText(text_string, number_size)
    local number_offset = vec2(12,8) * SectorsScale
    local window_wanted_size = square_size + square_padding * 2 + text_padding_vec.x * 2 + name_size.x + text_size_v.x + number_offset.x
    notification_size.x = math.max(notification_size.x, window_wanted_size)
    
    local bg_center = draw_top_left + window_size / 2
    local notification_center = bg_center + vec2(-window_size.x, window_size.y) / 2 + vec2(0, notification_offset) + vec2(notification_size.x, notification_size.y) / 2
    
    local anim_duration = 0.2
    local animation_elapsed = Time - mp_best_start_time
    local start_animation_percentage = math.clamp(settings.remap(animation_elapsed, 0, anim_duration, 0, 1), 0, 1)
    local end_animation_percentage = math.clamp(settings.remap(animation_elapsed, Sectors_AnimDuration - anim_duration, Sectors_AnimDuration, 0, 1), 0, 1)
    local clip_width = settings.remap(start_animation_percentage, 0, 1, 0, notification_size.x)
    local end_width = settings.remap(end_animation_percentage, 0, 1, 0, notification_size.x)
    
    local app_width = math.max(notification_size.x, window_size.x)
    local app_size = vec2(app_width, window_size.y + notification_offset + notification_size.y)
    if window_center.x > screensize.x / 2 then
        bg_center.x = app_width / 2
        notification_center.x = bg_center.x + window_size.x / 2 - notification_size.x / 2
    end
    
    if window_center.y > screensize.y / 2 then
        bg_center.y = draw_top_left.y + draw_size.y - window_size.y / 2 - sector_height - squares_height - sector_padding * 2
        notification_center.y = bg_center.y - window_size.y / 2 - notification_offset - notification_size.y / 2 + sector_height + squares_height + sector_padding * 2
    end
    
    local corner_start = notification_center - notification_size / 2 --+ vec2(end_width, 0)
    local bg_corner_tl = bg_center - window_size / 2
    local bg_corner_br = bg_center + window_size / 2
    
    if mp_best_laptime ~= times.previous_best_laptime then
        times.previous_best_laptime = mp_best_laptime
        mp_best_start_time = Time
    end
    
    --
    -- background of upper rectangle
    --
    -- BUG(cogno): top right corner is curved, but the purple/green gradient is not, fix it!
    players.play_intro_anim_setup(ui.windowSize() / 2, ui.windowSize(), on_show_animation_start, is_showing)
    local dots_texture = settings.get_asset("sector_dot")
    ui.drawRectFilled(bg_corner_tl, bg_corner_br, colors.BG, 5 * SectorsScale, ui.CornerFlags.Top)
    ui.drawImage(dots_texture,
        bg_corner_tl,
        bg_corner_br
    )
    --
    -- upper rectangles texts
    --
    -- positions of top left corner of word texts
    local top_left_text  = bg_center - window_size / 2 + padding + text_top_adjust
    local bot_left_text  = bg_center + vec2(-window_size.x, 0) / 2 + padding + text_bot_adjust
    local top_right_text = bg_center + vec2(0, -window_size.y) / 2 + padding + text_top_adjust
    local bot_right_text = bg_center + padding + text_bot_adjust
    
    -- positions of top RIGHT corner of number texts
    local top_right_numb = bg_center + vec2(window_size.x, -window_size.y) / 2 + vec2(-padding.x, padding.y) + text_top_adjust
    local bot_right_numb = bg_center + vec2(window_size.x, 0) / 2 + vec2(-padding.x, padding.y) + text_bot_adjust
    
    -- times text are put in a box at quarter levels
    -- basically each row has padding, text, time text, padding, padding, text, time text, padding
    local text_space = window_size.x / 2 - text_padding * 2
    local text_offset = vec2(text_space / 2, 0)
    
    local best_time_color = nil
    local record_time_color = nil
    
    local my_best_laptime = players.get_car_best_laptime(my_leaderboard_index)
    if my_best_laptime == nil then my_best_laptime = 0 end
    if show_new_session_best    then
        best_time_color = colors.GREEN
        if my_best_laptime > 0 and my_best_laptime <= mp_best_laptime then
            best_time_color = colors.PURPLE
        end
    end
    if show_new_personal_record then
        record_time_color = colors.GREEN
        if times.personal_record_time > 0 and times.personal_record_time <= mp_best_laptime then
            record_time_color = colors.PURPLE
        end
    end
    
    local best_time_text   = lap.time_to_string(my_best_laptime)
    local record_time_text = lap.time_to_string(times.personal_record_time)
    
    local best_time_size = ui.measureDWriteText(best_time_text, number_size)
    local record_time_size = ui.measureDWriteText(record_time_text, number_size)
    
    -- gradient colors behind Best time and Record time
    local best_curve_t = settings.get_curve_t(best_time_start_time, true, Sectors_AnimDuration)
    if best_time_color ~= nil then
        ui.drawImageRounded(
            settings.get_asset("white"),
            bg_center + vec2(0, -window_size.y / 2),
            bg_center + vec2(window_size.x / 2, 0),
            rgbm(best_time_color.r, best_time_color.g, best_time_color.b, settings.remap(best_curve_t, 0, 1, 0, 0.55)),
            vec2(0, 0), vec2(1, 1),
            5 * SectorsScale,
            ui.CornerFlags.TopRight
        )
    end
    
    local pb_curve_t = settings.get_curve_t(pb_time_start_time, true, Sectors_AnimDuration)
    if record_time_color ~= nil then
        ui.drawImageQuad(
            settings.get_asset("white"),
            bg_center + vec2(0, window_size.y / 2),
            bg_center + vec2(window_size.x, window_size.y) / 2,
            bg_center + vec2(window_size.x / 2, 0),
            bg_center + vec2(0, 0),
            rgbm(record_time_color.r, record_time_color.g, record_time_color.b, settings.remap(pb_curve_t, 0, 1, 0, 0.55))
        )
    end
    
    ui.dwriteDrawText("Current: ", text_size, top_left_text,  colors.TEXT_GRAY)
    ui.dwriteDrawText("Best: ",    text_size, top_right_text, colors.TEXT_GRAY)
    ui.dwriteDrawText("Last: ",    text_size, bot_left_text,  colors.TEXT_GRAY)
    ui.dwriteDrawText("Record: ",  text_size, bot_right_text, colors.TEXT_GRAY)
    
    -- PERF(jason): current_time_string takes a lot of time to measureDWrite (about 25% of idle time)
    -- because it changes every frame, so caching doesn't apply.
    -- To solve there are a couple of solutions, though I don't know if they
    -- work and which one is the best.
    -- 1. instead of writing "Current: 1:25.215*" we can write something like "Current: *1:25.215",
    --    this way we don't have to calculate the size of the number to put the '*', which is faster
    -- 2. Instead of combining the whole time into a single string, we can keep it split as
    --    minutes, seconds, milliseconds, and calculate each one separately,
    --    this way minutes is cached for 60s, seconds for 1s and only millisecond is
    --    calculated every time, it should be faster but we should try.
    local my_previous_laptime = players.get_previous_laptime(0)
    local last_laptime_exists = my_previous_laptime ~= nil and my_previous_laptime > 0
    local laptime_string = lap.time_to_string(my_previous_laptime)
    local current_time_string = lap.time_to_string(my_car.lapTimeMs)
    local top_left_text_size = ui.measureDWriteText(current_time_string, number_size)
    local bot_left_text_size = ui.measureDWriteText(laptime_string,      number_size)
    local top_left_text_pos = top_left_text  + text_offset + vec2(left_numb_adjust, 0)
    local bot_left_text_pos = bot_left_text  + text_offset + vec2(left_numb_adjust, 0)
    ui.dwriteDrawText(best_time_text,      number_size, top_right_numb + vec2(-best_time_size.x,   0),            colors.WHITE)
    ui.dwriteDrawText(record_time_text,    number_size, bot_right_numb + vec2(-record_time_size.x, 0),            colors.WHITE)
    ui.dwriteDrawText(current_time_string, number_size, top_left_text_pos, colors.WHITE)
    ui.dwriteDrawText(laptime_string,      number_size, bot_left_text_pos, colors.WHITE)
    ui.pushDWriteFont(fonts.opti_edgar)
    if my_car.isLapValid     == false                         then ui.dwriteDrawText('*', number_size, top_left_text_pos + vec2(top_left_text_size.x, -3 * SectorsScale)) end
    if my_car.isLastLapValid == false and last_laptime_exists then ui.dwriteDrawText('*', number_size, bot_left_text_pos + vec2(bot_left_text_size.x, -3 * SectorsScale)) end
    ui.popDWriteFont()
    --
    -- sectors
    --
    local top_left_sectors_corner = bg_center + vec2(-window_size.x, window_size.y)/2
    local sectors_size = vec2(window_size.x, sector_height)
    local stint_pos = top_left_sectors_corner + vec2(0, sector_height)
    local stint_size = vec2(window_size.x, squares_height + 2 * sector_padding)
    ui.drawRectFilled(top_left_sectors_corner, top_left_sectors_corner + sectors_size, colors.LIGHT_BG)
    ui.drawRectFilled(stint_pos, stint_pos + stint_size, colors.BG)
    
    
    local sector_count = #players.get_sector_splits()
    local actual_stint_width = (((window_width - sector_count + 1) / sector_count - 9 * sector_padding) / 8)
    local sector_width = (actual_stint_width * 8 + sector_padding * 7)
    local sector_rect_size = vec2(sector_width, sector_height)
    local spline = my_car.splinePosition
    if ac.getTrackName() == "Nordschleife - Tourist" then
        spline = players.normalize_spline_for_nordschleife_turist(spline)
    end
    local current_stint_index = lap.get_stint_index(spline)
    local current_sector_index = my_car.currentSector
    
    local sector_times = my_car.currentSplits
    local mp_best_sector_times = players.get_best_sector_times()
    local lap_to_draw = times.current_lap
    local player_best_sectors = players.get_player_best_sector_times(0)
    local lap_best_to_compare = times.aggregated_best_lap
    local lap_mp_to_compare = times.multiplayer_best_lap
    local showing_old = false
    if current_stint_index == 0 and players.get_previous_laptime(0) ~= 0 then
        -- we just update the things we want to draw, use the temporary display laps
        sector_times = players.get_last_splits(0)
        showing_old = true
        lap_to_draw = times.display_lap
        lap_best_to_compare = times.display_aggregated
        lap_mp_to_compare = times.display_multiplayer
    end
    
    for i=0, sector_count-1 do
        local corner_pos = top_left_sectors_corner + vec2((sector_width + 1 + sector_padding * 2) * i + sector_padding, 0)
        
        local sector_texture = nil
        local sector_time = sector_times[i]
        local best_time   = nil
        if player_best_sectors ~= nil then best_time = player_best_sectors[i] end
        local record_time = mp_best_sector_times[i]
        local texture_color = rgbm(1, 1, 1, 0)
        local sector_curve = settings.get_curve_t(sector_animation_start_times[i], false, Sectors_AnimDuration)
        
        if i >= current_sector_index and showing_old == false then sector_time = 0 end
        if sector_time ~= nil and sector_time > 0 then
            if best_time   == nil or best_time <= 0 or sector_time <= best_time then
                sector_texture = settings.get_asset("sec")
                texture_color.r = colors.GREEN.r
                texture_color.g = colors.GREEN.g
                texture_color.b = colors.GREEN.b
                texture_color.mult = settings.remap(sector_curve, 0, 1, 0, 0.7)
            end
            if record_time == nil or record_time <= 0 or sector_time <= record_time then
                sector_texture = settings.get_asset("sec")
                texture_color.r = colors.PURPLE.r
                texture_color.g = colors.PURPLE.g
                texture_color.b = colors.PURPLE.b
                texture_color.mult = settings.remap(sector_curve, 0, 1, 0, 0.8)
            end
        end
        
        if sector_texture ~= nil then
            ui.drawImageQuad(sector_texture,
                corner_pos,
                corner_pos + vec2(sector_rect_size.x, 0),
                corner_pos + vec2(sector_rect_size.x, sector_height),
                corner_pos + vec2(0, sector_height),
                texture_color
            )
        end
        
        local sector_center = corner_pos + sector_rect_size / 2
        local sector_text_string = string.format("S%d", i+1)
        local sector_text_size = ui.measureDWriteText(sector_text_string, text_size)
        ui.dwriteDrawText(sector_text_string, text_size, sector_center - sector_text_size / 2, colors.WHITE)
        
        for x=0, 7 do
            local square_pos = corner_pos + vec2((actual_stint_width + sector_padding) * x, sector_height + sector_padding)
            local stint_color = nil -- rgbm(0, 0, 0, 0.2)
            local stint_index = x + 8*i
            local stint_time = lap_to_draw.stints[stint_index]
            if stint_index >= current_stint_index and showing_old == false then stint_time = 0 end -- we're still updating a stint before this one, don't color it yet!
            if stint_time ~= nil and stint_time ~= 0 then
                stint_color = colors.LIGHT_GRAY
                local best_stint_time   = lap_best_to_compare.stints[stint_index]
                local record_stint_time = lap_mp_to_compare.stints[stint_index]
                if best_stint_time == nil or best_stint_time == 0 or stint_time <= best_stint_time   then stint_color = colors.GREEN  end
                if record_stint_time == nil or record_stint_time == 0 or stint_time <= record_stint_time then stint_color = colors.PURPLE end
            end
            if stint_color ~= nil then
                ui.drawRectFilled(square_pos, square_pos + vec2(actual_stint_width, squares_height), stint_color)
            end
        end
    end
    
    -- white lines
    for i=1, sector_count-1 do
        local line_start = top_left_sectors_corner + vec2((sector_width + sector_padding * 2) * i + (i-1), -1) -- NOTE(cogno): I don't know why but lines are 1px off vertically...
        local line_end = line_start + vec2(0, sector_height + stint_size.y)
        ui.drawLine(line_start, line_end, colors.WHITE)
    end
    
    
    local show_because_mouse = false
    if ui.mouseDown(ui.MouseButton.Left) and settings.is_inside(ui.mouseLocalPos(), draw_size / 2, draw_size / 2) then
        show_because_mouse = true
    end
    
    --
    -- record guy notification
    --
    if show_because_mouse == false then
        if window_center.x > screensize.x / 2 then
            ui.pushClipRect(corner_start + vec2(notification_size.x - clip_width + end_width, 0), corner_start + notification_size)
        else
            ui.pushClipRect(corner_start, corner_start + vec2(clip_width - end_width, notification_size.y))
        end
    end
    
    -- backgrounds
    ui.drawRectFilled(notification_center - notification_size / 2, notification_center + vec2(notification_size.x / 2, 0), colors.BG)
    ui.drawRectFilled(notification_center - vec2(notification_size.x / 2, 0), notification_center + notification_size / 2, colors.LIGHT_BG)
    
    local notification_cr = notification_center + vec2(notification_size.x / 2, 0)
    local gradient_width = notific_default_width * 0.6
    ui.drawImageQuad(
        settings.get_asset("white"),
        notification_cr - vec2(gradient_width, 0),
        notification_cr,
        notification_cr + vec2(0, notification_size.y / 2),
        notification_cr + vec2(-gradient_width, notification_size.y / 2),
        rgbm(colors.PURPLE.r, colors.PURPLE.g, colors.PURPLE.b, 0.55)
    )
    
    local text_pos = notification_center - notification_size / 2 + vec2(12,8) * SectorsScale
    ui.dwriteDrawText("Fastest Lap", text_size, text_pos, colors.TEXT_GRAY)
    
    local square_pos = notification_center + vec2(-notification_size.x, 0) / 2 + vec2(square_padding, square_padding)
    local square_center = square_pos + square_size / 2
    local number_text = string.format("%d", racepos_of_person_with_best_lap)
    local number_scrensize = ui.measureDWriteText(number_text, text_size)
    local number_pos = square_center - number_scrensize / 2
    ui.drawRectFilled(square_pos, square_pos + vec2(square_size, square_size), colors.WHITE, 6 * SectorsScale, ui.CornerFlags.BottomRight)
    ui.dwriteDrawText(number_text, text_size, number_pos, colors.BLACK)
    
    local text_pos = square_pos + vec2(square_size + square_padding, 0) + text_padding_vec
    ui.dwriteDrawText(name_of_person_with_best_lap, text_size, text_pos, colors.WHITE)
    
    local text_pos = notification_center + notification_size / 2 - text_size_v - number_offset
    ui.dwriteDrawText(text_string, number_size, text_pos, colors.WHITE)
    if show_because_mouse == false then
        ui.popClipRect()
    end
    
    ui.popDWriteFont()
    local app_center = draw_top_left + app_size / 2
    players.play_intro_anim(app_center, app_size, on_show_animation_start, SectorsScale)
    settings.lock_app(app_center, app_size, APPNAMES.sectors, SectorsScale)
    settings.auto_scale_window(app_size * 1.02, APPNAMES.sectors)
    settings.auto_place_once(app_size, APPNAMES.sectors)
end
    
return sectors