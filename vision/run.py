"""Start: python run.py   (see README.md)"""
from __future__ import annotations

import argparse
import logging
import logging.handlers
import sys
import threading
from pathlib import Path

from velora_vision.config import ConfigError, load_config, load_env

HERE = Path(__file__).resolve().parent


def _setup_logging(verbose: bool) -> None:
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%d.%m %H:%M:%S")
    root = logging.getLogger()
    root.setLevel(logging.DEBUG if verbose else logging.INFO)
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    root.addHandler(console)
    logfile = logging.handlers.RotatingFileHandler(
        HERE / "velora_vision.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8"
    )
    logfile.setFormatter(fmt)
    root.addHandler(logfile)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Velora Club: камеры и сеансы")
    ap.add_argument("--config", default=str(HERE / "config.yaml"))
    ap.add_argument("--zones", default=str(HERE / "zones.yaml"))
    ap.add_argument("--env", default=str(HERE / ".env"))
    ap.add_argument(
        "--dry-run", action="store_true",
        help="ничего не отправлять в Telegram, только показывать в окне",
    )
    ap.add_argument(
        "--no-sessions", action="store_true",
        help="не спрашивать программу: считать, что сеансов нет (для проверки на записи)",
    )
    ap.add_argument(
        "--list-tables", action="store_true",
        help="показать названия столов из программы и выйти",
    )
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    _setup_logging(args.verbose)
    log = logging.getLogger("velora_vision")

    load_env(Path(args.env))
    try:
        cfg = load_config(
            Path(args.config), Path(args.zones),
            need_supabase=not args.no_sessions or args.list_tables,
            need_telegram=not args.dry_run and not args.list_tables,
        )
    except ConfigError as e:
        log.error("%s", e)
        return 2

    from velora_vision.sessions import SessionsClient, SessionsError

    sessions = None
    if not args.no_sessions:
        sessions = SessionsClient(cfg.supabase_url, cfg.vision_secret, cfg.club_id)

    if args.list_tables:
        try:
            for r in sessions.fetch():
                state = r.session_status or "нет сеанса"
                print(f"{r.name}  [{r.zone or '—'}]  {state}")
        except SessionsError as e:
            log.error("%s", e)
            return 3
        return 0

    from velora_vision.camera import CameraReader
    from velora_vision.detector import PersonDetector
    from velora_vision.service import PrintNotifier, Service, TelegramNotifier
    from velora_vision.telegram import Telegram

    notifier = (
        PrintNotifier()
        if args.dry_run
        else TelegramNotifier(Telegram(cfg.telegram_token, cfg.alert_chats))
    )

    log.info("Загружаю модель %s (при первом запуске скачается, нужен интернет)", cfg.model)
    detector = PersonDetector(cfg.model, cfg.confidence, cfg.image_size)

    stop = threading.Event()
    readers = {
        c.name: CameraReader(c.name, c.source, c.is_file, stop) for c in cfg.cameras
    }
    for r in readers.values():
        r.start()

    service = Service(cfg, detector, readers, notifier, sessions)
    if not args.dry_run:
        notifier.notify("✅ Слежение за столами запущено")
    try:
        service.run(stop)
    except KeyboardInterrupt:
        log.info("Остановлено")
    finally:
        stop.set()
    return 0


if __name__ == "__main__":
    sys.exit(main())
