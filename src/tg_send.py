#!/usr/bin/env python3
import argparse
import asyncio
from dataclasses import dataclass
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
from typing import Callable, Dict, List, Mapping, Optional, Set, Tuple, TypeVar


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Telegram runtime helper for sync_tool."
    )
    parser.add_argument("--api-id", default="")
    parser.add_argument("--api-hash", default="")
    parser.add_argument("--session", default="")
    parser.add_argument("--session-string", default="")
    parser.add_argument("--to", default="", help="Username, phone, user ID, or Saved Messages")
    parser.add_argument("--from", dest="from_peer", default="", help="Source chat/user for pull")
    parser.add_argument("--file", default="")
    parser.add_argument("--text", default="")
    parser.add_argument("--caption", default="")
    parser.add_argument("--proxy-type", default="none", help=argparse.SUPPRESS)
    parser.add_argument("--socks5-host", default="", help=argparse.SUPPRESS)
    parser.add_argument("--socks5-port", default="", help=argparse.SUPPRESS)
    parser.add_argument("--socks5-user", default="", help=argparse.SUPPRESS)
    parser.add_argument("--socks5-password", default="", help=argparse.SUPPRESS)
    parser.add_argument("--http-host", default="", help=argparse.SUPPRESS)
    parser.add_argument("--http-port", default="", help=argparse.SUPPRESS)
    parser.add_argument("--http-user", default="", help=argparse.SUPPRESS)
    parser.add_argument("--http-password", default="", help=argparse.SUPPRESS)
    parser.add_argument("--mtproto-host", default="", help=argparse.SUPPRESS)
    parser.add_argument("--mtproto-port", default="", help=argparse.SUPPRESS)
    parser.add_argument("--mtproto-secret", default="", help=argparse.SUPPRESS)
    parser.add_argument("--pull-latest", action="store_true", help="Download latest sync pack from Telegram")
    parser.add_argument("--pack-dir", default="")
    parser.add_argument("--pack-prefix", default="")
    parser.add_argument("--project-name", default="")
    parser.add_argument("--path-file", default="")
    parser.add_argument("--meta-file", default="")
    parser.add_argument("--no-tmp-rename", action="store_true", help="Write download directly to final file")
    parser.add_argument("--scan-limit", type=int, default=200)
    parser.add_argument("--require-ack", action="store_true")
    parser.add_argument("--ack-text", default="Closed by")
    parser.add_argument("--machine-name", default="")
    parser.add_argument("--reply-to", type=int, default=0)
    parser.add_argument("--last-message-id", type=int, default=0)
    parser.add_argument("--doctor", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--parse-mode", default="", help="Force parse mode (e.g. md)")
    parser.add_argument("--check-ack", action="store_true", help="Only check whether latest pack is closed")
    parser.add_argument("--delete-message", type=int, default=0, help="Delete a message by id in the target chat")
    parser.add_argument("--current-sha", default="", help="Current bundle sha (short) to detect duplicates")
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
if os.getenv("FORCE_LIVE_STATUS") not in (None, "", "0"):
    LIVE_STATUS_ENABLED = True
_LIVE_STATUS_LOCK = threading.Lock()
_LIVE_STATUS_ACTIVE = False
_LIVE_STATUS_WIDTH = 0

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
        update_live_status(f"{step_label}... 0s{status_suffix()}")
    else:
        py(f"{step_label}... 0s{status_suffix()}")
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
    initial_total_bytes: int = 0,
    phase_label: str = "transfer",
    show_initial: bool = False,
) -> Tuple[Callable[[int, int], None], Callable[[], str]]:
    lock = threading.Lock()
    sent_bytes = 0
    total_bytes = max(0, int(initial_total_bytes or 0))
    progress_percent = 0
    started = bool(show_initial and total_bytes > 0)

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
                return f" | waiting for {phase_label}... {render_progress_bar(0)} 0%"
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
    parse_mode: str,
    reply_to: int = 0,
) -> object:
    async def _upload() -> object:
        return await client.send_file(
            to_peer,
            file_path,
            caption=caption or None,
            parse_mode=parse_mode or "md",
            progress_callback=progress_callback,
            reply_to=reply_to or None,
        )

    return client.loop.run_until_complete(_upload())


