"""
Pace model and handicap solver. Pure stdlib — no numpy.

The model factorises lap time so that a driver who has never seen a track still
gets a sensible handicap:

    log(laptime) = base[track, car] + skill[driver] + handicap_effect

`skill` is a single number per driver estimated across every track and car they
have ever run, so it transfers. `base` is estimated from everyone else's laps at
that track, so it exists before the new driver turns a wheel.

`handicap_effect` is modelled as log(1 + kr*restrictor + kb*ballast/10) with per
car coefficients kr, kb that are themselves learned (ridged toward a prior, so
they stay sane until there is enough spread in applied handicaps to identify
them).

Everything is fit by alternating weighted means, which is simple, has no matrix
inversion, and converges in a handful of passes on data this size.
"""

from __future__ import annotations

import math
import time
from collections import defaultdict
from dataclasses import dataclass, field

from .config import Config
from .db import Store

DAY = 86400.0


# ---------------------------------------------------------------------------
# small numeric helpers
# ---------------------------------------------------------------------------


def quantile(values: list[float], q: float) -> float:
    """Linear-interpolated quantile. q=1.0 returns the max."""
    if not values:
        return 0.0
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    pos = max(0.0, min(1.0, q)) * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    frac = pos - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def wmean(pairs: list[tuple[float, float]]) -> float:
    """Weighted mean of (value, weight) pairs."""
    tw = sum(w for _, w in pairs)
    if tw <= 0:
        return 0.0
    return sum(v * w for v, w in pairs) / tw


# ---------------------------------------------------------------------------
# inputs / outputs
# ---------------------------------------------------------------------------


@dataclass
class Lap:
    guid: str
    track: str
    car: str
    laptime_ms: int
    restrictor: float
    ballast: float
    ts: float
    weight: float = 1.0


@dataclass
class FitResult:
    skill: dict[str, float] = field(default_factory=dict)          # guid -> log offset
    skill_n: dict[str, int] = field(default_factory=dict)
    base: dict[tuple[str, str], float] = field(default_factory=dict)
    base_n: dict[tuple[str, str], int] = field(default_factory=dict)
    # sensitivity keyed by (track, car); ("", car) is the car-level average
    k_restrictor: dict[tuple[str, str], float] = field(default_factory=dict)
    k_ballast: dict[tuple[str, str], float] = field(default_factory=dict)
    k_n: dict[tuple[str, str], int] = field(default_factory=dict)
    # driver x track offset on top of skill
    affinity: dict[tuple[str, str], float] = field(default_factory=dict)
    affinity_n: dict[tuple[str, str], int] = field(default_factory=dict)
    laps_used: int = 0

    def sensitivity(self, track: str, car: str, cfg: Config) -> tuple[float, float]:
        """Per-track coefficients, falling back to car level, then to the prior."""
        for key in ((track, car), ("", car)):
            if key in self.k_restrictor:
                return self.k_restrictor[key], self.k_ballast[key]
        return cfg.prior_k_restrictor, cfg.prior_k_ballast

    def effective_skill(self, guid: str, track: str) -> float | None:
        """Pace at a specific track: global skill plus any learned affinity."""
        s = self.skill.get(guid)
        if s is None:
            return None
        return s + self.affinity.get((guid, track), 0.0)


@dataclass
class Handicap:
    guid: str
    track: str
    car: str
    restrictor: float
    ballast: float
    provisional: bool = False
    note: str = ""


# ---------------------------------------------------------------------------
# lap selection
# ---------------------------------------------------------------------------


def _decay_weight(ts: float, now: float, half_life_days: float) -> float:
    if half_life_days <= 0:
        return 1.0
    age_days = max(0.0, (now - ts) / DAY)
    return 0.5 ** (age_days / half_life_days)


