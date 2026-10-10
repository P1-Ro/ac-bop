local mod = {}

local settings = require('common.settings')
local colors = settings.colors
local fonts = settings.fonts
local lap = require('sectors.lap')
local players = require('common.players')
local acbop = require('common.acbop')

local storage = nil
local gearbox_migration_storage = ac.storage("Gearbox_Migrated_Mph", false)
local gearbox_mph_storage = ac.storage("Gearbox_ShowMph_v2", false)
local gearbox_gal_storage = ac.storage("Gearbox_ShowGal_v2", false)
local save_settings = false
Deltabar_Modes = {
    SESSION_LAP=0,
    SESSION_OPTIMAL=1,
    FASTEST_LAP=2,
    FASTEST_OPTIMAL=3,
    PREVIOUS_LAP=4,
    MULTIPLAYER_LAP=5
}
Deltabar_ShowSectorsPerMode = table.new(table.nkeys(Deltabar_Modes), 0) -- if false visualize data on the ENTIRE lap

-- default as false, if no laps folder exists (or if user manually resets) we change to true and move them one by one later inside each one
CanMoveApps = {
    [APPNAMES.deltabar]    = false,
    [APPNAMES.gearbox]     = false,
    [APPNAMES.leaderboard] = false,
    [APPNAMES.map]         = false,
    [APPNAMES.real_time]   = false,
    [APPNAMES.pedals]      = false,
    [APPNAMES.radar]       = false,
    [APPNAMES.sectors]     = false,
    [APPNAMES.local_time]  = false,
    [APPNAMES.tyres]       = false,
}
local app_version = ""
function mod.init()
    storage = ac.storage{
        gearbox_scale = 1,
        gearbox_show_mph = false, -- DEPRECATED(cogno): old value, replaced by :get() and :set(...)
        gearbox_dots_window = true,
        pctime_bg = true,
        pctime_bar = false,
        maptime_bg = true,
        maptime_bar = true,
        maptime_scale = 1,
        pctime_scale = 1,
        sectors_scale = 1,
        sectors_anim_duration = 8,
        leaderboard_anim_duration = 18,
        leaderboard_scale = 1,
        leaderboard_fah = false,
        leaderboard_show_tyres = true,
        tyres_scale = 1,
        map_scale = 1,
        deltabar_scale = 1,
        pedals_scale = 1,
        radar_scale = 1,
        tyres_show_pedals = true,
        pedals_show_gas = true,
        pedals_show_brk = true,
        pedals_show_handbrk = false,
        pedals_show_clt = false,
        pedals_show_ffb = false,
        leaderboard_refresh_rate = 2000, -- in ms
        tyres_show_fah = false,
        tyres_show_mph = false,
        tyres_temp_colored = true,
        tyres_pressure_delta = true,
        radar_show_dots = true,
        radar_show_double_lines = true,
        radar_show_players = true,
        radar_rotate_cars = false,
        radar_extra_warning = false,
        map_low_profile = true,
        deltabar_practice_mode = 0,
        deltabar_qualify_mode = 0,
        deltabar_race_mode = 0,
        deltabar_anim_duration = 8,
        deltabar_save_on_close = false,
        deltabar_minimized = false,
        deltabar_position = 1,
        apps_auto_scale = true,
        leaderboard_scroll_long_names = false,
        leaderboard_show_bop = true,
        acbop_url = '',
    }
    if storage.gearbox_show_mph ~= nil and gearbox_migration_storage:get() == false then -- transition into new values
        -- NOTE(cogno): doing storage.old_value = nil will NOT delete the value, so we use an extra storage to know if we did the transition
        gearbox_mph_storage:set(storage.gearbox_show_mph)
        gearbox_gal_storage:set(storage.gearbox_show_mph)
        gearbox_migration_storage:set(true) -- transition completed
    end
    Gearbox_ShowMph = gearbox_mph_storage:get()
    Gearbox_ShowGal = gearbox_gal_storage:get()
    GearboxScale = storage.gearbox_scale
    Gearbox_DotsWindow = storage.gearbox_dots_window
    PcTime_ShowBar  = storage.pctime_bar
    PcTime_ShowBg   = storage.pctime_bg
    MapTime_ShowBar = storage.maptime_bar
    MapTime_ShowBg  = storage.maptime_bg
    MapTimeScale = storage.maptime_scale
    PcTimeScale = storage.pctime_scale
    SectorsScale = storage.sectors_scale
    Sectors_AnimDuration = storage.sectors_anim_duration
    Leaderboard_AnimDuration = storage.leaderboard_anim_duration
    LeaderboardScale = storage.leaderboard_scale
    Leaderboard_ShowFah = storage.leaderboard_fah
    Leaderboard_ShowTyres = storage.leaderboard_show_tyres
    Leaderboard_RefreshRate = storage.leaderboard_refresh_rate
    TyresScale = storage.tyres_scale
    MapScale = storage.map_scale
    DeltabarScale = storage.deltabar_scale
    PedalsScale = storage.pedals_scale
    RadarScale = storage.radar_scale
    Tyres_ShowPedals = storage.tyres_show_pedals
    Pedals_ShowGas = storage.pedals_show_gas
    Pedals_ShowBrake = storage.pedals_show_brk
    Pedals_ShowHandbrake = storage.pedals_show_handbrk
    Pedals_ShowClutch = storage.pedals_show_clt
    Pedals_ShowFfb = storage.pedals_show_ffb
    Tyres_ShowFah = storage.tyres_show_fah
    Tyres_TempColored = storage.tyres_temp_colored
    Tyres_PressureDelta = storage.tyres_pressure_delta
    Tyres_ShowMph = storage.tyres_show_mph
    Radar_ShowDots = storage.radar_show_dots
    Radar_ShowDoubleLines = storage.radar_show_double_lines
    Radar_ShowPlayers = storage.radar_show_players
    Radar_RotateCars = storage.radar_rotate_cars
    Radar_MultiWarningLines = storage.radar_extra_warning
    Map_LowProfile = storage.map_low_profile
    Deltabar_PracMode = storage.deltabar_practice_mode
    Deltabar_QualMode = storage.deltabar_qualify_mode
    Deltabar_RaceMode = storage.deltabar_race_mode
    Deltabar_AnimDuration = storage.deltabar_anim_duration
    Deltabar_SaveOnClose = storage.deltabar_save_on_close
    Deltabar_Minimized = storage.deltabar_minimized
    Deltabar_Position = storage.deltabar_position
    Apps_AutoScale = storage.apps_auto_scale
    Leaderboard_ScrollLongNames = storage.leaderboard_scroll_long_names
    Leaderboard_ShowBop = storage.leaderboard_show_bop
    Acbop_Url = storage.acbop_url

    for i=0, table.nkeys(Deltabar_Modes)-1 do
        local access_string = "deltabar_mode"..i
        local stored = ac.storage(access_string, false)
        Deltabar_ShowSectorsPerMode[i] = stored:get()
    end

    local folderpath = ac.getFolder(ac.FolderID.ACDocuments) .. "/CMRT-Essential-HUD/"
    local folder_exists = io.dirExists(folderpath)
    if not folder_exists then
        -- it's the first time opening the app EVER
        -- set that apps should be moved
        CanMoveApps[APPNAMES.deltabar]    = true
        CanMoveApps[APPNAMES.gearbox]     = true
        CanMoveApps[APPNAMES.leaderboard] = true
        CanMoveApps[APPNAMES.map]         = true
        CanMoveApps[APPNAMES.real_time]   = true
        CanMoveApps[APPNAMES.pedals]      = true
        CanMoveApps[APPNAMES.radar]       = true
        CanMoveApps[APPNAMES.sectors]     = true
        CanMoveApps[APPNAMES.local_time]  = true
        CanMoveApps[APPNAMES.tyres]       = true
    end

    -- automatically gather app version so we propagate it to files
    local changelog_string = io.load("apps/lua/CMRT-Essential-HUD/CHANGELOG.txt")
    local splitted = changelog_string:split("\n")
    app_version = splitted[1]
