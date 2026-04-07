# sync_tool

Pack a Git repository into a `.tgz`, send it through Telegram, and take/apply the latest archive on another machine.

The user-facing commands are:

- `./pack`
- `./unpack`

## Quick Start

```bash
./pack setup
./pack doctor
./pack send setup
./pack send

./unpack setup
./unpack doctor
./unpack take setup
./unpack take
```

## Install

Telegram flows use the offline wheels from `offline/python_wheels`.

```bash
python -m ensurepip --upgrade
python -m pip install --no-index --find-links offline/python_wheels telethon colorama python-socks
```

Package notes:

- `telethon` is the Telegram client library
- `colorama` improves terminal output on Windows
- `python-socks` is required for transport proxy modes: `socks5` and `http`
- MTProto proxy uses a dedicated Telethon connection mode

Quick import check:

```bash
python -c "import telethon, colorama, pyaes, rsa, pyasn1; print('ok')"
```

## Configuration

The tool now uses one required root config file:

- `conf.toml` for live settings
- `conf.example.toml` as a full template

`conf.toml` is expected in the target project root:

- for `pack*`, that means the current Git repository top-level
- for `unpack*`, that means the current Git repository top-level if you are inside one, otherwise the current directory

`conf.toml` is intentionally ignored by Git through `.gitignore`.

## Config Layout

```toml
[pack]
output_dir = "C:/Users/USERNAME/syncpacks"
pack_prefix = "syncpack"
machine_name = ""
remote_name = "origin"
# update = -1

[pack.send.telegram]
to = "https://t.me/your-destination"

[unpack]
pack_dir = "C:/Users/USERNAME/syncpacks"
pack_prefix = "syncpack"
project_name = ""
peer = "sync"
ff_only = true
force_tags = false
prune_remote_refs = true
prune_local_branches = false
clean_peer_refs = true

[unpack.take.telegram]
from = "https://t.me/your-source"

[telegram.common]
api_id = 123456
api_hash = "replace_me"
session = "C:/Users/USERNAME/.sync_tool_telegram"
session_string = ""
phone = "+70000000000"
ack_scan_limit = 32
caption = ""
python_min = "3.8"
```

Proxy is optional. If you use it, define at most one of these blocks:

```toml
[telegram.common.proxy.socks5]
host = "127.0.0.1"
port = 1080
username = ""
password = ""
```

```toml
[telegram.common.proxy.http]
host = "proxy.example.com"
port = 8080
username = ""
password = ""
```

```toml
[telegram.common.proxy.mtproto]
host = "mtproxy.example.com"
port = 443
secret = "0123456789abcdef0123456789abcdef"
```

If no `telegram.common.proxy.*` section exists, Telegram works without a proxy.

## Setup Commands

Interactive setup updates only the relevant TOML section and rewrites `conf.toml` atomically.

```bash
./pack setup
./pack send setup
./unpack setup
./unpack take setup
```

What each one edits:

- `./pack setup` -> `[pack]`
- `./pack send setup` -> `[pack.send.telegram]`
- `./unpack setup` -> `[unpack]`
- `./unpack take setup` -> `[unpack.take.telegram]`

Common Telegram settings and proxy settings are edited manually in `conf.toml`.

## Doctor Commands

Use doctor commands to validate config and environment before running the real operation.

```bash
./pack doctor
./pack send doctor
./unpack doctor
./unpack take doctor
```

What they check:

- `./pack doctor` validates `[pack]` and runs the pack flow in dry-run mode
- `./pack send doctor` validates `[pack]`, `[pack.send.telegram]`, `[telegram.common]`, and Telegram connectivity prerequisites
- `./unpack doctor` validates `[unpack]`
- `./unpack take doctor` validates `[unpack]`, `[unpack.take.telegram]`, `[telegram.common]`, and take prerequisites

`--dry-run` still exists on the real runtime commands and means “show what this invocation would do”.

## Runtime Commands

Create a local archive:

```bash
./pack
```

Create a local archive using config, but override one value from CLI:

```bash
./pack --output-dir /tmp/syncpacks
./pack --update
./pack --update 14
```

Create and send an archive through Telegram:

```bash
./pack send
```

Apply the latest local archive:

```bash
./unpack
```

Take the latest archive from Telegram and apply it:

```bash
./unpack take
```

CLI flags still override `conf.toml` for the current invocation.

Examples:

- `./pack --update` overrides `[pack].update`
- `./pack --update 14` overrides `[pack].update`
- `./unpack --peer mirror` overrides `[unpack].peer`

Important `pack --update` behavior:

- if `[pack].update` is absent, no remote update happens
- if `[pack].update = -1`, remote update refreshes only already existing local branches
- if `[pack].update > 0`, remote update also brings in recent remote branches from the last N days

## Troubleshooting

- `conf.toml` is missing: run the relevant setup command first.
- Telegram auth is missing or expired: update `[telegram.common]` manually and rerun a `doctor` command.
- Proxy config is invalid: keep at most one `telegram.common.proxy.*` block.
- `pack doctor` fails on a dirty repository: commit or stash everything except `conf.toml` / `conf.example.toml`.
- `pack send` or `unpack take` on Windows cannot find proxy support: install `python-socks` from `offline/python_wheels`.
