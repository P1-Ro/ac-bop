-- acbop integration: every car's ballast and restrictor for the leaderboard,
-- the virtual safety car state, and a rebindable button that calls one.
--
-- acbop publishes all of it at <acbop>/csp/state. The address comes from the
-- Safety car settings tab, or is detected from the server's CSP options: an
-- [ACBOP] URL entry, or the [SCRIPT_...] line that loads acbop's limiter.
-- The speed limiting itself is not done here: CSP only lets a server-provided
-- script touch the throttle online, so acbop ships that separately.
local module = {}

local POLL_IDLE = 2.0       -- seconds between polls normally
local POLL_VSC = 0.5        -- and while a safety car is running
local STALE_AFTER = 6       -- failed polls before the data is treated as gone
local CALL_COOLDOWN = 3.0   -- seconds between two safety car requests
local POLL_TIMEOUT = 10.0   -- give up waiting on a request after this long

local state = nil           -- last decoded /csp/state
local by_name = {}          -- driver name -> car entry, with its text prebuilt
local polling = false
local poll_started = 0
local next_poll = 0
local failures = 0
local detected_url = nil
local detect_done = false
local call_button = nil
local last_call = -100
local status_text = 'no acbop address'

local function strip_slash(url)
    return (url:gsub('/+$', ''))
end

-- Look for acbop's address in the server's CSP extra options.
local function detect_url()
    local ok, url = pcall(function()
        local cfg = ac.INIConfig.onlineExtras()
        if cfg == nil then return nil end
        local explicit = cfg:get('ACBOP', 'URL', '')
        if type(explicit) == 'string' and explicit ~= '' then return explicit end
        for name, _ in pairs(cfg.sections) do
            if type(name) == 'string' and name:find('^SCRIPT') then
                local script = cfg:get(name, 'SCRIPT', '')
                if type(script) == 'string' then
                    local base = script:match("^['\"]?(https?://[^/'\"]+)/csp/vsc%.lua")
                    if base ~= nil then return base end
                end
            end
        end
        return nil
    end)
    if ok and type(url) == 'string' and url ~= '' then return strip_slash(url) end
    return nil
end

function module.base_url()
    if Acbop_Url ~= nil and Acbop_Url ~= '' then return strip_slash(Acbop_Url) end
    return detected_url
end

local function poll(base)
    polling = true
    poll_started = Time
    local this_poll = poll_started
    web.get(base .. '/csp/state', function(err, response)
        if this_poll ~= poll_started then return end -- an answer we already gave up on
        polling = false
        if err or response == nil or response.status ~= 200 then
            failures = failures + 1
            if failures >= STALE_AFTER then status_text = 'cannot reach ' .. base end
            return
        end
        local ok, data = pcall(JSON.parse, response.body)
        if not ok or type(data) ~= 'table' then
            failures = failures + 1
            return
        end
        state = data
        failures = 0
        status_text = 'connected to ' .. base
        -- TAG: GarbageSucks, build the row text here once rather than every frame.
        table.clear(by_name)
        if type(data.cars) == 'table' then
            for _, car in ipairs(data.cars) do
                if type(car) == 'table' and type(car.name) == 'string' then
                    local r = math.floor((tonumber(car.r) or 0) + 0.5)
                    local b = math.floor((tonumber(car.b) or 0) + 0.5)
                    car.text = string.format('%dkg %d%%', b, r)
                    by_name[car.name] = car
                end
            end
        end
    end)
end

function module.init()
    call_button = ac.ControlButton('CMRT-Essential-HUD/Call virtual safety car')
end

function module.on_session_start()
    detect_done = false
end

function module.update()
    if not detect_done and ac.getSim().isOnlineRace then
        detected_url = detect_url()
        detect_done = true
    end

    if polling and Time - poll_started > POLL_TIMEOUT then
        polling = false
        failures = failures + 1
    end

    local base = module.base_url()
    if base == nil then
        status_text = 'no acbop address'
    elseif not polling and Time >= next_poll then
        next_poll = Time + (module.get_vsc() ~= nil and POLL_VSC or POLL_IDLE)
        poll(base)
    end

    if call_button ~= nil and call_button:pressed() then module.call_vsc() end
end

-- Ask the server for a safety car. acbop decides whether it is allowed and
-- answers in chat either way.
function module.call_vsc()
    if Time - last_call < CALL_COOLDOWN then return end
    last_call = Time
    local cmd = '!vsc'
    if state ~= nil and type(state.cmd) == 'string' and state.cmd ~= '' then cmd = state.cmd end
    ac.sendChatMessage(cmd)
    pcall(ac.setMessage, 'Safety car requested', 'The server will confirm in chat.')
end

---@return table? @The running safety car: caller, held, limit_kmh, gap, target_gap...
function module.get_vsc()
    if failures >= STALE_AFTER or state == nil or type(state.vsc) ~= 'table' then return nil end
    return state.vsc
end

local function entry_for(car_index)
    if failures >= STALE_AFTER then return nil end
    local name = ac.getDriverName(car_index)
    if name == nil then return nil end
    return by_name[name]
end

---@return string? @"45kg 12%", or nil if acbop has nothing for this car.
function module.bop_text(car_index)
    local entry = entry_for(car_index)
    if entry == nil then return nil end
    return entry.text
end

---@return string? @'caller', 'held' or nil.
function module.vsc_role(car_index)
    local vsc = module.get_vsc()
    if vsc == nil then return nil end
    local entry = entry_for(car_index)
    if entry == nil then return nil end
    if vsc.caller == entry.id then return 'caller' end
    if type(vsc.held) == 'table' then
        for _, id in ipairs(vsc.held) do
            if id == entry.id then return 'held' end
        end
    end
    return nil
end

function module.status()
    return status_text
end

-- Draws the binding widget for the settings window.
function module.call_button_control()
    if call_button ~= nil then call_button:control(vec2(260, 0)) end
end

return module