def download_file_with_timeout(
    client: object,
    message: object,
    dest_path: str,
    final_path: str,
    progress_callback: Callable[[int, int], None],
) -> object:
    async def _download() -> object:
        return await client.download_media(
            message,
            file=dest_path,
            progress_callback=progress_callback,
        )

    result = client.loop.run_until_complete(_download())
    if dest_path != final_path:
        os.replace(dest_path, final_path)
    return result


def looks_like_placeholder(value: str) -> bool:
    v = value.strip().upper()
    return v.startswith("REPLACE") or "XXXXXXXX" in v


@dataclass(frozen=True)
class ProxyMode:
    kind: str
    host: str = ""
    port: int = 0
    user: str = ""
    password: str = ""
    secret: str = ""


def validate_proxy_type(raw: str) -> str:
    value = (raw or "").strip().lower()
    if not value or looks_like_placeholder(value):
        raise ValueError("telegram_proxy_type must be one of: none, socks5, http, mtproto")
    if value not in ("none", "socks5", "http", "mtproto"):
        raise ValueError("telegram_proxy_type must be one of: none, socks5, http, mtproto")
    return value


def parse_required_port(raw: str, field_name: str) -> int:
    value = (raw or "").strip()
    if not value or looks_like_placeholder(value):
        raise ValueError(f"{field_name} is required.")
    if not value.isdigit():
        raise ValueError(f"{field_name} must be an integer.")
    return int(value)


def validate_transport_credentials(user: str, password: str, prefix: str) -> Tuple[str, str]:
    normalized_user = normalize_mtproxy_value(user)
    normalized_password = normalize_mtproxy_value(password)
    if bool(normalized_user) != bool(normalized_password):
        raise ValueError(f"{prefix}_user and {prefix}_password must be supplied together.")
    return normalized_user, normalized_password


def validate_mtproto_secret(raw: str) -> str:
    value = (raw or "").strip().lower()
    if not value or looks_like_placeholder(value):
        raise ValueError(
            "telegram_mtproto_secret must be a non-empty even-length hexadecimal string"
        )
    if len(value) % 2 != 0 or any(ch not in "0123456789abcdef" for ch in value):
        raise ValueError(
            "telegram_mtproto_secret must be a non-empty even-length hexadecimal string"
        )
    return value