def select_laps(
    store: Store,
    cfg: Config,
    now: float | None = None,
    stats: dict | None = None,
) -> list[Lap]:
    """
    Pull clean laps and weight them. Nothing is discarded except genuinely
    broken laps.

    A lap gets three multiplied weights:
      * recency   — exponential decay, so old pace does not hold a driver back
      * pace      — laps near that driver's personal best on the combination
                    count fully, slower ones taper off. This is what handles
                    traffic and lifting WITHOUT throwing the lap away.
      * (optional) a hard trim, off by default.

    Earlier versions hard-trimmed to the quickest 50%, which silently binned
    half the data. Weighting keeps every lap's information while still
    privileging representative ones.

    `stats`, if given, is filled in with a funnel so the GUI can show exactly
    what happened to every lap.
    """
    now = now or time.time()
    rows = store.clean_laps()
    raw = [
        Lap(
            guid=r["guid"],
            track=r["track"],
            car=r["car_model"],
            laptime_ms=r["laptime_ms"],
            restrictor=r["restrictor"] or 0.0,
            ballast=r["ballast"] or 0.0,
            ts=r["ts"],
            weight=_decay_weight(r["ts"], now, cfg.half_life_days),
        )
        for r in rows
    ]

    groups: dict[tuple[str, str, str], list[Lap]] = defaultdict(list)
    for lap in raw:
        groups[(lap.guid, lap.track, lap.car)].append(lap)

    kept: list[Lap] = []
    n_outlier = 0
    n_trimmed = 0
    downweighted = 0

    for laps in groups.values():
        laps.sort(key=lambda l: l.laptime_ms)
        best = laps[0].laptime_ms

        # Hard cut only for laps so slow they carry no pace information at all
        # (a spin, a trip through the gravel, a lap spent behind a wreck).
        usable = [l for l in laps if l.laptime_ms <= best * cfg.outlier_ratio]
        n_outlier += len(laps) - len(usable)

        # Soft pace weight: 1.0 at a personal best, tapering as the lap slows.
        for l in usable:
            excess = (l.laptime_ms / best) - 1.0
            if cfg.pace_weight_falloff > 0:
                pw = 0.5 ** (excess / cfg.pace_weight_falloff)
            else:
                pw = 1.0
            if pw < 0.95:
                downweighted += 1
            l.weight *= pw

        # Optional hard trim, off by default (trim_fraction >= 1.0).
        if cfg.trim_fraction < 1.0:
            n_keep = max(1, int(round(len(usable) * cfg.trim_fraction)))
            n_trimmed += len(usable) - n_keep
            usable = usable[:n_keep]

        kept.extend(usable)

    if stats is not None:
        stats.update(
            {
                "clean_laps": len(raw),
                "dropped_outlier": n_outlier,
                "dropped_trim": n_trimmed,
                "downweighted": downweighted,
                "used": len(kept),
                "effective_weight": round(sum(l.weight for l in kept), 1),
            }
        )
    return kept


# ---------------------------------------------------------------------------
# the fit
# ---------------------------------------------------------------------------


def _handicap_factor(lap: Lap, kr: float, kb: float) -> float:
    f = 1.0 + kr * lap.restrictor + kb * (lap.ballast / 10.0)
    return max(0.5, f)


