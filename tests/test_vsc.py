"""The catch-up (VSC) mechanic: granting, expiry, and every refusal path."""

from __future__ import annotations

import asyncio
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from acbop.config import Config
from acbop.db import Store
from acbop.engine import Engine
from simserver import SimDriver, SimServer, p_car_update, p_chat, p_lap_completed

BASE_MS = 95_000.0
results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((cond, msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


async def run() -> int:
    tmp = tempfile.mkdtemp()
    cfg = Config(
        listen_host="127.0.0.1", listen_port=12421,
        server_host="127.0.0.1", server_port=12422,
        db_path=os.path.join(tmp, "vsc.sqlite"),
        vsc_duration_s=2.0,          # short so the test is quick
        vsc_min_gap_s=8.0,
        vsc_min_lap=2,
        vsc_per_session=1,
        announce_handicaps=False,
        floor_restrictor=6.0, floor_ballast=25.0,
        min_laps_for_rating=3,
    )
    store = Store(cfg.db_path)
    engine = Engine(cfg, store)
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: engine, local_addr=(cfg.listen_host, cfg.listen_port)
    )
    # VSC expiry lives in the housekeeping loop, exactly as it does in run.py
    bg = asyncio.create_task(engine.run_background())

    sims = [
        SimDriver(0, "Leader", "76561198000000001", "ks_mazda_mx5_cup", -0.02),
        SimDriver(1, "Middle", "76561198000000002", "ks_mazda_mx5_cup", 0.00),
        SimDriver(2, "Backmrk", "76561198000000003", "ks_mazda_mx5_cup", 0.03),
    ]
    srv = SimServer((cfg.listen_host, cfg.listen_port), cfg.server_port, sims)

    # Build up some history so handicaps exist and best laps are known.
    await srv.run_session("mugello", BASE_MS, n_laps=6, cuts_rate=0.0)
    await srv.end_session()
    from acbop.model import recompute_all
    recompute_all(store, cfg)

    # a 30-lap race, of which we simulate 4 — so nobody is on the final lap
    await srv.run_session("mugello", BASE_MS, n_laps=4, cuts_rate=0.0, declared_laps=30)
    await srv.pump(0.3)

    # --- spread the field out: leader two laps up, backmarker at the rear ---
    for cid, laps, spline in ((0, 2, 0.9), (1, 0, 0.5), (2, 0, 0.1)):
        d = engine.drivers[cid]
        d.laps_done += laps
        srv.send(p_car_update(cid, spline, 180.0))
    await srv.pump(0.3)

    back = engine.drivers[2]
    base_r, base_b = back.restrictor, back.ballast
    check(base_r > 0 and base_b > 0, f"backmarker carries a handicap ({base_b:.0f}kg/{base_r:.0f}%)")

    # --- leader cannot use it (nobody ahead) ---
    srv.chat_to_drivers.clear()
    srv.send(p_chat(0, "!vsc"))
    await srv.pump(0.3)
    check(engine.drivers[0].vsc_until is None, "leader refused (nobody ahead)")
    check(any("leading" in m for m in srv.chat_to_drivers), "leader told why")

    # --- backmarker gets it ---
    srv.chat_to_drivers.clear()
    srv.send(p_chat(2, "!vsc"))
    await srv.pump(0.4)
    check(back.vsc_until is not None, "backmarker granted the catch-up")
    check(
        sims[2].ballast == 0 and sims[2].restrictor == 0,
        f"handicap lifted on the server (now {sims[2].ballast:.0f}kg/{sims[2].restrictor:.0f}%)",
    )
    check(any("CATCH-UP" in m for m in srv.chat_to_drivers), "field was told")

    # --- a second attempt in the same race is refused ---
    srv.chat_to_drivers.clear()
    srv.send(p_chat(2, "!vsc"))
    await srv.pump(0.3)
    check(any("already" in m for m in srv.chat_to_drivers), "second use refused")

    # --- it expires and the handicap comes back ---
    await asyncio.sleep(2.2)
    await srv.pump(0.5)
    check(back.vsc_until is None, "catch-up expired")
    check(
        abs(sims[2].ballast - base_b) < 0.5 and abs(sims[2].restrictor - base_r) < 0.5,
        f"handicap restored ({sims[2].ballast:.0f}kg/{sims[2].restrictor:.0f}% "
        f"vs {base_b:.0f}kg/{base_r:.0f}%)",
    )

    # --- laps run under the catch-up must not pollute the model ---
    dropped = store.q1("SELECT COUNT(*) c FROM laps WHERE reason='VSC active'")["c"]
    back.vsc_until = time.time() + 999  # hold it open for the duration of this check
    srv.send(p_lap_completed(2, 80_000, 0, []))
    await srv.pump(0.2)
    now_dropped = store.q1("SELECT COUNT(*) c FROM laps WHERE reason='VSC active'")["c"]
    check(now_dropped == dropped + 1, "laps run under the catch-up are excluded from the model")

    # --- gap guard: a driver right behind another is refused ---
    back.vsc_until = None
    back.vsc_uses = 0
    store.vsc_clear_session(engine.session_id)
    engine.drivers[1].laps_done = back.laps_done
    engine.drivers[1].spline = back.spline + 0.005  # a few car lengths ahead
    srv.chat_to_drivers.clear()
    srv.send(p_chat(2, "!vsc"))
    await srv.pump(0.3)
    check(
        any("gap is only" in m for m in srv.chat_to_drivers),
        "refused when the car ahead is close (not push-to-pass)",
    )

    # --- a new session resets the budget ---
    await srv.end_session()
    await srv.run_session("mugello", BASE_MS, n_laps=3, cuts_rate=0.0, declared_laps=30)
    await srv.pump(0.3)
    check(
        engine.drivers[2].vsc_uses == 0,
        "catch-up budget resets for the next race",
    )

    bg.cancel()
    transport.close()
    store.close()

    failed = [m for ok, m in results if not ok]
    print("-" * 70)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
