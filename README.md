# Offline Python deps for `pack -s`

Directory `offline/python_wheels` contains all Python packages required for Telegram send mode:

- `telethon`
- `colorama`
- `python-socks` (required only when `telegram_proxy` is used)
- transitive deps: `pyaes`, `rsa`, `pyasn1`

## Install on an offline machine

Run from project root:

```bash
python -m ensurepip --upgrade
python -m pip install --no-index --find-links offline/python_wheels telethon colorama python-socks
```

## Quick check

```bash
python -c "import telethon, colorama, pyaes, rsa, pyasn1; print('ok')"
```
