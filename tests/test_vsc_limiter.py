"""
The safety car in limiter mode: the in-game script caps held cars' speed, and
acbop only decides who is held, publishes it, and catches any car that is
plainly not being limited.

The sim plays the client script's part: a held car's speed is capped at the
announced limit, unless it is the one car deliberately left without the
script, which keeps racing until acbop falls back to the restrictor.
"""

from __future__ import annotations

import asyncio
import json
import math
import os
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import simserver
from acbop import engine as engine_mod
from acbop.config import Config
from acbop.db import Store
from acbop.engine import Engine
from acbop.model import recompute_all
from acbop.web import build_app
from aiohttp import web
from simserver import SimDriver, SimServer, p_car_update, p_chat, p_lap_completed
from test_safetycar import BASE_MS, _WarpedTime, corner_shape, lap_time_fraction, true_loss

TRACK_M = 5200.0
results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((bool(cond), msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


def lap_s(s: SimDriver) -> float:
    return BASE_MS / 1000.0 * math.exp(s.skill) * (1.0 + true_loss(s))


async def drive(engine, srv, sims, seconds, limited, on_step=None) -> float:
    """Each car runs at its own pace, except that a car in `limited()` never
    exceeds the announced speed cap, which is what the client script does."""
    clock = engine_mod.time.time
    start = last = clock()
    lap_start = {c: last - lap_time_fraction(s.spline) * lap_s(s) for c, s in sims.items()}
    quiet: dict[int, float] = {}
    while clock() - start < seconds:
        await srv.pump(0.06)
        now = clock()
        dt, last = now - last, now
        for cid, s in sims.items():
            free_ms = TRACK_M / (lap_s(s) * corner_shape(s.spline))   # m/s
            speed = free_ms
            cap = limited(cid)
            if cap is not None:
                speed = min(speed, cap / 3.6)
            s.spline += speed * dt / TRACK_M
            if s.spline >= 1.0:
                s.spline -= 1.0
                srv.send(p_lap_completed(cid, int((now - lap_start[cid]) * 1000), 0, []))
                lap_start[cid] = now
                quiet[cid] = now + 1.0
            elif now >= quiet.get(cid, 0.0):
                srv.send(p_car_update(cid, s.spline, speed * 3.6))
        if on_step is not None and on_step(now - start) is False:
            break
    return clock() - start


async def main() -> int:
    engine_mod.time = _WarpedTime
    tmp = tempfile.mkdtemp()
    cfg = Config(
        listen_host="127.0.0.1", listen_port=12471,
        server_host="127.0.0.1", server_port=12472,
        db_path=os.path.join(tmp, "lim.sqlite"),
        announce_handicaps=False, min_laps_for_rating=3,
        vsc_mode="limiter", vsc_speed_limit_kmh=100.0,
        vsc_target_gap_s=3.0, vsc_min_gap_s=8.0, vsc_max_duration_s=180.0,
        vsc_tick_s=0.2, vsc_limiter_grace_s=10.0,
        web_password="secret",
    )
    store = Store(cfg.db_path)
    engine = Engine(cfg, store)
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: engine, local_addr=(cfg.listen_host, cfg.listen_port)
    )
    bg = asyncio.create_task(engine.run_background())

    runner = web.AppRunner(build_app(cfg, store, engine, os.path.join(tmp, "cfg.json")))
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 12473)
    await site.start()
    base_url = "http://127.0.0.1:12473"

    def http_get(path: str) -> tuple[int, str]:
        try:
            with urllib.request.urlopen(base_url + path, timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, ""

    sims = {
        0: SimDriver(0, "Leader", "76561198000002001", "ks_mazda_mx5_cup", -0.02),
        1: SimDriver(1, "Rogue",  "76561198000002002", "ks_mazda_mx5_cup", -0.01),
        2: SimDriver(2, "Third",  "76561198000002003", "ks_mazda_mx5_cup", 0.00),
        3: SimDriver(3, "Last",   "76561198000002004", "ks_mazda_mx5_cup", 0.02),
    }
    srv = SimServer((cfg.listen_host, cfg.listen_port), cfg.server_port, list(sims.values()))
    await srv.run_session("mugello", BASE_MS, n_laps=5, cuts_rate=0.0, declared_laps=60)
    await srv.end_session()
    recompute_all(store, cfg)
    await srv.run_session("mugello", BASE_MS, n_laps=4, cuts_rate=0.0, declared_laps=60)
    await srv.pump(0.3)
    for cid, sp in {0: 0.95, 1: 0.70, 2: 0.45, 3: 0.28}.items():
        engine.drivers[cid].laps_done = 3
        sims[cid].spline = sp
        srv.send(p_car_update(cid, sp, 180.0))
    await srv.pump(0.3)
    await drive(engine, srv, sims, BASE_MS / 1000.0 * 2.1, lambda c: None)

    # ------------------------------------------------------ public endpoints
    code, _ = await asyncio.to_thread(http_get, "/api/state")
    check(code == 401, f"the admin API still needs the password ({code})")
    code, body = await asyncio.to_thread(http_get, "/csp/vsc.lua?car=2")
    check(code == 200 and "http://127.0.0.1:12473/csp/state" in body
          and "local MY_CAR_ID = 2 " in body,
          "the in-game script is served without a password, with this server's "
          "address and the car's slot filled in")
    code, body = await asyncio.to_thread(http_get, "/csp/vsc.lua?car=../../x")
    check(code == 200 and "local MY_CAR_ID = -1 " in body,
          "a malformed car parameter falls back to finding the car by name")
    code, body = await asyncio.to_thread(http_get, "/csp/state")
    st = json.loads(body) if code == 200 else {}
    check(code == 200 and st.get("vsc") is None and len(st.get("cars", [])) == 4
          and all({"id", "name", "r", "b"} <= set(c) for c in st["cars"]),
          "public state lists every car's restrictor and ballast, no safety car yet")

    # ------------------------------------------------------------- the call
    base = {c: (engine.drivers[c].base_restrictor, engine.drivers[c].base_ballast) for c in sims}
    srv.admin_log.clear()
    srv.chat_to_drivers.clear()
    srv.send(p_chat(3, "!vsc"))
    await srv.pump(0.3)
    check(engine.vsc is not None, "phase started in limiter mode")
    check(any("limited to 100 km/h" in m for m in srv.chat_to_drivers),
          "the field is told the speed limit")

    code, body = await asyncio.to_thread(http_get, "/csp/state")
    st = json.loads(body)
    vsc = st.get("vsc") or {}
    check(vsc.get("caller") == 3 and vsc.get("held") == [0, 1, 2] and vsc.get("limit_kmh") == 100.0,
          f"/csp/state names the caller and holds every car ahead at 100 km/h ({vsc})")

    # "Rogue" has no client script: it keeps racing. Everyone else obeys.
    def limited(cid):
        held = engine.vsc is not None and engine.drivers[cid].vsc_limited
        return cfg.vsc_speed_limit_kmh if held and cid != 1 else None

    gaps = [engine.gap_ahead_seconds(engine.drivers[3])]
    touched: list[str] = []
    caller_loaded: list[str] = []

    def step(t):
        if engine.vsc is None:
            return False
        g = engine.gap_ahead_seconds(engine.drivers[3])
        if g is not None:
            gaps.append(g)
        if sims[3].restrictor or sims[3].ballast:
            caller_loaded.append(f"{sims[3].restrictor:.0f}%/{sims[3].ballast:.0f}kg")
        for c in (0, 2):
            if (abs(sims[c].restrictor - base[c][0]) >= 1.0
                    or abs(sims[c].ballast - base[c][1]) >= 2.5):
                touched.append(f"{sims[c].name} {sims[c].restrictor:.0f}%/{sims[c].ballast:.0f}kg")
        return True

    ran = await drive(engine, srv, sims, 170.0, limited, on_step=step)
    print(f"\n  gap {gaps[0]:.1f}s -> {gaps[-1]:.1f}s in {ran:.0f}s of running")

    check(not caller_loaded, "the caller ran unhandicapped throughout"
          + (f" ({caller_loaded[:2]})" if caller_loaded else ""))
    check(not touched, "cars obeying the limit never had their restrictor or ballast touched"
          + (f" ({touched[:2]})" if touched else ""))
    check(sims[1].restrictor >= 99.0 or any("/restrictor 1 100" in c for c in srv.admin_log),
          "a car that ignored the limit was caught and held with the restrictor instead")
    check(any("not slowing" in m for m in srv.chat_to_drivers),
          "...and was told why")
    check(gaps[-1] <= cfg.vsc_target_gap_s + 0.5 and ran < 120,
          f"the caller caught the pack ({gaps[0]:.1f}s -> {gaps[-1]:.1f}s in {ran:.0f}s)")

    await srv.pump(0.6)
    check(engine.vsc is None and any("has closed" in m for m in srv.chat_to_drivers),
          "the phase ended because the gap closed")
    restored = all(
        abs(sims[c].restrictor - base[c][0]) < 1.0 and abs(sims[c].ballast - base[c][1]) < 2.5
        for c in (0, 1, 2)
    )
    check(restored and not any(d.vsc_limited for d in engine.drivers.values()),
          "every held car released and back on its normal handicap")
    code, body = await asyncio.to_thread(http_get, "/csp/state")
    check(json.loads(body).get("vsc") is None, "/csp/state reports no safety car afterwards")

    bg.cancel()
    transport.close()
    await runner.cleanup()
    store.close()

    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
