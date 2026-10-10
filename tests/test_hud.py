"""
The CMRT HUD's acbop integration, under LuaJIT (what CSP uses).

Every Lua file in hud/ and acbop/csp/ must at least parse. Then the HUD's
acbop module runs against stand-ins for the CSP calls it makes: finding acbop
from the server's CSP options, polling /csp/state, the leaderboard text and
safety car roles, the rebindable call button, and dropping stale data.

The leaderboard drawing itself needs the game; this covers the logic behind it.
Needs the `lupa` package (pip install lupa); skipped without it.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "hud" / "assettocorsa" / "apps" / "lua" / "CMRT-Essential-HUD" / "common" / "acbop.lua"

try:
    from lupa import luajit21 as lupa
except ImportError:  # pragma: no cover - optional dependency
    print("SKIP: lupa not installed (pip install lupa)")
    sys.exit(0)

results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((bool(cond), msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


MOCKS = r"""
Time = 0
chat = {}
names = { [0] = 'Me', [1] = 'Alice', [2] = 'Bob', [3] = 'Nobody' }
extras = { sections = { SCRIPT_1 = {}, WEATHER = {} } }
function extras:get(sec, key, def)
  if sec == 'SCRIPT_1' and key == 'SCRIPT' then
    return "'http://bop.example:8770/csp/vsc.lua?car={SessionID}'"
  end
  return def
end
ac = {
  getSim = function() return { isOnlineRace = true } end,
  getDriverName = function(i) return names[i] end,
  INIConfig = { onlineExtras = function() return extras end },
  ControlButton = function(id)
    buttonId = id
    return { pressed = function() return pressedNow end, control = function() end }
  end,
  sendChatMessage = function(m) chat[#chat + 1] = m end,
  setMessage = function() end,
}
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
web = { get = function(url, cb) requested = url; pending = cb end }
"""


def syntax() -> None:
    rt = lupa.LuaRuntime()
    compile_ = rt.eval("function(src, name) local f, err = loadstring(src, '@' .. name); return err end")
    files = sorted((ROOT / "hud").rglob("*.lua")) + sorted((ROOT / "acbop" / "csp").rglob("*.lua"))
    bad = [(f, err) for f in files if (err := compile_(f.read_text(encoding="utf-8"), f.name))]
    for f, err in bad:
        print(f"  {f.relative_to(ROOT)}: {err}")
    check(files and not bad, f"all {len(files)} Lua files parse under LuaJIT")


def module() -> None:
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCKS)
    g = lua.globals()

    def to_lua(v):
        if isinstance(v, dict):
            return lua.table_from({k: to_lua(x) for k, x in v.items()})
        if isinstance(v, list):
            return lua.table_from([to_lua(x) for x in v])
        return v

    g.JSON = lua.table_from({"parse": lambda s: to_lua(json.loads(s))})
    m = lua.execute(MODULE.read_text(encoding="utf-8"))

    m.init()
    m.update()
    check(g.buttonId == "CMRT-Essential-HUD/Call virtual safety car",
          "registers a rebindable control for calling a safety car")
    check(g.requested == "http://bop.example:8770/csp/state",
          "finds acbop from the server's [SCRIPT_...] line and polls its state")

    g.pending(None, lua.table_from({"status": 200, "body": json.dumps({
        "cmd": "!sc",
        "vsc": {"caller": 7, "held": [5], "limit_kmh": 100},
        "cars": [{"id": 5, "name": "Alice", "r": 12.4, "b": 45},
                 {"id": 7, "name": "Bob", "r": 0, "b": 0}],
    })}))
    g.pending = None
    check(m.bop_text(1) == "45kg 12%", "leaderboard text: ballast and restrictor, rounded")
    check(m.bop_text(3) is None, "nothing shown for a driver acbop does not know")
    check(m.vsc_role(1) == "held" and m.vsc_role(2) == "caller" and m.vsc_role(0) is None,
          "safety car roles: held, caller, and nobody else")

    g.pressedNow = True
    g.Time = 10
    m.update()
    g.Time = 11
    m.update()
    check(list(g.chat.values()) == ["!sc"],
          "the button sends the server's own command, once per cooldown")

    g.pressedNow = False
    g.Acbop_Url = "http://manual:9000/"
    g.Time = 25    # past the timeout on the poll left unanswered above
    g.pending = None
    m.update()
    check(g.requested == "http://manual:9000/csp/state",
          "an address typed in settings overrides the detected one")

    for _ in range(6):
        g.Time += 3
        m.update()
        if g.pending is not None:
            g.pending("timeout", None)
            g.pending = None
    check(m.get_vsc() is None and m.bop_text(1) is None,
          "after repeated failures the data is dropped, not left stale on screen")


def main() -> int:
    syntax()
    module()
    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
