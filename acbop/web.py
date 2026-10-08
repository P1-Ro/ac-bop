"""aiohttp web GUI + JSON API."""

from __future__ import annotations

import hmac
import json
import logging
import time
from hashlib import sha256
from pathlib import Path

from aiohttp import web

from .config import Config
from .db import Store
from .engine import Engine
from .version import BUILD

log = logging.getLogger("acbop.web")

STATIC = Path(__file__).parent / "static"
COOKIE = "acbop_auth"


def _token(password: str) -> str:
    return hmac.new(b"acbop", password.encode(), sha256).hexdigest()[:32]


@web.middleware
async def auth_middleware(request: web.Request, handler):
    cfg: Config = request.app["cfg"]
    if not cfg.web_password:
        return await handler(request)
    if request.path in ("/login", "/static/style.css"):
        return await handler(request)
    expected = _token(cfg.web_password)
    given = request.cookies.get(COOKIE) or request.headers.get("X-ACBOP-Key", "")
    if hmac.compare_digest(given, expected):
        return await handler(request)
    if request.path.startswith("/api/"):
        return web.json_response({"error": "unauthorized"}, status=401)
    raise web.HTTPFound("/login")


def rows(result) -> list[dict]:
    return [dict(r) for r in result]


# ---------------------------------------------------------------------------
# handlers
# ---------------------------------------------------------------------------


async def index(request: web.Request) -> web.Response:
    return web.FileResponse(STATIC / "index.html")


async def login_get(request: web.Request) -> web.Response:
    return web.FileResponse(STATIC / "login.html")


async def login_post(request: web.Request) -> web.Response:
    cfg: Config = request.app["cfg"]
    data = await request.post()
    if hmac.compare_digest(str(data.get("password", "")), cfg.web_password):
        resp = web.HTTPFound("/")
        resp.set_cookie(COOKIE, _token(cfg.web_password), httponly=True, max_age=30 * 86400)
        raise resp
    raise web.HTTPFound("/login?bad=1")


async def api_state(request: web.Request) -> web.Response:
    engine: Engine = request.app["engine"]
    store: Store = request.app["store"]
    state = engine.state()
    state["events"] = rows(store.recent_events(30))
    state["build"] = BUILD
    return web.json_response(state)


