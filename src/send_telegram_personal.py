#!/usr/bin/env python3
import argparse
import getpass
import os
import sys
from typing import Dict, List, Optional, Set


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a file to Telegram using a personal account (MTProto)."
    )
    parser.add_argument("--api-id", type=int, required=True)
    parser.add_argument("--api-hash", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--config-file", default="")
    parser.add_argument("--session-string", default="")
    parser.add_argument("--phone", default="")
    parser.add_argument("--code", default="")
    parser.add_argument("--password", default="")
    parser.add_argument("--to", required=True, help="Username, phone, user ID, or Saved Messages")
    parser.add_argument("--file", required=True)
    parser.add_argument("--caption", default="")
    return parser.parse_args()


def looks_like_placeholder(value: str) -> bool:
    v = value.strip().upper()
    return v.startswith("REPLACE") or "XXXXXXXX" in v


def update_conf_file(path: str, updates: Optional[Dict[str, str]] = None, remove_keys: Optional[Set[str]] = None) -> None:
    if not path:
        return

    updates = updates or {}
    remove_keys = remove_keys or set()

    conf_path = os.path.expanduser(path)
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
    if not sys.stdin.isatty():
        return ""
    if secret:
        return getpass.getpass(prompt).strip()
    return input(prompt).strip()


def main() -> int:
    args = parse_args()

    if not os.path.isfile(args.file):
        print(f"ERROR: file not found: {args.file}", file=sys.stderr)
        return 1

    session = os.path.expanduser(args.session)
    session_dir = os.path.dirname(session)
    if session_dir:
        os.makedirs(session_dir, exist_ok=True)

    try:
        from telethon.errors import SessionPasswordNeededError
        from telethon.sessions import StringSession
        from telethon.sync import TelegramClient
    except Exception:
        print(
            "ERROR: telethon is not installed. Install it with: pip install telethon",
            file=sys.stderr,
        )
        return 2

    # Keep session path in config so user doesn't need to maintain it manually.
    update_conf_file(args.config_file, updates={"telegram_session": args.session})

    session_obj = session
    if args.session_string.strip():
        session_obj = StringSession(args.session_string.strip())

    client = TelegramClient(session_obj, args.api_id, args.api_hash)
    try:
        client.connect()
        if not client.is_user_authorized():
            phone = args.phone.strip()
            if not phone or looks_like_placeholder(phone):
                phone = prompt_input("Enter Telegram phone (+7999...): ")
            if not phone:
                print(
                    "ERROR: Telegram session is not authorized. "
                    "Set telegram_phone in conf (or enter it interactively), "
                    "or provide telegram_session_string.",
                    file=sys.stderr,
                )
                return 3

            sent = client.send_code_request(phone)

            code = args.code.strip()
            if not code or looks_like_placeholder(code):
                code = prompt_input("Enter Telegram login code: ")
            if not code:
                print(
                    "ERROR: Telegram login code is required.",
                    file=sys.stderr,
                )
                return 3

            try:
                client.sign_in(
                    phone=phone,
                    code=code,
                    phone_code_hash=sent.phone_code_hash,
                )
            except SessionPasswordNeededError:
                password = args.password.strip()
                if not password or looks_like_placeholder(password):
                    password = prompt_input("Enter Telegram 2FA password: ", secret=True)
                if not password:
                    print(
                        "ERROR: 2FA is enabled and password is required.",
                        file=sys.stderr,
                    )
                    return 3
                client.sign_in(password=password)

            # Persist stable auth settings and drop one-time secrets from config.
            update_conf_file(
                args.config_file,
                updates={"telegram_phone": phone, "telegram_session": args.session},
                remove_keys={"telegram_code", "telegram_password"},
            )

        client.send_file(args.to, args.file, caption=args.caption or None)
    except Exception as exc:
        print(f"ERROR: Telegram personal upload failed: {exc}", file=sys.stderr)
        return 1
    finally:
        client.disconnect()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
