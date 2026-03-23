# sync_tool

Pack a Git repository into a `.tgz`, send it through Telegram, and pull/apply the latest archive on another machine.

The project is built around two user-facing commands:

- `./pack` to create an archive, and optionally send it to Telegram
- `./unpack` to apply a local archive, or pull the latest one from Telegram first

## Quick Start

```bash
./pack
./pack --mproto-login
./pack push
./unpack pull
```

- `./pack` creates a local sync archive in `~/syncpacks`
- `./pack --mproto-login` creates or refreshes `conf/telegram.conf`
- `./pack push` creates an archive and sends it through Telegram
- `./unpack pull` downloads the latest archive from Telegram and applies it

## Install

The Telegram flows use offline Python wheels from `offline/python_wheels`.

```bash
python -m ensurepip --upgrade
python -m pip install --no-index --find-links offline/python_wheels telethon colorama python-socks
```

Package notes:

- `telethon` is the Telegram client library
- `colorama` keeps console output readable on Windows terminals
- `python-socks` is needed for transport proxy mode via `telegram_proxy`
- MTProto proxy uses a separate Telegram connection mode and does not use `python-socks`

Quick import check:

```bash
python -c "import telethon, colorama, pyaes, rsa, pyasn1; print('ok')"
```

## Configuration

The tool uses three config files:

- `conf/pack.conf` for archive creation defaults such as output directory, prefix, branch selection, and remote update behavior
- `conf/unpack.conf` for archive apply defaults such as input directory, project name, peer name, and prune/fast-forward behavior
- `conf/telegram.conf` for Telegram login/session settings and proxy configuration

You do not need every file on day one. The smallest useful path is:

1. install the Python packages
2. run `./pack --mproto-login`
3. use `./pack push` and `./unpack pull`

## Telegram Config

Base example without proxy:

```ini
telegram_api_id=123456
telegram_api_hash=0123456789abcdef0123456789abcdef
telegram_session=~/.sync_tool_telegram
telegram_to=@target_chat
telegram_from=@source_chat
telegram_python_min=3.8
```

Transport proxy example:

```ini
telegram_proxy=socks5://user:pass@127.0.0.1:1080
```

Supported transport proxy schemes are `socks5`, `socks4`, and `http`.

MTProto proxy example:

```ini
telegram_mtproxy_host=mtproxy.example.com
telegram_mtproxy_port=443
telegram_mtproxy_secret=00000000000000000000000000000000
```

Important:

- use `telegram_to` for `pack push`
- use `telegram_from` for `unpack pull`
- you can keep either `telegram_session` or `telegram_session_string`
- `telegram_proxy` and `telegram_mtproxy_*` are mutually exclusive

## Common Workflows

Create a local archive:

```bash
./pack
```

Create and send an archive through Telegram:

```bash
./pack push
```

First Telegram login or session refresh:

```bash
./pack --mproto-login
```

Find a Telegram chat before saving `telegram_to`:

```bash
./pack --list-chat my-project
```

Apply the latest local archive from `~/syncpacks`:

```bash
./unpack
```

Pull the latest archive from Telegram and apply it:

```bash
./unpack pull
```

## Compact Reference

### `pack`

Most useful options:

- `--output-dir PATH`
- `--pack-prefix PREFIX`
- `--machine-name NAME`
- `-u`, `--update-remote`
- `--remote NAME`
- `--recent-days N`
- `--branch NAME`
- `--branches LIST`
- `--with-tags 0|1`
- `--dry-run`

### `pack push`

Uses the same pack options, then sends the resulting archive through Telegram.

Important behavior:

- requires `conf/telegram.conf`
- prompts for `telegram_to` if it is still missing
- supports both transport proxy and MTProto proxy through `conf/telegram.conf`

### `pack --mproto-login`

Use this when:

- setting up Telegram for the first time
- refreshing a broken or expired session
- changing account/session settings in `conf/telegram.conf`

Related capability:

- `--list-chat TEXT` lists matching chats by name or username

### `unpack`

Most useful options:

- `--pack-dir PATH`
- `--pack-file PATH`
- `--pack-prefix PREFIX`
- `--project-name NAME`
- `--peer NAME`
- `--dry-run`
- `--ff-only 0|1`
- `--force-tags 0|1`
- `--prune-remote-refs 0|1`
- `--prune-local-branches 0|1`
- `--clean-peer-refs 0|1`

### `unpack pull`

Uses the unpack options, but downloads the latest matching archive from Telegram first.

Important behavior:

- requires `conf/telegram.conf`
- uses `telegram_from` as the source chat
- supports both transport proxy and MTProto proxy through `conf/telegram.conf`

## Troubleshooting

- Missing Python packages: rerun the offline `pip install` command from this README.
- Telegram is not configured: run `./pack --mproto-login`.
- `pack push` has no destination chat: set `telegram_to` or let the command prompt for it.
- `unpack pull` has no source chat: set `telegram_from` in `conf/telegram.conf`.
- Proxy config is invalid: use either `telegram_proxy` or `telegram_mtproxy_*`, not both.