end

local function increase_value(to_change)
    return math.clamp(to_change + 0.1, 0.5, 2)
end

local function decrease_value(to_change)
    return math.clamp(to_change - 0.1, 0.5, 2)
end



local function general_settings()
    local cursor_pos = ui.getCursor()
    local banner_size = vec2(ui.windowSize().x - 44, 30)
    ui.drawRectFilled(cursor_pos, cursor_pos + banner_size, colors.BLUE)
    ui.pushDWriteFont(fonts.archivo_bold)
    
    ui.drawRectFilled(cursor_pos, cursor_pos + banner_size, colors.BLUE)
    ui.pushClipRect(cursor_pos + vec2(0, -2), cursor_pos + banner_size)
    local chunk_fontsize = settings.fontsize(16)
    local chunk_textwidth = ui.measureDWriteText("CMRT COMPLETE HUD       CLICK HERE       GET IT NOW", chunk_fontsize)
    local chunk_width = chunk_textwidth.x + 30
    local banner_textpos = cursor_pos + vec2((-math.floor(Time * 120)) % chunk_width, banner_size.y / 2 - chunk_textwidth.y / 2)
    local chunks_we_fit = math.ceil(banner_size.x / chunk_width)
    for i=-1, chunks_we_fit-1 do
        local chunk_pos = banner_textpos + vec2(chunk_width * i, 0)
        ui.dwriteDrawText("CMRT COMPLETE HUD       CLICK HERE       GET IT NOW", chunk_fontsize, chunk_pos, colors.WHITE)
    end
    ui.popClipRect()
    ui.popDWriteFont()
    ui.setCursorY(cursor_pos.y + banner_size.y)
    
    local banner_tl = cursor_pos:clone()
    local banner_shift = banner_tl.y - ui.getScrollY()
    if banner_shift <= 20 then
        banner_size.y = banner_size.y + banner_shift - 20
        banner_tl.y = banner_tl.y + 20 - banner_shift
    end
    if settings.is_inside(ui.mouseLocalPos(), banner_tl + banner_size / 2, banner_size / 2) then -- is inside the banner
        local real_local_pos = ui.mouseLocalPos()
        real_local_pos.y = real_local_pos.y - ui.getScrollY()
        if settings.is_inside(real_local_pos, ui.windowSize() / 2, ui.windowSize() / 2) then -- is the banner inside the window (you can scroll it off!)
            if ui.mouseClicked(ui.MouseButton.Left) then
                os.openURL("https://www.patreon.com/CMRT/shop/cmrt-complete-hud-563983?source=storefront")
            end
            ui.setMouseCursor(ui.MouseCursor.Hand)
        end
    end

    ui.newLine(-5)
    ui.text(string.format("Change scale for every app:"))
    
    ui.newLine(-5)
    if ui.button("-", vec2(40)) then
        save_settings = true
        GearboxScale = decrease_value(GearboxScale)
        PcTimeScale  = decrease_value(PcTimeScale)
        MapTimeScale = decrease_value(MapTimeScale)
        SectorsScale = decrease_value(SectorsScale)
        LeaderboardScale = decrease_value(LeaderboardScale)
        TyresScale       = decrease_value(TyresScale)
        MapScale         = decrease_value(MapScale)
        DeltabarScale    = decrease_value(DeltabarScale)
        PedalsScale      = decrease_value(PedalsScale)
        RadarScale       = decrease_value(RadarScale)
    end
    ui.sameLine()
    if ui.button(" + ", vec2(40)) then
        save_settings = true
        GearboxScale = increase_value(GearboxScale)
        PcTimeScale  = increase_value(PcTimeScale)
        MapTimeScale = increase_value(MapTimeScale)
        SectorsScale = increase_value(SectorsScale)
        LeaderboardScale = increase_value(LeaderboardScale)
        TyresScale       = increase_value(TyresScale)
        MapScale         = increase_value(MapScale)
        DeltabarScale    = increase_value(DeltabarScale)
        PedalsScale      = increase_value(PedalsScale)
        RadarScale       = increase_value(RadarScale)
    end
    
    ui.newLine(-5)
    if ui.button("Reset") then
        save_settings = true
        GearboxScale = 1
        PcTimeScale = 1
        MapTimeScale = 1
        SectorsScale = 1
        LeaderboardScale = 1
        TyresScale = 1
        MapScale = 1
        DeltabarScale = 1
        PedalsScale = 1
        RadarScale = 1
    end
    ui.newLine(-5)
    ui.newLine(-5)

    if ui.checkbox("Scale Automatically", Apps_AutoScale) then
        Apps_AutoScale = not Apps_AutoScale
        save_settings = true
    end
    ui.newLine(-5)

    if ui.button("Reset Apps Layout") then
        -- player wants to move the apps
        CanMoveApps[APPNAMES.deltabar]    = true
        CanMoveApps[APPNAMES.gearbox]     = true
        CanMoveApps[APPNAMES.leaderboard] = true
        CanMoveApps[APPNAMES.map]         = true
        CanMoveApps[APPNAMES.real_time]   = true
        CanMoveApps[APPNAMES.pedals]      = true
        CanMoveApps[APPNAMES.radar]       = true
        CanMoveApps[APPNAMES.sectors]     = true
        CanMoveApps[APPNAMES.local_time]  = true
        CanMoveApps[APPNAMES.tyres]       = true
    end

    ui.newLine(15)
    ui.drawImage(settings.get_asset("cmrt_logo"), ui.getCursor(), ui.getCursor() + vec2(981, 217)*0.15)
    ui.setCursor(ui.getCursor() + vec2(0, 40))
    
    ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
    ui.text(app_version)
    ui.popStyleColor()
