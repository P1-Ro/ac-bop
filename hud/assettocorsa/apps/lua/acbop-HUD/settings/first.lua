-- The settings window: leaderboard look, and the safety car button and server.
local mod = {}

local acbop = require('common.acbop')

local VERSION = "1.1.1"

local storage = nil
local save_settings = false

-- the leaderboard places itself once, the first time it opens, or when asked
CanMoveApps = {
    [APPNAMES.leaderboard] = false,
}

function mod.init()
    storage = ac.storage{
        leaderboard_anim_duration = 18,
        leaderboard_scale = 1,
        leaderboard_fah = false,
        leaderboard_show_tyres = true,
        leaderboard_refresh_rate = 2000, -- in ms
        leaderboard_scroll_long_names = false,
        leaderboard_show_bop = true,
        leaderboard_placed = false,
        acbop_url = '',
    }
    Leaderboard_AnimDuration = storage.leaderboard_anim_duration
    LeaderboardScale = storage.leaderboard_scale
    Leaderboard_ShowFah = storage.leaderboard_fah
    Leaderboard_ShowTyres = storage.leaderboard_show_tyres
    Leaderboard_RefreshRate = storage.leaderboard_refresh_rate
    Leaderboard_ScrollLongNames = storage.leaderboard_scroll_long_names
    Leaderboard_ShowBop = storage.leaderboard_show_bop
    Acbop_Url = storage.acbop_url
    Apps_AutoScale = true

    if not storage.leaderboard_placed then
        CanMoveApps[APPNAMES.leaderboard] = true
        storage.leaderboard_placed = true
    end
end

local function leaderboard_settings()
    ui.text(string.format("Scale: %.0f%%", LeaderboardScale * 100))
    if ui.button("-", vec2(40)) then
        LeaderboardScale = LeaderboardScale - 0.1
        save_settings = true
    end
    ui.sameLine()
    if ui.button(" + ", vec2(40)) then
        LeaderboardScale = LeaderboardScale + 0.1
        save_settings = true
    end
    ui.sameLine()
    if ui.button("Reset") then
        LeaderboardScale = 1
        save_settings = true
    end
    LeaderboardScale = math.clamp(LeaderboardScale, 0.5, 2)
    if ui.button("Move back to the default position") then
        CanMoveApps[APPNAMES.leaderboard] = true
    end

    ui.newLine(-5)
    if ui.checkbox("Show ballast and restrictor", Leaderboard_ShowBop) then
        Leaderboard_ShowBop = not Leaderboard_ShowBop
        save_settings = true
    end
    if ui.checkbox("Show tyres compound", Leaderboard_ShowTyres) then
        Leaderboard_ShowTyres = not Leaderboard_ShowTyres
        save_settings = true
    end
    if ui.checkbox("Make long names scroll", Leaderboard_ScrollLongNames) then
        Leaderboard_ScrollLongNames = not Leaderboard_ScrollLongNames
        save_settings = true
    end
    if ui.checkbox("Temperatures in Fahrenheit", Leaderboard_ShowFah) then
        Leaderboard_ShowFah = not Leaderboard_ShowFah
        save_settings = true
    end

    ui.newLine(-5)
    ui.text("Fastest lap highlight:")
    local value, changed = ui.slider("##leaderb_anim_length", Leaderboard_AnimDuration, 5, 40, "%.0f seconds")
    Leaderboard_AnimDuration = value
    if changed then save_settings = true end

    ui.text("Interval refresh rate:")
    value, changed = ui.slider("##leaderb_interv_refresh_rate", Leaderboard_RefreshRate / 1000, 0.1, 60, "%.1f s")
    Leaderboard_RefreshRate = value * 1000
    if changed then save_settings = true end
end

local function safetycar_settings()
    ui.text("Call a virtual safety car:")
    acbop.call_button_control()
    ui.text("Click the box above, then press a key or wheel button to bind it.")
    ui.text("Pressing it asks the server for a safety car, same as typing the chat command.")

    ui.newLine(-5)
    ui.text("acbop server address:")
    local value, changed = ui.inputText("##acbop_url", Acbop_Url)
    if changed then
        Acbop_Url = value
        save_settings = true
    end
    ui.text("Leave empty to detect it from the server. Example: http://myserver:8770")
    ui.text("Status: " .. acbop.status())
end

function mod.main()
    ui.tabBar("main bar", ui.TabBarFlags.FittingPolicyScroll, function()
        ui.tabItem("Leaderboard", leaderboard_settings)
        ui.tabItem("Safety car", safetycar_settings)
    end)
    ui.newLine(-5)
    ui.text("acbop HUD " .. VERSION .. " - leaderboard from CMRT Essential HUD by CMRT Group")

    if save_settings then
        save_settings = false
        storage.leaderboard_anim_duration = Leaderboard_AnimDuration
        storage.leaderboard_scale = LeaderboardScale
        storage.leaderboard_fah = Leaderboard_ShowFah
        storage.leaderboard_show_tyres = Leaderboard_ShowTyres
        storage.leaderboard_refresh_rate = Leaderboard_RefreshRate
        storage.leaderboard_scroll_long_names = Leaderboard_ScrollLongNames
        storage.leaderboard_show_bop = Leaderboard_ShowBop
        storage.acbop_url = Acbop_Url
    end
end

return mod
