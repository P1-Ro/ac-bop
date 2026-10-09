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
from acbop import engine as engine_mod
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
        vsc_max_duration_s=180.0,
        vsc_target_gap_s=3.0,
        vsc_min_gap_s=8.0,
        vsc_ramp_s=2.0,
        vsc_tick_s=0.2,
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


# The engine's clock runs WARP times faster than the wall clock, so a lap and a
# half of live running takes seconds rather than minutes. Everything the
# limiter measures is on the engine's clock, so the physics stays consistent.
WARP = 5.0
_t0 = time.time()


class _WarpedTime:
    @staticmethod
    def time() -> float:
        return _t0 + (time.time() - _t0) * WARP


def true_loss(s: SimDriver) -> float:
    """Fractional pace loss from what the car carries. The restrictor bites
    less than linearly at high values, as a real one does, so the model's
    linear estimate under-delivers and the live correction has to make it up."""
    kr, kb = simserver.true_k("mugello")
    return kr * s.restrictor / (1.0 + s.restrictor / 1000.0) + kb * (s.ballast / 10.0)


def corner_shape(spline: float) -> float:
    """Share of lap time spent per unit of track: slow corners, fast straights.
    Integrates to 1 over a lap, so lap time is unaffected."""
    return 1.0 + 0.4 * math.sin(2 * math.pi * spline)


def lap_time_fraction(spline: float) -> float:
    """Share of the lap's time already spent at this point: corner_shape integrated."""
    return spline + 0.4 * (1 - math.cos(2 * math.pi * spline)) / (2 * math.pi)


async def drive(engine, srv, sims, seconds: float, on_step=None) -> float:
    """Run every car at the speed its current penalty allows, on the engine's
    clock, reporting positions and lap completions as a real server would."""
    clock = engine_mod.time.time
    start = last = clock()
    # Back-date each car's lap start to where it already is on the lap, so the
    # first lap it completes is reported at a realistic time.
    lap_start = {
        d.car_id: last - lap_time_fraction(sims[d.car_id].spline) * BASE_MS / 1000.0
        * math.exp(sims[d.car_id].skill) * (1.0 + true_loss(sims[d.car_id]))
        for d in engine.drivers.values()
    }
    while clock() - start < seconds:
        await srv.pump(0.06)
        now = clock()
        dt = now - last
        last = now
        for d in list(engine.drivers.values()):
            s = sims[d.car_id]
            lap_s = BASE_MS / 1000.0 * math.exp(s.skill) * (1.0 + true_loss(s))
            s.spline += dt / (lap_s * corner_shape(s.spline))
            if s.spline >= 1.0:
                s.spline -= 1.0
                srv.send(p_car_update(d.car_id, s.spline, 170.0))
                s.laps += 1
                srv.send(p_lap_completed(d.car_id, int((now - lap_start[d.car_id]) * 1000), 0, []))
                lap_start[d.car_id] = now
            else:
                srv.send(p_car_update(d.car_id, s.spline, 170.0))
        if on_step is not None and on_step(now - start) is False:
            break
    return clock() - start