end

local function scale_settings(old_value)
    ui.newLine(-5)
    ui.text(string.format("Change scale: %.0f%%", old_value * 100))
    
    ui.newLine(-5)
    if ui.button("-", vec2(40)) then
        old_value = old_value - 0.1
        save_settings = true
    end
    ui.sameLine()
    if ui.button(" + ", vec2(40)) then
        old_value = old_value + 0.1
        save_settings = true
    end
    
    ui.newLine(-5)
    if ui.button("Reset") then
        old_value = 1
        save_settings = true
    end
    ui.newLine(-5)
    ui.newLine(-5)
    
    old_value = math.clamp(old_value, 0.5, 2)
    return old_value
end

local function gearbox_settings()
    GearboxScale = scale_settings(GearboxScale)
    
    if ui.checkbox("RPM lights at limiter", Gearbox_DotsWindow) then
        Gearbox_DotsWindow = not Gearbox_DotsWindow
        save_settings = true
    end
    ui.newLine(-5)

    ui.text("Speed measurement units:")
    if ui.radioButton("KMH##mph", not Gearbox_ShowMph) then
        Gearbox_ShowMph = false
        save_settings = true
    end
    if ui.radioButton("MPH##mph", Gearbox_ShowMph) then
        Gearbox_ShowMph = true
        save_settings = true
    end
    ui.newLine(-5)

    ui.text("Fuel measurement units:")
    if ui.radioButton("Liters##gal", not Gearbox_ShowGal) then
        Gearbox_ShowGal = false
        save_settings = true
    end
    if ui.radioButton("Gallons##gal", Gearbox_ShowGal) then
        Gearbox_ShowGal = true
        save_settings = true
    end