def resolve_configured_proxy_mode(
    *,
    proxy_type: str,
    socks5_host: str = "",
    socks5_port: str = "",
    socks5_user: str = "",
    socks5_password: str = "",
    http_host: str = "",
    http_port: str = "",
    http_user: str = "",
    http_password: str = "",
    mtproto_host: str = "",
    mtproto_port: str = "",
    mtproto_secret: str = "",
) -> ProxyMode:
    normalized_type = validate_proxy_type(proxy_type)
    socks5_host = normalize_mtproxy_value(socks5_host)
    socks5_port = normalize_mtproxy_value(socks5_port)
    socks5_user = normalize_mtproxy_value(socks5_user)
    socks5_password = normalize_mtproxy_value(socks5_password)
    http_host = normalize_mtproxy_value(http_host)
    http_port = normalize_mtproxy_value(http_port)
    http_user = normalize_mtproxy_value(http_user)
    http_password = normalize_mtproxy_value(http_password)
    mtproto_host = normalize_mtproxy_value(mtproto_host)
    mtproto_port = normalize_mtproxy_value(mtproto_port)
    mtproto_secret = normalize_mtproxy_value(mtproto_secret)

    has_socks5 = bool(socks5_host or socks5_port or socks5_user or socks5_password)
    has_http = bool(http_host or http_port or http_user or http_password)
    has_mtproto = bool(mtproto_host or mtproto_port or mtproto_secret)

    if normalized_type == "none":
        if has_socks5 or has_http or has_mtproto:
            raise ValueError("Proxy keys are not allowed when telegram_proxy_type=none.")
        return ProxyMode(kind="none")

    if normalized_type == "socks5":
        if has_http or has_mtproto:
            raise ValueError("telegram_http_* and telegram_mtproto_* keys are not allowed when telegram_proxy_type=socks5.")
        if not socks5_host:
            raise ValueError("telegram_socks5_host is required when telegram_proxy_type=socks5.")
        socks5_user, socks5_password = validate_transport_credentials(
            socks5_user, socks5_password, "telegram_socks5"
        )
        return ProxyMode(
            kind="socks5",
            host=socks5_host,
            port=parse_required_port(socks5_port, "telegram_socks5_port"),
            user=socks5_user,
            password=socks5_password,
        )

    if normalized_type == "http":
        if has_socks5 or has_mtproto:
            raise ValueError("telegram_socks5_* and telegram_mtproto_* keys are not allowed when telegram_proxy_type=http.")
        if not http_host:
            raise ValueError("telegram_http_host is required when telegram_proxy_type=http.")
        http_user, http_password = validate_transport_credentials(
            http_user, http_password, "telegram_http"
        )
        return ProxyMode(
            kind="http",
            host=http_host,
            port=parse_required_port(http_port, "telegram_http_port"),
            user=http_user,
            password=http_password,
        )

    if has_socks5 or has_http:
        raise ValueError("telegram_socks5_* and telegram_http_* keys are not allowed when telegram_proxy_type=mtproto.")
    if not mtproto_host:
        raise ValueError("telegram_mtproto_host is required when telegram_proxy_type=mtproto.")
    return ProxyMode(
        kind="mtproto",
        host=mtproto_host,
        port=parse_required_port(mtproto_port, "telegram_mtproto_port"),
        secret=validate_mtproto_secret(mtproto_secret),
    )


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
            "transport proxy support requires python-socks or PySocks. Install with: pip install python-socks"
        )

def normalize_mtproxy_value(value: str) -> str:
    raw = (value or "").strip()
    if not raw or looks_like_placeholder(raw):
        return ""
    return raw


def normalize_session_path(raw_value: str) -> str:
    value = os.path.expanduser((raw_value or "").strip())
    if os.name == "nt":
        return value

    unix_style = value.replace("\\", "/")
    match = re.match(r"^([A-Za-z]):/(.*)$", unix_style)
    if not match:
        return value

    drive = match.group(1).lower()
    rest = match.group(2)
    return f"/mnt/{drive}/{rest}"

def format_mtproxy_for_log(host: str, port: int) -> str:
    if not host or not port:
        return "none"
    return f"mtproto://{host}:{port}"


def extract_pack_timestamp(name: str) -> str:
    m = re.match(r"^.+_([0-9]{8}_[0-9]{6})\.tgz$", name)
    if not m:
        return ""
    return m.group(1)


def _unpack_ack_text(text: str, machine: str) -> str:
    base = (text or "Closed by").strip()
    if machine:
        return f"{base} {machine}"
    return base


