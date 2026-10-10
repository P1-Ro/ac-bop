local mod = {} -- will be filled with public functions

local settings = require('common.settings')
local players  = require('common.players')
local colors = settings.colors
local fonts = settings.fonts

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
    
    local rect_size = vec2(512, 5) * MapTimeScale
    local time_rect_size = vec2(70, 24) * MapTimeScale
    local center_width = vec2(200, 0) * MapTimeScale
    
    local draw_top = draw_top_left + vec2(rect_size.x / 2, 0)
    local half_size = vec2(rect_size.x / 2, rect_size.y)
    local bottom_center = draw_top_left + vec2(rect_size.x / 2, time_rect_size.y + rect_size.y)
    local rect_tl = draw_top - vec2(time_rect_size.x / 2, 0)
    
    local bg_color = colors.DARK_BG
    local transp_color = colors.TRANSP
    if ui.mouseDown(ui.MouseButton.Left) then
        if settings.is_inside(ui.mouseLocalPos(), ui.windowSize() / 2, ui.windowSize() / 2) then
            transp_color = colors.DARK_BG
        end
    end
    players.play_intro_anim_setup(ui.windowSize() / 2, ui.windowSize(), on_show_animation_start, is_showing, true)
    
    if MapTime_ShowBar then
        ui.drawRectFilledMultiColor(
            bottom_center - half_size,
            bottom_center - center_width / 2,
            transp_color,
            bg_color,
            bg_color,
            transp_color
        )
    
        ui.drawRectFilled(bottom_center - vec2(center_width.x / 2, rect_size.y), bottom_center + center_width / 2, bg_color)
        
        ui.drawRectFilledMultiColor(
            bottom_center + center_width / 2,
            bottom_center + vec2(half_size.x, -half_size.y),
            bg_color,
            transp_color,
            transp_color,
            bg_color
        )
    else
        rect_tl = draw_top_left
    end
        
    if MapTime_ShowBg then
        ui.drawRectFilled(rect_tl, rect_tl + time_rect_size, bg_color)
    end
    
    local sim_info = ac.getSim()
    local text_string = string.format("%02d:%02d", sim_info.timeHours, sim_info.timeMinutes)
    local fontsize = settings.fontsize(14) * MapTimeScale
    local rect_center = rect_tl + time_rect_size / 2
    ui.pushDWriteFont(fonts.archivo_medium)
    local text_size = ui.measureDWriteText(text_string, fontsize)
    ui.dwriteDrawText(text_string, fontsize, rect_center - text_size / 2)
    ui.popDWriteFont()
    local app_size = vec2(rect_size.x, time_rect_size.y + rect_size.y)
    if MapTime_ShowBar == false then app_size.x = time_rect_size.x end
    settings.lock_app(rect_center, app_size, APPNAMES.local_time, 1)
    settings.auto_scale_window(app_size * 1.01, APPNAMES.local_time)
    settings.auto_place_once(app_size, APPNAMES.local_time)
    players.play_intro_anim(draw_top_left + app_size / 2, app_size / 2, 0, MapTimeScale) -- anim_start is 0 because we don't want to show the logo, the app is too small!
end

return mod -- expose functions to the outside