end

local function maptime_settings()
    MapTimeScale = scale_settings(MapTimeScale)
    if ui.checkbox("show background", MapTime_ShowBg) then
        MapTime_ShowBg = not MapTime_ShowBg
        save_settings = true
    end
    
    if ui.checkbox("show bar", MapTime_ShowBar) then
        MapTime_ShowBar = not MapTime_ShowBar
        save_settings = true
    end
end
local function pctime_settings()
    PcTimeScale = scale_settings(PcTimeScale)
    if ui.checkbox("show background", PcTime_ShowBg) then
        PcTime_ShowBg = not PcTime_ShowBg
        save_settings = true
    end
    
    if ui.checkbox("show bar", PcTime_ShowBar) then
        PcTime_ShowBar = not PcTime_ShowBar
        save_settings = true
    end
end

local function sectors_settings()
    SectorsScale = scale_settings(SectorsScale)
    
    ui.text("Fastest Lap notification:")
    local value, changed = ui.slider("##sectors_anim_length", Sectors_AnimDuration, 5, 40, "%.0f seconds")
    Sectors_AnimDuration = value
    if changed then save_settings = true end
end

local function leaderboard_settings()
    LeaderboardScale = scale_settings(LeaderboardScale)
    
    ui.text("Temperature Indicator:")
    if ui.radioButton("Celsius", not Leaderboard_ShowFah) then
        Leaderboard_ShowFah = false
        save_settings = true
    end
    if ui.radioButton("Fahrenheit", Leaderboard_ShowFah) then
        Leaderboard_ShowFah = true
        save_settings = true
    end
    
    ui.newLine(-5)
    if ui.checkbox("Show tyres compound", Leaderboard_ShowTyres) then
        Leaderboard_ShowTyres = not Leaderboard_ShowTyres
        save_settings = true
    end
    if ui.checkbox("Show ballast and restrictor", Leaderboard_ShowBop) then
        Leaderboard_ShowBop = not Leaderboard_ShowBop
        save_settings = true
    end
    if ui.checkbox("Make Long Names Scroll", Leaderboard_ScrollLongNames) then
        Leaderboard_ScrollLongNames = not Leaderboard_ScrollLongNames
        save_settings = true
    end
    
    ui.newLine(-5)
    ui.text("Fastest Lap notification:")
    local value, changed = ui.slider("##sectors_anim_length", Leaderboard_AnimDuration, 5, 40, "%.0f seconds")
    Leaderboard_AnimDuration = value
    if changed then save_settings = true end
    
    ui.newLine(-5)
    ui.text("Interval refresh rate:")
    local value, changed = ui.slider("##leaderb_interv_refresh_rate", Leaderboard_RefreshRate / 1000, 0.1, 60, "%.1f s")
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

