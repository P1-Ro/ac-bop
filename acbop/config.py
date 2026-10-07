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
    trim_fraction: float = 0.5          # keep the best X of a driver's laps
    outlier_ratio: float = 1.25         # drop laps slower than X * personal best

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

    # --- VSC --------------------------------------------------------------
    vsc_enabled: bool = True
    vsc_command: str = "!vsc"
    vsc_duration_s: float = 45.0
    vsc_min_gap_s: float = 8.0      # must be this far behind the car ahead
    vsc_min_lap: int = 2            # not on the opening lap
    vsc_forbid_final_lap: bool = True
    vsc_per_session: int = 1        # uses per driver per session
    vsc_race_only: bool = True

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

    def apply_updates(self, updates: dict[str, Any]) -> list[str]:
        """Apply a partial update, coercing types. Returns the keys changed."""
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
                continue
            if value != current:
                setattr(self, key, value)
                changed.append(key)
        return changed