def fit(laps: list[Lap], cfg: Config, passes: int = 14) -> FitResult:
    res = FitResult(laps_used=len(laps))
    if not laps:
        return res

    by_driver: dict[str, list[Lap]] = defaultdict(list)
    by_tc: dict[tuple[str, str], list[Lap]] = defaultdict(list)
    by_car: dict[str, list[Lap]] = defaultdict(list)
    by_dt: dict[tuple[str, str], list[Lap]] = defaultdict(list)
    for l in laps:
        by_driver[l.guid].append(l)
        by_tc[(l.track, l.car)].append(l)
        by_car[l.car].append(l)
        by_dt[(l.guid, l.track)].append(l)

    # sensitivity: ("", car) is the car-level value, (track, car) the per-track one
    k: dict[tuple[str, str], tuple[float, float]] = {}
    for c in by_car:
        k[("", c)] = (cfg.prior_k_restrictor, cfg.prior_k_ballast)
    for (t, c) in by_tc:
        k[(t, c)] = (cfg.prior_k_restrictor, cfg.prior_k_ballast)

    def kof(lap: Lap) -> tuple[float, float]:
        return k.get((lap.track, lap.car)) or k[("", lap.car)]

    skill: dict[str, float] = defaultdict(float)
    aff: dict[tuple[str, str], float] = defaultdict(float)
    base: dict[tuple[str, str], float] = defaultdict(float)

    def corrected(l: Lap) -> float:
        kr, kb = kof(l)
        return math.log(l.laptime_ms / _handicap_factor(l, kr, kb))

    # seed base with the group mean so the first skill pass is sensible
    for key, group in by_tc.items():
        base[key] = wmean([(corrected(l), l.weight) for l in group])

    for it in range(passes):
        # --- skill given base and affinity -------------------------------
        for guid, group in by_driver.items():
            skill[guid] = wmean(
                [
                    (corrected(l) - base[(l.track, l.car)] - aff[(l.guid, l.track)], l.weight)
                    for l in group
                ]
            )

        # centre skill so the decomposition is identifiable
        centre = wmean([(skill[g], sum(l.weight for l in by_driver[g])) for g in by_driver])
        for g in skill:
            skill[g] -= centre
        for key in base:
            base[key] += centre

        # --- base given the rest -----------------------------------------
        for key, group in by_tc.items():
            base[key] = wmean(
                [
                    (corrected(l) - skill[l.guid] - aff[(l.guid, l.track)], l.weight)
                    for l in group
                ]
            )

        # --- driver x track affinity, shrunk hard toward zero -------------
        if it >= 3:
            for key, group in by_dt.items():
                resid = [
                    (corrected(l) - skill[l.guid] - base[(l.track, l.car)], l.weight)
                    for l in group
                ]
                w = sum(x[1] for x in resid)
                shrunk = (wmean(resid) * w) / (w + cfg.affinity_prior_weight)
                aff[key] = max(-cfg.max_affinity, min(cfg.max_affinity, shrunk))
            # affinity must not absorb a driver's overall pace: centre per driver
            for guid, group in by_driver.items():
                tracks = {l.track for l in group}
                if len(tracks) < 2:
                    for t in tracks:
                        aff[(guid, t)] = 0.0
                    continue
                m = sum(aff[(guid, t)] for t in tracks) / len(tracks)
                for t in tracks:
                    aff[(guid, t)] -= m

        # --- sensitivity: car level, then per track shrunk toward it ------
        if it >= 2:
            for car, group in by_car.items():
                k[("", car)] = _fit_sensitivity(
                    group, skill, base, aff, cfg,
                    (cfg.prior_k_restrictor, cfg.prior_k_ballast),
                    cfg.sensitivity_prior_weight,
                )
            for (track, car), group in by_tc.items():
                k[(track, car)] = _fit_sensitivity(
                    group, skill, base, aff, cfg,
                    k[("", car)], cfg.track_sensitivity_weight,
                )

    res.skill = dict(skill)
    res.skill_n = {g: len(v) for g, v in by_driver.items()}
    res.base = dict(base)
    res.base_n = {key: len(v) for key, v in by_tc.items()}
    res.k_restrictor = {key: v[0] for key, v in k.items()}
    res.k_ballast = {key: v[1] for key, v in k.items()}
    res.k_n = {("", c): len(v) for c, v in by_car.items()}
    res.k_n.update({key: len(v) for key, v in by_tc.items()})
    res.affinity = {key: v for key, v in aff.items() if abs(v) > 1e-9}
    res.affinity_n = {key: len(v) for key, v in by_dt.items()}
    return res


