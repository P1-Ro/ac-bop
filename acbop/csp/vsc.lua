--[[
  acbop virtual safety car: the in-game half.

  acbop serves this file and CSP runs it on every client, because only a
  server-provided "online script" may touch the throttle and brakes during an
  online race; a regular app may not. Add it to the server's CSP extra
  options:

    [SCRIPT_1]
    SCRIPT = 'http://<acbop host>:<web_port>/csp/vsc.lua?car={SessionID}'
    REQUIRED = 1

  Those reach the game inside the welcome message: Content Manager puts them
  there when it starts the server, tools/csp_welcome.py does otherwise.

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

-- What went wrong last, if anything. Sent to acbop with the next poll so it
-- lands in the events log, and shown in CSP's Lua Debug app.
local lastError = nil
local reportedError = nil
local polls = 0

local function urlEncode(text)
  return (tostring(text):gsub('[^%w%-%._~]', function (c) return string.format('%%%02X', string.byte(c)) end))
end

local function contains(list, value)
  if type(list) ~= 'table' then return false end
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function myId()
  if MY_CAR_ID >= 0 then return MY_CAR_ID end
  -- The game knows its own server slot; the name match is a last resort.
  local own = ac.getCar(0)
  local sid = own and tonumber(own.sessionID)
  if sid and sid >= 0 then return sid end
  if state and type(state.cars) == 'table' then
    local me = ac.getDriverName(0)
    for _, c in ipairs(state.cars) do
      if c.name == me then return c.id end
    end
  end
  return -1
end

local function poll()
  -- Saying which car we are tells acbop this script is running here.
  local id = myId()
  local url = id >= 0 and (STATE_URL .. '?car=' .. tostring(id)) or STATE_URL
  if lastError and lastError ~= reportedError and id >= 0 then
    url = url .. '&err=' .. urlEncode(lastError:sub(1, 200))
    reportedError = lastError
  end
  polling = true
  local sent, why = pcall(web.get, url, function (err, response)
    polling = false
    polls = polls + 1
    if err or not response or response.status ~= 200 then
      failures = failures + 1
      ac.debug('acbop last poll', 'failed: ' .. tostring(err or (response and response.status)))
      return
    end
    local ok, data = pcall(JSON.parse, response.body)
    if ok and type(data) == 'table' then
      state = data
      failures = 0
      ac.debug('acbop last poll', 'ok')
    else
      failures = failures + 1
      ac.debug('acbop last poll', 'bad JSON')
    end
  end)
  if not sent then
    -- It never went out, so no callback will clear the flag.
    polling = false
    failures = failures + 1
    error(why, 0)
  end
end

-- Stale data must never hold a car: after a few missed polls, let go.
local function activeVsc()
  if failures >= 6 or not state then return nil end
  return state.vsc
end

local function step(dt)
  clock = clock + dt
  local vsc = activeVsc()
  if not polling and clock >= nextPoll then
    nextPoll = clock + (vsc and 0.5 or 2)
    poll()
  end

  local wasHeld = held
  held = vsc ~= nil and contains(vsc.held, myId())
  ac.debug('acbop car', myId())
  ac.debug('acbop polls', string.format('%d (%d failing)', polls, failures))
  ac.debug('acbop safety car', vsc and 'running' or 'none')
  ac.debug('acbop held', held)
  if not held then return end

  local my = ac.getCar(0)
  if not wasHeld then
    heldSince = clock
    startSpeed = my.speedKmh
  end

  local cap = math.max(tonumber(vsc.limit_kmh) or 100, startSpeed - DECEL_KMH_S * (clock - heldSince))
  local over = my.speedKmh - cap
  ac.debug('acbop cap km/h', math.floor(cap + 0.5))

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

-- An error thrown out of script.update can stop CSP running the script, which
-- would leave the car unlimited with nobody any the wiser. Catch it, keep
-- polling, and tell acbop what it was.
function script.update(dt)
  local ok, err = pcall(step, dt)
  if not ok then
    if tostring(err) ~= lastError then
      lastError = tostring(err)
      ac.log('acbop limiter: ' .. lastError)
    end
    ac.debug('acbop error', lastError)
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
