#!/usr/bin/env python3
import argparse
import asyncio
import logging
import os
import re
import sys
import threading
import time
from typing import Callable, Dict, List, Optional, Set, Tuple, TypeVar


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a file to Telegram using a personal account (MTProto)."
    )
    parser.add_argument("--api-id", default="")
    parser.add_argument("--api-hash", default="")
    parser.add_argument("--session", default="")
    parser.add_argument("--config-file", default="")
    parser.add_argument("--session-string", default="")
    parser.add_argument("--phone", default="")
    parser.add_argument("--code", default="")
    parser.add_argument("--password", default="")
    parser.add_argument("--to", default="", help="Username, phone, user ID, or Saved Messages")
    parser.add_argument("--file", required=True)
    parser.add_argument("--caption", default="")
    return parser.parse_args()


def supports_color() -> bool:
    if os.getenv("NO_COLOR"):
        return False
    force = os.getenv("FORCE_COLOR")
    if force and force != "0":
        return True
    if not sys.stdout.isatty():
        return False

    term = (os.getenv("TERM") or "").lower()
    if term in ("", "dumb"):
        return False

    if os.name != "nt":
        return True

    # Git Bash / MSYS / Cygwin terminals on Windows.
    if os.getenv("MSYSTEM") or os.getenv("CYGWIN"):
        return True
    if term.startswith("xterm") or "color" in term:
        return True

    # Windows terminals with ANSI support.
    if os.getenv("WT_SESSION"):
        return True
    if os.getenv("ANSICON"):
        return True
    if (os.getenv("ConEmuANSI") or "").upper() == "ON":
        return True
    if (os.getenv("TERM_PROGRAM") or "").lower() in ("vscode", "mintty"):
        return True
    return False


def supports_256_color() -> bool:
    if os.getenv("NO_COLOR"):
        return False
    force = os.getenv("FORCE_256_COLOR")
    if force and force != "0":
        return True
    term = (os.getenv("TERM") or "").lower()
    if "256color" in term:
        return True
    if os.getenv("COLORTERM"):
        return True
    if os.getenv("WT_SESSION") or os.getenv("MSYSTEM") or os.getenv("ANSICON"):
        return True
    if (os.getenv("ConEmuANSI") or "").upper() == "ON":
        return True
    return False


USE_COLOR = supports_color()
USE_256_COLOR = USE_COLOR and supports_256_color()
T = TypeVar("T")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
LIVE_STATUS_ENABLED = sys.stdout.isatty()
_LIVE_STATUS_LOCK = threading.Lock()
_LIVE_STATUS_ACTIVE = False
_LIVE_STATUS_WIDTH = 0
UPLOAD_TIMEOUT_SECONDS = 20

if USE_256_COLOR:
    C_PYT = "38;5;33"
    C_ERR = "38;5;196"
else:
    C_PYT = "35"
    C_ERR = "31"


def _tag(name: str, code: str) -> str:
    if not USE_COLOR:
        return f"[{name}]"
    return f"\033[{code}m[{name}]\033[0m"


def _prefix(name: str, code: str) -> str:
    return f"{_tag(name, code)} "


def _visible_len(text: str) -> int:
    return len(ANSI_RE.sub("", text))


def clear_live_status() -> None:
    global _LIVE_STATUS_ACTIVE, _LIVE_STATUS_WIDTH
    if not LIVE_STATUS_ENABLED:
        return
    with _LIVE_STATUS_LOCK:
        if not _LIVE_STATUS_ACTIVE:
            return
        sys.stdout.write("\r" + (" " * _LIVE_STATUS_WIDTH) + "\r")
        sys.stdout.flush()
        _LIVE_STATUS_ACTIVE = False
        _LIVE_STATUS_WIDTH = 0


