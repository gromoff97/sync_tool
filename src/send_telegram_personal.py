#!/usr/bin/env python3
import argparse
import os
import sys
from typing import Dict, List, Optional, Set


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


USE_COLOR = supports_color()


def _tag(name: str, code: str) -> str:
    if not USE_COLOR:
        return f"[{name}]"
    return f"\033[{code}m[{name}]\033[0m"


def py(msg: str) -> None:
    print(f"{_tag('PY', '34')} {msg}", flush=True)


def err(msg: str) -> None:
    if USE_COLOR:
        print(f"\033[31m[ERROR]\033[0m {msg}", file=sys.stderr, flush=True)
    else:
        print(f"[ERROR] {msg}", file=sys.stderr, flush=True)


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
    prompt_text = f"{_tag('PY', '34')} {prompt}"

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
        request_retries=1,
        connection_retries=1,
        retry_delay=1,
        timeout=20,
        flood_sleep_threshold=0,
    )
    try:
        py("Connecting to Telegram...")
        client.connect()

        if not client.is_user_authorized():
            try:
                phone = resolve_required("telegram_phone", args.phone, "Enter telegram_phone (+7999...): ")
            except ValueError as exc:
                err(str(exc))
                return 3

            py("Requesting login code from Telegram...")
            sent = client.send_code_request(phone)
            py("Login code requested. Check Telegram messages.")

            try:
                code = resolve_required("telegram_code", args.code, "Enter Telegram login code: ")
            except ValueError as exc:
                err(str(exc))
                return 3

            try:
                py("Verifying login code...")
                client.sign_in(
                    phone=phone,
                    code=code,
                    phone_code_hash=sent.phone_code_hash,
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
                py("Verifying 2FA password...")
                client.sign_in(password=password)

            update_conf_file(
                args.config_file,
                updates={"telegram_phone": phone, "telegram_session": session},
                remove_keys={"telegram_code", "telegram_password"},
            )

        py("Uploading archive to Telegram...")
        client.send_file(
            to_peer,
            args.file,
            caption=args.caption or None,
            parse_mode="md",
        )
        py("Upload completed.")
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
        client.disconnect()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
