#!/usr/bin/env python3
"""acbop entrypoint: starts the UDP plugin and the web GUI in one process."""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys

from aiohttp import web

from acbop.config import Config
from acbop.db import Store
from acbop.engine import Engine
from acbop.web import build_app


async def main_async(cfg: Config, cfg_path: str) -> None:
    store = Store(cfg.db_path)
    engine = Engine(cfg, store)

    loop = asyncio.get_running_loop()
    try:
        transport, _ = await loop.create_datagram_endpoint(
            lambda: engine, local_addr=(cfg.listen_host, cfg.listen_port)
        )
    except OSError as exc:
        logging.error(
            "cannot bind %s:%s — %s. Another plugin may already hold this port; "
            "vanilla acServer only supports one, so chain them with a relay.",
            cfg.listen_host, cfg.listen_port, exc,
        )
        raise SystemExit(1)

    app = build_app(cfg, store, engine, cfg_path)
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    site = web.TCPSite(runner, cfg.web_host, cfg.web_port)
    await site.start()

    logging.info("web GUI on http://%s:%s", cfg.web_host, cfg.web_port)
    store.log("info", "acbop started")

    bg = asyncio.create_task(engine.run_background())

    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:  # Windows
            pass

    try:
        await stop.wait()
    finally:
        logging.info("shutting down")
        bg.cancel()
        transport.close()
        await runner.cleanup()
        store.log("info", "acbop stopped")
        store.close()


def main() -> None:
    ap = argparse.ArgumentParser(description="Adaptive BoP for Assetto Corsa")
    ap.add_argument("-c", "--config", default="config.json")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument(
        "--recompute", action="store_true",
        help="refit the model from stored laps and exit",
    )
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-5s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    cfg = Config.load(args.config)

    if args.recompute:
        from acbop.model import recompute_all

        store = Store(cfg.db_path)
        print(recompute_all(store, cfg))
        store.close()
        return

    try:
        asyncio.run(main_async(cfg, args.config))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
