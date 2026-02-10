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
        from telethon import TelegramClient
    except Exception:
        print(
            "ERROR: telethon is not installed. Install it with: pip install telethon",
            file=sys.stderr,
        )
        return 2

    try:
        with TelegramClient(session, args.api_id, args.api_hash) as client:
            # On first run Telethon will ask for phone/code (and 2FA password if enabled).
            client.start()
            client.send_file(args.to, args.file, caption=args.caption or None)
    except Exception as exc:
        print(f"ERROR: Telegram personal upload failed: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