local function tyres_settings()
    TyresScale = scale_settings(TyresScale)
    
    if ui.checkbox("Show attached pedals", Tyres_ShowPedals) then
        Tyres_ShowPedals = not Tyres_ShowPedals
        save_settings = true
    end
    if ui.checkbox("Show pressure delta from ideal", Tyres_PressureDelta) then
        Tyres_PressureDelta = not Tyres_PressureDelta
        save_settings = true
    end
    if ui.checkbox("Show core temperature gradient", Tyres_TempColored) then
        Tyres_TempColored = not Tyres_TempColored
        save_settings = true
    end
    ui.newLine(-5)
    ui.text("Temperature Indicator:")
    if ui.radioButton("Celsius", not Tyres_ShowFah) then
        Tyres_ShowFah = false
        save_settings = true
    end
    if ui.radioButton("Fahrenheit", Tyres_ShowFah) then
        Tyres_ShowFah = true
        save_settings = true
    end
    
    ui.newLine(-5)
    ui.text("Speed Indicator:")
    if ui.radioButton("Metric", not Tyres_ShowMph) then
        Tyres_ShowMph = false
        save_settings = true
    end
    if ui.radioButton("Imperial", Tyres_ShowMph) then
        Tyres_ShowMph = true
        save_settings = true
    end
end

