"""
The safety car in limiter mode: a queue behind the leader. The in-game script
caps the queued cars' speed, and acbop only decides who is in the queue,
publishes it, ends the phase once everyone is, and catches any car that is
plainly not being limited.

The sim plays the client script's part: a held car's speed is capped at the
announced limit, unless it is a car deliberately left without the script. And
no car drives through the one in front: it slows to its speed instead, as a
driver would.
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


FOLLOW_M = 25.0  # a car this close behind another goes no faster than it


async def drive(engine, srv, sims, seconds, limited, on_step=None) -> float:
    """Each car runs at its own pace, except that a car in `limited()` never
    exceeds the announced speed cap, which is what the client script does,
    and none drives through the car in front of it."""
    clock = engine_mod.time.time
    start = last = clock()
    lap_start = {c: last - lap_time_fraction(s.spline) * lap_s(s) for c, s in sims.items()}
    quiet: dict[int, float] = {}
    speeds: dict[int, float] = {}
    while clock() - start < seconds:
        await srv.pump(0.06)
        now = clock()
        dt, last = now - last, now
        wanted = {}
        for cid, s in sims.items():
            speed = TRACK_M / (lap_s(s) * corner_shape(s.spline))   # m/s
            cap = limited(cid)
            if cap is not None:
                speed = min(speed, cap / 3.6)
            wanted[cid] = speed
        for cid, s in sims.items():
            speed = wanted[cid]
            others = [(((o.spline - s.spline) % 1.0) * TRACK_M, oc) for oc, o in sims.items() if oc != cid]
            dist, front = min(others)
            if dist < FOLLOW_M:
                speed = min(speed, speeds.get(front, wanted[front]))
            speeds[cid] = speed
        for cid, s in sims.items():
            speed = speeds[cid]
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
        vsc_mode="limiter", vsc_speed_limit_kmh=60.0,
        vsc_queue_gap_s=0.5, vsc_min_gap_s=8.0, vsc_max_duration_s=180.0,
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
    # The in-game script polls /csp/state with its car id, which is how acbop
    # knows it is running. Cars 0-2 have it (Rogue's simply fails to slow the
    # car); the caller's game never checks in.
    for cid in (0, 1, 2):
        code, _ = await asyncio.to_thread(http_get, f"/csp/state?car={cid}")
    flags = {d["car_id"]: d["limiter_script"] for d in engine.state()["drivers"]}
    check(code == 200 and flags == {0: True, 1: True, 2: True, 3: False},
          f"cars whose script polls are seen as running it, the others are not ({flags})")

    # A script that hit an error in the game says so with its poll, and it
    # lands in the events log with the driver's name.
    code, _ = await asyncio.to_thread(
        http_get, "/csp/state?car=1&err=attempt%20to%20call%20nil%0A%1B[x]"
    )
    events = [r["message"] for r in store.recent_events(20)]
    hit = [m for m in events if "limiter script error" in m]
    check(code == 200 and len(hit) == 1 and "attempt to call nil" in hit[0]
          and "\x1b" not in hit[0] and "\n" not in hit[0],
          f"a script error reported by a game is logged, control characters stripped ({hit})")

    # Cars 0, 2 and 3 run the script from here on; "Rogue" (car 1) never does.
    srv.admin_log.clear()
    srv.chat_to_drivers.clear()
    srv.send(p_chat(3, "!vsc"))
    await srv.pump(0.3)
    check(engine.vsc is not None, "phase started in limiter mode")
    check(any("leader is limited to 60 km/h" in m for m in srv.chat_to_drivers),
          "the field is told the leader is limited to 60 km/h")

    code, body = await asyncio.to_thread(http_get, "/csp/state")
    st = json.loads(body)
    vsc = st.get("vsc") or {}
    check(vsc.get("leader") == 0 and vsc.get("held") == [0] and vsc.get("limit_kmh") == 60.0
          and vsc.get("queue") == 1 and vsc.get("field") == 4,
          f"at the call only the leader is held, at 60 km/h ({vsc})")

    def limited(cid):
        held = engine.vsc is not None and engine.drivers[cid].vsc_limited
        return cfg.vsc_speed_limit_kmh if held and cid != 1 else None

    join_order: list[int] = []
    join_gaps: dict[int, float] = {}
    order0 = sorted(sims, key=lambda c: -engine.drivers[c].progress)
    passes: list[str] = []
    touched: list[str] = []
    caller_loaded: list[str] = []
    rogue_restricted_at: list[int] = []

    def step(t):
        if engine.vsc is None:
            return False
        for c in (0, 2, 3):
            engine.csp_checkin(c)  # their scripts keep polling
        for cid in engine.vsc.queue:
            if cid not in join_order:
                join_order.append(cid)
                d = engine.drivers[cid]
                a = engine._ahead_on_track(d, list(engine.drivers.values()))
                join_gaps[cid] = engine._gap_on_track(d, a) if a else 0.0
                if cid == 1:
                    rogue_restricted_at.append(len(srv.admin_log))
        order = sorted(sims, key=lambda c: -engine.drivers[c].progress)
        if order != order0:
            passes.append(str(order))
        if 3 not in engine.vsc.queue and (sims[3].restrictor or sims[3].ballast):
            caller_loaded.append(f"{sims[3].restrictor:.0f}%/{sims[3].ballast:.0f}kg")
        for c in (0, 2):
            if (abs(sims[c].restrictor - base[c][0]) >= 1.0
                    or abs(sims[c].ballast - base[c][1]) >= 2.5):
                touched.append(f"{sims[c].name} {sims[c].restrictor:.0f}%/{sims[c].ballast:.0f}kg")
        return True

    ran = await drive(engine, srv, sims, 175.0, limited, on_step=step)
    print(f"\n  queue formed in {ran:.0f}s: joined {join_order}, at gaps "
          + ", ".join(f"{c}:{g:.2f}s" for c, g in join_gaps.items()))

    check(join_order == [0, 1, 2, 3],
          f"the queue built from the front, each car joining behind the one before ({join_order})")
    check(all(g <= cfg.vsc_queue_gap_s + 0.05 for c, g in join_gaps.items() if c != 0),
          f"each car joined within {cfg.vsc_queue_gap_s}s of the car in front ({join_gaps})")
    check(not passes, "nobody passed anybody" + (f" ({passes[:1]})" if passes else ""))
    check(not caller_loaded, "the caller ran unhandicapped while catching up"
          + (f" ({caller_loaded[:2]})" if caller_loaded else ""))
    check(not touched, "cars obeying the limit never had their restrictor or ballast touched"
          + (f" ({touched[:2]})" if touched else ""))
    check(any("/restrictor 1 100" in c for c in srv.admin_log)
          and any("limiter is not running in your game" in m for m in srv.chat_to_drivers),
          "a car without the script was held with the restrictor as it joined, and told why")
    check(ran < 175.0, f"the phase ended before the time limit ({ran:.0f}s)")

    await srv.pump(0.6)
    check(engine.vsc is None and any("whole field has caught up" in m for m in srv.chat_to_drivers),
          "the phase ended because the whole field was in the queue")
    restored = all(
        abs(sims[c].restrictor - base[c][0]) < 1.0 and abs(sims[c].ballast - base[c][1]) < 2.5
        for c in (0, 1, 2)
    )
    check(restored and not any(d.vsc_limited for d in engine.drivers.values()),
          "every held car released and back on its normal handicap")
    code, body = await asyncio.to_thread(http_get, "/csp/state")
    check(json.loads(body).get("vsc") is None, "/csp/state reports no safety car afterwards")

    # -------------------------------------------- a leader ignoring the cap
    # Its script checks in but it keeps racing: after the grace period it is
    # caught by its speed and held with the restrictor.
    cfg.vsc_min_gap_s = 0.0
    laps = max(d.laps_done for d in engine.drivers.values())
    for cid, sp in {0: 0.95, 1: 0.70, 2: 0.45, 3: 0.28}.items():
        engine.drivers[cid].laps_done = laps
        sims[cid].spline = sp
        srv.send(p_car_update(cid, sp, 60.0))
    await srv.pump(0.3)
    last, leader = 3, 0
    srv.chat_to_drivers.clear()
    check(engine.handle_vsc(last, admin=True) is None, "a second phase can be started by an admin")

    def ignoring(cid):
        held = engine.vsc is not None and engine.drivers[cid].vsc_limited
        return cfg.vsc_speed_limit_kmh if held and cid not in (1, leader) else None

    def step2(t):
        if engine.vsc is None:
            return False
        for c in sims:
            engine.csp_checkin(c)
        return leader not in engine.vsc.fallback

    await drive(engine, srv, sims, 30.0, ignoring, on_step=step2)
    check(engine.vsc is not None and leader in engine.vsc.fallback
          and any("not slowing to 60" in m for m in srv.chat_to_drivers),
          "a leader that ignores the cap is caught and held with the restrictor, and told why")
    engine._end_vsc("test over")

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
