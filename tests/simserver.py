"""
A fake Assetto Corsa dedicated server that speaks ACSP.

It drives the real engine over a real UDP socket, so this exercises the codec,
the engine state machine and the model end to end. The packet *encoders* here
are written independently of acbop.protocol's decoders on purpose — if the two
disagree, that is a bug worth catching.

Simulated drivers have a fixed true pace. The sim applies whatever ballast and
restrictor the plugin orders, and reports lap times accordingly. A working
system should make the field converge.
"""

from __future__ import annotations

import asyncio
import math
import random
import socket
import struct

# ---------------------------------------------------------------- encoders

def u32s(s: str) -> bytes:
    return struct.pack("B", len(s)) + s.encode("utf-32-le")


def u8s(s: str) -> bytes:
    b = s.encode("utf-8")
    return struct.pack("B", len(b)) + b


def p_new_session(track: str, config: str, name: str, stype: int, laps: int) -> bytes:
    return (
        struct.pack("BBBBB", 50, 4, 0, 0, 1)
        + u32s("sim server")
        + u8s(track) + u8s(config) + u8s(name)
        + struct.pack("<BHHHBB", stype, 20, laps, 0, 24, 30)
        + u8s("3_clear")
        + struct.pack("<i", 0)
    )


def p_new_connection(name: str, guid: str, car_id: int, model: str) -> bytes:
    return struct.pack("B", 51) + u32s(name) + u32s(guid) + struct.pack("B", car_id) \
        + u8s(model) + u8s("skin")


def p_connection_closed(name: str, guid: str, car_id: int, model: str) -> bytes:
    return struct.pack("B", 52) + u32s(name) + u32s(guid) + struct.pack("B", car_id) \
        + u8s(model) + u8s("skin")


def p_client_loaded(car_id: int) -> bytes:
    return struct.pack("BB", 58, car_id)


def p_car_update(car_id: int, spline: float, speed: float) -> bytes:
    v = speed / 3.6
    return struct.pack("B", 53) + struct.pack("B", car_id) \
        + struct.pack("<fff", 0.0, 0.0, 0.0) \
        + struct.pack("<fff", v, 0.0, 0.0) \
        + struct.pack("<BH", 4, 6000) + struct.pack("<f", spline)


def p_lap_completed(car_id: int, laptime_ms: int, cuts: int, board) -> bytes:
    out = struct.pack("B", 73) + struct.pack("<BIB", car_id, laptime_ms, cuts)
    out += struct.pack("B", len(board))
    for cid, t, laps in board:
        out += struct.pack("<BIHB", cid, t, laps, 1)
    out += struct.pack("<f", 1.0)
    return out


def p_chat(car_id: int, msg: str) -> bytes:
    return struct.pack("BB", 57, car_id) + u32s(msg)


def p_client_event(car_id: int, other: int | None) -> bytes:
    ev = 10 if other is not None else 11
    out = struct.pack("BB", 130, ev, )
    out = struct.pack("B", 130) + struct.pack("BB", ev, car_id)
    if other is not None:
        out += struct.pack("B", other)
    out += struct.pack("<f", 40.0)
    out += struct.pack("<fff", 0, 0, 0) + struct.pack("<fff", 0, 0, 0)
    return out


# ---------------------------------------------------------------- sim model

TRUE_K_RESTRICTOR = 0.0025   # fractional laptime per 1% restrictor
TRUE_K_BALLAST = 0.0015      # fractional laptime per 10 kg

# Per-track overrides, so tests can model a power circuit where a restrictor
# hurts far more than it does somewhere tight and slow.
TRACK_K: dict[str, tuple[float, float]] = {}


def true_k(track: str) -> tuple[float, float]:
    return TRACK_K.get(track, (TRUE_K_RESTRICTOR, TRUE_K_BALLAST))