async def main() -> int:
    engine_mod.time = _WarpedTime
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

    # Spread the field: leader well clear, "Last" ~12s back of Third, then
    # race a lap and a half so everyone has a live lap profile.
    layout = {0: 0.95, 1: 0.70, 2: 0.45, 3: 0.32}
    for cid, sp in layout.items():
        engine.drivers[cid].laps_done = 3
        sims[cid].spline = sp
        srv.send(p_car_update(cid, sp, 180.0))
    await srv.pump(0.3)
    await drive(engine, srv, sims, BASE_MS / 1000.0 * 2.1)

    missing = [d.name for d in engine.drivers.values() if not d.pace_profile]
    check(not missing, "every driver has a live lap profile before the call"
          + (f" (missing: {', '.join(missing)})" if missing else ""))

    last = engine.drivers[3]
    gap0 = engine.gap_ahead_seconds(last)
    check(gap0 is not None and gap0 > cfg.vsc_min_gap_s,
          f"field is spread before the call (gap ahead {gap0:.1f}s)")

    base = {d.car_id: (d.base_restrictor, d.base_ballast) for d in engine.drivers.values()}

    # ------------------------------------------------- the phase itself
    srv.chat_to_drivers.clear()
    srv.admin_log.clear()
    srv.send(p_chat(3, "!vsc"))
    await srv.pump(0.3)

    check(engine.vsc is not None, "phase started")
    check(any("SAFETY CAR" in m for m in srv.chat_to_drivers), "field was told")

    # The caller must be unhandicapped...
    check(sims[3].ballast == 0 and sims[3].restrictor == 0,
          f"caller unhandicapped ({sims[3].ballast:.0f}kg/{sims[3].restrictor:.0f}%)")
    eta = engine.vsc_closure_eta(last)

    # ------------------------------- does the gap ACTUALLY close? ---------
    print("\n  simulating running under the phase:")
    print(f"  {'t':>5} {'gap':>7}   total restrictor (measured slowdown)")
    gaps = [gap0]
    ballast_touched = []
    pace_err: dict[int, list[float]] = {c: [] for c in (0, 1, 2)}
    shown = [-99.0]
    over_cap: list[int] = []
    peak_r = {c: 0.0 for c in (0, 1, 2)}

    def step(t: float):
        if engine.vsc is None:
            return False
        for c in (0, 1, 2):
            if abs(sims[c].ballast - base[c][1]) > 0.5:
                ballast_touched.append((c, sims[c].ballast))
            over_cap.extend([c] if engine.drivers[c].restrictor > 100.0 else [])
            peak_r[c] = max(peak_r[c], sims[c].restrictor)
            d = engine.drivers[c]
            if t > 25.0 and d.vsc_target_ms:
                s = sims[c]
                true_lap = BASE_MS * math.exp(s.skill) * (1.0 + true_loss(s))
                pace_err[c].append(true_lap / d.vsc_target_ms - 1.0)
        g = engine.gap_ahead_seconds(last)
        if g is not None:
            gaps.append(g)
            if t - shown[0] >= 12.0:
                shown[0] = t
                held = " ".join(
                    f"{sims[c].restrictor:4.0f}%"
                    f"({(engine.drivers[c].vsc_measured_slow or 0) * 100:+.0f}%)"
                    for c in (0, 1, 2)
                )
                print(f"  {t:5.1f} {g:6.1f}s   {held}")
        return True

    ran = await drive(engine, srv, sims, 170.0, on_step=step)

    print(f"\n  gap {gaps[0]:.1f}s -> {gaps[-1]:.1f}s in {ran:.0f}s of running")
    check(not ballast_touched,
          "no ballast is ever added by the safety car"
          + (f" (touched: {ballast_touched[:3]})" if ballast_touched else ""))
    check(gaps[-1] <= cfg.vsc_target_gap_s + 0.5,
          f"the caller actually caught the pack ({gaps[0]:.1f}s -> {gaps[-1]:.1f}s, "
          f"target {cfg.vsc_target_gap_s:.0f}s)")
    check(all(gaps[i + 1] <= gaps[i] + 0.4 for i in range(len(gaps) - 1)),
          "gap closed monotonically (no oscillation)")
    check(eta is not None and abs(eta - ran) < 0.35 * ran,
          f"the predicted ETA held up ({eta:.0f}s predicted, {ran:.0f}s actual)")

    # Every held car is driven to the same target pace, whatever its own
    # speed: the restrictor is tuned per driver from their measured pace.
    for c in (0, 1, 2):
        errs = pace_err[c]
        tail = errs[len(errs) // 2:] or [9.9]
        mean = sum(tail) / len(tail)
        check(abs(mean) < 0.06,
              f"{sims[c].name} held to the target pace ({mean * 100:+.1f}% off once settled)")

    check(not over_cap, "the restrictor never exceeds a vanilla server's 100% cap")
    # With the restrictor capped, the quickest held car at full restrictor sets
    # the pace, and slower drivers get only enough to match it.
    check(peak_r[0] >= 99.0,
          f"the quickest held car runs at the ceiling ({peak_r[0]:.0f}%)")
    check(peak_r[2] < peak_r[0] - 5,
          f"a slower held car carries less to reach the same pace "
          f"(Third {peak_r[2]:.0f}% vs Leader {peak_r[0]:.0f}%)")

    sent = sum(1 for cmd in srv.admin_log if cmd.startswith("/restrictor 0 "))
    check(sent < 25, f"the limiter is not spamming commands (leader got {sent})")

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

    base2 = {d.car_id: d.base_restrictor for d in engine2.drivers.values()}
    srv2.send(p_chat(1, "!vsc"))
    await srv2.pump(0.8)
    behind_extra = sims2[2].restrictor - base2[2]
    check(engine2.vsc is not None and behind_extra > 0,
          f"with vsc_slow_whole_field the car behind is slowed too (+{behind_extra:.0f}%)")

    bg2.cancel()
    transport2.close()
    store2.close()

    failed = [m for ok, m in results if not ok]
    print("-" * 72)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