def resolve_proxy_mode_from_config(
    args: argparse.Namespace,
) -> ProxyMode:
    proxy_type_raw = (getattr(args, "proxy_type", "") or "").strip()
    socks5_host = (getattr(args, "socks5_host", "") or "").strip()
    socks5_port = (getattr(args, "socks5_port", "") or "").strip()
    socks5_user = (getattr(args, "socks5_user", "") or "").strip()
    socks5_password = (getattr(args, "socks5_password", "") or "").strip()
    http_host = (getattr(args, "http_host", "") or "").strip()
    http_port = (getattr(args, "http_port", "") or "").strip()
    http_user = (getattr(args, "http_user", "") or "").strip()
    http_password = (getattr(args, "http_password", "") or "").strip()
    mtproto_host = (getattr(args, "mtproto_host", "") or "").strip()
    mtproto_port = (getattr(args, "mtproto_port", "") or "").strip()
    mtproto_secret = (getattr(args, "mtproto_secret", "") or "").strip()

    proxy_type = validate_proxy_type(proxy_type_raw or "none")

    return resolve_configured_proxy_mode(
        proxy_type=proxy_type,
        socks5_host=socks5_host,
        socks5_port=socks5_port,
        socks5_user=socks5_user,
        socks5_password=socks5_password,
        http_host=http_host,
        http_port=http_port,
        http_user=http_user,
        http_password=http_password,
        mtproto_host=mtproto_host,
        mtproto_port=mtproto_port,
        mtproto_secret=mtproto_secret,
    )


