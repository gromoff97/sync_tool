#!/usr/bin/env python3
import argparse
import asyncio
import logging
import os
import platform
import re
import socket
import sys
import threading
import time
import traceback
from urllib.parse import urlparse
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
    parser.add_argument("--from", dest="from_peer", default="", help="Source chat/user for pull")
    parser.add_argument("--file", default="")
    parser.add_argument("--text", default="")
    parser.add_argument("--caption", default="")
    parser.add_argument("--proxy", default="", help="Proxy URL, e.g. socks5://user:pass@host:1080")
    parser.add_argument("--pull-latest", action="store_true", help="Download latest sync pack from Telegram")
    parser.add_argument("--pack-dir", default="")
    parser.add_argument("--pack-prefix", default="")
    parser.add_argument("--project-name", default="")
    parser.add_argument("--path-file", default="")
    parser.add_argument("--meta-file", default="")
    parser.add_argument("--scan-limit", type=int, default=200)
    parser.add_argument("--require-ack", action="store_true")
    parser.add_argument("--ack-text", default="Unpacked by")
    parser.add_argument("--machine-name", default="")
    parser.add_argument("--reply-to", type=int, default=0)
    parser.add_argument("--last-message-id", type=int, default=0)
    parser.add_argument("--mproto-login", action="store_true", help="Interactive MTProto login and connection test")
    parser.add_argument("--mtproto-test", dest="mproto_login", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--list-chats", action="store_true", help="List available chats with peer_id/access_hash")
    parser.add_argument("--chat-filter", default="", help="Filter for list-chats (substring match)")
    parser.add_argument("--parse-mode", default="", help="Force parse mode (e.g. md)")
    parser.add_argument("--non-interactive", action="store_true", help="Do not prompt for missing values")
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
NON_INTERACTIVE = False

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


def make_upload_progress_logger(
    initial_total_bytes: int = 0, phase_label: str = "transfer"
) -> Tuple[Callable[[int, int], None], Callable[[], str]]:
    lock = threading.Lock()
    sent_bytes = 0
    total_bytes = max(0, int(initial_total_bytes or 0))
    progress_percent = 0
    started = False

    def cb(sent: int, total: int) -> None:
        nonlocal sent_bytes, total_bytes, progress_percent, started
        if total <= 0:
            return
        percent = int((max(0, sent) * 100) / total)
        with lock:
            sent_bytes = max(0, sent)
            total_bytes = max(0, total)
            progress_percent = max(0, min(100, percent))
            started = True

    def suffix() -> str:
        with lock:
            if not started:
                return f" | waiting for {phase_label}..."
            sent_text = format_bytes(sent_bytes)
            total_text = format_bytes(total_bytes)
            pct = max(0, min(100, progress_percent))
            return f" | {render_progress_bar(pct)} {pct}% ({sent_text} / {total_text})"

    return cb, suffix


def send_file_with_timeout(
    client: object,
    to_peer: str,
    file_path: str,
    caption: str,
    progress_callback: Callable[[int, int], None],
    reply_to: int = 0,
) -> object:
    async def _upload() -> object:
        return await client.send_file(
            to_peer,
            file_path,
            caption=caption or None,
            parse_mode="md",
            progress_callback=progress_callback,
            reply_to=reply_to or None,
        )

    return client.loop.run_until_complete(_upload())


def download_file_with_timeout(
    client: object,
    message: object,
    dest_path: str,
    progress_callback: Callable[[int, int], None],
) -> object:
    async def _download() -> object:
        return await client.download_media(
            message,
            file=dest_path,
            progress_callback=progress_callback,
        )

    return client.loop.run_until_complete(_download())


def looks_like_placeholder(value: str) -> bool:
    v = value.strip().upper()
    return v.startswith("REPLACE") or "XXXXXXXX" in v


def normalize_proxy(value: str) -> str:
    raw = (value or "").strip()
    if not raw or looks_like_placeholder(raw):
        return ""
    return raw


def parse_proxy(value: str) -> Tuple[Tuple[object, str, int, bool, Optional[str], Optional[str]], str]:
    raw = normalize_proxy(value)
    if not raw:
        raise ValueError("telegram_proxy is empty.")
    if "://" not in raw:
        raw = "socks5://" + raw

    parsed = urlparse(raw)
    scheme = (parsed.scheme or "").lower()
    host = parsed.hostname
    port = parsed.port
    if not scheme or not host or not port:
        raise ValueError("telegram_proxy must be like socks5://host:port or http://host:port")

    rdns = True
    if scheme in ("socks5h", "socks4a"):
        scheme = scheme[:-1]
        rdns = True

    if scheme not in ("socks5", "socks4", "http"):
        raise ValueError("telegram_proxy scheme must be socks5, socks4, or http")

    return (scheme, host, int(port), rdns, parsed.username, parsed.password), raw


def ensure_proxy_support() -> None:
    try:
        import python_socks  # noqa: F401
        return
    except Exception:
        pass
    try:
        import socks  # noqa: F401
        return
    except Exception:
        raise ValueError(
            "telegram_proxy requires python-socks or PySocks. Install with: pip install python-socks"
        )


def format_proxy_for_log(value: str) -> str:
    raw = normalize_proxy(value)
    if not raw:
        return "none"
    try:
        if "://" not in raw:
            raw = "socks5://" + raw
        parsed = urlparse(raw)
        scheme = parsed.scheme or "socks5"
        host = parsed.hostname or "?"
        port = parsed.port or "?"
        return f"{scheme}://{host}:{port}"
    except Exception:
        return "set"


def extract_pack_timestamp(name: str) -> str:
    m = re.match(r"^.+_([0-9]{8}_[0-9]{6})\.tgz$", name)
    if not m:
        return ""
    return m.group(1)


def _unpack_ack_text(text: str, machine: str) -> str:
    base = (text or "Unpacked by").strip()
    if machine:
        return f"{base} {machine}"
    return base


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
    if NON_INTERACTIVE:
        return ""
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
        if NON_INTERACTIVE:
            raise ValueError(f"{name} is required. Run pack --mproto-login.")
        value = prompt_input(prompt, secret=secret)
    if not value:
        raise ValueError(f"{name} is required.")
    return value


def main() -> int:
    args = parse_args()
    global NON_INTERACTIVE
    NON_INTERACTIVE = bool(args.non_interactive)

    if not args.mproto_login:
        if args.list_chats:
            if args.pull_latest or args.file or args.text:
                err("list-chats cannot be combined with file/text/pull-latest")
                return 1
        else:
            if args.pull_latest and (args.file or args.text):
                err("file/text cannot be used with --pull-latest")
                return 1
            if args.text and args.file:
                err("use either --text or --file, not both")
                return 1
            if not args.file and not args.text:
                if not args.pull_latest:
                    err("file or text is required unless --mproto-login or --pull-latest is set")
                    return 1
            if args.pull_latest:
                if not args.pack_dir or not args.pack_prefix or not args.project_name:
                    err("--pull-latest requires --pack-dir, --pack-prefix, and --project-name")
                    return 1
            else:
                if args.file and not os.path.isfile(args.file):
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

    def _import_telethon() -> Tuple[object, object, object, object]:
        from telethon.errors import FloodWaitError, SessionPasswordNeededError
        try:
            from telethon.errors import ProxyConnectionError as _ProxyConnectionError
        except Exception:
            _ProxyConnectionError = ConnectionError
        from telethon.sessions import StringSession
        from telethon.sync import TelegramClient
        return FloodWaitError, SessionPasswordNeededError, _ProxyConnectionError, StringSession, TelegramClient

    try:
        FloodWaitError, SessionPasswordNeededError, ProxyConnectionError, StringSession, TelegramClient = _import_telethon()
    except Exception as exc:
        # Retry once with user site explicitly enabled (Store Python can disable it).
        try:
            import site as _site
            user_site = _site.getusersitepackages()
            if user_site and user_site not in sys.path:
                sys.path.append(user_site)
            FloodWaitError, SessionPasswordNeededError, ProxyConnectionError, StringSession, TelegramClient = _import_telethon()
        except Exception as exc2:
            err(f"telethon import failed: {type(exc2).__name__}: {exc2}")
            err(f"sys.executable: {sys.executable}")
            err(f"user site: {getattr(_site, 'getusersitepackages', lambda: 'n/a')()}")
            return 2

    # Keep terminal output clean: only our own [PYT]/[ERR] messages.
    telethon_logger = logging.getLogger("telethon")
    telethon_logger.handlers = [logging.NullHandler()]
    telethon_logger.propagate = False
    telethon_logger.setLevel(logging.CRITICAL + 1)
    telethon_version = getattr(sys.modules.get("telethon"), "__version__", "unknown")

    def _mask_secret(value: str, keep: int = 4) -> str:
        if not value:
            return "unset"
        if len(value) <= keep:
            return "***"
        return f"{value[:keep]}***"

    def _probe_tcp(host: str, port: int, timeout: float = 3.0) -> Tuple[bool, str]:
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True, "ok"
        except Exception as exc:
            return False, f"{type(exc).__name__}: {exc}"

    def _dns_lookup(host: str) -> Tuple[bool, str]:
        try:
            infos = socket.getaddrinfo(host, None)
            ips = sorted({info[4][0] for info in infos})
            return True, ", ".join(ips[:6])
        except Exception as exc:
            return False, f"{type(exc).__name__}: {exc}"

    def _err_detail(msg: str) -> None:
        err(msg)

    def diagnose_connection_failure(stage: str, exc: BaseException) -> None:
        _err_detail(f"Connection diagnostics (stage={stage}):")
        _err_detail(f"  exception: {type(exc).__name__}: {exc}")
        if isinstance(exc, OSError):
            winerror = getattr(exc, "winerror", None)
            errno = getattr(exc, "errno", None)
            if winerror is not None:
                _err_detail(f"  winerror: {winerror}")
            if errno is not None:
                _err_detail(f"  errno: {errno}")
        _err_detail(f"  python: {platform.python_version()} ({sys.executable})")
        _err_detail(f"  os: {platform.platform()}")
        _err_detail(f"  telethon: {telethon_version}")
        _err_detail(f"  api_id: {args.api_id or 'unset'}")
        _err_detail(f"  api_hash: {_mask_secret(args.api_hash)}")
        _err_detail(f"  to: {args.to or 'unset'}")
        _err_detail(f"  from: {args.from_peer or 'unset'}")
        _err_detail(f"  session: {os.path.expanduser(args.session or '~/.sync_tool_telegram')}")
        _err_detail(f"  session_string: {'set' if (args.session_string or '').strip() else 'unset'}")
        _err_detail(f"  proxy: {format_proxy_for_log(proxy_raw)}")
        _err_detail(f"  ack_required: {args.require_ack}")
        if args.last_message_id:
            _err_detail(f"  last_message_id: {args.last_message_id}")

        proxy_env = []
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                    "http_proxy", "https_proxy", "all_proxy", "no_proxy"):
            val = os.getenv(key)
            if val:
                proxy_env.append(f"{key}={val}")
        if proxy_env:
            _err_detail("  proxy env: " + " | ".join(proxy_env))
        else:
            _err_detail("  proxy env: none")

        ok, dns_info = _dns_lookup("telegram.org")
        _err_detail(f"  dns telegram.org: {'ok' if ok else 'fail'} ({dns_info})")
        ok, dns_info = _dns_lookup("api.telegram.org")
        _err_detail(f"  dns api.telegram.org: {'ok' if ok else 'fail'} ({dns_info})")

        probes = [
            ("149.154.167.50", 443),
            ("149.154.167.50", 80),
            ("149.154.167.51", 443),
            ("149.154.167.91", 443),
            ("91.108.56.130", 443),
        ]
        _err_detail("  tcp probe (may be blocked by network/VPN):")
        for host, port in probes:
            ok, info = _probe_tcp(host, port)
            _err_detail(f"    {host}:{port} -> {'ok' if ok else 'fail'} ({info})")

        tb = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__, limit=5)).strip()
        if tb:
            _err_detail("  traceback (last 5):")
            for line in tb.splitlines():
                _err_detail(f"    {line}")

    proxy_raw = ""
    proxy_tuple = None
    to_peer = ""
    from_peer = ""

    try:
        py("Telegram settings...")
        api_id_raw = resolve_required("telegram_api_id", args.api_id, "Enter telegram_api_id: ")
        if not api_id_raw.isdigit():
            err("telegram_api_id must be an integer.")
            return 3
        api_id = int(api_id_raw)

        api_hash = resolve_required("telegram_api_hash", args.api_hash, "Enter telegram_api_hash: ")
        if args.list_chats:
            to_peer = (args.to or "").strip()
        elif args.mproto_login:
            to_peer = (args.to or "").strip()
        elif args.pull_latest:
            from_peer = (args.from_peer or "").strip()
            if not from_peer:
                if NON_INTERACTIVE:
                    raise ValueError("telegram_from is required. Run pack --mproto-login or set telegram_from.")
                from_peer = prompt_input("Enter telegram_from (@group/@user/phone/id): ")
        else:
            to_peer = resolve_required("telegram_to", args.to, "Enter telegram_to (@username/phone/id/me): ")

        proxy_raw = normalize_proxy(args.proxy)
        if args.mproto_login and not proxy_raw and not NON_INTERACTIVE:
            proxy_raw = prompt_input("Enter telegram_proxy (optional, blank to skip): ")
        proxy_raw = normalize_proxy(proxy_raw)
        if proxy_raw:
            proxy_tuple, proxy_raw = parse_proxy(proxy_raw)
            ensure_proxy_support()
    except ValueError as exc:
        err(str(exc))
        return 3

    # Persist stable values so the next run needs less input.
    updates = {
        "telegram_api_id": str(api_id),
        "telegram_api_hash": api_hash,
        "telegram_session": session,
    }
    if proxy_raw:
        updates["telegram_proxy"] = proxy_raw
    if to_peer:
        updates["telegram_to"] = to_peer
    if from_peer:
        updates["telegram_from"] = from_peer

    session_string = (args.session_string or "").strip()
    if looks_like_placeholder(session_string):
        session_string = ""

    session_obj = session
    if session_string:
        session_obj = StringSession(session_string)

    client_kwargs = {
        "request_retries": 0,
        "connection_retries": 0,
        "retry_delay": 0,
        "auto_reconnect": False,
        "timeout": 20,
        "flood_sleep_threshold": 0,
    }
    if proxy_tuple:
        client_kwargs["proxy"] = proxy_tuple

    client = TelegramClient(
        session_obj,
        api_id,
        api_hash,
        **client_kwargs,
    )
    current_stage = "connect"

    def ensure_authorized() -> None:
        nonlocal current_stage
        if client.is_user_authorized():
            return
        if NON_INTERACTIVE:
            raise ValueError("telegram session is not authorized. Run pack --mproto-login.")

        phone = resolve_required("telegram_phone", args.phone, "Enter telegram_phone (+7999...): ")
        current_stage = "request_code"
        sent = run_wait_step("Request login code", lambda: client.send_code_request(phone))
        py("Login code sent. Check Telegram.")

        code = resolve_required("telegram_code", args.code, "Enter Telegram login code: ")
        try:
            current_stage = "verify_code"
            run_wait_step(
                "Verify login code",
                lambda: client.sign_in(
                    phone=phone,
                    code=code,
                    phone_code_hash=sent.phone_code_hash,
                ),
            )
        except SessionPasswordNeededError:
            password = resolve_required(
                "telegram_password",
                args.password,
                "Enter Telegram 2FA password: ",
                secret=True,
            )
            current_stage = "verify_2fa"
            run_wait_step("Verify 2FA", lambda: client.sign_in(password=password))

        update_conf_file(
            args.config_file,
            updates={"telegram_phone": phone, "telegram_session": session},
            remove_keys={"telegram_code", "telegram_password"},
        )
    try:
        if args.mproto_login:
            py("MTProto login: probes")
            if proxy_raw:
                py(f"Proxy: {format_proxy_for_log(proxy_raw)} (TCP probes are direct)")
            ok, dns_info = _dns_lookup("telegram.org")
            py(f"DNS telegram.org: {'ok' if ok else 'fail'} ({dns_info})")
            ok, dns_info = _dns_lookup("api.telegram.org")
            py(f"DNS api.telegram.org: {'ok' if ok else 'fail'} ({dns_info})")
            for host, port in [
                ("149.154.167.50", 443),
                ("149.154.167.51", 443),
                ("149.154.167.91", 443),
                ("91.108.56.130", 443),
            ]:
                ok, info = _probe_tcp(host, port)
                py(f"TCP {host}:{port} -> {'ok' if ok else 'fail'} ({info})")

            run_wait_step("Connect Telegram", client.connect)
            py(f"Connected: {client.is_connected()}")
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            dc_id = getattr(client.session, "dc_id", None)
            server = getattr(client.session, "server_address", None)
            port = getattr(client.session, "port", None)
            if dc_id or server or port:
                py(f"Session DC: {dc_id} {server}:{port}")
            remove_keys = {"telegram_code", "telegram_password"}
            if not proxy_raw:
                remove_keys.add("telegram_proxy")
            update_conf_file(args.config_file, updates=updates, remove_keys=remove_keys)
            return 0

        if args.list_chats:
            run_wait_step("Connect Telegram", client.connect)
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            from telethon.utils import get_peer_id
            filt = (args.chat_filter or "").strip().lower()
            py("Chats (groups/channels):")
            matched = 0
            for d in client.iter_dialogs():
                if not (d.is_group or d.is_channel):
                    continue
                ent = d.entity
                peer_id = get_peer_id(ent)
                access_hash = getattr(ent, "access_hash", None)
                username = getattr(ent, "username", None)
                name = (d.name or "")
                if filt:
                    hay = f"{name} {username or ''}".lower()
                    if filt not in hay:
                        continue
                kind = "group"
                if getattr(ent, "broadcast", False):
                    kind = "channel"
                elif getattr(ent, "megagroup", False):
                    kind = "supergroup"
                py(
                    f"{name} | {kind} | peer_id={peer_id} | access_hash={access_hash} | username={username or ''}"
                )
                matched += 1
            if filt and matched == 0:
                py(f"No chats matched: {args.chat_filter}")
            return 0

        def resolve_peer(peer_raw: str, label: str) -> object:
            if not peer_raw:
                raise ValueError(f"{label} is required.")
            try:
                return client.get_input_entity(peer_raw)
            except Exception:
                raise ValueError(f"Cannot find any entity corresponding to \"{peer_raw}\"")

        if args.pull_latest:
            run_wait_step("Connect Telegram", client.connect)
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            entity = resolve_peer(from_peer, "telegram_from")
            pattern = re.compile(
                rf"^{re.escape(args.pack_prefix)}_{re.escape(args.project_name)}_([0-9]{{8}}_[0-9]{{6}})\.tgz$"
            )
            ack_text = (args.ack_text or "Unpacked by").strip()
            ack_prefixes = [ack_text, "Closed by"]
            ack_reply_ids = set()

            best_msg = None
            best_ts = ""
            best_name = ""
            scanned = 0
            for msg in client.iter_messages(entity, limit=args.scan_limit):
                scanned += 1
                if msg and msg.message:
                    if any(msg.message.startswith(p) for p in ack_prefixes if p):
                        if getattr(msg, "reply_to_msg_id", None):
                            ack_reply_ids.add(msg.reply_to_msg_id)
                        continue
                if not msg or not msg.file:
                    continue
                name = getattr(msg.file, "name", "") or ""
                m = pattern.match(name)
                if not m:
                    continue
                ts = m.group(1)
                if ts > best_ts:
                    best_ts = ts
                    best_msg = msg
                    best_name = name

            if not best_msg:
                err(
                    f"No packs found in last {args.scan_limit} messages for "
                    f"{args.pack_prefix}_{args.project_name}_*.tgz"
                )
                return 4

            already_acked = best_msg.id in ack_reply_ids
            if args.meta_file:
                try:
                    with open(args.meta_file, "w", encoding="utf-8") as fh:
                        fh.write(f"message_id={best_msg.id}\n")
                        if getattr(best_msg, "chat_id", None) is not None:
                            fh.write(f"chat_id={best_msg.chat_id}\n")
                        fh.write(f"file_name={best_name}\n")
                        fh.write(f"status={'acked' if already_acked else 'new'}\n")
                except OSError:
                    pass

            if already_acked:
                py("Latest pack already acknowledged. Skipping download.")
                return 0

            os.makedirs(args.pack_dir, exist_ok=True)
            dest_path = os.path.join(args.pack_dir, best_name)
            tmp_path = dest_path + ".part"
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

            total_hint = 0
            try:
                total_hint = int(getattr(best_msg.file, "size", 0) or 0)
            except Exception:
                total_hint = 0
            progress_cb, progress_suffix = make_upload_progress_logger(total_hint, "download")
            run_wait_step(
                "Download from Telegram",
                lambda: download_file_with_timeout(
                    client=client,
                    message=best_msg,
                    dest_path=tmp_path,
                    progress_callback=progress_cb,
                ),
                status_suffix=progress_suffix,
            )
            os.replace(tmp_path, dest_path)
            py(f"Downloaded: {dest_path}")
            if args.path_file:
                with open(args.path_file, "w", encoding="utf-8") as fh:
                    fh.write(dest_path)

            if args.config_file and from_peer:
                update_conf_file(args.config_file, updates={"telegram_from": from_peer})
            return 0

        run_wait_step("Connect Telegram", client.connect)

        if not client.is_user_authorized():
            try:
                ensure_authorized()
            except ValueError as exc:
                err(str(exc))
                return 3

        resolved_to_peer = resolve_peer(to_peer, "telegram_to")

        if args.require_ack:
            if not args.pack_prefix or not args.project_name:
                err("--require-ack requires --pack-prefix and --project-name")
                return 3
            ack_text = (args.ack_text or "Unpacked by").strip()
            ack_prefixes = [ack_text, "Closed by"]
            if args.last_message_id:
                ack_found = False
                for msg in client.iter_messages(resolved_to_peer, limit=args.scan_limit):
                    if not msg or not msg.message:
                        continue
                    if not any(msg.message.startswith(p) for p in ack_prefixes if p):
                        continue
                    if getattr(msg, "reply_to_msg_id", None) == args.last_message_id:
                        ack_found = True
                        break
                if not ack_found:
                    err("Previous pack not acknowledged yet. Wait for 'Unpacked by ...' or 'Closed by ...' reply.")
                    return 4
            else:
                pattern = re.compile(
                    rf"^{re.escape(args.pack_prefix)}_{re.escape(args.project_name)}_([0-9]{{8}}_[0-9]{{6}})\.tgz$"
                )
                latest_pack = None
                latest_pack_ts = ""
                ack_reply_ids = set()
                for msg in client.iter_messages(resolved_to_peer, limit=args.scan_limit):
                    if msg and msg.message:
                        if any(msg.message.startswith(p) for p in ack_prefixes if p):
                            if getattr(msg, "reply_to_msg_id", None):
                                ack_reply_ids.add(msg.reply_to_msg_id)
                            continue
                    if not msg or not msg.file:
                        continue
                    name = getattr(msg.file, "name", "") or ""
                    m = pattern.match(name)
                    if not m:
                        continue
                    ts = m.group(1)
                    if ts > latest_pack_ts:
                        latest_pack_ts = ts
                        latest_pack = msg

                if latest_pack and latest_pack.id not in ack_reply_ids:
                    err("Previous pack not acknowledged yet. Wait for 'Unpacked by ...' or 'Closed by ...' reply.")
                    return 4

        if args.text:
            parse_mode = args.parse_mode or "md"
            run_wait_step(
                "Send message",
                lambda: client.send_message(
                    resolved_to_peer,
                    args.text,
                    reply_to=args.reply_to or None,
                    parse_mode=parse_mode,
                ),
            )
            py("Message sent.")
            if args.config_file and to_peer:
                update_conf_file(args.config_file, updates={"telegram_to": to_peer})
            return 0

        current_stage = "upload"
        total_hint = 0
        if args.file:
            try:
                total_hint = int(os.path.getsize(args.file))
            except OSError:
                total_hint = 0
        progress_cb, progress_suffix = make_upload_progress_logger(total_hint, "upload")
        result = run_wait_step(
            "Upload to Telegram",
            lambda: send_file_with_timeout(
                client=client,
                to_peer=resolved_to_peer,
                file_path=args.file,
                caption=args.caption,
                progress_callback=progress_cb,
                reply_to=args.reply_to or 0,
            ),
            status_suffix=progress_suffix,
        )
        py("Upload done.")
        if args.meta_file:
            try:
                msg = result[0] if isinstance(result, list) else result
                msg_id = getattr(msg, "id", None)
                chat_id = getattr(msg, "chat_id", None)
                with open(args.meta_file, "w", encoding="utf-8") as fh:
                    if msg_id is not None:
                        fh.write(f"message_id={msg_id}\n")
                    if chat_id is not None:
                        fh.write(f"chat_id={chat_id}\n")
                    if args.file:
                        fh.write(f"file_name={os.path.basename(args.file)}\n")
            except OSError:
                pass
        if args.config_file and to_peer:
            update_conf_file(args.config_file, updates={"telegram_to": to_peer})
    except KeyboardInterrupt:
        err("Interrupted by user.")
        return 130
    except ProxyConnectionError as exc:
        err(f"Telegram proxy connection failed (stage={current_stage}).")
        diagnose_connection_failure(current_stage, exc)
        return 1
    except (OSError, ConnectionError) as exc:
        err(f"Telegram connection failed (stage={current_stage}).")
        diagnose_connection_failure(current_stage, exc)
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
        diagnose_connection_failure(current_stage, exc)
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