async def api_drivers(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    cfg: Config = request.app["cfg"]
    out = []
    for d in store.drivers():
        r = dict(d)
        r["rated"] = (d["skill_n"] or 0) >= cfg.min_laps_for_rating
        # pace relative to the field, as a readable percentage
        r["pace_pct"] = round((pow(2.718281828, d["skill"]) - 1) * 100, 2) if d["skill"] is not None else None
        out.append(r)
    return web.json_response(out)


async def api_driver_update(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    guid = request.match_info["guid"]
    body = await request.json()
    if "enabled" in body:
        store.set_driver_enabled(guid, bool(body["enabled"]))
    return web.json_response({"ok": True})


async def api_handicaps(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    track = request.query.get("track") or None
    return web.json_response(rows(store.handicaps(track)))


async def api_handicap_set(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    engine: Engine = request.app["engine"]
    b = await request.json()
    store.set_handicap(
        b["guid"],
        b["track"],
        b["car_model"],
        float(b["restrictor"]),
        float(b["ballast"]),
        manual=bool(b.get("manual", True)),
    )
    store.log(
        "info",
        f"manual handicap {b['guid'][:8]} @ {b['track']}: "
        f"{b['ballast']}kg / {b['restrictor']}%",
    )
    engine.apply_all()
    return web.json_response({"ok": True})


async def api_handicap_unpin(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    m = request.match_info
    row = store.get_handicap(m["guid"], m["track"], m["car"])
    if row:
        store.set_handicap(
            m["guid"], m["track"], m["car"],
            row["restrictor"], row["ballast"], manual=False,
        )
    return web.json_response({"ok": True})


async def api_laps(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    limit = int(request.query.get("limit", 150))
    return web.json_response(rows(store.recent_laps(limit)))


async def api_sessions(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    return web.json_response(rows(store.sessions()))


async def api_model(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    return web.json_response(
        {
            "track_car": rows(store.track_cars()),
            "sensitivity": rows(
                store.q("SELECT * FROM car_sensitivity ORDER BY car_model, track")
            ),
            "affinity": rows(
                store.q(
                    "SELECT a.*, d.name FROM affinity a LEFT JOIN drivers d "
                    "ON d.guid=a.guid WHERE ABS(a.value) > 0.0005 "
                    "ORDER BY ABS(a.value) DESC LIMIT 60"
                )
            ),
            "tracks": store.known_tracks(),
            "cars": store.known_cars(),
        }
    )


async def api_recompute(request: web.Request) -> web.Response:
    engine: Engine = request.app["engine"]
    stats = await engine.recompute()
    engine.apply_all()
    return web.json_response(stats)


async def api_apply(request: web.Request) -> web.Response:
    engine: Engine = request.app["engine"]
    engine.apply_all(announce=True)
    return web.json_response({"ok": True, "drivers": len(engine.drivers)})


async def api_config_get(request: web.Request) -> web.Response:
    cfg: Config = request.app["cfg"]
    return web.json_response(cfg.to_dict())


async def api_config_post(request: web.Request) -> web.Response:
    cfg: Config = request.app["cfg"]
    store: Store = request.app["store"]
    body = await request.json()
    changed = cfg.apply_updates(body)
    if changed:
        cfg.save(request.app["cfg_path"])
        store.log("info", f"settings changed: {', '.join(changed)}")
    return web.json_response({"ok": True, "changed": changed, "config": cfg.to_dict()})


async def api_vsc_grant(request: web.Request) -> web.Response:
    """Admin override: start a safety car phase for this driver from the GUI."""
    engine: Engine = request.app["engine"]
    store: Store = request.app["store"]
    car_id = int(request.match_info["car_id"])
    d = engine.drivers.get(car_id)
    if d is None:
        return web.json_response({"error": "no such car"}, status=404)
    if engine.vsc is not None:
        return web.json_response({"error": "a phase is already running"}, status=409)
    # An admin override ignores the per-race budget.
    d.vsc_uses = 0
    if engine.session_id is not None:
        store.x(
            "DELETE FROM vsc_used WHERE session_id=? AND guid=?",
            (engine.session_id, d.guid),
        )
    engine.handle_vsc(car_id)
    return web.json_response({"ok": True, "started": engine.vsc is not None})


async def api_vsc_end(request: web.Request) -> web.Response:
    """Stop an active phase early."""
    engine: Engine = request.app["engine"]
    if engine.vsc is None:
        return web.json_response({"error": "no phase running"}, status=404)
    engine._end_vsc("stopped by an admin")
    return web.json_response({"ok": True})


async def api_events(request: web.Request) -> web.Response:
    store: Store = request.app["store"]
    return web.json_response(rows(store.recent_events(int(request.query.get("limit", 200)))))


# ---------------------------------------------------------------------------


def build_app(cfg: Config, store: Store, engine: Engine, cfg_path: str) -> web.Application:
    app = web.Application(middlewares=[auth_middleware])
    app["cfg"] = cfg
    app["store"] = store
    app["engine"] = engine
    app["cfg_path"] = cfg_path

    app.add_routes(
        [
            web.get("/", index),
            web.get("/login", login_get),
            web.post("/login", login_post),
            web.get("/api/state", api_state),
            web.get("/api/drivers", api_drivers),
            web.post("/api/drivers/{guid}", api_driver_update),
            web.get("/api/handicaps", api_handicaps),
            web.post("/api/handicaps", api_handicap_set),
            web.delete("/api/handicaps/{guid}/{track}/{car}", api_handicap_unpin),
            web.get("/api/laps", api_laps),
            web.get("/api/sessions", api_sessions),
            web.get("/api/model", api_model),
            web.post("/api/recompute", api_recompute),
            web.post("/api/apply", api_apply),
            web.get("/api/config", api_config_get),
            web.post("/api/config", api_config_post),
            web.post("/api/vsc/{car_id}", api_vsc_grant),
            web.delete("/api/vsc", api_vsc_end),
            web.get("/api/events", api_events),
            web.static("/static", STATIC),
        ]
    )
    return app