local function map_settings()
    MapScale = scale_settings(MapScale)
    
    if ui.checkbox("Low Profile Mode", Map_LowProfile) then
        Map_LowProfile = not Map_LowProfile
        save_settings = true
    end
    ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
    ui.textWrapped("In low profile mode the map will show bigger only the leader, yourself and the two positions ahead and behind you. In normal mode, instead, the map will show bigger everyone.")
    ui.popStyleColor()
end

local barmode_names = {
    [0]="Session Best",
    "Session Optimal",
    "Record Best",
    "Record Optimal",
    "Previous Lap",
    "Session Record",
}

-- NOTE(cogno): be careful when you change these, because we have code that manually checks these values in deltabar.first
local barmode_choices = {
    [0]="Don't Change",
    "Session Best",
    "Session Optimal",
    "Record Best",
    "Record Optimal",
    "Previous Lap",
    "Session Record",
}

local barmode_dropdown = 0
local function deltabar_settings()
    ui.newLine(-5)
    ui.newLine(-5)
    ui.tabBar("Tab", function()
        ui.tabItem("General", function()
            DeltabarScale = scale_settings(DeltabarScale)
            
            ui.text("Info bar notification:")
            local value, changed = ui.slider("##deltabar_anim_length", Deltabar_AnimDuration, 2, 40, "%.0f seconds")
            Deltabar_AnimDuration = value
            if changed then save_settings = true end
            
            ui.newLine(-5)
            if ui.checkbox("Minimized ", Deltabar_Minimized) then
                Deltabar_Minimized = not Deltabar_Minimized
                save_settings = true
            end
            ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
            ui.textWrapped("Hides the delta bar itself, leaving only the delta on screen.")
            ui.popStyleColor()
            
            ui.newLine(-5)
            if Deltabar_Minimized then
                ui.text("Delta Position:")
                if ui.radioButton("Upper", Deltabar_Position == 0) then
                    Deltabar_Position = 0
                    save_settings = true
                end
                if ui.radioButton("Lower", Deltabar_Position == 2 or Deltabar_Position == 1) then
                    Deltabar_Position = 1
                    save_settings = true
                end
            else
                ui.text("Deltabar Position:")
                if ui.radioButton("Upper", Deltabar_Position == 0) then
                    Deltabar_Position = 0
                    save_settings = true
                end
                if ui.radioButton("Centered", Deltabar_Position == 1) then
                    Deltabar_Position = 1
                    save_settings = true
                end
                if ui.radioButton("Lower", Deltabar_Position == 2) then
                    Deltabar_Position = 2
                    save_settings = true
                end
            end

            ui.newLine(-5)
            if ui.checkbox("Save on Close", Deltabar_SaveOnClose) then
                Deltabar_SaveOnClose = not Deltabar_SaveOnClose
                save_settings = true
            end
            ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
            ui.textWrapped("Useful if notice stuttering at the end of each sector. With this setting enabled the lap/sectors data will be saved when the game closes instead of at the end of every sector.")
            ui.popStyleColor()
            ui.text("WARNING: ")
            ui.sameLine()
            ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
            ui.textWrapped("The data will be lost if the game crashes or closes unexpectedly (for example by using Alt+F4)")
            ui.popStyleColor()
        end)
        ui.tabItem("Preferences", function()
            ui.newLine(-5)
            ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
            ui.text("Choose the deltabar mode for each session")
            ui.popStyleColor()
            ui.newLine(-5)
            
            ui.text("Practice:")
            local practice_choice, prac_changed = ui.combo("##dtbar_1", Deltabar_PracMode, ui.ComboFlags.None, barmode_choices)
            Deltabar_PracMode = practice_choice
            if prac_changed then save_settings = true end

            ui.text("Qualify:")
            local qualify_choice, qual_changed = ui.combo("##dtbar_2", Deltabar_QualMode, ui.ComboFlags.None, barmode_choices)
            Deltabar_QualMode = qualify_choice
            if qual_changed then save_settings = true end
            
            ui.text("Race:")
            local race_choice, race_changed = ui.combo("##dtbar_3", Deltabar_RaceMode, ui.ComboFlags.None, barmode_choices)
            Deltabar_RaceMode = race_choice
            if race_changed then save_settings = true end
        end)
        
        ui.tabItem("Info panel", function()
            ui.newLine(-5)
            ui.pushStyleColor(ui.StyleColor.Text, colors.SETTINGS_TEXT)
            ui.text("Choose what the Info Panel shows for each mode")
            ui.popStyleColor()
            ui.newLine(-5)
            ui.text("Mode:")
            barmode_dropdown = ui.combo("##dtbar_4", barmode_dropdown, ui.ComboFlags.None, barmode_names)
            
            if ui.radioButton("Show sector", Deltabar_ShowSectorsPerMode[barmode_dropdown]) then
                Deltabar_ShowSectorsPerMode[barmode_dropdown] = true
                save_settings = true
            end
            if ui.radioButton("Show lap", not Deltabar_ShowSectorsPerMode[barmode_dropdown]) then
                Deltabar_ShowSectorsPerMode[barmode_dropdown] = false
                save_settings = true
            end
        end)
    end)
