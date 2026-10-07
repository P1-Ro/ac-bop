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

    vsc_until: float | None = None
    vsc_uses: int = 0

    @property
    def progress(self) -> float:
        return self.laps_done + self.spline

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
            "vsc_active": self.vsc_until is not None,
            "vsc_remaining": (
                round(self.vsc_until - time.time(), 1) if self.vsc_until else 0
            ),
            "vsc_uses": self.vsc_uses,
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
        if d.vsc_until is not None:
            return "VSC active"
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

        if d.vsc_until is not None:
            return  # VSC owns the values until it expires

        self._push(d, r, b)

        if announce and (r > 0 or b > 0):
            self.whisper(
                d.car_id,
                f"BoP: {b:.0f} kg ballast, {r:.0f}% restrictor. "
                f"Type {self.cfg.vsc_command} once per race to catch up."
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
        elif low == "!help":
            self.whisper(
                c.car_id,
                f"{self.cfg.vsc_command} = catch-up boost (once per race) | "
                f"!bop = show your handicap",
            )

    def gap_ahead_seconds(self, d: Driver) -> float | None:
        """Estimated gap to the car in front, in seconds."""
        others = [o for o in self.drivers.values() if o is not d and o.loaded]
        ahead = [o for o in others if o.progress > d.progress]
        if not ahead:
            return None
        nearest = min(ahead, key=lambda o: o.progress - d.progress)
        delta_laps = nearest.progress - d.progress
        ref = d.best_laptime_ms or d.last_laptime_ms
        if not ref:
            ref = min((o.best_laptime_ms for o in others if o.best_laptime_ms), default=0)
        if not ref:
            return None
        return delta_laps * (ref / 1000.0)

    def handle_vsc(self, car_id: int) -> None:
        d = self.drivers.get(car_id)
        if d is None:
            return
        reason = self._vsc_refusal(d)
        if reason:
            self.whisper(car_id, f"Catch-up unavailable: {reason}")
            return

        d.vsc_uses += 1
        if self.session_id is not None:
            self.store.vsc_mark_used(self.session_id, d.guid)
        d.vsc_until = time.time() + self.cfg.vsc_duration_s

        self._push(d, 0.0, 0.0, force=True)
        self.broadcast(
            f"CATCH-UP: {d.name} runs clean for {self.cfg.vsc_duration_s:.0f}s"
        )
        self.store.log("info", f"VSC used by {d.name}")
        log.info("VSC: %s for %.0fs", d.name, self.cfg.vsc_duration_s)

    def _vsc_refusal(self, d: Driver) -> str | None:
        cfg = self.cfg
        if not cfg.vsc_enabled:
            return "disabled"
        if self.session is None:
            return "no session"
        if cfg.vsc_race_only and self.session.type_name != "race":
            return "race sessions only"
        if d.vsc_until is not None:
            return "already active"
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

    def tick_vsc(self) -> None:
        now = time.time()
        for d in self.drivers.values():
            if d.vsc_until is not None and now >= d.vsc_until:
                d.vsc_until = None
                self._push(d, d.base_restrictor, d.base_ballast, force=True)
                self.whisper(d.car_id, "Catch-up over, BoP restored.")

    # -- background -------------------------------------------------------

    async def run_background(self) -> None:
        """Housekeeping loop: VSC expiry, keepalive, deferred recomputes."""
        while True:
            try:
                self.tick_vsc()

                if self._pending_recompute:
                    self._pending_recompute = False
                    await self.recompute()

                # keepalive: if the server has gone quiet, re-arm realtime
                if self.last_packet_ts and time.time() - self.last_packet_ts > 30:
                    self.connected = False
                    self.send(p.enc_get_session_info(-1))
                    self.send(p.enc_realtime_interval(self.cfg.realtime_interval_ms))
            except Exception:
                log.exception("background tick failed")
            await asyncio.sleep(1.0)

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
            "drivers": [
                d.to_json()
                for d in sorted(self.drivers.values(), key=lambda x: -x.progress)
            ],
            "packets": self.packet_counts,
        }