class SimDriver:
    def __init__(self, car_id: int, name: str, guid: str, model: str, skill: float,
                 affinity: dict[str, float] | None = None):
        self.car_id = car_id
        self.name = name
        self.guid = guid
        self.model = model
        self.skill = skill          # log offset; negative = quicker
        self.affinity = affinity or {}   # per-track offset on top of skill
        self.ballast = 0.0
        self.restrictor = 0.0
        self.laps = 0
        self.spline = 0.0

    def _factor(self, track: str) -> float:
        kr, kb = true_k(track)
        return 1.0 + kr * self.restrictor + kb * (self.ballast / 10.0)

    def laptime_ms(self, base_ms: float, rng: random.Random, track: str = "",
                   noise: float = 0.004) -> int:
        s = self.skill + self.affinity.get(track, 0.0)
        t = base_ms * math.exp(s) * self._factor(track) * math.exp(rng.gauss(0, noise))
        return int(t)

    def effective_skill(self, track: str = "") -> float:
        """True pace including the handicap currently carried."""
        return self.skill + self.affinity.get(track, 0.0) + math.log(self._factor(track))


class SimServer:
    """Sends ACSP packets to the plugin and obeys the admin commands it gets back."""

    def __init__(self, plugin_addr, bind_port: int, drivers, seed: int = 7):
        self.plugin_addr = plugin_addr
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", bind_port))
        self.sock.setblocking(False)
        self.drivers = {d.car_id: d for d in drivers}
        self.rng = random.Random(seed)
        self.admin_log: list[str] = []
        self.chat_to_drivers: list[str] = []

    def send(self, data: bytes) -> None:
        self.sock.sendto(data, self.plugin_addr)

    async def pump(self, seconds: float = 0.25) -> None:
        """Read and act on whatever the plugin has sent us."""
        loop = asyncio.get_running_loop()
        end = loop.time() + seconds
        while loop.time() < end:
            try:
                data, _ = self.sock.recvfrom(4096)
            except BlockingIOError:
                await asyncio.sleep(0.01)
                continue
            self.handle(data)
        await asyncio.sleep(0)

    def handle(self, data: bytes) -> None:
        pid = data[0]
        if pid == 209:  # ADMIN_COMMAND
            n = data[1]
            cmd = data[2 : 2 + n * 4].decode("utf-32-le")
            self.admin_log.append(cmd)
            self.apply_admin(cmd)
        elif pid in (202, 203):  # SEND_CHAT / BROADCAST_CHAT
            off = 2 if pid == 202 else 1
            n = data[off]
            self.chat_to_drivers.append(
                data[off + 1 : off + 1 + n * 4].decode("utf-32-le")
            )

    def apply_admin(self, cmd: str) -> None:
        parts = cmd.split()
        if len(parts) != 3:
            return
        verb, target, value = parts
        try:
            car_id = int(target)
            val = float(value)
        except ValueError:
            return
        d = self.drivers.get(car_id)
        if d is None:
            return
        if verb == "/ballast":
            d.ballast = val
        elif verb == "/restrictor":
            d.restrictor = val

    # -- scripted session ------------------------------------------------

    async def run_session(self, track: str, base_ms: float, n_laps: int,
                          stype: int = 3, join_order=None, cuts_rate: float = 0.12,
                          declared_laps: int | None = None):
        """`declared_laps` is the race distance the server announces; `n_laps` is
        how many we actually simulate. They differ when a test needs a long race
        but only a few laps of it."""
        self.send(p_new_session(track, "", "Race", stype,
                                n_laps if declared_laps is None else declared_laps))
        await self.pump(0.4)

        order = join_order if join_order is not None else list(self.drivers)
        for cid in order:
            d = self.drivers[cid]
            d.laps = 0
            self.send(p_new_connection(d.name, d.guid, d.car_id, d.model))
            await self.pump(0.05)
        for cid in order:
            self.send(p_client_loaded(cid))
            await self.pump(0.05)

        # a moment of green-flag running so the out-lap flag clears properly
        for cid in order:
            self.send(p_car_update(cid, 0.1, 160.0))
        await self.pump(0.2)

        for lap in range(n_laps):
            for cid in order:
                d = self.drivers[cid]
                cuts = 1 if self.rng.random() < cuts_rate else 0
                t = d.laptime_ms(base_ms, self.rng, track)
                d.laps += 1
                board = [(x.car_id, 0, x.laps) for x in self.drivers.values()]
                self.send(p_lap_completed(cid, t, cuts, board))
                self.send(p_car_update(cid, 0.5, 180.0))
            await self.pump(0.15)

        return {d.name: d for d in self.drivers.values()}

    async def end_session(self):
        for cid in list(self.drivers):
            d = self.drivers[cid]
            self.send(p_connection_closed(d.name, d.guid, d.car_id, d.model))
        await self.pump(0.3)
