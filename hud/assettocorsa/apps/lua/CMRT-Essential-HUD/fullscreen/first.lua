local mod = {} -- will be filled with public functions

local settings = require('common.settings')
local colors = settings.colors
local fonts = settings.fonts

local anim_start = 0
local anim_started = false
local intro_anim_clip_size = vec2(500, 300)
local intro_logo_size = vec2(1024, 217) * 0.17 -- resolution of image scaled down

function mod.on_session_start()
    anim_started = false
    anim_start = 0
end

function mod.intro_anim_played()
    local elapsed = Time - anim_start
    return elapsed > 2
end

local function intro_anim()
    if DEV_IntroAnimOff then return end

    local center = settings.get_screensize() / 2
    local anim_t = math.clamp(settings.remap(Time - anim_start, 0.8, 1.0, 0, 1), 0, 1)
    local logo_clip_pos = center - intro_anim_clip_size / 2 + vec2(intro_anim_clip_size.x * anim_t, 0)
    ui.pushClipRect(logo_clip_pos, logo_clip_pos + intro_anim_clip_size)
    ui.drawImage(
        settings.get_asset("cmrt_logo"),
        center - intro_logo_size,
        center + intro_logo_size
    )
    ui.popClipRect()
end

function mod.main()
    if not anim_started then
        anim_started = true
        anim_start = Time
    end
    
    intro_anim()
end

return mod -- expose functions to the outside