def update_live_status(msg: str) -> None:
    global _LIVE_STATUS_ACTIVE, _LIVE_STATUS_WIDTH
    if not LIVE_STATUS_ENABLED:
        return

    line = f"{_prefix('PYT', C_PYT)}{msg}"
    visible = _visible_len(line)
    with _LIVE_STATUS_LOCK:
        pad = ""
        if _LIVE_STATUS_WIDTH > visible:
            pad = " " * (_LIVE_STATUS_WIDTH - visible)
        sys.stdout.write("\r" + line + pad)
        sys.stdout.flush()
        _LIVE_STATUS_ACTIVE = True
        _LIVE_STATUS_WIDTH = visible


def py(msg: str) -> None:
    clear_live_status()
    print(f"{_prefix('PYT', C_PYT)}{msg}", flush=True)


def err(msg: str) -> None:
    clear_live_status()
    print(f"{_prefix('ERR', C_ERR)}{msg}", file=sys.stderr, flush=True)


def format_bytes(value: int) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    size = float(max(value, 0))
    idx = 0
    while size >= 1024.0 and idx < len(units) - 1:
        size /= 1024.0
        idx += 1
    if idx == 0:
        return f"{int(size)} {units[idx]}"
    return f"{size:.1f} {units[idx]}"


def render_progress_bar(percent: int, width: int = 24) -> str:
    p = max(0, min(100, percent))
    filled = int((p * width) / 100)
    return "[" + ("#" * filled) + ("-" * (width - filled)) + "]"


def run_wait_step(step_label: str, action: Callable[[], T], status_suffix: Optional[Callable[[], str]] = None) -> T:
    start_ts = time.monotonic()
    stop_event = threading.Event()
    status_suffix = status_suffix or (lambda: "")

    def ticker() -> None:
        while not stop_event.wait(1.0):
            elapsed = int(time.monotonic() - start_ts)
            update_live_status(f"{step_label}... {elapsed}s{status_suffix()}")

    if LIVE_STATUS_ENABLED:
        update_live_status(f"{step_label}... 0s")
    else:
        py(f"{step_label}...")
    worker = None
    if LIVE_STATUS_ENABLED:
        worker = threading.Thread(target=ticker, daemon=True)
        worker.start()

    try:
        result = action()
    except BaseException:
        elapsed = int(time.monotonic() - start_ts)
        if LIVE_STATUS_ENABLED:
            update_live_status(f"{step_label}... {elapsed}s{status_suffix()}")
            clear_live_status()
        py(f"{step_label}... {elapsed}s{status_suffix()}")
        raise
    else:
        elapsed = int(time.monotonic() - start_ts)
        if LIVE_STATUS_ENABLED:
            update_live_status(f"{step_label}... {elapsed}s{status_suffix()}")
            clear_live_status()
        py(f"{step_label}... {elapsed}s{status_suffix()}")
        return result
    finally:
        stop_event.set()
        if worker is not None:
            worker.join(timeout=0.2)


def make_upload_progress_logger() -> Tuple[Callable[[int, int], None], Callable[[], str]]:
    lock = threading.Lock()
    sent_bytes = 0
    total_bytes = 0
    progress_percent = -1

    def cb(sent: int, total: int) -> None:
        nonlocal sent_bytes, total_bytes, progress_percent
        if total <= 0:
            return
        percent = int((max(0, sent) * 100) / total)
        with lock:
            sent_bytes = max(0, sent)
            total_bytes = max(0, total)
            progress_percent = max(0, min(100, percent))

    def suffix() -> str:
        with lock:
            if progress_percent < 0 or total_bytes <= 0:
                return ""
            sent_text = format_bytes(sent_bytes)
            total_text = format_bytes(total_bytes)
            return f" | {render_progress_bar(progress_percent)} {progress_percent}% ({sent_text} / {total_text})"

    return cb, suffix