def main() -> int:
    args = parse_args()

    if args.doctor:
        if args.pull_latest or args.file or args.text or args.check_ack or args.delete_message:
            err("doctor cannot be combined with file/text/pull-latest/check-ack/delete-message")
            return 1
        if not args.to and not args.from_peer:
            err("doctor requires --to or --from")
            return 1
    elif args.check_ack or args.delete_message:
        if args.pull_latest or args.file or args.text:
            err("check-ack/delete-message cannot be combined with file/text/pull-latest")
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
                err("file or text is required unless --doctor or --pull-latest is set")
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
    session = normalize_session_path(session_value)

    session_dir = os.path.dirname(session)
    if session_dir:
        os.makedirs(session_dir, exist_ok=True)

    def _import_telethon() -> Tuple[object, object, object, object, object]:
        from telethon import connection
        from telethon.errors import FloodWaitError
        try:
            from telethon.errors import ProxyConnectionError as _ProxyConnectionError
        except Exception:
            _ProxyConnectionError = ConnectionError
        from telethon.sessions import StringSession
        from telethon.sync import TelegramClient
        return FloodWaitError, _ProxyConnectionError, StringSession, TelegramClient, connection

    try:
        FloodWaitError, ProxyConnectionError, StringSession, TelegramClient, telethon_connection = _import_telethon()
    except Exception as exc:
        # Retry once with user site explicitly enabled (Store Python can disable it).
        try:
            import site as _site
            user_site = _site.getusersitepackages()
            if user_site and user_site not in sys.path:
                sys.path.append(user_site)
            FloodWaitError, ProxyConnectionError, StringSession, TelegramClient, telethon_connection = _import_telethon()
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
        if proxy_mode == "socks5":
            _err_detail("  proxy mode: socks5")
            _err_detail(f"  proxy: socks5://{socks5_host}:{socks5_port}")
        elif proxy_mode == "http":
            _err_detail("  proxy mode: http")
            _err_detail(f"  proxy: http://{http_host}:{http_port}")
        elif proxy_mode == "mtproto":
            _err_detail(f"  proxy mode: mtproxy")
            _err_detail(f"  mtproxy: {format_mtproxy_for_log(mtproto_host, mtproto_port)}")
            _err_detail(f"  mtproxy_secret: {_mask_secret(mtproto_secret)}")
        else:
            _err_detail("  proxy mode: none")
            _err_detail("  proxy: none")
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

    proxy_mode = "none"
    socks5_host = ""
    socks5_port = 0
    socks5_user = ""
    socks5_password = ""
    http_host = ""
    http_port = 0
    http_user = ""
    http_password = ""
    mtproto_host = ""
    mtproto_port = 0
    mtproto_secret = ""
    to_peer = ""
    from_peer = ""

    try:
        py("Telegram settings...")
        api_id_raw = (args.api_id or "").strip()
        if not api_id_raw or looks_like_placeholder(api_id_raw):
            raise ValueError("telegram_api_id is required. Update [telegram.common] in conf.toml.")
        if not api_id_raw.isdigit():
            err("telegram_api_id must be an integer.")
            return 3
        api_id = int(api_id_raw)

        api_hash = (args.api_hash or "").strip()
        if not api_hash or looks_like_placeholder(api_hash):
            raise ValueError("telegram_api_hash is required. Update [telegram.common] in conf.toml.")
        if args.pull_latest:
            from_peer = (args.from_peer or "").strip()
            if not from_peer:
                raise ValueError("telegram_from is required. Set [unpack.take.telegram].from in conf.toml or run unpack take setup.")
        elif args.doctor:
            to_peer = (args.to or "").strip()
            from_peer = (args.from_peer or "").strip()
        else:
            to_peer = (args.to or "").strip()
            if not to_peer:
                raise ValueError("telegram_to is required. Set [pack.send.telegram].to in conf.toml or run pack send setup.")

        proxy_state = resolve_proxy_mode_from_config(args)
        proxy_mode = proxy_state.kind
        socks5_host = proxy_state.host if proxy_mode == "socks5" else ""
        socks5_port = proxy_state.port if proxy_mode == "socks5" else 0
        socks5_user = proxy_state.user if proxy_mode == "socks5" else ""
        socks5_password = proxy_state.password if proxy_mode == "socks5" else ""
        http_host = proxy_state.host if proxy_mode == "http" else ""
        http_port = proxy_state.port if proxy_mode == "http" else 0
        http_user = proxy_state.user if proxy_mode == "http" else ""
        http_password = proxy_state.password if proxy_mode == "http" else ""
        mtproto_host = proxy_state.host if proxy_mode == "mtproto" else ""
        mtproto_port = proxy_state.port if proxy_mode == "mtproto" else 0
        mtproto_secret = proxy_state.secret if proxy_mode == "mtproto" else ""
    except ValueError as exc:
        err(str(exc))
        return 3

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
    if proxy_mode in ("socks5", "http"):
        ensure_proxy_support()
        host = socks5_host if proxy_mode == "socks5" else http_host
        port = socks5_port if proxy_mode == "socks5" else http_port
        user = socks5_user if proxy_mode == "socks5" else http_user
        password = socks5_password if proxy_mode == "socks5" else http_password
        client_kwargs["proxy"] = (proxy_mode, host, port, True, user or None, password or None)
    elif proxy_mode == "mtproto":
        client_kwargs["connection"] = telethon_connection.ConnectionTcpMTProxyRandomizedIntermediate
        client_kwargs["proxy"] = (mtproto_host, mtproto_port, mtproto_secret)

    client = TelegramClient(
        session_obj,
        api_id,
        api_hash,
        **client_kwargs,
    )
    current_stage = "connect"

    def ensure_authorized() -> None:
        if client.is_user_authorized():
            return
        raise ValueError("telegram session is not authorized. Update [telegram.common] in conf.toml and refresh the session.")
    try:
        def resolve_peer(peer_raw: str, label: str) -> object:
            if not peer_raw:
                raise ValueError(f"{label} is required.")
            try:
                return client.get_input_entity(peer_raw)
            except Exception:
                raise ValueError(f"Cannot find any entity corresponding to \"{peer_raw}\"")

        if args.doctor:
            run_wait_step("Connect Telegram", client.connect)
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            if to_peer:
                resolve_peer(to_peer, "telegram_to")
            if from_peer:
                resolve_peer(from_peer, "telegram_from")
            py("Doctor OK")
            return 0

        if args.check_ack:
            run_wait_step("Connect Telegram", client.connect)
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            resolved_to_peer = resolve_peer(to_peer, "telegram_to")
            if not args.pack_prefix or not args.project_name:
                err("--check-ack requires --pack-prefix and --project-name")
                return 3
            ack_text = (args.ack_text or "Closed by").strip()
            pattern = re.compile(
                rf"^{re.escape(args.pack_prefix)}_{re.escape(args.project_name)}_([0-9]{{8}}_[0-9]{{6}})\.tgz$"
            )
            latest_pack = None
            latest_pack_ts = ""
            ack_by_reply = {}
            for msg in client.iter_messages(resolved_to_peer, limit=args.scan_limit):
                if msg and msg.message and ack_text and msg.message.startswith(ack_text):
                    if getattr(msg, "reply_to_msg_id", None):
                        ack_by_reply[msg.reply_to_msg_id] = msg.message
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
            if not latest_pack:
                py(
                    f"No previous packs found (checked last {args.scan_limit} messages for "
                    f"{args.pack_prefix}_{args.project_name}_*.tgz)."
                )
                return 0

            ack_msg = ack_by_reply.get(latest_pack.id)
            if ack_msg:
                current_sha = (args.current_sha or "").strip().lower()
                if current_sha:
                    m = re.search(r"sha:([0-9a-fA-F]{6,64})", ack_msg)
                    if m and current_sha.startswith(m.group(1).lower()):
                        err("Latest pack already closed with same SHA.")
                        return 5
                if args.meta_file:
                    try:
                        with open(args.meta_file, "w", encoding="utf-8") as fh:
                            fh.write(f"message_id={latest_pack.id}\n")
                            fh.write(f"file_name={getattr(latest_pack.file,'name','')}\n")
                            fh.write("status=acked\n")
                    except OSError:
                        pass
                return 0

            if args.meta_file:
                try:
                    with open(args.meta_file, "w", encoding="utf-8") as fh:
                        fh.write(f"message_id={latest_pack.id}\n")
                        fh.write(f"file_name={getattr(latest_pack.file,'name','')}\n")
                        fh.write("status=unacked\n")
                except OSError:
                    pass
            err("Previous pack not acknowledged yet. Wait for 'Closed by ...' reply.")
            return 4

        if args.delete_message:
            run_wait_step("Connect Telegram", client.connect)
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            resolved_to_peer = resolve_peer(to_peer, "telegram_to")
            run_wait_step(
                "Delete message",
                lambda: client.delete_messages(resolved_to_peer, [args.delete_message]),
            )
            py("Message deleted.")
            return 0

        if args.pull_latest:
            run_wait_step("Connect Telegram", client.connect)
            ensure_authorized()
            py(f"Authorized: {client.is_user_authorized()}")
            entity = resolve_peer(from_peer, "telegram_from")
            pattern = re.compile(
                rf"^{re.escape(args.pack_prefix)}_{re.escape(args.project_name)}_([0-9]{{8}}_[0-9]{{6}})\.tgz$"
            )
            ack_text = (args.ack_text or "Closed by").strip()
            ack_prefixes = [ack_text]
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
            if args.no_tmp_rename:
                tmp_path = dest_path
            elif os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

            total_hint = 0
            try:
                total_hint = int(getattr(best_msg.file, "size", 0) or 0)
            except Exception:
                total_hint = 0
            progress_cb, progress_suffix = make_upload_progress_logger(total_hint, "download", show_initial=True)
            run_wait_step(
                "Download from Telegram",
                lambda: download_file_with_timeout(
                    client=client,
                    message=best_msg,
                    dest_path=tmp_path,
                    final_path=dest_path,
                    progress_callback=progress_cb,
                ),
                status_suffix=progress_suffix,
            )
            py(f"Downloaded: {dest_path}")
            if args.path_file:
                with open(args.path_file, "w", encoding="utf-8") as fh:
                    fh.write(dest_path)

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
            ack_text = (args.ack_text or "Closed by").strip()
            ack_prefixes = [ack_text]
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
                    err("Previous pack not acknowledged yet. Wait for 'Closed by ...' reply.")
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
                    err("Previous pack not acknowledged yet. Wait for 'Closed by ...' reply.")
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
                parse_mode=args.parse_mode or "md",
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
