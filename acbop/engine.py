"""
The plugin engine: owns the UDP socket, the live session state, lap
classification, handicap application and the VSC.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field

from . import protocol as p
from .config import Config
from .db import LapRecord, Store
from .model import recompute_all

log = logging.getLogger("acbop.engine")


@dataclass
class Driver:
    car_id: int
    guid: str
    name: str
    car_model: str
    car_skin: str = ""
    connected_at: float = field(default_factory=time.time)
    loaded: bool = False

    # applied handicap (what the server currently believes)
    restrictor: float = 0.0
    ballast: float = 0.0
    # what it should be once any VSC expires
    base_restrictor: float = 0.0
    base_ballast: float = 0.0

    laps_done: int = 0
    last_laptime_ms: int = 0
    best_laptime_ms: int = 0
    spline: float = 0.0
    speed_kmh: float = 0.0

    last_collision: float = 0.0
    slow_since: float | None = None
    out_lap_pending: bool = True  # first flying lap after joining is an out-lap

    vsc_uses: int = 0
    # Extra penalty currently imposed by an active VSC phase, on top of the
    # driver's normal handicap. Zero for the caller, who is unhandicapped.
    vsc_extra_restrictor: float = 0.0
    vsc_extra_ballast: float = 0.0
    # Set while this driver is the one who called the phase.
    vsc_is_caller: bool = False

    @property
    def progress(self) -> float:
        return self.laps_done + self.spline

    @property
    def in_vsc(self) -> bool:
        return (
            self.vsc_is_caller
            or self.vsc_extra_restrictor > 0
            or self.vsc_extra_ballast > 0
        )

    def to_json(self) -> dict:
        return {
            "car_id": self.car_id,
            "guid": self.guid,
            "name": self.name,
            "car_model": self.car_model,
            "loaded": self.loaded,
            "restrictor": round(self.restrictor, 1),
            "ballast": round(self.ballast),
            "base_restrictor": round(self.base_restrictor, 1),
            "base_ballast": round(self.base_ballast),
            "laps": self.laps_done,
            "last_laptime_ms": self.last_laptime_ms,
            "best_laptime_ms": self.best_laptime_ms,
            "spline": round(self.spline, 4),
            "speed_kmh": round(self.speed_kmh, 1),
            "vsc_caller": self.vsc_is_caller,
            "vsc_slowed": self.vsc_extra_restrictor > 0 or self.vsc_extra_ballast > 0,
            "vsc_extra_restrictor": round(self.vsc_extra_restrictor, 1),
            "vsc_extra_ballast": round(self.vsc_extra_ballast),
            "vsc_uses": self.vsc_uses,
        }


@dataclass
class VscPhase:
    """
    A live safety-car phase.

    The caller runs unhandicapped while everyone ahead is slowed in proportion
    to their gap, so the field concertinas instead of being teleported
    together. Recomputed every tick from live gaps and ended as soon as the
    caller has closed up, or at the hard time limit.
    """

    caller_guid: str
    caller_car_id: int
    started: float
    deadline: float
    start_gap_s: float
    target_gap_s: float

    closed_early: bool = False
    peak_slow: float = 0.0        # strongest slowdown fraction applied so far
    last_gap_s: float = 0.0

    def ramp(self, now: float, ramp_s: float) -> float:
        """Ease in at the start and out as the deadline approaches."""
        if ramp_s <= 0:
            return 1.0
        rise = min(1.0, (now - self.started) / ramp_s)
        fall = min(1.0, max(0.0, (self.deadline - now) / ramp_s))
        return max(0.0, min(rise, fall))

    @property
    def elapsed(self) -> float:
        return time.time() - self.started

    def to_json(self) -> dict:
        now = time.time()
        return {
            "caller_guid": self.caller_guid,
            "caller_car_id": self.caller_car_id,
            "elapsed": round(now - self.started, 1),
            "remaining": round(max(0.0, self.deadline - now), 1),
            "start_gap_s": round(self.start_gap_s, 1),
            "gap_s": round(self.last_gap_s, 1),
            "target_gap_s": round(self.target_gap_s, 1),
            "closed_pct": (
                round(
                    max(
                        0.0,
                        min(
                            100.0,
                            (self.start_gap_s - self.last_gap_s)
                            / max(0.001, self.start_gap_s - self.target_gap_s)
                            * 100,
                        ),
                    )
                )
                if self.start_gap_s > self.target_gap_s
                else 100
            ),
        }


class Engine(asyncio.DatagramProtocol):
    def __init__(self, cfg: Config, store: Store):
        self.cfg = cfg
        self.store = store
        self.transport: asyncio.DatagramTransport | None = None
        self.server_addr = (cfg.server_host, cfg.server_port)

        self.drivers: dict[int, Driver] = {}       # car_id -> Driver
        self.by_guid: dict[str, int] = {}          # guid -> car_id

        self.session: p.SessionInfo | None = None
        self.session_id: int | None = None
        self.session_started = 0.0

        self.connected = False
        self.last_packet_ts = 0.0
        self.packet_counts: dict[str, int] = {}
        self._pending_recompute = False

        # The live VSC phase, or None. One at a time.
        self.vsc: VscPhase | None = None

    # -- transport --------------------------------------------------------

    def connection_made(self, transport) -> None:  # type: ignore[override]
        self.transport = transport
        log.info("listening on %s:%s, server at %s:%s",
                 self.cfg.listen_host, self.cfg.listen_port,
                 self.cfg.server_host, self.cfg.server_port)
        self.send(p.enc_get_session_info(-1))
        self.send(p.enc_realtime_interval(self.cfg.realtime_interval_ms))

    def send(self, data: bytes) -> None:
        if self.transport is None:
            log.warning("send before transport ready")
            return
        self.transport.sendto(data, self.server_addr)

    def admin(self, command: str) -> None:
        self.send(p.enc_admin_command(command))

    def broadcast(self, message: str) -> None:
        self.send(p.enc_broadcast_chat(message))

    def whisper(self, car_id: int, message: str) -> None:
        self.send(p.enc_send_chat(car_id, message))

    def datagram_received(self, data: bytes, addr) -> None:  # type: ignore[override]
        self.last_packet_ts = time.time()
        self.connected = True
        try:
            pid, payload = p.decode(data)
        except p.ProtocolError as exc:
            log.debug("undecodable packet from %s: %s", addr, exc)
            return
        name = p.PACKET_NAMES.get(pid, str(pid))
        self.packet_counts[name] = self.packet_counts.get(name, 0) + 1
        try:
            self.dispatch(pid, payload)
        except Exception:
            log.exception("error handling %s", name)

    # -- dispatch ---------------------------------------------------------

    def dispatch(self, pid: int, m) -> None:
        if pid in (p.NEW_SESSION, p.SESSION_INFO):
            self.on_session(m)
        elif pid == p.NEW_CONNECTION:
            self.on_connect(m)
        elif pid == p.CONNECTION_CLOSED:
            self.on_disconnect(m)
        elif pid == p.CLIENT_LOADED:
            self.on_loaded(m)
        elif pid == p.CAR_UPDATE:
            self.on_car_update(m)
        elif pid == p.CAR_INFO:
            self.on_car_info(m)
        elif pid == p.LAP_COMPLETED:
            self.on_lap(m)
        elif pid == p.CHAT:
            self.on_chat(m)
        elif pid == p.CLIENT_EVENT:
            self.on_client_event(m)
        elif pid == p.END_SESSION:
            self.on_end_session(m)
        elif pid == p.ERROR:
            log.warning("server error: %s", m.message)
            self.store.log("warn", f"server error: {m.message}")

    # -- session ----------------------------------------------------------

    def on_session(self, s: p.SessionInfo) -> None:
        changed = (
            self.session is None
            or s.track_key != self.session.track_key
            or s.session_type != self.session.session_type
            or s.is_new
        )
        self.session = s
        if not changed:
            return

        if self.session_id is not None:
            self.store.close_session(self.session_id)
            if self.cfg.recompute_after_session:
                self._pending_recompute = True

        self.session_id = self.store.open_session(s.track_key, s.type_name, s.name)
        self.session_started = time.time()
        self.store.log("info", f"session: {s.type_name} at {s.track_key}")
        log.info("new session: %s at %s", s.type_name, s.track_key)

        # A fresh session clears penalties server-side, and VSC budget resets.
        for d in self.drivers.values():
            d.restrictor = 0.0
            d.ballast = 0.0
            d.vsc_until = None
            d.vsc_uses = 0
            d.laps_done = 0
            d.out_lap_pending = True
        # re-apply after the server settles
        asyncio.get_event_loop().call_later(3.0, self.apply_all)

        # keep session info fresh (elapsed time, for final-lap checks)
        self.send(p.enc_realtime_interval(self.cfg.realtime_interval_ms))

    def on_end_session(self, m: p.EndSession) -> None:
        log.info("session ended, results: %s", m.results_filename)
        if self.session_id is not None:
            self.store.close_session(self.session_id)
            if self.cfg.recompute_after_session:
                self._pending_recompute = True
            self.session_id = None

    # -- connections ------------------------------------------------------

    def on_connect(self, c: p.Connection) -> None:
        if not c.driver_guid:
            log.warning("connection with no GUID for car %s, ignoring", c.car_id)
            return
        # A reused slot must not inherit the previous occupant's penalties.
        old = self.drivers.get(c.car_id)
        if old and old.guid != c.driver_guid:
            self.clear_penalties(c.car_id)

        d = Driver(
            car_id=c.car_id,
            guid=c.driver_guid,
            name=c.driver_name,
            car_model=c.car_model,
            car_skin=c.car_skin,
        )
        self.drivers[c.car_id] = d
        self.by_guid[c.driver_guid] = c.car_id
        self.store.upsert_driver(c.driver_guid, c.driver_name)
        log.info("connect: %s (%s) car=%s slot=%s", c.driver_name, c.driver_guid,
                 c.car_model, c.car_id)

    def on_disconnect(self, c: p.Connection) -> None:
        d = self.drivers.pop(c.car_id, None)
        if d:
            self.by_guid.pop(d.guid, None)
            log.info("disconnect: %s", d.name)
        # Leave the slot clean for whoever takes it next.
        self.clear_penalties(c.car_id)

    def on_car_info(self, ci: p.CarInfo) -> None:
        if not ci.is_connected:
            return
        d = self.drivers.get(ci.car_id)
        if d is None and ci.driver_guid:
            d = Driver(ci.car_id, ci.driver_guid, ci.driver_name, ci.car_model, ci.car_skin)
            self.drivers[ci.car_id] = d
            self.by_guid[ci.driver_guid] = ci.car_id
            self.store.upsert_driver(ci.driver_guid, ci.driver_name)

    def on_loaded(self, m: p.ClientLoaded) -> None:
        d = self.drivers.get(m.car_id)
        if d is None:
            self.send(p.enc_get_car_info(m.car_id))
            return
        d.loaded = True
        d.out_lap_pending = True
        self.apply_driver(d, announce=self.cfg.announce_handicaps)

    # -- live telemetry ---------------------------------------------------

    def on_car_update(self, u: p.CarUpdate) -> None:
        d = self.drivers.get(u.car_id)
        if d is None:
            return
        d.spline = u.spline
        d.speed_kmh = u.speed_kmh

        # Crude pit detection: AC gives us no pit event over ACSP, so treat a
        # sustained stop as "the next lap is an out-lap".
        now = time.time()
        if u.speed_kmh < 10.0:
            if d.slow_since is None:
                d.slow_since = now
            elif now - d.slow_since > 3.0:
                d.out_lap_pending = True
        else:
            d.slow_since = None

    def on_client_event(self, e: p.ClientEvent) -> None:
        now = time.time()
        d = self.drivers.get(e.car_id)
        if d:
            d.last_collision = now
        if e.is_car_collision and e.other_car_id is not None:
            o = self.drivers.get(e.other_car_id)
            if o:
                o.last_collision = now

    # -- laps -------------------------------------------------------------

    def on_lap(self, lap: p.LapCompleted) -> None:
        d = self.drivers.get(lap.car_id)
        if d is None or self.session is None:
            return

        d.laps_done += 1
        d.last_laptime_ms = lap.laptime_ms

        reason = self._reject_reason(d, lap)
        clean = reason is None
        if clean and (d.best_laptime_ms == 0 or lap.laptime_ms < d.best_laptime_ms):
            d.best_laptime_ms = lap.laptime_ms

        self.store.add_lap(
            self.session_id,
            LapRecord(
                guid=d.guid,
                track=self.session.track_key,
                car_model=d.car_model,
                laptime_ms=lap.laptime_ms,
                restrictor=d.base_restrictor,
                ballast=d.base_ballast,
                cuts=lap.cuts,
                lap_num=d.laps_done,
                clean=clean,
                reason=reason,
            ),
        )

        if d.out_lap_pending:
            d.out_lap_pending = False

    def _reject_reason(self, d: Driver, lap: p.LapCompleted) -> str | None:
        if lap.laptime_ms <= 0 or lap.laptime_ms > 30 * 60 * 1000:
            return "implausible laptime"
        if self.cfg.drop_cut_laps and lap.cuts > 0:
            return f"{lap.cuts} cut(s)"
        if d.out_lap_pending:
            return "out lap"
        if self.vsc is not None or d.in_vsc:
            # Nobody's lap time means anything during a safety car, whether
            # they were boosted, slowed, or merely stuck behind someone slowed.
            return "safety car"
        if time.time() - d.last_collision < self.cfg.collision_cooldown_s:
            return "contact"
        return None

    # -- handicaps --------------------------------------------------------

    def target_for(self, d: Driver) -> tuple[float, float]:
        if self.session is None:
            return 0.0, 0.0
        if not self._applies_to_session():
            return 0.0, 0.0
        row = self.store.get_handicap(d.guid, self.session.track_key, d.car_model)
        if row:
            return float(row["restrictor"]), float(row["ballast"])
        return self.cfg.floor_restrictor, self.cfg.floor_ballast

    def _applies_to_session(self) -> bool:
        if self.session is None:
            return False
        t = self.session.type_name
        return (
            (t == "practice" and self.cfg.apply_in_practice)
            or (t == "qualify" and self.cfg.apply_in_qualify)
            or (t == "race" and self.cfg.apply_in_race)
        )

    def apply_driver(self, d: Driver, announce: bool = False) -> None:
        r, b = self.target_for(d)
        d.base_restrictor, d.base_ballast = r, b

        if self.vsc is not None:
            return  # the live phase owns the values until it ends

        self._push(d, r, b)

        if announce and (r > 0 or b > 0):
            self.whisper(
                d.car_id,
                f"BoP: {b:.0f} kg ballast, {r:.0f}% restrictor. "
                f"Type {self.cfg.vsc_command} once per race to bring out a safety car."
                if self.cfg.vsc_enabled
                else f"BoP: {b:.0f} kg ballast, {r:.0f}% restrictor.",
            )

    def _push(self, d: Driver, r: float, b: float, force: bool = False) -> None:
        """Send admin commands, respecting the deadband."""
        if force or abs(r - d.restrictor) >= self.cfg.deadband_restrictor:
            self.admin(f"/restrictor {d.car_id} {r:.0f}")
            d.restrictor = r
        if force or abs(b - d.ballast) >= self.cfg.deadband_ballast:
            self.admin(f"/ballast {d.car_id} {b:.0f}")
            d.ballast = b

    def clear_penalties(self, car_id: int) -> None:
        self.admin(f"/ballast {car_id} 0")
        self.admin(f"/restrictor {car_id} 0")

    def apply_all(self, announce: bool = False) -> None:
        for d in list(self.drivers.values()):
            if d.loaded:
                self.apply_driver(d, announce=announce)

    # -- VSC --------------------------------------------------------------

    def on_chat(self, c: p.Chat) -> None:
        msg = c.message.strip()
        if not msg:
            return
        low = msg.lower()
        if low == self.cfg.vsc_command.lower():
            self.handle_vsc(c.car_id)
        elif low in ("!bop", "!handicap"):
            d = self.drivers.get(c.car_id)
            if d:
                self.whisper(
                    c.car_id,
                    f"Your BoP: {d.base_ballast:.0f} kg / {d.base_restrictor:.0f}%",
                )
        elif low in ("!gap", "!gaps"):
            d = self.drivers.get(c.car_id)
            if d:
                g = self.gap_ahead_seconds(d)
                self.whisper(
                    c.car_id,
                    f"Gap to car ahead: {g:.1f}s" if g is not None else "You are leading.",
                )
        elif low == "!help":
            self.whisper(
                c.car_id,
                f"{self.cfg.vsc_command} = call a safety car to close up "
                f"(once per race) | !bop = your handicap | !gap = gap ahead",
            )

    def _lap_reference_ms(self, d: Driver | None = None) -> float:
        """A lap time to convert track-position deltas into seconds."""
        if d is not None and (d.best_laptime_ms or d.last_laptime_ms):
            return float(d.best_laptime_ms or d.last_laptime_ms)
        times = [
            o.best_laptime_ms or o.last_laptime_ms
            for o in self.drivers.values()
            if o.best_laptime_ms or o.last_laptime_ms
        ]
        return float(min(times)) if times else 0.0

    def gap_ahead_seconds(self, d: Driver) -> float | None:
        """Estimated gap to the car directly in front, in seconds."""
        ahead = [
            o for o in self.drivers.values()
            if o is not d and o.loaded and o.progress > d.progress
        ]
        if not ahead:
            return None
        nearest = min(ahead, key=lambda o: o.progress - d.progress)
        ref = self._lap_reference_ms(d)
        if not ref:
            return None
        return (nearest.progress - d.progress) * (ref / 1000.0)

    def gap_to_leader_seconds(self, d: Driver) -> float | None:
        """Estimated gap from `d` back to the race leader, in seconds."""
        others = [o for o in self.drivers.values() if o.loaded]
        if not others:
            return None
        leader = max(others, key=lambda o: o.progress)
        if leader is d:
            return None
        ref = self._lap_reference_ms(d)
        if not ref:
            return None
        return (leader.progress - d.progress) * (ref / 1000.0)

    # -- safety car -------------------------------------------------------

    def handle_vsc(self, car_id: int) -> None:
        d = self.drivers.get(car_id)
        if d is None:
            return
        reason = self._vsc_refusal(d)
        if reason:
            self.whisper(car_id, f"Safety car unavailable: {reason}")
            return

        cfg = self.cfg
        now = time.time()
        gap = self.gap_ahead_seconds(d) or 0.0

        d.vsc_uses += 1
        if self.session_id is not None:
            self.store.vsc_mark_used(self.session_id, d.guid)

        self.vsc = VscPhase(
            caller_guid=d.guid,
            caller_car_id=d.car_id,
            started=now,
            deadline=now + cfg.vsc_max_duration_s,
            start_gap_s=gap,
            target_gap_s=cfg.vsc_target_gap_s,
            last_gap_s=gap,
        )
        d.vsc_is_caller = True

        eta = self.vsc_closure_eta(d)
        when = (
            f"~{min(eta, cfg.vsc_max_duration_s):.0f}s"
            if eta is not None
            else f"up to {cfg.vsc_max_duration_s:.0f}s"
        )
        self.broadcast(
            f"SAFETY CAR: {d.name} is {gap:.0f}s back. Cars ahead are held "
            f"until the gap is under {cfg.vsc_target_gap_s:.0f}s ({when})."
        )
        self.store.log(
            "info",
            f"safety car called by {d.name}, {gap:.1f}s behind, eta {when}",
        )
        log.info("VSC phase: caller=%s gap=%.1fs eta=%s", d.name, gap, when)
        self.tick_vsc()  # apply immediately rather than waiting a tick

    def _vsc_refusal(self, d: Driver) -> str | None:
        cfg = self.cfg
        if not cfg.vsc_enabled:
            return "disabled"
        if self.session is None:
            return "no session"
        if cfg.vsc_race_only and self.session.type_name != "race":
            return "race sessions only"
        if self.vsc is not None:
            return "one is already running"
        if d.vsc_uses >= cfg.vsc_per_session:
            return "already used this race"
        if self.session_id is not None and self.store.vsc_was_used(self.session_id, d.guid):
            return "already used this race"
        if d.laps_done < cfg.vsc_min_lap - 1:
            return f"not before lap {cfg.vsc_min_lap}"
        if cfg.vsc_forbid_final_lap and self.session.laps:
            if d.laps_done >= self.session.laps - 1:
                return "not on the final lap"
        gap = self.gap_ahead_seconds(d)
        if gap is None:
            return "you are leading"
        if gap < cfg.vsc_min_gap_s:
            return f"gap is only {gap:.1f}s (need {cfg.vsc_min_gap_s:.0f}s)"
        return None

    def _vsc_sensitivity(self) -> tuple[float, float]:
        """Learned laptime cost per 1% restrictor and per 10 kg, for this track."""
        kr, kb = self.cfg.prior_k_restrictor, self.cfg.prior_k_ballast
        if self.session is None:
            return kr, kb
        track = self.session.track_key
        cars = [d.car_model for d in self.drivers.values()]
        sens = self.store.car_sensitivities()
        for car in cars:
            row = sens.get((track, car)) or sens.get(("", car))
            if row and row["k_restrictor"] and row["k_ballast"]:
                return float(row["k_restrictor"]), float(row["k_ballast"])
        return kr, kb

    def _vsc_gap_to_caller(self, caller: Driver, other: Driver) -> float:
        """Seconds `other` is ahead of `caller`. Negative if behind."""
        ref = self._lap_reference_ms(caller)
        if not ref:
            return 0.0
        return (other.progress - caller.progress) * (ref / 1000.0)

    def _vsc_slowdowns(self, caller: Driver) -> dict[int, float]:
        """
        Fractional pace loss for every car, solved from live gaps.

        The reference is the gap the caller actually has to close: the one to
        the car directly ahead, since that is what ends the phase. A car that
        far ahead or further is slowed as hard as allowed, so the caller closes
        at the maximum rate. Cars nearer than the reference — which only
        happens in whole-field mode, or mid-phase as the order shuffles — are
        slowed pro rata, so they are not punished for being close by.

        Anchoring on the leader instead would be wrong: a leader a lap and a
        half up would dilute everyone else's penalty to nothing and the caller
        would never catch the car in front of them.
        """
        cfg = self.cfg
        gaps: dict[int, float] = {}
        for o in self.drivers.values():
            if o is caller or not o.loaded:
                continue
            gap = self._vsc_gap_to_caller(caller, o)
            if gap <= 0 and not cfg.vsc_slow_whole_field:
                continue
            gaps[o.car_id] = abs(gap)
        if not gaps:
            return {}

        if cfg.vsc_compress_pack:
            # Grade against the biggest gap in the field, so the leader is held
            # hardest and the pack bunches. Costs closure rate for the caller.
            reference = max(gaps.values())
        else:
            ahead = [
                g for cid, g in gaps.items()
                if self._vsc_gap_to_caller(caller, self.drivers[cid]) > 0
            ]
            reference = min(ahead) if ahead else max(gaps.values())
        # Never reference a gap so small the whole phase is pointless.
        reference = max(reference, cfg.vsc_target_gap_s, 0.5)

        return {
            cid: cfg.vsc_max_slowdown * min(1.0, g / reference)
            for cid, g in gaps.items()
        }

    def vsc_closure_eta(self, caller: Driver) -> float | None:
        """
        Seconds of running needed to bring the caller to the target gap, at the
        current slowdown. Physics, not a guess: if the car ahead runs at
        (1 + s) times the caller's lap time, the caller gains s/(1+s) seconds
        for every second of running.
        """
        gap = self.gap_ahead_seconds(caller)
        if gap is None:
            return None
        to_close = gap - self.cfg.vsc_target_gap_s
        if to_close <= 0:
            return 0.0
        s = self._vsc_slowdowns(caller)
        ahead = [
            o for o in self.drivers.values()
            if o.loaded and o is not caller and o.progress > caller.progress
        ]
        if not ahead:
            return None
        nearest = min(ahead, key=lambda o: o.progress - caller.progress)
        slow = s.get(nearest.car_id, 0.0)
        if slow <= 0:
            return None
        return to_close / (slow / (1.0 + slow))

    def _vsc_penalty(self, slowdown: float) -> tuple[float, float]:
        """
        Convert a wanted fractional pace loss into restrictor % and ballast kg,
        using the learned sensitivity for this track and car.

        Split proportionally to each channel's headroom so neither saturates
        long before the other.
        """
        cfg = self.cfg
        if slowdown <= 0:
            return 0.0, 0.0
        kr, kb = self._vsc_sensitivity()

        # What each channel could deliver on its own at full lock.
        cap_r = kr * cfg.vsc_max_extra_restrictor
        cap_b = kb * (cfg.vsc_max_extra_ballast / 10.0)
        total = cap_r + cap_b
        if total <= 0:
            return 0.0, 0.0

        share_r = cap_r / total
        want_r = slowdown * share_r
        want_b = slowdown * (1.0 - share_r)

        r = want_r / kr if kr > 0 else 0.0
        b = (want_b / kb) * 10.0 if kb > 0 else 0.0
        return (
            min(cfg.vsc_max_extra_restrictor, r),
            min(cfg.vsc_max_extra_ballast, b),
        )

    def tick_vsc(self) -> None:
        """Recompute the whole phase from live gaps. Called every tick."""
        phase = self.vsc
        if phase is None:
            return

        cfg = self.cfg
        now = time.time()
        caller = self.drivers.get(phase.caller_car_id)

        # Caller gone (disconnected or slot reused) — abandon the phase.
        if caller is None or caller.guid != phase.caller_guid:
            self._end_vsc("caller left")
            return

        gap = self.gap_ahead_seconds(caller)
        phase.last_gap_s = gap if gap is not None else 0.0

        if gap is None:
            self._end_vsc(f"{caller.name} is now leading")
            return
        if gap <= phase.target_gap_s:
            phase.closed_early = True
            self._end_vsc(f"{caller.name} has closed to {gap:.1f}s")
            return
        if now >= phase.deadline:
            self._end_vsc(f"time limit reached, gap {gap:.1f}s")
            return

        ramp = phase.ramp(now, cfg.vsc_ramp_s)

        # The caller runs with no handicap at all.
        caller.vsc_extra_restrictor = 0.0
        caller.vsc_extra_ballast = 0.0
        self._push(caller, 0.0, 0.0)

        slowdowns = self._vsc_slowdowns(caller)
        for o in self.drivers.values():
            if o is caller or not o.loaded:
                continue
            slowdown = slowdowns.get(o.car_id, 0.0) * ramp
            er, eb = self._vsc_penalty(slowdown)
            o.vsc_extra_restrictor = er
            o.vsc_extra_ballast = eb
            phase.peak_slow = max(phase.peak_slow, slowdown)
            # AC's own ceilings are 100% and 5000 kg.
            r = min(100.0, o.base_restrictor + er)
            b = min(5000.0, o.base_ballast + eb)
            self._push(o, r, b)

    def _end_vsc(self, why: str) -> None:
        phase = self.vsc
        self.vsc = None
        if phase is None:
            return
        for d in self.drivers.values():
            d.vsc_is_caller = False
            d.vsc_extra_restrictor = 0.0
            d.vsc_extra_ballast = 0.0
            if d.loaded:
                self._push(d, d.base_restrictor, d.base_ballast, force=True)
            # Lap times were meaningless during the phase; make the next one
            # an out-lap so a slowed driver's crawl never reaches the model.
            d.out_lap_pending = True
        self.broadcast(f"SAFETY CAR ENDING: {why}. Handicaps restored.")
        self.store.log("info", f"safety car ended: {why}")
        log.info("VSC ended after %.0fs: %s", phase.elapsed, why)

    # -- background -------------------------------------------------------

    async def run_background(self) -> None:
        """Housekeeping loop: safety car ticks, keepalive, deferred recomputes."""
        last_keepalive = 0.0
        while True:
            try:
                # An active phase is recomputed from live gaps every tick.
                self.tick_vsc()

                if self._pending_recompute:
                    self._pending_recompute = False
                    await self.recompute()

                # keepalive: if the server has gone quiet, re-arm realtime
                now = time.time()
                if (
                    self.last_packet_ts
                    and now - self.last_packet_ts > 30
                    and now - last_keepalive > 10
                ):
                    last_keepalive = now
                    self.connected = False
                    self.send(p.enc_get_session_info(-1))
                    self.send(p.enc_realtime_interval(self.cfg.realtime_interval_ms))
            except Exception:
                log.exception("background tick failed")
            await asyncio.sleep(max(0.2, self.cfg.vsc_tick_s))

    async def recompute(self) -> dict:
        loop = asyncio.get_running_loop()
        stats = await loop.run_in_executor(None, recompute_all, self.store, self.cfg)
        self.store.log(
            "info",
            f"model refit: {stats['laps_used']} laps, "
            f"{stats['drivers_rated']} rated drivers, "
            f"{stats['handicaps_updated']} handicaps updated",
        )
        log.info("recompute: %s", stats)
        return stats

    # -- introspection for the web UI -------------------------------------

    def state(self) -> dict:
        return {
            "connected": self.connected,
            "last_packet_age": (
                round(time.time() - self.last_packet_ts, 1) if self.last_packet_ts else None
            ),
            "session": (
                {
                    "track": self.session.track_key,
                    "type": self.session.type_name,
                    "name": self.session.name,
                    "laps": self.session.laps,
                    "time_minutes": self.session.time_minutes,
                    "id": self.session_id,
                    "applies": self._applies_to_session(),
                }
                if self.session
                else None
            ),
            "vsc": (
                dict(
                    self.vsc.to_json(),
                    eta=(
                        round(e, 1)
                        if (c := self.drivers.get(self.vsc.caller_car_id)) is not None
                        and (e := self.vsc_closure_eta(c)) is not None
                        else None
                    ),
                    caller_name=(
                        c.name
                        if (c := self.drivers.get(self.vsc.caller_car_id))
                        else "?"
                    ),
                )
                if self.vsc
                else None
            ),
            "drivers": [
                dict(
                    d.to_json(),
                    gap_ahead=(
                        round(g, 1)
                        if (g := self.gap_ahead_seconds(d)) is not None
                        else None
                    ),
                )
                for d in sorted(self.drivers.values(), key=lambda x: -x.progress)
            ],
            "packets": self.packet_counts,
        }