def _fit_sensitivity(
    group: list[Lap],
    skill: dict[str, float],
    base: dict[tuple[str, str], float],
    aff: dict[tuple[str, str], float],
    cfg: Config,
    prior: tuple[float, float],
    prior_weight: float,
) -> tuple[float, float]:
    """
    Weighted ridge regression of residual on (restrictor, ballast/10),
    no intercept, shrunk toward `prior`.

    Solving the 2x2 normal equations directly:
        [Sxx+p  Sxy  ] [kr]   [Sxr + p*prior_kr]
        [Sxy    Syy+p] [kb] = [Syr + p*prior_kb]

    Note the two regressors are strongly collinear in normal running, because
    acbop always applies ballast and restrictor in a fixed ratio. The ridge is
    what keeps that from blowing up; the split between the two coefficients is
    only weakly identified, their combined effect much better so.
    """
    prior_kr, prior_kb = prior
    p = max(1e-6, prior_weight)
    sxx = syy = sxy = sxr = syr = 0.0
    for l in group:
        w = l.weight
        x = l.restrictor
        y = l.ballast / 10.0
        r = (
            math.log(l.laptime_ms)
            - skill.get(l.guid, 0.0)
            - base.get((l.track, l.car), 0.0)
            - aff.get((l.guid, l.track), 0.0)
        )
        sxx += w * x * x
        syy += w * y * y
        sxy += w * x * y
        sxr += w * x * r
        syr += w * y * r

    a11 = sxx + p
    a22 = syy + p
    a12 = sxy
    b1 = sxr + p * prior_kr
    b2 = syr + p * prior_kb

    det = a11 * a22 - a12 * a12
    if abs(det) < 1e-12:
        return prior_kr, prior_kb

    kr = (b1 * a22 - a12 * b2) / det
    kb = (a11 * b2 - a12 * b1) / det

    # Physically a handicap can only slow a car down. Keep the coefficients
    # positive and within a factor of four of the prior so a noisy fit can
    # never produce an absurd handicap.
    kr = min(max(kr, cfg.prior_k_restrictor * 0.25), cfg.prior_k_restrictor * 4.0)
    kb = min(max(kb, cfg.prior_k_ballast * 0.25), cfg.prior_k_ballast * 4.0)
    return kr, kb


# ---------------------------------------------------------------------------
# handicap solving
# ---------------------------------------------------------------------------


def solve_handicaps(
    res: FitResult,
    cfg: Config,
    track: str,
    car: str,
    guids: list[str],
    current: dict[str, tuple[float, float]] | None = None,
) -> list[Handicap]:
    """
    Turn fitted skills into restrictor + ballast for one track/car combination.

    `current` maps guid -> (restrictor, ballast) already in force, used for
    damping and per-step clamping so handicaps move gently between races.
    """
    current = current or {}
    kr, kb = res.sensitivity(track, car, cfg)

    rated = [g for g in guids if res.skill_n.get(g, 0) >= cfg.min_laps_for_rating]
    # pace AT THIS TRACK: global skill plus learned affinity
    eff = {g: res.effective_skill(g, track) for g in rated}
    eff = {g: v for g, v in eff.items() if v is not None}
    skills = list(eff.values())

    out: list[Handicap] = []

    if not skills:
        # Nothing known at all: everyone runs the floor.
        for g in guids:
            out.append(
                Handicap(g, track, car, cfg.floor_restrictor, cfg.floor_ballast,
                         provisional=True, note="no rated laps yet")
            )
        return out

    target = quantile(skills, cfg.target_percentile)

    # headroom above the floor
    room_r = max(0.0, cfg.max_restrictor - cfg.floor_restrictor)
    room_b = max(0.0, cfg.max_ballast - cfg.floor_ballast)

    raw: dict[str, tuple[float, float]] = {}
    for g in eff:
        gap = max(0.0, math.exp(target - eff[g]) - 1.0)
        want_r = gap * cfg.restrictor_share
        want_b = gap * (1.0 - cfg.restrictor_share)

        r = want_r / kr if kr > 0 else 0.0
        b = (want_b / kb) * 10.0 if kb > 0 else 0.0

        # If one channel saturates, push the remainder into the other rather
        # than silently under-handicapping the quickest driver.
        if r > room_r:
            spill = (r - room_r) * kr          # fractional laptime not delivered
            r = room_r
            b += (spill / kb) * 10.0 if kb > 0 else 0.0
        if b > room_b:
            spill = (b - room_b) / 10.0 * kb
            b = room_b
            r = min(room_r, r + (spill / kr if kr > 0 else 0.0))

        raw[g] = (r, b)

    # Unrated drivers start on the field median: zero would let a quick newcomer
    # walk it, maximum would be unfair to a slow one.
    if raw:
        med_r = quantile([v[0] for v in raw.values()], 0.5)
        med_b = quantile([v[1] for v in raw.values()], 0.5)
    else:
        med_r = med_b = 0.0

    for g in guids:
        provisional = g not in raw
        r, b = raw.get(g, (med_r, med_b))

        # damp + clamp against what is already applied
        cur_r, cur_b = current.get(g, (None, None))  # type: ignore[assignment]
        if cur_r is not None:
            cur_r_f = max(0.0, float(cur_r) - cfg.floor_restrictor)
            cur_b_f = max(0.0, float(cur_b) - cfg.floor_ballast)
            r = cur_r_f + cfg.damping * (r - cur_r_f)
            b = cur_b_f + cfg.damping * (b - cur_b_f)
            r = max(cur_r_f - cfg.max_restrictor_step, min(cur_r_f + cfg.max_restrictor_step, r))
            b = max(cur_b_f - cfg.max_ballast_step, min(cur_b_f + cfg.max_ballast_step, b))

        r = round(min(room_r, max(0.0, r)) + cfg.floor_restrictor, 1)
        b = round(min(room_b, max(0.0, b)) + cfg.floor_ballast)

        note = ""
        if provisional:
            n = res.skill_n.get(g, 0)
            note = f"provisional ({n}/{cfg.min_laps_for_rating} laps)"
        out.append(Handicap(g, track, car, r, b, provisional, note))

    return out


