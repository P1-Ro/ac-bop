"""
The in-game limiter script, run under LuaJIT (what CSP uses) with the CSP
functions it calls replaced by recorders. Checks what it does to the throttle
and brakes in each situation, and that it lets go when it should.

Needs the `lupa` package (pip install lupa); skipped without it.
"""

from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "acbop", "csp", "vsc.lua")

try:
    from lupa import luajit21 as lupa
except ImportError:  # pragma: no cover - optional dependency
    try:
        import lupa  # type: ignore
    except ImportError:
        print("SKIP: lupa not installed (pip install lupa)")
        sys.exit(0)

results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((bool(cond), msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


MOCKS = r"""
calls = {}
local function record(name) return function(...) calls[#calls + 1] = { name, ... } end end
car = { speedKmh = 0, gas = 1, brake = 0 }
pending = nil       -- the web callback waiting for a response
ac = {
  getCar = function(i) return car end,
  getDriverName = function(i) return 'Me' end,
  getSim = function() return { windowWidth = 1920, windowHeight = 1080 } end,
  getUI = function() return { uiScale = 1 } end,
  debug = function(k, v) debugged = debugged or {}; debugged[k] = tostring(v) end,
  log = record('log'),
}
web = { get = function(url, cb) requested = url; pending = cb end }
physics = { forceUserThrottleFor = record('throttle'), forceUserBrakesFor = record('brake') }
ui = {
  drawRectFilled = record('rect'),
  dwriteDrawText = record('text'),
  measureDWriteText = function(t, s) return { x = #t * s * 0.5, y = s } end,
}
vec2 = setmetatable({}, { __call = function(_, x, y)
  local mt = {}
  mt.__add = function(a, b) return vec2(a.x + b.x, a.y + b.y) end
  return setmetatable({ x = x, y = y }, mt)
end })
rgbm = function(...) return { ... } end
script = {}
"""


def main() -> int:
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    body = (
        open(SCRIPT).read()
        .replace("__ACBOP_STATE_URL__", "http://acbop.test:8770/csp/state")
        .replace("__ACBOP_CAR_ID__", "2")
    )
    lua.execute(MOCKS)
    g = lua.globals()

    def to_lua(v):
        if isinstance(v, dict):
            return lua.table_from({k: to_lua(x) for k, x in v.items()})
        if isinstance(v, list):
            return lua.table_from([to_lua(x) for x in v])
        return v

    g.JSON = lua.table_from({"parse": lambda s: to_lua(json.loads(s))})
    lua.execute(body)
    update, draw = g.script.update, g.script.drawUI

    def answer(state, status=200):
        cb = g.pending
        g.pending = None
        if cb is not None:
            cb(None, lua.table_from({"status": status, "body": json.dumps(state)}))

    def frame(dt=0.05, speed=None, gas=None, brake=None):
        if speed is not None:
            g.car.speedKmh = speed
        if gas is not None:
            g.car.gas = gas
        if brake is not None:
            g.car.brake = brake
        lua.execute("calls = {}")
        update(dt)
        out = {}
        for i in range(1, len(g.calls) + 1):
            c = g.calls[i]
            out[c[1]] = c[3]
        return out

    held = {"vsc": {"caller": 3, "caller_name": "Last", "held": [0, 1, 2],
                    "limit_kmh": 100, "gap": 14.2, "target_gap": 3}, "cars": []}
    quiet = {"vsc": None, "cars": []}

    frame(speed=180)
    check(g.requested == "http://acbop.test:8770/csp/state?car=2",
          f"polls acbop's state URL, saying which car it runs in ({g.requested})")
    answer(quiet)
    check(frame(speed=180) == {}, "no safety car: the car is never touched")

    # Wait for the next poll and hand it a phase holding this car.
    for _ in range(60):
        frame(speed=180)
        if g.pending is not None:
            break
    answer(held)
    out = frame(speed=180, gas=1)
    check("throttle" in out and out["throttle"] == 0 and "brake" not in out,
          f"at the call the throttle is lifted, with no brake yet ({dict(out)})")

    # Ten seconds on, the cap has closed in to 100 km/h; still doing 130.
    for _ in range(200):
        frame(dt=0.05, speed=130)
        if g.pending is not None:
            answer(held)
    out = frame(speed=130, gas=1, brake=0)
    check(out.get("throttle") == 0 and 0 < out.get("brake", 0) <= 0.35,
          f"30 km/h over the cap: no throttle and a gentle, capped brake ({dict(out)})")

    out = frame(speed=97, gas=1, brake=0)
    check(0 < out.get("throttle", -1) < 1 and "brake" not in out,
          f"just under the cap: throttle partly faded, no brake ({dict(out)})")
    out = frame(speed=97, gas=0.2, brake=0)
    check(out.get("throttle") == 0.2,
          "never adds throttle the driver is not asking for")
    out = frame(speed=97, gas=0, brake=0.8)
    check(out.get("throttle") == 0 and "brake" not in out,
          "a driver braking for a corner is left alone")
    check(frame(speed=80) == {}, "well under the cap: nothing forced")

    lua.execute("calls = {}")
    draw()
    texts = [g.calls[i][2] for i in range(1, len(g.calls) + 1) if g.calls[i][1] == "text"]
    check("VIRTUAL SAFETY CAR" in texts and any("LIMIT 100 KM/H" in t for t in texts),
          f"the banner shows the limit to a held car ({texts})")

    # The caller is never limited, and sees the gap instead.
    caller_state = json.loads(json.dumps(held))
    caller_state["vsc"]["caller"] = 2
    caller_state["vsc"]["held"] = [0, 1]
    for _ in range(40):
        frame(speed=180)
        if g.pending is not None:
            answer(caller_state)
            break
    check(frame(speed=180) == {}, "the caller is never limited")
    lua.execute("calls = {}")
    draw()
    texts = [g.calls[i][2] for i in range(1, len(g.calls) + 1) if g.calls[i][1] == "text"]
    check(any("CATCH UP" in t for t in texts), "the caller's banner tells them to catch up")

    # acbop goes quiet mid-phase: after a few failed polls the car is released.
    for _ in range(40):
        frame(speed=180)
        if g.pending is not None:
            answer(held)
            break
    check("throttle" in frame(speed=180), "held again before the outage")
    for _ in range(400):
        frame(dt=0.05, speed=180)
        if g.pending is not None:
            answer({}, status=503)
    check(frame(speed=180) == {}, "after acbop stops answering, the car is let go")

    # Served without a car id (the URL placeholder was not filled in): the
    # script asks the game for its own server slot instead.
    lua2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(MOCKS)
    lua2.execute("car.sessionID = 5")
    g2 = lua2.globals()
    g2.JSON = lua2.table_from({"parse": lambda s: lua2.table_from({
        "vsc": lua2.table_from({"caller": 7, "held": lua2.table_from([5]), "limit_kmh": 100}),
    }) if json.loads(s) else None})
    lua2.execute(
        open(SCRIPT).read()
        .replace("__ACBOP_STATE_URL__", "http://acbop.test:8770/csp/state")
        .replace("__ACBOP_CAR_ID__", "-1")
    )
    g2.script.update(0.05)
    check(g2.requested == "http://acbop.test:8770/csp/state?car=5",
          f"without a served car id it reports the game's own slot ({g2.requested})")
    g2.pending(None, lua2.table_from({"status": 200, "body": "{\"x\": 1}"}))
    g2.car.speedKmh = 180
    lua2.execute("calls = {}")
    g2.script.update(0.05)
    forced = [g2.calls[i][1] for i in range(1, len(g2.calls) + 1)]
    check("throttle" in forced, f"...and is held when that slot is listed ({forced})")

    # The queue: a car that brakes for the car in front itself is not let
    # back up to its old speed, and the banners speak of the queue.
    lua5 = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua5.execute(MOCKS)
    g5 = lua5.globals()
    queue_state = {"vsc": {"mode": "limiter", "caller": 3, "leader": 0, "held": [0, 2],
                           "limit_kmh": 60, "queue": 2, "field": 4}}
    g5.JSON = lua5.table_from({"parse": lambda s: to_lua5(json.loads(s))})

    def to_lua5(v):
        if isinstance(v, dict):
            return lua5.table_from({k: to_lua5(x) for k, x in v.items()})
        if isinstance(v, list):
            return lua5.table_from([to_lua5(x) for x in v])
        return v

    lua5.execute(
        open(SCRIPT).read()
        .replace("__ACBOP_STATE_URL__", "http://acbop.test:8770/csp/state")
        .replace("__ACBOP_CAR_ID__", "2")
    )

    def frame5(speed, gas=1.0, brake=0.0, dt=0.05):
        g5.car.speedKmh, g5.car.gas, g5.car.brake = speed, gas, brake
        lua5.execute("calls = {}")
        g5.script.update(dt)
        if g5.pending is not None:
            cb, g5.pending = g5.pending, None
            cb(None, lua5.table_from({"status": 200, "body": json.dumps(queue_state)}))
        return {g5.calls[i][1]: g5.calls[i][3] for i in range(1, len(g5.calls) + 1)}

    frame5(200)
    frame5(200)                       # joined the queue at 200 km/h
    for _ in range(20):
        frame5(90, gas=0, brake=0.6)  # the driver brakes for the car in front
    out = frame5(92, gas=1)
    check(out.get("throttle", 1) < 1,
          f"after braking to 90 for the queue, the throttle is cut at once ({dict(out)})")

    def banner5():
        lua5.execute("calls = {}")
        g5.script.drawUI()
        return [g5.calls[i][2] for i in range(1, len(g5.calls) + 1) if g5.calls[i][1] == "text"]

    texts = banner5()
    check(any("LIMIT 60 KM/H" in t and "stay in line" in t for t in texts),
          f"a queued car is told the limit and to stay in line ({texts})")
    queue_state["vsc"]["leader"] = 2
    for _ in range(60):
        frame5(60)
    texts = banner5()
    check(any("YOU LEAD" in t for t in texts), f"the leader is told they lead ({texts})")
    queue_state["vsc"]["held"] = [0]
    queue_state["vsc"]["leader"] = 0
    for _ in range(60):
        frame5(150)
    texts = banner5()
    check(any("CATCH UP TO THE QUEUE - 2/4 in line" in t for t in texts),
          f"a car still catching up is told to, with the count in line ({texts})")
    check(frame5(150) == {}, "...and is not limited")

    # A CSP function throwing must not kill the script: it keeps polling, the
    # error is shown in Lua Debug and reported to acbop once with the next poll.
    lua3 = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua3.execute(MOCKS)
    g3 = lua3.globals()
    g3.JSON = lua3.table_from({"parse": lambda s: lua3.table_from({
        "vsc": lua3.table_from({"caller": 7, "held": lua3.table_from([2]), "limit_kmh": 100}),
    })})
    lua3.execute(
        open(SCRIPT).read()
        .replace("__ACBOP_STATE_URL__", "http://acbop.test:8770/csp/state")
        .replace("__ACBOP_CAR_ID__", "2")
    )
    lua3.execute("physics.forceUserThrottleFor = function() error('not allowed here') end")
    g3.car.speedKmh = 180
    g3.script.update(0.05)
    g3.pending(None, lua3.table_from({"status": 200, "body": "{}"}))
    g3.pending = None
    try:
        g3.script.update(0.05)
        survived = True
    except Exception:  # noqa: BLE001
        survived = False
    check(survived, "an error from a CSP call is caught, not thrown out of script.update")
    check("not allowed here" in str(g3.debugged["acbop error"]),
          f"...shown in the Lua Debug app ({g3.debugged['acbop error']})")
    reported = None
    for _ in range(100):
        g3.script.update(0.05)
        if g3.pending is not None:
            reported = g3.requested
            g3.pending(None, lua3.table_from({"status": 200, "body": "{}"}))
            g3.pending = None
            break
    check(reported is not None and reported.startswith("http://acbop.test:8770/csp/state?car=2&err=")
          and "not%20allowed%20here" in reported,
          f"...and reported to acbop with the next poll ({reported})")
    again = None
    for _ in range(100):
        g3.script.update(0.05)
        if g3.pending is not None:
            again = g3.requested
            break
    check(again == "http://acbop.test:8770/csp/state?car=2",
          f"...only once, not on every poll ({again})")

    # web.get itself throwing must not leave the script waiting forever for
    # a reply that will never come.
    lua4 = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua4.execute(MOCKS)
    g4 = lua4.globals()
    lua4.execute(
        open(SCRIPT).read()
        .replace("__ACBOP_STATE_URL__", "http://acbop.test:8770/csp/state")
        .replace("__ACBOP_CAR_ID__", "2")
    )
    lua4.execute("tries = 0; web.get = function() tries = tries + 1; error('no web') end")
    for _ in range(100):
        g4.script.update(0.05)
    check(g4.tries >= 2, f"a poll that could not be sent is retried ({g4.tries} tries)")

    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
