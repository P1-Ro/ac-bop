"""
Handicaps must differ by track, for two independent reasons:

  1. A restrictor costs far more lap time on a power circuit than somewhere
     tight, so the same slowdown needs a different number.
  2. Some drivers are simply better at some circuits.

Both are learned from lap times alone — nothing about the tracks is hardcoded.
"""

from __future__ import annotations

import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import simserver
from acbop.config import Config
from acbop.db import Store
from acbop.engine import Engine
from acbop.model import recompute_all
from simserver import SimDriver, SimServer

results: list[tuple[bool, str]] = []


def check(cond: bool, msg: str) -> None:
    results.append((cond, msg))
    print(("PASS: " if cond else "FAIL: ") + msg)


# A power circuit where the restrictor bites hard, and a tight one where it
# barely matters but weight does.
simserver.TRACK_K = {
    "monza": (0.0045, 0.0008),
    "magione": (0.0010, 0.0022),
}
TRACKS = [("monza", 105_000.0), ("magione", 62_000.0)]

FIELD = [
    # Specialist is quick overall but notably better at magione than monza.
    ("Specialist", -0.025, {"monza": +0.012, "magione": -0.012}),
    ("Allrounder", -0.012, {}),
    ("Steady",      0.004, {}),
    ("Learner",     0.026, {}),
]


async def run() -> int:
    tmp = tempfile.mkdtemp()
    cfg = Config(
        listen_host="127.0.0.1", listen_port=12441,
        server_host="127.0.0.1", server_port=12442,
        db_path=os.path.join(tmp, "tv.sqlite"),
        min_laps_for_rating=4, damping=0.65,
        max_restrictor_step=8.0, max_ballast_step=40.0,
        announce_handicaps=False,
        floor_restrictor=6.0, floor_ballast=25.0,
    )
    store = Store(cfg.db_path)
    engine = Engine(cfg, store)
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: engine, local_addr=(cfg.listen_host, cfg.listen_port)
    )

    sims = [
        SimDriver(i, n, f"765611981111{i:05d}", "ks_bmw_m3_e30", s, a)
        for i, (n, s, a) in enumerate(FIELD)
    ]
    srv = SimServer((cfg.listen_host, cfg.listen_port), cfg.server_port, sims, seed=11)

    applied: dict[str, dict[str, tuple[float, float]]] = {}
    for rnd in range(10):
        for track, base in TRACKS:
            order = list(range(len(sims)))
            if rnd % 2:
                order.reverse()
            await srv.run_session(track, base, n_laps=8, join_order=order,
                                  declared_laps=30, cuts_rate=0.05)
            if rnd == 9:
                applied[track] = {d.name: (d.ballast, d.restrictor) for d in sims}
            await srv.end_session()
        recompute_all(store, cfg)

    print()
    for track in applied:
        line = "  ".join(f"{n}:{b:.0f}kg/{r:.0f}%" for n, (b, r) in applied[track].items())
        print(f"{track:9} {line}")

    kr = {}
    print("\nlearned sensitivity by track (true in brackets):")
    for r in store.q("SELECT * FROM car_sensitivity WHERE track != ''"):
        t = r["track"]
        kr[t] = r["k_restrictor"]
        tk = simserver.TRACK_K[t]
        print(f"  {t:9} {r['k_restrictor']*100:.3f}% / {r['k_ballast']*100:.3f}%"
              f"   (true {tk[0]*100:.3f}% / {tk[1]*100:.3f}%)")

    print("\nlearned driver x track affinity (true: Specialist +1.2% monza, -1.2% magione):")
    aff = {}
    for r in store.affinities():
        aff[(r["name"], r["track"])] = r["value"]
        print(f"  {r['name']:11} {r['track']:9} {r['value']*100:+.2f}%")
    print()

    # 1. the restrictor coefficient must be higher on the power circuit
    check(
        kr.get("monza", 0) > kr.get("magione", 1) * 1.25,
        f"restrictor learned as costlier at monza "
        f"({kr.get('monza', 0)*100:.3f}% vs {kr.get('magione', 0)*100:.3f}%)",
    )

    # 2. because of that, the same driver gets a different restrictor per track
    diffs = [
        abs(applied["monza"][n][1] - applied["magione"][n][1])
        for n, _, _ in FIELD
    ]
    check(max(diffs) >= 2.0,
          f"restrictor varies by track for the same driver (max delta {max(diffs):.1f}%)")

    # 3. the track specialist's affinity has the right sign on both circuits
    a_monza = aff.get(("Specialist", "monza"), 0.0)
    a_mag = aff.get(("Specialist", "magione"), 0.0)
    check(a_monza > 0 and a_mag < 0,
          f"specialist's affinity recovered with correct signs "
          f"(monza {a_monza*100:+.2f}%, magione {a_mag*100:+.2f}%)")

    # 4. and it feeds through: they carry less at the track they are worse at
    sm = applied["monza"]["Specialist"]
    sg = applied["magione"]["Specialist"]
    check(sm[0] + sm[1] * 4 < sg[0] + sg[1] * 4,
          f"specialist handicapped less where they are weaker "
          f"(monza {sm[0]:.0f}kg/{sm[1]:.0f}%, magione {sg[0]:.0f}kg/{sg[1]:.0f}%)")

    # 5. an all-rounder should not pick up a large spurious affinity
    spurious = max(
        abs(aff.get((n, t), 0.0))
        for n, _, a in FIELD if not a
        for t in ("monza", "magione")
    )
    check(spurious < 0.006,
          f"drivers with no real track bias stay near zero (max {spurious*100:.2f}%)")

    transport.close()
    store.close()
    failed = [m for ok, m in results if not ok]
    print("-" * 70)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
