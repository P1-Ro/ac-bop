-- Stand-ins for the CSP API, loose enough to run the acbop HUD headless in
-- tests/test_hud.py: a three-car race, with every drawing call a no-op.
errors = {}
local function loose(t, default)
  return setmetatable(t, { __index = function() return default end })
end
local V = {}
V.__index = V
function vec2(x, y) return setmetatable({ x = x or 0, y = y or x or 0 }, V) end
local function v(a) if type(a) == 'number' then return vec2(a, a) end return a end
V.__add = function(a, b) a, b = v(a), v(b) return vec2(a.x + b.x, a.y + b.y) end
V.__sub = function(a, b) a, b = v(a), v(b) return vec2(a.x - b.x, a.y - b.y) end
V.__mul = function(a, b) a, b = v(a), v(b) return vec2(a.x * b.x, a.y * b.y) end
V.__div = function(a, b) a, b = v(a), v(b) return vec2(a.x / b.x, a.y / b.y) end
V.__unm = function(a) return vec2(-a.x, -a.y) end
function V:clone() return vec2(self.x, self.y) end
function V:length() return math.sqrt(self.x * self.x + self.y * self.y) end
function vec3(x, y, z) return { x = x, y = y, z = z, rotate = function(s) return s end } end
function quat() return { setAngleAxis = function(s) return s end } end
function rgbm(r, g, b, m) return { r = r, g = g, b = b, mult = m } end

table.new = function() return {} end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
table.nkeys = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
math.sign = function(x) return x > 0 and 1 or (x < 0 and -1 or 0) end
math.round = function(x) return math.floor(x + 0.5) end
math.lerp = function(a, b, t) return a + (b - a) * t end
function string.split(s, sep) local out = {} for p in s:gmatch('[^' .. sep .. ']+') do out[#out + 1] = p end return out end

local enum = function() return setmetatable({}, { __index = function(t, k) return k end }) end
ui = setmetatable({
  CornerFlags = enum(), MouseButton = enum(), TabBarFlags = enum(), StyleColor = enum(), MouseCursor = enum(),
  measureDWriteText = function(t, size) return vec2(#tostring(t) * (size or 10) * 0.5, size or 10) end,
  windowSize = function() return vec2(700, 400) end,
  windowPos = function() return vec2(50, 50) end,
  mouseLocalPos = function() return vec2(-1000, -1000) end,
  mouseDown = function() return false end, mouseClicked = function() return false end,
  checkbox = function() return false end, button = function() return false end, radioButton = function() return false end,
  slider = function(label, value) return value, false end,
  inputText = function(label, value) return value, false end,
  tabBar = function(name, flags, fn) fn() end, tabItem = function(name, fn) fn() end,
  DWriteFont = function() return {} end,
  getCursor = function() return vec2(0, 0) end, getScrollY = function() return 0 end,
}, { __index = function() return function() return vec2(10, 10) end end })

SessionType = { Practice = 1, Qualify = 2, Race = 3, Hotlap = 4, TimeAttack = 5, Drift = 6, Drag = 7 }
local function car(i)
  return loose({ index = i, isConnected = true, splinePosition = 0.1 + i * 0.2, speedMs = 50, speedKmh = 180,
    lapTimeMs = 12000, lapCount = 2, currentSector = 0, isLastLapValid = true, position = vec3(i * 30, 0, i * 5),
    currentSplits = { [0] = 30000 }, lastSplits = { [0] = 30000 }, bestSplits = { [0] = 29000, [1] = 30000, [2] = 31000 }, bestLapTimeMs = 90000 + i * 500,
    previousLapTimeMs = 91000, isInPitlane = false, isRetired = false, isRaceFinished = false, wheelsOutside = 0 }, 0)
end
cars = { [0] = car(0), [1] = car(1), [2] = car(2) }
local board = { [0] = { car = cars[2], bestLapTimeMs = 90000 }, [1] = { car = cars[1], bestLapTimeMs = 90500 }, [2] = { car = cars[0], bestLapTimeMs = 91000 } }
session = loose({ type = SessionType.Race, laps = 20, isTimedRace = false, hasAdditionalLap = false, leaderboard = board }, 0)
sim = loose({ isOnlineRace = true, isLive = true, isPaused = false, currentSessionTime = 1000, currentSessionIndex = 0,
  raceSessionType = SessionType.Race, raceFlagType = 0, sessionTimeLeft = 600000, ambientTemperature = 22, roadTemperature = 30,
  windowWidth = 1920, windowHeight = 1080, trackLengthM = 5000, lapSplits = { [0] = 0.0, [1] = 0.33, [2] = 0.66 }, carsCount = 3, timestamp = 0 }, 0)
names = { [0] = 'Me', [1] = 'Alice', [2] = 'Bob' }
chat = {}
ac = {
  SessionType = SessionType, FlagType = { None = 0, Caution = 1, Stop = 2, ReturnToPits = 3, FasterCar = 4, OneLapLeft = 5, Finished = 6 },
  getSim = function() return sim end, getSession = function() return session end, getCar = function(i) return cars[i] end,
  getUI = function() return { uiScale = 1 } end,
  iterateCars = { leaderboard = function() local i = -1 return function() i = i + 1 if board[i] then return i, board[i].car end end end },
  getDriverName = function(i) return names[i] end, getCarName = function(i) return 'mx5' end, getTyresName = function() return 'SM' end,
  getTrackName = function() return 'Mugello' end,
  storage = function(layout, default)
    if type(layout) == 'table' then local t = {} for k, val in pairs(layout) do t[k] = val end return t end
    local value = default
    return { get = function() return value end, set = function(_, x) value = x end }
  end,
  getAppWindows = function() return {} end, accessAppWindow = function() return nil end,
  onSessionStart = function() end,
  debug = function(k, msg) if tostring(k):find('^ERROR') then errors[#errors + 1] = tostring(msg) end end,
  ControlButton = function() return { pressed = function() return false end, control = function() end } end,
  sendChatMessage = function(m) chat[#chat + 1] = m end, setMessage = function() end,
  INIConfig = { onlineExtras = function() return nil end },
}
web = { get = function(url, cb) pending = cb end }
script = {}
