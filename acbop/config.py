"""Configuration. File defaults, overridable live from the web GUI."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any


@dataclass
class Config:
    # --- networking -------------------------------------------------------
    # Must mirror server_cfg.ini:
    #   UDP_PLUGIN_ADDRESS=127.0.0.1:<listen_port>   (where WE listen)
    #   UDP_PLUGIN_LOCAL_PORT=<server_port>          (where the SERVER listens)
    listen_host: str = "127.0.0.1"
    listen_port: int = 12000
    server_host: str = "127.0.0.1"
    server_port: int = 11000

    web_host: str = "0.0.0.0"
    web_port: int = 8770
    web_password: str = ""  # blank = no auth (only do this behind a VPN/LAN)

    db_path: str = "data/acbop.sqlite"

    # --- realtime ---------------------------------------------------------
    realtime_interval_ms: int = 1000  # CAR_UPDATE rate; also the VSC tick

    # --- handicap shape ---------------------------------------------------
    # Fraction of the handicap delivered as restrictor; the rest is ballast.
    # 0.6 = 60% restrictor / 40% ballast.
    restrictor_share: float = 0.6

    max_restrictor: float = 25.0   # percent
    max_ballast: float = 120.0     # kg

    # Headroom so VSC has something to give back. Everyone carries at least
    # this much; a driver with zero handicap still runs the floor.
    floor_restrictor: float = 6.0
    floor_ballast: float = 25.0

    # Where to anchor the field, as a quantile of driver pace.
    # 1.0 = everyone slowed to the very slowest driver (max handicaps),
    # 0.0 = everyone slowed to the fastest, i.e. nobody gets anything.
    # 0.85 leans slow while ignoring a single extreme outlier.
    target_percentile: float = 0.85

    # --- convergence ------------------------------------------------------
    damping: float = 0.4               # fraction of the computed delta applied
    max_restrictor_step: float = 4.0   # per recompute
    max_ballast_step: float = 20.0
    min_laps_for_rating: int = 5       # clean laps before a driver is rated
    half_life_days: float = 60.0       # exponential decay on old laps

    # --- lap filtering ----------------------------------------------------
    drop_cut_laps: bool = True
    collision_cooldown_s: float = 20.0  # ignore laps within N s of a contact
    # Hard outlier cut: a lap slower than this multiple of the driver's best on
    # the combination carries no pace information (spin, gravel, stuck behind a
    # wreck) and is dropped outright.
    outlier_ratio: float = 1.20
    # Soft pace weighting. A lap at a personal best weighs 1.0; every
    # `pace_weight_falloff` of fractional lap time above it halves the weight.
    # 0.02 means a lap 2% off their best counts half, 4% off counts a quarter.
    # This handles traffic without discarding the lap. Set 0 to weight all
    # usable laps equally.
    pace_weight_falloff: float = 0.02
    # Optional hard trim to the quickest fraction of a driver's laps.
    # 1.0 = off, which is the default: the pace weighting above does this job
    # better, because it keeps the information instead of binning it.
    trim_fraction: float = 1.0

    # --- car sensitivity priors ------------------------------------------
    # Fractional laptime loss per 1% restrictor, and per 10 kg ballast.
    prior_k_restrictor: float = 0.0020
    prior_k_ballast: float = 0.0012
    sensitivity_prior_weight: float = 40.0  # pseudo-samples anchoring the prior
    # A per-track sensitivity shrinks toward its car's average by this weight.
    # Lower = tracks diverge faster from one another.
    track_sensitivity_weight: float = 25.0

    # --- driver x track affinity -----------------------------------------
    # Some drivers are simply better at some circuits. Shrunk hard toward zero
    # so it takes real evidence to move; set the weight very high to disable.
    affinity_prior_weight: float = 25.0
    max_affinity: float = 0.015  # +/- 1.5% of lap time

    # --- VSC / safety car -------------------------------------------------
    # A VSC is a live phase, not a one-shot boost. The caller is unhandicapped
    # and everyone AHEAD of them is slowed in proportion to how far ahead they
    # are, so the field genuinely compresses. Recomputed every tick from live
    # gaps, and it ends as soon as the caller has closed to the target gap.
    vsc_enabled: bool = True
    vsc_command: str = "!vsc"
    # How the cars being held are slowed:
    #   "limiter"    — a CSP script on every client caps their speed at
    #                  vsc_speed_limit_kmh, like a pit limiter. acbop serves the
    #                  script; add it to csp_extra_options.ini (see README).
    #   "restrictor" — server-side only, no client script: the restrictor is
    #                  used as a pace limiter. Works on any client, but 100% is
    #                  only worth about 20% of lap time, so it closes slowly.
    vsc_mode: str = "limiter"
    # Speed cap for held cars in limiter mode.
    vsc_speed_limit_kmh: float = 100.0
    # Safety net for limiter mode: a held car still more than this over the
    # cap after the grace period, for 3 seconds running, has evidently not
    # got the client script, and is held with the restrictor instead.
    vsc_limiter_tolerance_kmh: float = 15.0
    vsc_limiter_grace_s: float = 10.0
    vsc_max_duration_s: float = 180.0  # hard ceiling even if the gap never closes
    vsc_target_gap_s: float = 3.0      # phase ends once this close to the car ahead
    vsc_min_gap_s: float = 8.0         # must be this far behind to call it
    vsc_min_lap: int = 2               # not on the opening lap
    vsc_forbid_final_lap: bool = True
    vsc_per_session: int = 1           # uses per driver per session
    vsc_race_only: bool = True
    vsc_tick_s: float = 1.0            # how often gaps and penalties are redone

    # How much slower than the caller the held cars are made to run, at most.
    # Every held car is limited to the same target lap time: the caller's own
    # unhandicapped pace times (1 + this). In practice the restrictor ceiling
    # is what binds: 100% is worth roughly 20% of lap time, so the quickest
    # held car at full restrictor sets the pace and everyone else is matched
    # to it. A 20% hold closes about 0.17 s of gap per second of running, so
    # a 20 s gap takes around 100 s. Lower this for a gentler hold.
    vsc_max_slowdown: float = 0.60
    # The hold is a pace limiter built from the restrictor alone; no ballast is
    # ever added. Each held car's restrictor is solved from that driver's own
    # pace (a quick driver needs more to reach the same target than a slow
    # one), then trimmed every tick from their measured live pace, so the
    # restrictor's non-linear bite at high values is corrected automatically.
    # Ceiling on the total restrictor, normal handicap included. A vanilla
    # acServer caps the admin command at 100%; some server managers accept
    # more.
    vsc_max_restrictor: float = 100.0
    # How hard the live correction pulls toward the target pace, per second.
    # Higher reacts faster but can overshoot; 0 uses the model estimate only.
    vsc_limiter_gain: float = 0.10
    # Seconds of live running averaged to measure a held car's pace. Compared
    # against that driver's own lap profile, so slow corners and long
    # straights do not read as the car being too slow or too fast.
    vsc_pace_window_s: float = 6.0
    # Restrictor changes smaller than this are not sent during a phase. Each
    # command pops a notification for the driver, so keep this above the
    # normal deadband.
    vsc_deadband_restrictor: float = 3.0
    # Grade the slowdown so cars further ahead are held harder, which bunches
    # the leaders together as well — more like a real safety car, but the
    # caller closes more slowly because the car directly ahead of them is held
    # less. Off by default: closing the caller's own gap is the point.
    vsc_compress_pack: bool = False
    # Drivers already behind the caller are left alone by default. Turn this on
    # to slow the whole field instead, which keeps relative order behind intact.
    vsc_slow_whole_field: bool = False
    # Ease the limiter in and out over this long, so nobody loses half their
    # power between one corner and the next.
    vsc_ramp_s: float = 3.0

    # --- behaviour --------------------------------------------------------
    apply_in_practice: bool = True
    apply_in_qualify: bool = True
    apply_in_race: bool = True
    # Don't resend a command unless the value moved by at least this much.
    deadband_restrictor: float = 1.0
    deadband_ballast: float = 5.0
    announce_handicaps: bool = True
    recompute_after_session: bool = True

    @classmethod
    def load(cls, path: str | Path) -> "Config":
        p = Path(path)
        if not p.exists():
            cfg = cls()
            cfg.save(p)
            return cfg
        raw = json.loads(p.read_text())
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in raw.items() if k in known})

    def save(self, path: str | Path) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(asdict(self), indent=2) + "\n")

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def apply_updates(
        self, updates: dict[str, Any], rejected: list[str] | None = None
    ) -> list[str]:
        """Apply a partial update, coercing types. Returns the keys changed;
        keys whose value could not be coerced are appended to `rejected`."""
        changed = []
        types = {f.name: f.type for f in fields(self)}
        for key, value in updates.items():
            if key not in types:
                continue
            current = getattr(self, key)
            try:
                if isinstance(current, bool):
                    value = value in (True, "true", "True", 1, "1", "on")
                elif isinstance(current, int):
                    value = int(value)
                elif isinstance(current, float):
                    value = float(value)
                else:
                    value = str(value)
            except (TypeError, ValueError):
                if rejected is not None:
                    rejected.append(key)
                continue
            if value != current:
                setattr(self, key, value)
                changed.append(key)
        return changed
