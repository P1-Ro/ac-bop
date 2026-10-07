"""End-to-end: does the field actually converge, and does join order matter?"""

from __future__ import annotations

import asyncio
import math
import os
import statistics
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from acbop.config import Config
from acbop.db import Store
from acbop.engine import Engine
from acbop.model import recompute_all
from simserver import SimDriver, SimServer

BASE_MS = 95_000.0  # a 1:35 reference lap

# True pace spread: an alien, two quick, two midfield, one slow.
FIELD = [
    ("Alien",  -0.040),
    ("Quick1", -0.022),
    ("Quick2", -0.016),
    ("Mid1",    0.000),
    ("Mid2",    0.006),
    ("Slow",    0.035),
]


def spread(drivers) -> float:
    """Std-dev of effective pace, in percent of lap time."""
    return statistics.pstdev([d.effective_skill() for d in drivers]) * 100


def gap_pct(drivers) -> float:
    eff = [d.effective_skill() for d in drivers]
    return (math.exp(max(eff) - min(eff)) - 1) * 100


async def run() -> int:
    tmp = tempfile.mkdtemp()
    cfg = Config(
        listen_host="127.0.0.1",
        listen_port=12411,
        server_host="127.0.0.1",
        server_port=12412,
        db_path=os.path.join(tmp, "test.sqlite"),
        min_laps_for_rating=4,
        damping=0.6,
        max_restrictor_step=6.0,
        max_ballast_step=35.0,
        announce_handicaps=False,
        floor_restrictor=6.0,
        floor_ballast=25.0,
        max_restrictor=25.0,
        max_ballast=120.0,
        restrictor_share=0.6,
        target_percentile=0.85,
    )
    store = Store(cfg.db_path)
    engine = Engine(cfg, store)

    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: engine, local_addr=(cfg.listen_host, cfg.listen_port)
    )

    sims = [
        SimDriver(i, name, f"7656119800000{i:04d}", "ks_mazda_mx5_cup", skill)
        for i, (name, skill) in enumerate(FIELD)
    ]
    srv = SimServer((cfg.listen_host, cfg.listen_port), cfg.server_port, sims)

    print(f"{'race':>5} {'spread%':>9} {'P1-last%':>9}   handicaps (kg/%)")
    print("-" * 78)

    # baseline: no handicaps at all
    print(f"{'raw':>5} {spread(sims):9.3f} {gap_pct(sims):9.2f}")

    history = []
    for race in range(1, 9):
        # deliberately shuffle join order every race — slot ids move around
        order = list(range(len(sims)))
        if race % 2 == 0:
            order.reverse()
        elif race % 3 == 0:
            order = order[2:] + order[:2]

        await srv.run_session("mugello", BASE_MS, n_laps=10, join_order=order)
        await srv.end_session()

        stats = recompute_all(store, cfg)

        # reconnect so handicaps get pushed, then measure what they carry
        await srv.run_session("mugello", BASE_MS, n_laps=1, join_order=order)
        await srv.pump(0.3)

        s, g = spread(sims), gap_pct(sims)
        history.append((s, g))
        # snapshot before disconnecting — CONNECTION_CLOSED correctly zeroes the slot
        applied = {d.name: (d.ballast, d.restrictor) for d in sims}
        hc = " ".join(f"{d.name[:5]}:{d.ballast:.0f}/{d.restrictor:.0f}" for d in sims)
        print(f"{race:>5} {s:9.3f} {g:9.2f}   {hc}")
        await srv.end_session()

    print("\nlearned sensitivity (true: 0.250% per 1% restr, 0.150% per 10kg):")
    for r in store.q("SELECT * FROM car_sensitivity"):
        print(f"  {r['car_model']}: {r['k_restrictor']*100:.3f}% / "
              f"{r['k_ballast']*100:.3f}%  ({r['samples']} laps)")
    print()

    transport.close()
    store.close()

    first, last = history[0][1], history[-1][1]
    raw = gap_pct([SimDriver(i, n, "", "", s) for i, (n, s) in enumerate(FIELD)])

    print("-" * 78)
    print(f"raw field spread (no BoP):      {raw:.2f}%")
    print(f"after first race:               {first:.2f}%")
    print(f"after eight races:              {last:.2f}%")

    ok = True

    if last >= raw * 0.5:
        print(f"FAIL: spread did not halve ({last:.2f}% vs raw {raw:.2f}%)")
        ok = False
    else:
        print(f"PASS: spread reduced by {(1 - last / raw) * 100:.0f}%")

    # the quickest driver must be carrying meaningfully more than the slowest
    a_b, a_r = applied["Alien"]
    s_b, s_r = applied["Slow"]
    if a_b <= s_b or a_r <= s_r:
        print(f"FAIL: ordering wrong — alien {a_b:.0f}kg/{a_r:.0f}% vs slow {s_b:.0f}kg/{s_r:.0f}%")
        ok = False
    else:
        print(f"PASS: alien carries {a_b:.0f}kg/{a_r:.0f}%, slowest {s_b:.0f}kg/{s_r:.0f}%")

    # both channels in use, i.e. the split is actually happening
    if a_b <= cfg.floor_ballast or a_r <= cfg.floor_restrictor:
        print("FAIL: one channel unused — the split is not working")
        ok = False
    else:
        print("PASS: ballast and restrictor both in use")

    # monotonic: quicker drivers must never carry less than slower ones
    order = [applied[n][0] + applied[n][1] * 4 for n, _ in FIELD]
    if any(order[i] < order[i + 1] - 1e-6 for i in range(len(order) - 1)):
        print(f"FAIL: handicaps not monotonic in pace: {order}")
        ok = False
    else:
        print("PASS: handicaps monotonic in true pace")

    for name, (b, r) in applied.items():
        if r > cfg.max_restrictor + 0.01 or b > cfg.max_ballast + 0.01:
            print(f"FAIL: {name} exceeded caps ({b}kg/{r}%)")
            ok = False
            break
    else:
        print("PASS: caps respected")

    # floor respected, so the catch-up always has room to give
    for name, (b, r) in applied.items():
        if r < cfg.floor_restrictor - 0.01 or b < cfg.floor_ballast - 0.01:
            print(f"FAIL: {name} below the floor ({b}kg/{r}%)")
            ok = False
            break
    else:
        print("PASS: floor respected (catch-up has headroom)")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
