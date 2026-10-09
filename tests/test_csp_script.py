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
    check(g.requested == "http://acbop.test:8770/csp/state", "polls acbop's state URL")
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

    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
