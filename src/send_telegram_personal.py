#!/usr/bin/env python3
import argparse
import os
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a file to Telegram using a personal account (MTProto)."
    )
    parser.add_argument("--api-id", type=int, required=True)
    parser.add_argument("--api-hash", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--session-string", default="")
    parser.add_argument("--phone", default="")
    parser.add_argument("--code", default="")
    parser.add_argument("--password", default="")
    parser.add_argument("--to", required=True, help="Username, phone, user ID, or Saved Messages")
    parser.add_argument("--file", required=True)
    parser.add_argument("--caption", default="")
    return parser.parse_args()


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

    session_obj = session
    if args.session_string.strip():
        session_obj = StringSession(args.session_string.strip())

    client = TelegramClient(session_obj, args.api_id, args.api_hash)
    try:
        client.connect()
        if not client.is_user_authorized():
            if not args.phone:
                print(
                    "ERROR: Telegram session is not authorized. "
                    "Set telegram_phone + telegram_code (and telegram_password if 2FA) "
                    "or provide telegram_session_string.",
                    file=sys.stderr,
                )
                return 3

            sent = client.send_code_request(args.phone)
            if not args.code:
                print(
                    "ERROR: telegram_code is required for first non-interactive login.",
                    file=sys.stderr,
                )
                return 3

            try:
                client.sign_in(
                    phone=args.phone,
                    code=args.code,
                    phone_code_hash=sent.phone_code_hash,
                )
            except SessionPasswordNeededError:
                if not args.password:
                    print(
                        "ERROR: 2FA is enabled. Set telegram_password for non-interactive login.",
                        file=sys.stderr,
                    )
                    return 3
                client.sign_in(password=args.password)

        client.send_file(args.to, args.file, caption=args.caption or None)
    except Exception as exc:
        print(f"ERROR: Telegram personal upload failed: {exc}", file=sys.stderr)
        return 1
    finally:
        client.disconnect()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
