"""
Assetto Corsa Server Protocol (ACSP) codec.

The AC dedicated server exposes a UDP plugin interface. This module turns the
wire format into dataclasses and back.

String encoding is the main trap:
  * Most strings are length-prefixed UTF-32 little endian. The length byte is
    the number of CHARACTERS, not bytes.
  * A few fields (track, car model, skin in some packets) are length-prefixed
    UTF-8 instead. There is no flag telling you which; it is per-field and you
    just have to know. The layouts below encode that knowledge.
  * The server pads driver names with a trailing '%' in some builds. Stripped.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Any

# ---------------------------------------------------------------------------
# Packet identifiers
# ---------------------------------------------------------------------------

# server -> plugin
NEW_SESSION = 50
NEW_CONNECTION = 51
CONNECTION_CLOSED = 52
CAR_UPDATE = 53
CAR_INFO = 54
END_SESSION = 55
VERSION = 56
CHAT = 57
CLIENT_LOADED = 58
SESSION_INFO = 59
ERROR = 60
LAP_COMPLETED = 73
CLIENT_EVENT = 130

# client event subtypes
CE_COLLISION_WITH_CAR = 10
CE_COLLISION_WITH_ENV = 11

# plugin -> server
REALTIMEPOS_INTERVAL_MS = 200
GET_CAR_INFO = 201
SEND_CHAT = 202
BROADCAST_CHAT = 203
GET_SESSION_INFO = 204
SET_SESSION_INFO = 205
KICK_USER = 206
NEXT_SESSION = 207
RESTART_SESSION = 208
ADMIN_COMMAND = 209

PACKET_NAMES = {
    NEW_SESSION: "new_session",
    NEW_CONNECTION: "new_connection",
    CONNECTION_CLOSED: "connection_closed",
    CAR_UPDATE: "car_update",
    CAR_INFO: "car_info",
    END_SESSION: "end_session",
    VERSION: "version",
    CHAT: "chat",
    CLIENT_LOADED: "client_loaded",
    SESSION_INFO: "session_info",
    ERROR: "error",
    LAP_COMPLETED: "lap_completed",
    CLIENT_EVENT: "client_event",
}


class ProtocolError(Exception):
    pass


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------


class Reader:
    """Sequential cursor over a received datagram."""

    __slots__ = ("buf", "pos")

    def __init__(self, buf: bytes):
        self.buf = buf
        self.pos = 0

    def _take(self, n: int) -> bytes:
        if self.pos + n > len(self.buf):
            raise ProtocolError(
                f"truncated packet: wanted {n} bytes at {self.pos}, "
                f"have {len(self.buf) - self.pos}"
            )
        chunk = self.buf[self.pos : self.pos + n]
        self.pos += n
        return chunk

    def u8(self) -> int:
        return self._take(1)[0]

    def u16(self) -> int:
        return struct.unpack("<H", self._take(2))[0]

    def i16(self) -> int:
        return struct.unpack("<h", self._take(2))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self._take(4))[0]

    def i32(self) -> int:
        return struct.unpack("<i", self._take(4))[0]

    def f32(self) -> float:
        return struct.unpack("<f", self._take(4))[0]

    def vec3(self) -> tuple[float, float, float]:
        return struct.unpack("<fff", self._take(12))

    def utf32(self) -> str:
        n = self.u8()
        if n == 0xFF:  # some builds use 0xff as "empty"
            return ""
        raw = self._take(n * 4)
        return _clean(raw.decode("utf-32-le", errors="replace"))

    def utf8(self) -> str:
        n = self.u8()
        raw = self._take(n)
        return _clean(raw.decode("utf-8", errors="replace"))

    def remaining(self) -> int:
        return len(self.buf) - self.pos


def _clean(s: str) -> str:
    # AC pads some strings with '%' and NULs depending on build.
    return s.replace("\x00", "").rstrip("%").strip()


# ---------------------------------------------------------------------------
# Decoded packet types
# ---------------------------------------------------------------------------


@dataclass
class SessionInfo:
    protocol_version: int
    session_index: int
    current_session_index: int
    session_count: int
    server_name: str
    track: str
    track_config: str
    name: str
    session_type: int  # 1=practice 2=qualify 3=race
    time_minutes: int
    laps: int
    wait_time: int
    ambient_temp: int
    road_temp: int
    weather: str
    elapsed_ms: int
    is_new: bool = False

    @property
    def track_key(self) -> str:
        return f"{self.track}/{self.track_config}" if self.track_config else self.track

    @property
    def type_name(self) -> str:
        return {1: "practice", 2: "qualify", 3: "race"}.get(self.session_type, "other")


@dataclass
class Connection:
    driver_name: str
    driver_guid: str
    car_id: int
    car_model: str
    car_skin: str
    closed: bool = False


@dataclass
class CarInfo:
    car_id: int
    is_connected: bool
    car_model: str
    car_skin: str
    driver_name: str
    driver_team: str
    driver_guid: str


@dataclass
class CarUpdate:
    car_id: int
    pos: tuple[float, float, float]
    velocity: tuple[float, float, float]
    gear: int
    rpm: int
    spline: float

    @property
    def speed_kmh(self) -> float:
        vx, vy, vz = self.velocity
        return (vx * vx + vy * vy + vz * vz) ** 0.5 * 3.6


@dataclass
class LeaderboardEntry:
    car_id: int
    laptime_ms: int
    laps: int
    completed: bool


@dataclass
class LapCompleted:
    car_id: int
    laptime_ms: int
    cuts: int
    leaderboard: list[LeaderboardEntry] = field(default_factory=list)
    grip: float = 1.0


@dataclass
class Chat:
    car_id: int
    message: str


@dataclass
class ClientLoaded:
    car_id: int


@dataclass
class ClientEvent:
    ev_type: int
    car_id: int
    other_car_id: int | None
    impact_speed: float
    world_pos: tuple[float, float, float]
    rel_pos: tuple[float, float, float]

    @property
    def is_car_collision(self) -> bool:
        return self.ev_type == CE_COLLISION_WITH_CAR


@dataclass
class EndSession:
    results_filename: str


@dataclass
class ServerError:
    message: str


@dataclass
class ServerVersion:
    version: int


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------


def _read_session(r: Reader, is_new: bool) -> SessionInfo:
    return SessionInfo(
        protocol_version=r.u8(),
        session_index=r.u8(),
        current_session_index=r.u8(),
        session_count=r.u8(),
        server_name=r.utf32(),
        track=r.utf8(),
        track_config=r.utf8(),
        name=r.utf8(),
        session_type=r.u8(),
        time_minutes=r.u16(),
        laps=r.u16(),
        wait_time=r.u16(),
        ambient_temp=r.u8(),
        road_temp=r.u8(),
        weather=r.utf8(),
        elapsed_ms=r.i32(),
        is_new=is_new,
    )


def _read_connection(r: Reader, closed: bool) -> Connection:
    return Connection(
        driver_name=r.utf32(),
        driver_guid=r.utf32(),
        car_id=r.u8(),
        car_model=r.utf8(),
        car_skin=r.utf8(),
        closed=closed,
    )


def _read_lap(r: Reader) -> LapCompleted:
    car_id = r.u8()
    laptime = r.u32()
    cuts = r.u8()
    n = r.u8()
    board = []
    for _ in range(n):
        board.append(
            LeaderboardEntry(
                car_id=r.u8(),
                laptime_ms=r.u32(),
                laps=r.u16(),
                completed=bool(r.u8()),
            )
        )
    grip = r.f32() if r.remaining() >= 4 else 1.0
    return LapCompleted(car_id, laptime, cuts, board, grip)


def _read_client_event(r: Reader) -> ClientEvent:
    ev_type = r.u8()
    car_id = r.u8()
    other = r.u8() if ev_type == CE_COLLISION_WITH_CAR else None
    speed = r.f32()
    world = r.vec3()
    rel = r.vec3()
    return ClientEvent(ev_type, car_id, other, speed, world, rel)


def decode(data: bytes) -> tuple[int, Any]:
    """Decode a datagram. Returns (packet_id, payload_object)."""
    if not data:
        raise ProtocolError("empty datagram")
    r = Reader(data)
    pid = r.u8()

    if pid == NEW_SESSION:
        return pid, _read_session(r, True)
    if pid == SESSION_INFO:
        return pid, _read_session(r, False)
    if pid == NEW_CONNECTION:
        return pid, _read_connection(r, False)
    if pid == CONNECTION_CLOSED:
        return pid, _read_connection(r, True)
    if pid == CAR_UPDATE:
        return pid, CarUpdate(
            car_id=r.u8(),
            pos=r.vec3(),
            velocity=r.vec3(),
            gear=r.u8(),
            rpm=r.u16(),
            spline=r.f32(),
        )
    if pid == CAR_INFO:
        return pid, CarInfo(
            car_id=r.u8(),
            is_connected=bool(r.u8()),
            car_model=r.utf32(),
            car_skin=r.utf32(),
            driver_name=r.utf32(),
            driver_team=r.utf32(),
            driver_guid=r.utf32(),
        )
    if pid == LAP_COMPLETED:
        return pid, _read_lap(r)
    if pid == CHAT:
        return pid, Chat(car_id=r.u8(), message=r.utf32())
    if pid == CLIENT_LOADED:
        return pid, ClientLoaded(car_id=r.u8())
    if pid == CLIENT_EVENT:
        return pid, _read_client_event(r)
    if pid == END_SESSION:
        return pid, EndSession(results_filename=r.utf32())
    if pid == ERROR:
        return pid, ServerError(message=r.utf32())
    if pid == VERSION:
        return pid, ServerVersion(version=r.u8())

    raise ProtocolError(f"unknown packet id {pid}")


# ---------------------------------------------------------------------------
# Encoding (plugin -> server)
# ---------------------------------------------------------------------------


def _utf32(s: str) -> bytes:
    """Length-prefixed UTF-32LE. Length is in characters."""
    # Non-BMP characters would break the char count; AC can't render them anyway.
    s = "".join(ch for ch in s if ord(ch) < 0x10000)
    if len(s) > 255:
        s = s[:255]
    return struct.pack("B", len(s)) + s.encode("utf-32-le")


def enc_realtime_interval(ms: int) -> bytes:
    return struct.pack("<BH", REALTIMEPOS_INTERVAL_MS, max(0, min(65535, ms)))


def enc_get_car_info(car_id: int) -> bytes:
    return struct.pack("BB", GET_CAR_INFO, car_id)


def enc_get_session_info(session_index: int = -1) -> bytes:
    return struct.pack("<Bh", GET_SESSION_INFO, session_index)


def enc_send_chat(car_id: int, message: str) -> bytes:
    return struct.pack("BB", SEND_CHAT, car_id) + _utf32(message)


def enc_broadcast_chat(message: str) -> bytes:
    return struct.pack("B", BROADCAST_CHAT) + _utf32(message)


def enc_admin_command(command: str) -> bytes:
    """Run `command` as if an admin typed it in chat. No /admin login needed."""
    return struct.pack("B", ADMIN_COMMAND) + _utf32(command)


def enc_kick(car_id: int) -> bytes:
    return struct.pack("BB", KICK_USER, car_id)


def enc_next_session() -> bytes:
    return struct.pack("B", NEXT_SESSION)


def enc_restart_session() -> bytes:
    return struct.pack("B", RESTART_SESSION)
