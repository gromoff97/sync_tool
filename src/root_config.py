#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
import tempfile
from typing import Any, Dict, Mapping, Optional, Tuple

try:
    import tomllib  # type: ignore[attr-defined]
except Exception:  # pragma: no cover
    tomllib = None

if tomllib is None:  # pragma: no cover
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(
            "TOML parsing requires Python 3.11+ or the tomli package."
        ) from exc


PACK_COMMANDS = {
    "pack",
    "pack-setup",
    "pack-doctor",
    "pack-send",
    "pack-send-setup",
    "pack-send-doctor",
}

UNPACK_COMMANDS = {
    "unpack",
    "unpack-setup",
    "unpack-doctor",
    "unpack-take",
    "unpack-take-setup",
    "unpack-take-doctor",
}

REMOVED_CONFIG_KEYS = {
    "pack.update_remote": "[pack].update_remote is no longer supported; use [pack].update",
    "pack.recent_days": "[pack].recent_days is no longer supported; use [pack].update",
    "pack.machine_name": "[pack].machine_name is no longer supported; use [telegram.common].local_machine_name",
    "unpack.project_name": "[unpack].project_name is no longer supported; use --project-name for outside-repo unpack take bootstrap",
    "telegram.common.session_string": "[telegram.common].session_string is no longer supported; use [telegram.common].session",
    "telegram.common.phone": "[telegram.common].phone is no longer supported",
    "telegram.common.caption": "[telegram.common].caption is no longer supported",
    "telegram.common.python_min": "[telegram.common].python_min is no longer supported",
}

REMOVED_CONFIG_TABLES = {
    "pack.push.telegram": "[pack.push.telegram] is no longer supported; use [pack.send.telegram]",
    "unpack.pull.telegram": "[unpack.pull.telegram] is no longer supported; use [unpack.take.telegram]",
}


def normalize_command(command: str) -> str:
    value = (command or "").strip().lower().replace(" ", "-")
    if value not in PACK_COMMANDS | UNPACK_COMMANDS:
        raise ValueError(f"Unsupported command scope: {command}")
    return value


def resolve_config_root(command: str, cwd: str, git_top_level: str, tool_root: str) -> str:
    normalize_command(command)
    cwd = os.path.abspath(cwd)
    git_top_level = os.path.abspath(git_top_level) if git_top_level else ""
    tool_root = os.path.abspath(tool_root) if tool_root else ""
    if not tool_root:
        raise ValueError("tool_root is required to resolve global conf.toml")
    return tool_root


def load_conf_toml(path: str) -> Dict[str, Any]:
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    if not isinstance(data, dict):
        raise ValueError("conf.toml must parse into a top-level table")
    return data


def _lookup_path(document: Mapping[str, Any], dotted_path: str) -> Any:
    current: Any = document
    for segment in dotted_path.split("."):
        if not isinstance(current, Mapping) or segment not in current:
            return None
        current = current[segment]
    return current


def table_exists(document: Mapping[str, Any], dotted_path: str) -> bool:
    value = _lookup_path(document, dotted_path)
    return isinstance(value, Mapping)


def extract_table(document: Mapping[str, Any], dotted_path: str) -> Dict[str, Any]:
    value = _lookup_path(document, dotted_path)
    if not isinstance(value, Mapping):
        raise KeyError(f"Table not found: {dotted_path}")
    return dict(value)


def _find_removed_entry(
    document: Mapping[str, Any],
    prefix: str = "",
) -> Optional[Tuple[str, str]]:
    for key, value in document.items():
        path = f"{prefix}.{key}" if prefix else key
        if path in REMOVED_CONFIG_KEYS and not isinstance(value, Mapping):
            return path, REMOVED_CONFIG_KEYS[path]
        if isinstance(value, Mapping):
            if path in REMOVED_CONFIG_TABLES:
                return path, REMOVED_CONFIG_TABLES[path]
            found = _find_removed_entry(value, path)
            if found is not None:
                return found
    return None


def validate_update_value(value: Any) -> None:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError("[pack].update must be an integer")
    if value == 0 or value < -1:
        raise ValueError("[pack].update must be -1 or a positive integer")


def validate_document(document: Mapping[str, Any]) -> None:
    removed = _find_removed_entry(document)
    if removed is not None:
        raise ValueError(removed[1])
    pack = _lookup_path(document, "pack")
    if isinstance(pack, Mapping) and "update" in pack:
        validate_update_value(pack["update"])


def _stringify(value: Any) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if value is None:
        return ""
    return str(value)


def flatten_table(document: Mapping[str, Any], dotted_path: str, prefix: str) -> Dict[str, str]:
    table = extract_table(document, dotted_path)
    result: Dict[str, str] = {}
    for key, value in table.items():
        if isinstance(value, Mapping):
            continue
        result[f"{prefix}{key.upper()}"] = _stringify(value)
    return result


def detect_proxy_settings(document: Mapping[str, Any]) -> Dict[str, str]:
    proxy_paths = (
        ("socks5", "telegram.common.proxy.socks5"),
        ("http", "telegram.common.proxy.http"),
        ("mtproto", "telegram.common.proxy.mtproto"),
    )
    found = [(mode, path) for mode, path in proxy_paths if table_exists(document, path)]
    if len(found) > 1:
        raise ValueError(
            "Only one [telegram.common.proxy.*] table is allowed in conf.toml."
        )
    if not found:
        return {"CFG_TELEGRAM_PROXY_MODE": "none"}

    mode, path = found[0]
    table = extract_table(document, path)
    exported = {"CFG_TELEGRAM_PROXY_MODE": mode}
    for key, value in table.items():
        if isinstance(value, Mapping):
            raise ValueError(f"Nested proxy tables are not supported in {path}.{key}")
        exported[f"CFG_TELEGRAM_PROXY_{key.upper()}"] = _stringify(value)
    return exported