end

local function pedals_settings()
    PedalsScale = scale_settings(PedalsScale)
    
    ui.text("Telemetry:")
    if ui.checkbox("Show throttle", Pedals_ShowGas) then
        Pedals_ShowGas = not Pedals_ShowGas
        save_settings = true
    end
    
    if ui.checkbox("Show brake", Pedals_ShowBrake) then
        Pedals_ShowBrake = not Pedals_ShowBrake
        save_settings = true
    end

    if ui.checkbox("Show handbrake", Pedals_ShowHandbrake) then
        Pedals_ShowHandbrake = not Pedals_ShowHandbrake
        save_settings = true
    end
    
    
    if ui.checkbox("Show clutch", Pedals_ShowClutch) then
        Pedals_ShowClutch = not Pedals_ShowClutch
        save_settings = true
    end
    
    if ui.checkbox("Show force feedback", Pedals_ShowFfb) then
        Pedals_ShowFfb = not Pedals_ShowFfb
        save_settings = true
    end
end

local function radar_settings()
    RadarScale = scale_settings(RadarScale)
    
    if ui.checkbox("Show background dots", Radar_ShowDots) then
        Radar_ShowDots = not Radar_ShowDots
        save_settings = true
    end
    if ui.checkbox("Show single horizontal line", not Radar_ShowDoubleLines) then
        Radar_ShowDoubleLines = not Radar_ShowDoubleLines
        save_settings = true
    end
    if ui.checkbox("Show other players rectangles", Radar_ShowPlayers) then
        Radar_ShowPlayers = not Radar_ShowPlayers
        save_settings = true
    end
    if Radar_ShowPlayers then
        if ui.checkbox("Rotate other players rectangles", Radar_RotateCars) then
            Radar_RotateCars = not Radar_RotateCars
            save_settings = true
        end
    end
    if ui.checkbox("Show extra warning bands", Radar_MultiWarningLines) then
        Radar_MultiWarningLines = not Radar_MultiWarningLines
        save_settings = true
    end
end

