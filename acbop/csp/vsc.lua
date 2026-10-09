--[[
  acbop virtual safety car: the in-game half.

  acbop serves this file and CSP runs it on every client, because only a
  server-provided "online script" may touch the throttle and brakes during an
  online race; a regular app may not. Add it to the server's
  cfg/csp_extra_options.ini:

    [SCRIPT_1]
    SCRIPT = 'http://<acbop host>:<web_port>/csp/vsc.lua?car={SessionID}'
    REQUIRED = 1

  While a safety car is running, acbop lists the cars to hold; if this car is
  one of them its speed is capped at the announced limit, like a pit limiter.
  Throttle is faded out approaching the cap and brakes are only added well
  past it, so the car is eased down rather than slammed. The caller and the
  cars behind them are never touched.

  The two placeholders below are filled in by acbop when it serves the file.
]]

local STATE_URL = "__ACBOP_STATE_URL__"
local MY_CAR_ID = __ACBOP_CAR_ID__ -- server slot, or -1 to find ourselves by name

-- How the cap is applied.
local DECEL_KMH_S = 12   -- the cap closes in from the speed you were doing at this rate
local THROTTLE_FADE = 6  -- km/h below the cap over which throttle is faded out
local BRAKE_FROM = 8     -- km/h over the cap before any brake is added
local MAX_BRAKE = 0.35   -- strongest brake the limiter will ever apply

local state = nil        -- last decoded /csp/state
local polling = false
local nextPoll = 0
local clock = 0
local failures = 0

local held = false
local heldSince = 0
local startSpeed = 0

local function contains(list, value)
  if type(list) ~= 'table' then return false end
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function myId()
  if MY_CAR_ID >= 0 then return MY_CAR_ID end
  if state and type(state.cars) == 'table' then
    local me = ac.getDriverName(0)
    for _, c in ipairs(state.cars) do
      if c.name == me then return c.id end
    end
  end
  return -1
end

local function poll()
  polling = true
  web.get(STATE_URL, function (err, response)
    polling = false
    if err or not response or response.status ~= 200 then
      failures = failures + 1
      return
    end
    local ok, data = pcall(JSON.parse, response.body)
    if ok and type(data) == 'table' then
      state = data
      failures = 0
    else
      failures = failures + 1
    end
  end)
end

-- Stale data must never hold a car: after a few missed polls, let go.
local function activeVsc()
  if failures >= 6 or not state then return nil end
  return state.vsc
end

function script.update(dt)
  clock = clock + dt
  local vsc = activeVsc()
  if not polling and clock >= nextPoll then
    nextPoll = clock + (vsc and 0.5 or 2)
    poll()
  end

  local wasHeld = held
  held = vsc ~= nil and contains(vsc.held, myId())
  if not held then return end

  local my = ac.getCar(0)
  if not wasHeld then
    heldSince = clock
    startSpeed = my.speedKmh
  end

  local cap = math.max(tonumber(vsc.limit_kmh) or 100, startSpeed - DECEL_KMH_S * (clock - heldSince))
  local over = my.speedKmh - cap

  -- Never add throttle the driver is not asking for: only ever take it away.
  if over > -THROTTLE_FADE then
    local allowed = math.min(1, math.max(0, -over / THROTTLE_FADE))
    physics.forceUserThrottleFor(0.1, math.min(my.gas, allowed))
  end
  if over > BRAKE_FROM then
    local brake = math.min(MAX_BRAKE, (over - BRAKE_FROM) / 40)
    physics.forceUserBrakesFor(0.1, math.max(my.brake, brake))
  end
end

function script.drawUI()
  local vsc = activeVsc()
  if not vsc then return end

  local id = myId()
  local line
  if vsc.caller == id then
    line = string.format('CATCH UP - gap %.1fs, ends under %.0fs', tonumber(vsc.gap) or 0, tonumber(vsc.target_gap) or 0)
  elseif held then
    line = string.format('LIMIT %d KM/H - you %d', math.floor((tonumber(vsc.limit_kmh) or 0) + 0.5),
      math.floor(ac.getCar(0).speedKmh + 0.5))
  else
    line = 'Cars ahead of ' .. tostring(vsc.caller_name or '?') .. ' are limited'
  end

  local sim = ac.getSim()
  local scale = ac.getUI().uiScale
  local width = sim.windowWidth / scale
  local size = vec2(440, 58)
  local tl = vec2(width / 2 - size.x / 2, 70)
  ui.drawRectFilled(tl, tl + size, rgbm(1, 0.89, 0, 0.92), 6)
  local title = 'VIRTUAL SAFETY CAR'
  local titleSize = ui.measureDWriteText(title, 22)
  ui.dwriteDrawText(title, 22, tl + vec2(size.x / 2 - titleSize.x / 2, 4), rgbm(0, 0, 0, 1))
  local lineSize = ui.measureDWriteText(line, 15)
  ui.dwriteDrawText(line, 15, tl + vec2(size.x / 2 - lineSize.x / 2, 34), rgbm(0, 0, 0, 1))
end
