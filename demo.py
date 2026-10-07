#!/usr/bin/env python3
"""
Demo mode: pretend to be an Assetto Corsa server and race a fake field against a
running acbop, so you can watch the GUI do its thing without AC installed.

    python3 run.py          # terminal 1 — leave it running
    python3 demo.py         # terminal 2

It reads config.json for the ports, runs a handful of races across three tracks,
and leaves a grid sitting on track with one driver mid catch-up so the Live tab
has something in it.

Nothing here touches a real server. Delete data/acbop.sqlite to start clean.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "tests"))
sys.path.insert(0, str(HERE))

import simserver  # noqa: E402
from simserver import SimDriver, SimServer, p_car_update, p_chat  # noqa: E402

# Three circuits with deliberately different character, so you can see the
# per-track sensitivity diverge: a power track where the restrictor bites, a
# tight one where weight matters more, and something in between.
#            name        reference lap   (restrictor cost, ballast cost)
TRACKS = [
    ("monza",    105_000.0, (0.0042, 0.0009)),
    ("magione",   62_000.0, (0.0011, 0.0021)),
    ("mugello",   95_000.0, (0.0025, 0.0015)),
]

# True pace, as a fraction of lap time off the field average. Marek is also a
# genuine Monza specialist, which the affinity term should pick up.
FIELD = [
    ("Marek",  -0.030, {"monza": -0.010, "magione": +0.010}),
    ("Jozef",  -0.018, {}),
    ("Peter",  -0.009, {}),
    ("Lukas",   0.002, {}),
    ("Tomas",   0.011, {}),
    ("Juraj",   0.028, {}),
]


def load_ports(config_path: Path) -> tuple[int, int, int]:
    if config_path.exists():
        cfg = json.loads(config_path.read_text())
    else:
        cfg = {}
    return (
        int(cfg.get("listen_port", 12000)),
        int(cfg.get("server_port", 11000)),
        int(cfg.get("web_port", 8770)),
    )


def recompute(web_port: int) -> dict | None:
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{web_port}/api/recompute", method="POST",
            data=b"{}", headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except Exception as exc:
        print(f"  (could not reach the web API on port {web_port}: {exc})")
        print("   acbop refits after every session anyway, so this is cosmetic.")
        return None


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", default=str(HERE / "config.json"))
    ap.add_argument("-r", "--races", type=int, default=5,
                    help="rounds of three races each (default 5)")
    ap.add_argument("-l", "--laps", type=int, default=8, help="laps per race")
    args = ap.parse_args()

    plugin_port, sim_port, web_port = load_ports(Path(args.config))
    simserver.TRACK_K = {t: k for t, _, k in TRACKS}

    sims = [
        SimDriver(i, name, f"7656119800000{i:04d}", "ks_bmw_m3_e30", skill, aff)
        for i, (name, skill, aff) in enumerate(FIELD)
    ]

    try:
        srv = SimServer(("127.0.0.1", plugin_port), sim_port, sims)
    except OSError as exc:
        print(f"Could not bind port {sim_port}: {exc}")
        print("Is a real AC server already using it? Stop it, or change")
        print("server_port in config.json and restart acbop.")
        return 1

    print(f"Pretending to be an AC server on 127.0.0.1:{sim_port},")
    print(f"talking to acbop on 127.0.0.1:{plugin_port}.")
    print(f"Open the GUI at http://127.0.0.1:{web_port} and watch.\n")

    for rnd in range(1, args.races + 1):
        for track, base, _ in TRACKS:
            # shuffle join order every round — slot ids move, GUIDs don't
            order = list(range(len(sims)))
            if rnd % 2:
                order.reverse()
            await srv.run_session(track, base, n_laps=args.laps,
                                  join_order=order, declared_laps=30)
            await srv.end_session()
        stats = recompute(web_port)
        if stats:
            print(f"round {rnd}/{args.races}: {stats['laps_used']} laps, "
                  f"{stats['drivers_rated']} rated drivers, "
                  f"{stats['handicaps_updated']} handicaps updated")
        else:
            print(f"round {rnd}/{args.races} done")

    # Leave a race running so the Live tab is populated.
    print("\nLeaving a race on track at Monza...")
    await srv.run_session("monza", 105_000.0, n_laps=6, declared_laps=30)
    for cid, spline in ((0, 0.82), (1, 0.41), (2, 0.77), (3, 0.30), (4, 0.88), (5, 0.22)):
        srv.send(p_car_update(cid, spline, 185.0))
    await srv.pump(0.4)

    srv.send(p_chat(5, "!vsc"))   # the backmarker takes their catch-up
    await srv.pump(0.6)
    boost = [m for m in srv.chat_to_drivers if "CATCH-UP" in m]
    print("catch-up:", boost[-1] if boost else "(refused — check the Live tab)")

    print("\nWhat to look at:")
    print(f"  Live       http://127.0.0.1:{web_port}/        grid, ballast/restrictor, boost")
    print("  Drivers    pace per driver, with the handicap mathematically removed")
    print("  Handicaps  same driver, different numbers per track")
    print("  Model      learned per-track sensitivity and driver/track affinity")
    print("  Laps       every lap, including rejected ones and why")
    print("\nThe grid stays connected until you restart acbop.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        pass