def recompute_all(store: Store, cfg: Config) -> dict:
    """Full refit, then refresh the handicap cache for every known combination."""
    funnel: dict = {}
    laps = select_laps(store, cfg, stats=funnel)
    res = fit(laps, cfg)

    for guid, s in res.skill.items():
        store.set_skill(guid, s, res.skill_n.get(guid, 0))
    for (track, car), b in res.base.items():
        store.set_track_car(track, car, b, res.base_n.get((track, car), 0))
    for (track, car) in res.k_restrictor:
        store.set_car_sensitivity(
            car,
            res.k_restrictor[(track, car)],
            res.k_ballast[(track, car)],
            res.k_n.get((track, car), 0),
            track=track,
        )
    for (guid, track), v in res.affinity.items():
        store.set_affinity(guid, track, v, res.affinity_n.get((guid, track), 0))

    # Which driver/track/car triples do we care about? Anything with history,
    # plus every driver against every track they have raced (so a returning
    # driver already has a number waiting).
    combos: dict[tuple[str, str], set[str]] = defaultdict(set)
    for lap in laps:
        combos[(lap.track, lap.car)].add(lap.guid)
    all_guids = {d["guid"] for d in store.drivers() if d["enabled"]}
    for key in list(combos):
        combos[key] |= all_guids

    updated = 0
    for (track, car), guids in combos.items():
        current: dict[str, tuple[float, float]] = {}
        manual: set[str] = set()
        for g in guids:
            row = store.get_handicap(g, track, car)
            if row:
                current[g] = (row["restrictor"], row["ballast"])
                if row["manual"]:
                    manual.add(g)
        for h in solve_handicaps(res, cfg, track, car, sorted(guids), current):
            if h.guid in manual:
                continue  # admin pinned this one
            store.set_handicap(h.guid, track, car, h.restrictor, h.ballast)
            updated += 1

    # Everything the engine rejected before a lap ever reached the model,
    # so the GUI can account for every lap in the database.
    rejected = {
        r["reason"]: r["n"]
        for r in store.q(
            "SELECT COALESCE(reason,'unknown') reason, COUNT(*) n FROM laps "
            "WHERE clean=0 GROUP BY reason ORDER BY n DESC"
        )
    }
    total = store.q1("SELECT COUNT(*) n FROM laps")["n"]

    return {
        "laps_used": res.laps_used,
        "drivers_rated": sum(
            1 for g, n in res.skill_n.items() if n >= cfg.min_laps_for_rating
        ),
        "combos": len(combos),
        "handicaps_updated": updated,
        "funnel": {
            "total_laps": total,
            "rejected_by_engine": rejected,
            **funnel,
        },
    }