def send_file_with_timeout(
    client: object,
    to_peer: str,
    file_path: str,
    caption: str,
    progress_callback: Callable[[int, int], None],
    timeout_seconds: int,
) -> object:
    async def _upload() -> object:
        return await client.send_file(
            to_peer,
            file_path,
            caption=caption or None,
            parse_mode="md",
            progress_callback=progress_callback,
        )

    return client.loop.run_until_complete(
        asyncio.wait_for(_upload(), timeout=timeout_seconds)
    )


def looks_like_placeholder(value: str) -> bool:
    v = value.strip().upper()
    return v.startswith("REPLACE") or "XXXXXXXX" in v


def update_conf_file(path: str, updates: Optional[Dict[str, str]] = None, remove_keys: Optional[Set[str]] = None) -> None:
    if not path:
        return

    updates = updates or {}
    remove_keys = remove_keys or set()

    conf_path = os.path.expanduser(path)
    conf_dir = os.path.dirname(conf_path)
    if conf_dir:
        os.makedirs(conf_dir, exist_ok=True)

    lines: List[str] = []
    if os.path.exists(conf_path):
        with open(conf_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.read().splitlines()

    out: List[str] = []
    seen: Set[str] = set()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in line:
            out.append(line)
            continue

        key, _ = line.split("=", 1)
        key = key.strip()

        if key in remove_keys:
            continue

        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)

    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")

    text = "\n".join(out)
    if text:
        text += "\n"
    with open(conf_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def prompt_input(prompt: str, secret: bool = False) -> str:
    del secret  # Plain input is the most reliable across Git Bash + Windows Python.
    prompt_text = f"{_prefix('PYT', C_PYT)}{prompt}"

    # Primary path: explicit prompt + stdin read.
    try:
        if sys.stdout.isatty():
            sys.stdout.write(prompt_text)
            sys.stdout.flush()
        else:
            sys.stderr.write(prompt_text)
            sys.stderr.flush()
        line = sys.stdin.readline()
        if line:
            return line.strip()
    except OSError:
        pass

    # Fallback for terminals with detached stdin handles.
    for in_name, out_name in (("/dev/tty", "/dev/tty"), ("CONIN$", "CONOUT$")):
        try:
            with open(in_name, "r", encoding="utf-8", errors="ignore") as tty_in, open(
                out_name, "w", encoding="utf-8", errors="ignore"
            ) as tty_out:
                tty_out.write(prompt_text)
                tty_out.flush()
                line = tty_in.readline()
                if line:
                    return line.strip()
        except OSError:
            continue

    # Last-resort path.
    try:
        return input(prompt_text).strip()
    except (EOFError, OSError):
        pass

    return ""


def resolve_required(name: str, raw_value: str, prompt: str, secret: bool = False) -> str:
    value = (raw_value or "").strip()
    if not value or looks_like_placeholder(value):
        value = prompt_input(prompt, secret=secret)
    if not value:
        raise ValueError(f"{name} is required.")
    return value


def main() -> int:
    args = parse_args()

    if not os.path.isfile(args.file):
        err(f"file not found: {args.file}")
        return 1

    try:
        from colorama import just_fix_windows_console
    except Exception:
        err("colorama is not installed. Install it with: pip install colorama")
        return 2
    just_fix_windows_console()

    session_value = (args.session or "").strip()
    if not session_value or looks_like_placeholder(session_value):
        session_value = "~/.sync_tool_telegram"
    session = os.path.expanduser(session_value)

    session_dir = os.path.dirname(session)
    if session_dir:
        os.makedirs(session_dir, exist_ok=True)

    try:
        from telethon.errors import FloodWaitError, SessionPasswordNeededError
        from telethon.sessions import StringSession
        from telethon.sync import TelegramClient
    except Exception:
        err("telethon is not installed. Install it with: pip install telethon")
        return 2

    # Keep terminal output clean: only our own [PYT]/[ERR] messages.
    telethon_logger = logging.getLogger("telethon")
    telethon_logger.handlers = [logging.NullHandler()]
    telethon_logger.propagate = False
    telethon_logger.setLevel(logging.CRITICAL + 1)

    try:
        py("Collecting Telegram connection settings...")
        api_id_raw = resolve_required("telegram_api_id", args.api_id, "Enter telegram_api_id: ")
        if not api_id_raw.isdigit():
            err("telegram_api_id must be an integer.")
            return 3
        api_id = int(api_id_raw)

        api_hash = resolve_required("telegram_api_hash", args.api_hash, "Enter telegram_api_hash: ")
        to_peer = resolve_required("telegram_to", args.to, "Enter telegram_to (@username/phone/id/me): ")
    except ValueError as exc:
        err(str(exc))
        return 3

    # Persist stable values so the next run needs less input.
    update_conf_file(
        args.config_file,
        updates={
            "telegram_api_id": str(api_id),
            "telegram_api_hash": api_hash,
            "telegram_to": to_peer,
            "telegram_session": session,
        },
    )

    session_string = (args.session_string or "").strip()
    if looks_like_placeholder(session_string):
        session_string = ""

    session_obj = session
    if session_string:
        session_obj = StringSession(session_string)

    client = TelegramClient(
        session_obj,
        api_id,
        api_hash,
        request_retries=0,
        connection_retries=0,
        retry_delay=0,
        auto_reconnect=False,
        timeout=20,
        flood_sleep_threshold=0,
    )
    try:
        run_wait_step("Connecting to Telegram", client.connect)

        if not client.is_user_authorized():
            try:
                phone = resolve_required("telegram_phone", args.phone, "Enter telegram_phone (+7999...): ")
            except ValueError as exc:
                err(str(exc))
                return 3

            sent = run_wait_step("Requesting login code from Telegram", lambda: client.send_code_request(phone))
            py("Login code requested. Check Telegram messages.")

            try:
                code = resolve_required("telegram_code", args.code, "Enter Telegram login code: ")
            except ValueError as exc:
                err(str(exc))
                return 3

            try:
                run_wait_step(
                    "Verifying login code",
                    lambda: client.sign_in(
                        phone=phone,
                        code=code,
                        phone_code_hash=sent.phone_code_hash,
                    ),
                )
            except SessionPasswordNeededError:
                try:
                    password = resolve_required(
                        "telegram_password",
                        args.password,
                        "Enter Telegram 2FA password: ",
                        secret=True,
                    )
                except ValueError as exc:
                    err(str(exc))
                    return 3
                run_wait_step("Verifying 2FA password", lambda: client.sign_in(password=password))

            update_conf_file(
                args.config_file,
                updates={"telegram_phone": phone, "telegram_session": session},
                remove_keys={"telegram_code", "telegram_password"},
            )

        progress_cb, progress_suffix = make_upload_progress_logger()
        run_wait_step(
            "Uploading archive to Telegram",
            lambda: send_file_with_timeout(
                client=client,
                to_peer=to_peer,
                file_path=args.file,
                caption=args.caption,
                progress_callback=progress_cb,
                timeout_seconds=UPLOAD_TIMEOUT_SECONDS,
            ),
            status_suffix=progress_suffix,
        )
        py("Upload completed.")
    except KeyboardInterrupt:
        err("Interrupted by user.")
        return 130
    except asyncio.TimeoutError:
        err(f"Telegram upload timed out after {UPLOAD_TIMEOUT_SECONDS} second(s).")
        return 1
    except FloodWaitError as exc:
        seconds = getattr(exc, "seconds", None)
        if seconds is None:
            err("Telegram rate limit (FloodWait). Try again later.")
        else:
            err(f"Telegram rate limit (FloodWait). Retry after {seconds} second(s).")
        return 1
    except Exception as exc:
        err(f"Telegram personal upload failed: {exc}")
        return 1
    finally:
        try:
            client.disconnect()
        except KeyboardInterrupt:
            pass
        except Exception:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