def export_config(document: Mapping[str, Any]) -> Dict[str, str]:
    validate_document(document)
    exported: Dict[str, str] = {}
    if table_exists(document, "pack"):
        exported.update(flatten_table(document, "pack", "CFG_PACK_"))
    if table_exists(document, "pack.send.telegram"):
        exported.update(flatten_table(document, "pack.send.telegram", "CFG_PACK_SEND_TELEGRAM_"))
    if table_exists(document, "unpack"):
        exported.update(flatten_table(document, "unpack", "CFG_UNPACK_"))
    if table_exists(document, "unpack.take.telegram"):
        exported.update(flatten_table(document, "unpack.take.telegram", "CFG_UNPACK_TAKE_TELEGRAM_"))
    if table_exists(document, "telegram.common"):
        exported.update(flatten_table(document, "telegram.common", "CFG_TELEGRAM_COMMON_"))
    exported.update(detect_proxy_settings(document))
    return exported


def shell_export_lines(values: Mapping[str, str]) -> str:
    lines = []
    for key in sorted(values):
        lines.append(f"{key}={shlex.quote(values[key])}")
    return "\n".join(lines) + ("\n" if lines else "")


def build_export(command: str, cwd: str, git_top_level: str, tool_root: str) -> Dict[str, str]:
    config_root = resolve_config_root(command, cwd, git_top_level, tool_root)
    config_file = os.path.join(config_root, "conf.toml")
    exported = {
        "CFG_CONFIG_ROOT": config_root,
        "CFG_CONFIG_FILE": config_file,
        "CFG_HAS_CONF_TOML": "1" if os.path.isfile(config_file) else "0",
    }
    if not os.path.isfile(config_file):
        return exported
    exported.update(export_config(load_conf_toml(config_file)))
    return exported


def _format_toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    raise ValueError(f"Unsupported TOML value type: {type(value).__name__}")


def dump_conf_toml(document: Mapping[str, Any]) -> str:
    lines = []

    def emit_table(path: str, table: Mapping[str, Any]) -> None:
        scalar_items = [(key, value) for key, value in table.items() if not isinstance(value, Mapping)]
        child_keys = [key for key, value in table.items() if isinstance(value, Mapping)]

        if path and scalar_items:
            lines.append(f"[{path}]")
        for key, value in scalar_items:
            lines.append(f"{key} = {_format_toml_value(value)}")
        for index, key in enumerate(child_keys):
            if lines and lines[-1] != "":
                lines.append("")
            child_path = f"{path}.{key}" if path else key
            emit_table(child_path, table[key])
            if index != len(child_keys) - 1:
                lines.append("")

    emit_table("", document)
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines) + ("\n" if lines else "")


def save_conf_toml(path: str, document: Mapping[str, Any]) -> None:
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    payload = dump_conf_toml(document)
    fd, tmp_path = tempfile.mkstemp(prefix=".conf.", suffix=".toml.tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def set_table(document: Dict[str, Any], dotted_path: str, values: Mapping[str, Any]) -> Dict[str, Any]:
    current: Dict[str, Any] = document
    segments = dotted_path.split(".")
    for segment in segments[:-1]:
        next_value = current.get(segment)
        if not isinstance(next_value, dict):
            next_value = {}
            current[segment] = next_value
        current = next_value
    existing = current.get(segments[-1])
    merged: Dict[str, Any] = {}
    if isinstance(existing, Mapping):
        for key, value in existing.items():
            if isinstance(value, Mapping):
                merged[key] = value
    merged.update(values)
    current[segments[-1]] = merged
    return document


def update_table_file(path: str, dotted_path: str, values: Mapping[str, Any]) -> None:
    if os.path.exists(path):
        document = load_conf_toml(path)
    else:
        document = {}
    set_table(document, dotted_path, values)
    validate_document(document)
    save_conf_toml(path, document)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve sync_tool root conf.toml values.")
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    export_parser = subparsers.add_parser("export", help="Export conf.toml values as shell assignments")
    export_parser.add_argument("--command", required=True)
    export_parser.add_argument("--cwd", required=True)
    export_parser.add_argument("--git-top-level", default="")
    export_parser.add_argument("--tool-root", required=True)

    update_parser = subparsers.add_parser("update-table", help="Replace one TOML table atomically")
    update_parser.add_argument("--config-file", required=True)
    update_parser.add_argument("--table", required=True)
    update_parser.add_argument("--set", action="append", default=[])

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command_name == "export":
        values = build_export(args.command, args.cwd, args.git_top_level, args.tool_root)
        sys.stdout.write(shell_export_lines(values))
        return 0
    if args.command_name == "update-table":
        values: Dict[str, Any] = {}
        for item in args.set:
            if "=" not in item:
                raise ValueError(f"Invalid --set entry: {item}")
            key, raw_value = item.split("=", 1)
            if raw_value.lower() in ("true", "false"):
                values[key] = raw_value.lower() == "true"
            elif re.fullmatch(r"-?\d+", raw_value):
                values[key] = int(raw_value)
            else:
                values[key] = raw_value
        update_table_file(args.config_file, args.table, values)
        return 0
    raise ValueError(f"Unsupported command: {args.command_name}")


if __name__ == "__main__":
    raise SystemExit(main())
