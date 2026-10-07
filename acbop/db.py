"""SQLite store for laps, ratings and handicaps."""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS drivers (
    guid         TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    skill        REAL,              -- log-time offset; higher = slower
    skill_n      INTEGER DEFAULT 0, -- laps behind the estimate
    first_seen   REAL,
    last_seen    REAL,
    enabled      INTEGER DEFAULT 1  -- 0 = excluded from BoP entirely
);

CREATE TABLE IF NOT EXISTS sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    track        TEXT NOT NULL,
    session_type TEXT NOT NULL,
    name         TEXT,
    started      REAL NOT NULL,
    ended        REAL
);

CREATE TABLE IF NOT EXISTS laps (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER REFERENCES sessions(id),
    guid        TEXT NOT NULL,
    track       TEXT NOT NULL,
    car_model   TEXT NOT NULL,
    laptime_ms  INTEGER NOT NULL,
    cuts        INTEGER NOT NULL DEFAULT 0,
    restrictor  REAL NOT NULL DEFAULT 0,
    ballast     REAL NOT NULL DEFAULT 0,
    lap_num     INTEGER NOT NULL DEFAULT 0,
    clean       INTEGER NOT NULL DEFAULT 1,   -- passed all filters
    reason      TEXT,                          -- why it was rejected
    ts          REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_laps_lookup ON laps(track, car_model, clean);
CREATE INDEX IF NOT EXISTS idx_laps_guid ON laps(guid, clean);

CREATE TABLE IF NOT EXISTS track_car (
    track       TEXT NOT NULL,
    car_model   TEXT NOT NULL,
    base_log    REAL,         -- log(reference laptime in ms)
    samples     INTEGER DEFAULT 0,
    PRIMARY KEY (track, car_model)
);

-- How much lap time a unit of handicap actually costs. Keyed by track AND car,
-- because a restrictor is worth far more at Monza than at a tight circuit.
-- track='' holds the car-level average that per-track rows shrink toward.
CREATE TABLE IF NOT EXISTS car_sensitivity (
    track        TEXT NOT NULL DEFAULT '',
    car_model    TEXT NOT NULL,
    k_restrictor REAL,   -- fractional laptime gain per 1% restrictor
    k_ballast    REAL,   -- fractional laptime gain per 10 kg ballast
    samples      INTEGER DEFAULT 0,
    PRIMARY KEY (track, car_model)
);

-- Driver-by-track affinity: some people are simply better at some circuits.
-- Heavily shrunk toward zero so it needs real evidence to move.
CREATE TABLE IF NOT EXISTS affinity (
    guid        TEXT NOT NULL,
    track       TEXT NOT NULL,
    value       REAL NOT NULL DEFAULT 0,
    samples     INTEGER DEFAULT 0,
    PRIMARY KEY (guid, track)
);

-- Materialised cache: what to apply the moment a driver loads in.
CREATE TABLE IF NOT EXISTS handicaps (
    guid        TEXT NOT NULL,
    track       TEXT NOT NULL,
    car_model   TEXT NOT NULL,
    restrictor  REAL NOT NULL DEFAULT 0,
    ballast     REAL NOT NULL DEFAULT 0,
    manual      INTEGER NOT NULL DEFAULT 0,  -- 1 = pinned by an admin, never auto-updated
    updated     REAL,
    PRIMARY KEY (guid, track, car_model)
);

CREATE TABLE IF NOT EXISTS vsc_used (
    session_id  INTEGER NOT NULL,
    guid        TEXT NOT NULL,
    ts          REAL NOT NULL,
    PRIMARY KEY (session_id, guid)
);

CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          REAL NOT NULL,
    level       TEXT NOT NULL,
    message     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
"""


@dataclass
class LapRecord:
    guid: str
    track: str
    car_model: str
    laptime_ms: int
    restrictor: float
    ballast: float
    cuts: int = 0
    lap_num: int = 0
    clean: bool = True
    reason: str | None = None


class Store:
    def __init__(self, path: str | Path):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    # -- generic ----------------------------------------------------------

    def q(self, sql: str, args: Iterable[Any] = ()) -> list[sqlite3.Row]:
        return self.conn.execute(sql, tuple(args)).fetchall()

    def q1(self, sql: str, args: Iterable[Any] = ()) -> sqlite3.Row | None:
        return self.conn.execute(sql, tuple(args)).fetchone()

    def x(self, sql: str, args: Iterable[Any] = ()) -> sqlite3.Cursor:
        cur = self.conn.execute(sql, tuple(args))
        self.conn.commit()
        return cur

    # -- settings ---------------------------------------------------------

    def get_setting(self, key: str, default: str | None = None) -> str | None:
        row = self.q1("SELECT value FROM settings WHERE key=?", (key,))
        return row["value"] if row else default

    def set_setting(self, key: str, value: str) -> None:
        self.x(
            "INSERT INTO settings(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )

    def all_settings(self) -> dict[str, str]:
        return {r["key"]: r["value"] for r in self.q("SELECT key,value FROM settings")}

    # -- log --------------------------------------------------------------

    def log(self, level: str, message: str) -> None:
        self.x(
            "INSERT INTO events(ts,level,message) VALUES(?,?,?)",
            (time.time(), level, message),
        )
        # keep the table from growing without bound
        self.x(
            "DELETE FROM events WHERE id < (SELECT MAX(id)-2000 FROM events)"
        )

    def recent_events(self, limit: int = 200) -> list[sqlite3.Row]:
        return self.q(
            "SELECT ts,level,message FROM events ORDER BY id DESC LIMIT ?", (limit,)
        )

    # -- drivers ----------------------------------------------------------

    def upsert_driver(self, guid: str, name: str) -> None:
        now = time.time()
        self.x(
            "INSERT INTO drivers(guid,name,first_seen,last_seen) VALUES(?,?,?,?) "
            "ON CONFLICT(guid) DO UPDATE SET name=excluded.name, last_seen=excluded.last_seen",
            (guid, name, now, now),
        )

    def driver(self, guid: str) -> sqlite3.Row | None:
        return self.q1("SELECT * FROM drivers WHERE guid=?", (guid,))

    def drivers(self) -> list[sqlite3.Row]:
        return self.q("SELECT * FROM drivers ORDER BY name COLLATE NOCASE")

    def set_skill(self, guid: str, skill: float, n: int) -> None:
        self.x(
            "UPDATE drivers SET skill=?, skill_n=? WHERE guid=?", (skill, n, guid)
        )

    def set_driver_enabled(self, guid: str, enabled: bool) -> None:
        self.x("UPDATE drivers SET enabled=? WHERE guid=?", (1 if enabled else 0, guid))

    # -- sessions ---------------------------------------------------------

    def open_session(self, track: str, session_type: str, name: str) -> int:
        cur = self.x(
            "INSERT INTO sessions(track,session_type,name,started) VALUES(?,?,?,?)",
            (track, session_type, name, time.time()),
        )
        return int(cur.lastrowid)

    def close_session(self, session_id: int) -> None:
        self.x("UPDATE sessions SET ended=? WHERE id=?", (time.time(), session_id))

    def sessions(self, limit: int = 50) -> list[sqlite3.Row]:
        return self.q(
            "SELECT s.*, (SELECT COUNT(*) FROM laps l WHERE l.session_id=s.id AND l.clean=1) "
            "AS clean_laps FROM sessions s ORDER BY s.id DESC LIMIT ?",
            (limit,),
        )

    # -- laps -------------------------------------------------------------

    def add_lap(self, session_id: int | None, lap: LapRecord) -> int:
        cur = self.x(
            "INSERT INTO laps(session_id,guid,track,car_model,laptime_ms,cuts,"
            "restrictor,ballast,lap_num,clean,reason,ts) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                session_id,
                lap.guid,
                lap.track,
                lap.car_model,
                lap.laptime_ms,
                lap.cuts,
                lap.restrictor,
                lap.ballast,
                lap.lap_num,
                1 if lap.clean else 0,
                lap.reason,
                time.time(),
            ),
        )
        return int(cur.lastrowid)

    def clean_laps(self, since: float | None = None) -> list[sqlite3.Row]:
        sql = (
            "SELECT l.guid, l.track, l.car_model, l.laptime_ms, l.restrictor, "
            "l.ballast, l.ts FROM laps l JOIN drivers d ON d.guid=l.guid "
            "WHERE l.clean=1 AND d.enabled=1"
        )
        args: list[Any] = []
        if since is not None:
            sql += " AND l.ts >= ?"
            args.append(since)
        return self.q(sql, args)

    def recent_laps(self, limit: int = 100) -> list[sqlite3.Row]:
        return self.q(
            "SELECT l.*, d.name FROM laps l LEFT JOIN drivers d ON d.guid=l.guid "
            "ORDER BY l.id DESC LIMIT ?",
            (limit,),
        )

    # -- model outputs ----------------------------------------------------

    def set_track_car(self, track: str, car: str, base_log: float, n: int) -> None:
        self.x(
            "INSERT INTO track_car(track,car_model,base_log,samples) VALUES(?,?,?,?) "
            "ON CONFLICT(track,car_model) DO UPDATE SET base_log=excluded.base_log, "
            "samples=excluded.samples",
            (track, car, base_log, n),
        )

    def track_cars(self) -> list[sqlite3.Row]:
        return self.q("SELECT * FROM track_car ORDER BY track, car_model")

    def set_car_sensitivity(
        self, car: str, kr: float, kb: float, n: int, track: str = ""
    ) -> None:
        self.x(
            "INSERT INTO car_sensitivity(track,car_model,k_restrictor,k_ballast,samples) "
            "VALUES(?,?,?,?,?) ON CONFLICT(track,car_model) DO UPDATE SET "
            "k_restrictor=excluded.k_restrictor, k_ballast=excluded.k_ballast, "
            "samples=excluded.samples",
            (track, car, kr, kb, n),
        )

    def car_sensitivities(self) -> dict[tuple[str, str], sqlite3.Row]:
        return {
            (r["track"], r["car_model"]): r
            for r in self.q("SELECT * FROM car_sensitivity")
        }

    def set_affinity(self, guid: str, track: str, value: float, n: int) -> None:
        self.x(
            "INSERT INTO affinity(guid,track,value,samples) VALUES(?,?,?,?) "
            "ON CONFLICT(guid,track) DO UPDATE SET value=excluded.value, "
            "samples=excluded.samples",
            (guid, track, value, n),
        )

    def affinities(self) -> list[sqlite3.Row]:
        return self.q(
            "SELECT a.*, d.name FROM affinity a LEFT JOIN drivers d ON d.guid=a.guid "
            "ORDER BY a.track, a.value"
        )

    # -- handicaps --------------------------------------------------------

    def get_handicap(self, guid: str, track: str, car: str) -> sqlite3.Row | None:
        return self.q1(
            "SELECT * FROM handicaps WHERE guid=? AND track=? AND car_model=?",
            (guid, track, car),
        )

    def set_handicap(
        self,
        guid: str,
        track: str,
        car: str,
        restrictor: float,
        ballast: float,
        manual: bool | None = None,
    ) -> None:
        existing = self.get_handicap(guid, track, car)
        if manual is None:
            manual = bool(existing["manual"]) if existing else False
        self.x(
            "INSERT INTO handicaps(guid,track,car_model,restrictor,ballast,manual,updated) "
            "VALUES(?,?,?,?,?,?,?) ON CONFLICT(guid,track,car_model) DO UPDATE SET "
            "restrictor=excluded.restrictor, ballast=excluded.ballast, "
            "manual=excluded.manual, updated=excluded.updated",
            (guid, track, car, restrictor, ballast, 1 if manual else 0, time.time()),
        )

    def handicaps(self, track: str | None = None) -> list[sqlite3.Row]:
        sql = (
            "SELECT h.*, d.name FROM handicaps h LEFT JOIN drivers d ON d.guid=h.guid"
        )
        args: list[Any] = []
        if track:
            sql += " WHERE h.track=?"
            args.append(track)
        sql += " ORDER BY h.track, d.name COLLATE NOCASE"
        return self.q(sql, args)

    def known_tracks(self) -> list[str]:
        return [r["track"] for r in self.q("SELECT DISTINCT track FROM laps ORDER BY track")]

    def known_cars(self) -> list[str]:
        return [
            r["car_model"]
            for r in self.q("SELECT DISTINCT car_model FROM laps ORDER BY car_model")
        ]

    # -- vsc --------------------------------------------------------------

    def vsc_mark_used(self, session_id: int, guid: str) -> None:
        self.x(
            "INSERT OR IGNORE INTO vsc_used(session_id,guid,ts) VALUES(?,?,?)",
            (session_id, guid, time.time()),
        )

    def vsc_was_used(self, session_id: int, guid: str) -> bool:
        return (
            self.q1(
                "SELECT 1 FROM vsc_used WHERE session_id=? AND guid=?",
                (session_id, guid),
            )
            is not None
        )

    def vsc_clear_session(self, session_id: int) -> None:
        self.x("DELETE FROM vsc_used WHERE session_id=?", (session_id,))
