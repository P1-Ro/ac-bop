"""
The safety car as a live field-compression phase.

The point of the redesign: calling it must actually bring the caller back to
the pack, by slowing the cars ahead in proportion to their gap. So the headline
check simulates real running through a phase and asserts the gap shrinks.
"""

from __future__ import annotations

import asyncio
import math
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import simserver
from acbop.config import Config
from acbop.db import Store
from acbop.engine import Engine
from acbop.model import recompute_all
from simserver import SimDriver, SimServer, p_car_update, p_chat, p_lap_completed

BASE_MS = 95_000.0
results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((bool(cond), msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


async def build(cfg_over: dict | None = None, port_base: int = 12451):
    tmp = tempfile.mkdtemp()
    cfg = Config(
        listen_host="127.0.0.1", listen_port=port_base,
        server_host="127.0.0.1", server_port=port_base + 1,
        db_path=os.path.join(tmp, "sc.sqlite"),
        announce_handicaps=False,
        min_laps_for_rating=3,
        floor_restrictor=6.0, floor_ballast=25.0,
        vsc_max_duration_s=120.0,
        vsc_target_gap_s=3.0,
        vsc_min_gap_s=8.0,
        vsc_ramp_s=0.5,
        vsc_tick_s=0.25,
        vsc_max_slowdown=0.60,
        deadband_restrictor=0.5, deadband_ballast=2.0,
        **(cfg_over or {}),
    )
    store = Store(cfg.db_path)
    engine = Engine(cfg, store)
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: engine, local_addr=(cfg.listen_host, cfg.listen_port)
    )
    bg = asyncio.create_task(engine.run_background())
    return cfg, store, engine, transport, bg


async def main() -> int:
    # ---------------------------------------------------------------- setup
    cfg, store, engine, transport, bg = await build()
    sims = [
        SimDriver(0, "Leader", "76561198000000001", "ks_mazda_mx5_cup", -0.02),
        SimDriver(1, "Second", "76561198000000002", "ks_mazda_mx5_cup", -0.01),
        SimDriver(2, "Third",  "76561198000000003", "ks_mazda_mx5_cup", 0.00),
        SimDriver(3, "Last",   "76561198000000004", "ks_mazda_mx5_cup", 0.02),
    ]
    srv = SimServer((cfg.listen_host, cfg.listen_port), cfg.server_port, sims)

    await srv.run_session("mugello", BASE_MS, n_laps=5, cuts_rate=0.0, declared_laps=60)
    await srv.end_session()
    recompute_all(store, cfg)
    await srv.run_session("mugello", BASE_MS, n_laps=4, cuts_rate=0.0, declared_laps=60)
    await srv.pump(0.3)

    # Spread the field: leader well clear, "Last" 20s back of Third.
    # 20s at a 95s lap is 0.21 of a lap.
    layout = {0: 0.95, 1: 0.70, 2: 0.45, 3: 0.24}
    for cid, sp in layout.items():
        engine.drivers[cid].laps_done = 3
        srv.send(p_car_update(cid, sp, 180.0))
    await srv.pump(0.4)

    last = engine.drivers[3]
    gap0 = engine.gap_ahead_seconds(last)
    check(gap0 is not None and gap0 > cfg.vsc_min_gap_s,
          f"field is spread before the call (gap ahead {gap0:.1f}s)")

    base = {d.car_id: (d.base_restrictor, d.base_ballast) for d in engine.drivers.values()}

    # ------------------------------------------------- the phase itself
    srv.chat_to_drivers.clear()
    srv.send(p_chat(3, "!vsc"))
    await srv.pump(0.6)

    check(engine.vsc is not None, "phase started")
    check(any("SAFETY CAR" in m for m in srv.chat_to_drivers), "field was told")

    # The caller must be unhandicapped...
    check(sims[3].ballast == 0 and sims[3].restrictor == 0,
          f"caller unhandicapped ({sims[3].ballast:.0f}kg/{sims[3].restrictor:.0f}%)")

    # ...and everyone ahead must be slowed BEYOND their normal handicap.
    slowed = [
        (d.name, sims[d.car_id].ballast - base[d.car_id][1])
        for d in engine.drivers.values() if d.car_id != 3
    ]
    check(all(extra > 0 for _, extra in slowed),
          "every car ahead is slowed beyond its normal handicap: "
          + ", ".join(f"{n} +{e:.0f}kg" for n, e in slowed))

    # In the default mode every car at or beyond the gap the caller must close
    # is held as hard as allowed, which gives the fastest possible closure.
    extra_by_pos = [sims[c].ballast - base[c][1] for c in (0, 1, 2)]
    check(min(extra_by_pos) > 0 and max(extra_by_pos) - min(extra_by_pos) < 50,
          f"all cars ahead held at full strength for maximum closure "
          f"(leader +{extra_by_pos[0]:.0f}kg, 2nd +{extra_by_pos[1]:.0f}kg, "
          f"3rd +{extra_by_pos[2]:.0f}kg)")

    eta = engine.vsc_closure_eta(last)
    check(eta is not None and 20 < eta < 120,
          f"closure ETA is physically sane ({eta:.0f}s for a {gap0:.0f}s gap)")

    # ------------------------------- does the gap ACTUALLY close? ---------
    # Simulate 12 seconds of running: each car advances at a speed set by the
    # handicap it is carrying right now, exactly as the real cars would.
    print("\n  simulating running under the phase:")
    print(f"  {'t':>5} {'gap':>7}   penalties (extra kg)")
    gaps = [gap0]
    t = 0.0
    step = 0.5
    while t < 70.0 and engine.vsc is not None:
        for d in engine.drivers.values():
            s = sims[d.car_id]
            # fractional pace loss from whatever is currently applied
            kr, kb = simserver.true_k("mugello")
            loss = kr * s.restrictor + kb * (s.ballast / 10.0)
            speed = 1.0 / (math.exp(s.skill) * (1.0 + loss))
            d.spline += step / (BASE_MS / 1000.0) * speed
            while d.spline >= 1.0:
                d.spline -= 1.0
                # a real server would report the completed lap
                srv.send(p_lap_completed(d.car_id, int(BASE_MS), 0, []))
            srv.send(p_car_update(d.car_id, d.spline, 170.0))
        await srv.pump(step)
        g = engine.gap_ahead_seconds(last)
        if g is not None:
            gaps.append(g)
            if round(t * 2) % 16 == 0:
                pen = " ".join(
                    f"{sims[c].ballast - base[c][1]:+.0f}" for c in (0, 1, 2)
                )
                print(f"  {t:5.1f} {g:6.1f}s   {pen}")
        t += step

    print(f"\n  gap {gaps[0]:.1f}s -> {gaps[-1]:.1f}s in {t:.0f}s of running")
    check(gaps[-1] <= cfg.vsc_target_gap_s + 0.5,
          f"the caller actually caught the pack ({gaps[0]:.1f}s -> {gaps[-1]:.1f}s, "
          f"target {cfg.vsc_target_gap_s:.0f}s)")
    check(all(gaps[i + 1] <= gaps[i] + 0.4 for i in range(len(gaps) - 1)),
          "gap closed monotonically (no oscillation)")

    # ----------------------------------------- end and restore -----------
    deadline = time.time() + 10
    while engine.vsc is not None and time.time() < deadline:
        await srv.pump(0.3)
    check(engine.vsc is None, "phase ended once the gap had closed")

    await srv.pump(0.6)
    restored = all(
        abs(sims[c].ballast - base[c][1]) < 2.5
        and abs(sims[c].restrictor - base[c][0]) < 1.0
        for c in (0, 1, 2, 3)
    )
    check(restored, "every driver's normal handicap restored afterwards")
    check(any("ENDING" in m for m in srv.chat_to_drivers), "end was announced")

    # Laps during the phase must never reach the model.
    bad = store.q1(
        "SELECT COUNT(*) c FROM laps WHERE clean=1 AND reason IS NOT NULL"
    )["c"]
    check(bad == 0, "no lap is both counted and flagged")
    sc = store.q1("SELECT COUNT(*) c FROM laps WHERE reason='safety car'")["c"]
    check(sc > 0, f"laps run under the phase were excluded ({sc} of them)")

    # Second call in the same race refused.
    srv.chat_to_drivers.clear()
    srv.send(p_chat(3, "!vsc"))
    await srv.pump(0.4)
    check(any("already used" in m for m in srv.chat_to_drivers),
          "a second call in the same race is refused")

    # Leader cannot call one.
    srv.chat_to_drivers.clear()
    srv.send(p_chat(0, "!vsc"))
    await srv.pump(0.4)
    check(any("leading" in m for m in srv.chat_to_drivers), "the leader is refused")

    bg.cancel()
    transport.close()
    store.close()

    # ------------------------------------------- whole-field variant -----
    print("\n  whole-field mode (keeps order behind the caller intact):")
    cfg2, store2, engine2, transport2, bg2 = await build({"vsc_slow_whole_field": True}, port_base=12461)
    sims2 = [
        SimDriver(0, "P1", "76561198000001001", "ks_mazda_mx5_cup", -0.02),
        SimDriver(1, "P2", "76561198000001002", "ks_mazda_mx5_cup", 0.00),
        SimDriver(2, "P3", "76561198000001003", "ks_mazda_mx5_cup", 0.02),
    ]
    srv2 = SimServer((cfg2.listen_host, cfg2.listen_port), cfg2.server_port, sims2)
    await srv2.run_session("mugello", BASE_MS, n_laps=5, cuts_rate=0.0, declared_laps=60)
    await srv2.end_session()
    recompute_all(store2, cfg2)
    await srv2.run_session("mugello", BASE_MS, n_laps=3, cuts_rate=0.0, declared_laps=60)
    await srv2.pump(0.3)

    # caller is P2 (middle), so P3 is behind them
    for cid, sp in ((0, 0.95), (1, 0.60), (2, 0.40)):
        engine2.drivers[cid].laps_done = 2
        srv2.send(p_car_update(cid, sp, 180.0))
    await srv2.pump(0.4)

    base2 = {d.car_id: d.base_ballast for d in engine2.drivers.values()}
    srv2.send(p_chat(1, "!vsc"))
    await srv2.pump(0.8)
    behind_extra = sims2[2].ballast - base2[2]
    check(engine2.vsc is not None and behind_extra > 0,
          f"with vsc_slow_whole_field the car behind is slowed too (+{behind_extra:.0f}kg)")

    bg2.cancel()
    transport2.close()
    store2.close()

    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