function mod.main()
    ui.tabBar("main bar", ui.TabBarFlags.FittingPolicyScroll, function()
        ui.tabItem("General", general_settings)
        ui.tabItem("Gearbox", gearbox_settings)
        ui.tabItem("Local time", maptime_settings)
        ui.tabItem("Real time", pctime_settings)
        ui.tabItem("Sectors", sectors_settings)
        ui.tabItem("Leaderboard", leaderboard_settings)
        ui.tabItem("Safety car", safetycar_settings)
        ui.tabItem("Tyres", tyres_settings)
        ui.tabItem("Map", map_settings)
        ui.tabItem("Deltabar", deltabar_settings)
        ui.tabItem("Pedals", pedals_settings)
        ui.tabItem("Radar", radar_settings)
    end)
    
    if save_settings then
        save_settings = false
        gearbox_gal_storage:set(Gearbox_ShowGal)
        gearbox_mph_storage:set(Gearbox_ShowMph)
        storage.gearbox_scale = GearboxScale
        storage.maptime_bar = MapTime_ShowBar
        storage.maptime_bg = MapTime_ShowBg
        storage.pctime_bar = PcTime_ShowBar
        storage.pctime_bg = PcTime_ShowBg
        storage.maptime_scale = MapTimeScale
        storage.pctime_scale = PcTimeScale
        storage.gearbox_dots_window = Gearbox_DotsWindow
        storage.sectors_scale = SectorsScale
        storage.sectors_anim_duration = Sectors_AnimDuration
        storage.leaderboard_anim_duration = Leaderboard_AnimDuration
        storage.leaderboard_scale = LeaderboardScale
        storage.leaderboard_fah = Leaderboard_ShowFah
        storage.leaderboard_show_tyres = Leaderboard_ShowTyres
        storage.leaderboard_show_bop = Leaderboard_ShowBop
        storage.acbop_url = Acbop_Url
        storage.leaderboard_refresh_rate = Leaderboard_RefreshRate
        storage.tyres_scale = TyresScale
        storage.map_scale = MapScale
        storage.deltabar_scale = DeltabarScale
        storage.pedals_scale = PedalsScale
        storage.radar_scale = RadarScale
        storage.tyres_show_pedals = Tyres_ShowPedals
        storage.pedals_show_gas = Pedals_ShowGas
        storage.pedals_show_brk = Pedals_ShowBrake
        storage.pedals_show_handbrk = Pedals_ShowHandbrake
        storage.pedals_show_clt = Pedals_ShowClutch
        storage.pedals_show_ffb = Pedals_ShowFfb
        storage.tyres_show_fah = Tyres_ShowFah
        storage.tyres_temp_colored = Tyres_TempColored
        storage.tyres_pressure_delta = Tyres_PressureDelta
        storage.tyres_show_mph = Tyres_ShowMph
        storage.radar_show_dots = Radar_ShowDots
        storage.radar_show_double_lines = Radar_ShowDoubleLines
        storage.radar_show_players = Radar_ShowPlayers
        storage.radar_rotate_cars = Radar_RotateCars
        storage.radar_extra_warning = Radar_MultiWarningLines
        storage.map_low_profile = Map_LowProfile
        storage.deltabar_practice_mode = Deltabar_PracMode
        storage.deltabar_qualify_mode = Deltabar_QualMode
        storage.deltabar_race_mode = Deltabar_RaceMode
        storage.deltabar_anim_duration = Deltabar_AnimDuration
        storage.deltabar_save_on_close = Deltabar_SaveOnClose
        storage.deltabar_minimized = Deltabar_Minimized
        storage.deltabar_position = Deltabar_Position
        local old_scale_value = storage.apps_auto_scale
        storage.apps_auto_scale = Apps_AutoScale
        storage.leaderboard_scroll_long_names = Leaderboard_ScrollLongNames

        for i=0, table.nkeys(Deltabar_Modes)-1 do
            local access_string = "deltabar_mode"..i
            local stored = ac.storage(access_string, false)
            stored:set(Deltabar_ShowSectorsPerMode[i])
        end

        if old_scale_value ~= Apps_AutoScale then
            -- now that we have saved if apps scale or not, we can replace the file
            if Apps_AutoScale then
                -- scale automatically
                io.copyFile("apps/lua/CMRT-Essential-HUD/auto_resize.ini", "apps/lua/CMRT-Essential-HUD/manifest.ini", false)
            else
                -- scale manually
                io.copyFile("apps/lua/CMRT-Essential-HUD/manual_resize.ini", "apps/lua/CMRT-Essential-HUD/manifest.ini", false)
            end
        end
    end
end

return mod