#!/usr/bin/env bash
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
else
  C_RESET=''
  C_RED=''
  C_YELLOW=''
  C_CYAN=''
  C_GREEN=''
  C_BLUE=''
  C_MAGENTA=''
fi

log_pack()  { printf '%b[PACK]%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
log_git()   { printf '%b[GIT]%b  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_tar()   { printf '%b[TAR]%b  %s\n' "$C_MAGENTA" "$C_RESET" "$*"; }
log_py()    { printf '%b[PY]%b   %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%b[PACK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
die()       { printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_tools() {
  have git || die "git not found"
  have tar || die "tar not found"
  have awk || die "awk not found"
  have sort || die "sort not found"
  have wc  || die "wc not found"
}

mktemp_dir() {
  if have mktemp; then
    mktemp -d 2>/dev/null && return 0
  fi
  local d="./.tmp_pack_$$"
  mkdir -p "$d"
  echo "$d"
}

sha256_file() {
  local f="$1"
  if have sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 "$f" | awk '{print $2}'
  else
    die "No sha256 tool found (sha256sum/shasum/openssl)."
  fi
}

sha256_text() {
  local s="$1"
  if have sha256sum; then
    printf '%s' "$s" | sha256sum | awk '{print $1}'
  elif have shasum; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  elif have openssl; then
    printf '%s' "$s" | openssl dgst -sha256 | awk '{print $2}'
  else
    die "No sha256 tool found (sha256sum/shasum/openssl)."
  fi
}

detect_machine_name() {
  local name=""
  if have hostname; then
    name="$(hostname 2>/dev/null || true)"
  fi
  if [[ -z "$name" ]]; then
    name="${COMPUTERNAME:-${HOSTNAME:-}}"
  fi
  [[ -n "$name" ]] || name="unknown"
  printf '%s' "$name"
}

sanitize_for_manifest() {
  # just strip CR/LF; keep the rest as-is (manifest is text)
  local s="$1"
  s="$(echo "$s" | tr -d '\r\n')"
  [[ -n "$s" ]] || s="unknown"
  printf '%s' "$s"
}

escape_md() {
  # Escape common Markdown meta chars for Telegram 'md' parse mode.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\*/\\*}"
  s="${s//_/\\_}"
  s="${s//\`/\\\`}"
  s="${s//[/\\[}"
  s="${s//]/\\]}"
  s="${s//(/\\(}"
  s="${s//)/\\)}"
  printf '%s' "$s"
}

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_quotes() {
  local s="$1"
  if [[ ${#s} -ge 2 ]]; then
    if [[ "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
      s="${s:1:${#s}-2}"
    elif [[ "${s:0:1}" == "'" && "${s: -1}" == "'" ]]; then
      s="${s:1:${#s}-2}"
    fi
  fi
  printf '%s' "$s"
}

expand_user_path() {
  local p="$1"
  case "$p" in
    "~")
      [[ -n "${HOME:-}" ]] || die "HOME is not set; cannot expand '~' in config."
      printf '%s' "$HOME"
      ;;
    "~/"*)
      [[ -n "${HOME:-}" ]] || die "HOME is not set; cannot expand '~/' in config."
      printf '%s' "$HOME/${p#~/}"
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}

load_config_overrides() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0

  local raw line key value
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="$(trim_ws "$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || die "Invalid config line in $cfg: $raw"

    key="$(trim_ws "${line%%=*}")"
    value="$(trim_ws "${line#*=}")"
    value="$(strip_quotes "$value")"

    case "$key" in
      output_dir|OUTPUT_DIR)       OUTPUT_DIR="$(expand_user_path "$value")" ;;
      pack_prefix|PACK_PREFIX)     PACK_PREFIX="$value" ;;
      machine_name|MACHINE_NAME)   MACHINE_NAME="$value" ;;
      *) ;;
    esac
  done < "$cfg"
}

load_telegram_config() {
  local cfg="$1"
  TG_API_ID=""
  TG_API_HASH=""
  TG_TO=""
  TG_SESSION=""
  TG_SESSION_STRING=""
  TG_PHONE=""
  TG_CODE=""
  TG_PASSWORD=""
  TG_CAPTION=""
  TG_PYTHON_MIN="3.8"

  [[ -f "$cfg" ]] || return 0

  local raw line key value
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="$(trim_ws "$line")"
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || die "Invalid config line in $cfg: $raw"

    key="$(trim_ws "${line%%=*}")"
    value="$(trim_ws "${line#*=}")"
    value="$(strip_quotes "$value")"

    case "$key" in
      telegram_api_id|TELEGRAM_API_ID|api_id|API_ID) TG_API_ID="$value" ;;
      telegram_api_hash|TELEGRAM_API_HASH|api_hash|API_HASH) TG_API_HASH="$value" ;;
      telegram_to|TELEGRAM_TO|to|TO|telegram_peer|TELEGRAM_PEER|peer|PEER) TG_TO="$value" ;;
      telegram_session|TELEGRAM_SESSION|session|SESSION) TG_SESSION="$(expand_user_path "$value")" ;;
      telegram_session_string|TELEGRAM_SESSION_STRING|session_string|SESSION_STRING) TG_SESSION_STRING="$value" ;;
      telegram_phone|TELEGRAM_PHONE|phone|PHONE) TG_PHONE="$value" ;;
      telegram_code|TELEGRAM_CODE|code|CODE) TG_CODE="$value" ;;
      telegram_password|TELEGRAM_PASSWORD|password|PASSWORD) TG_PASSWORD="$value" ;;
      telegram_caption|TELEGRAM_CAPTION|caption|CAPTION) TG_CAPTION="$value" ;;
      telegram_python_min|TELEGRAM_PYTHON_MIN|python_min|PYTHON_MIN) TG_PYTHON_MIN="$value" ;;
      *) ;;
    esac
  done < "$cfg"

  [[ -z "$TG_API_ID" || "$TG_API_ID" =~ ^[0-9]+$ ]] || die "telegram_api_id must be an integer in $cfg"
  [[ "$TG_PYTHON_MIN" =~ ^[0-9]+\.[0-9]+$ ]] || die "telegram_python_min must be MAJOR.MINOR in $cfg"
}

python_version_at_least() {
  local py_bin="$1" min_major="$2" min_minor="$3"
  "$py_bin" - "$min_major" "$min_minor" >/dev/null 2>&1 <<'PY'
import sys
min_major = int(sys.argv[1])
min_minor = int(sys.argv[2])
sys.exit(0 if (sys.version_info.major, sys.version_info.minor) >= (min_major, min_minor) else 1)
PY
}

python_module_available() {
  local py_bin="$1" module="$2"
  "$py_bin" - "$module" >/dev/null 2>&1 <<'PY'
import importlib
import sys
importlib.import_module(sys.argv[1])
PY
}

select_python_for_telegram() {
  local min_ver="$1"
  local min_major="${min_ver%%.*}"
  local min_minor="${min_ver##*.}"
  local py_bin

  for py_bin in python3 python; do
    if have "$py_bin" && python_version_at_least "$py_bin" "$min_major" "$min_minor"; then
      printf '%s' "$py_bin"
      return 0
    fi
  done

  die "Python >= $min_ver not found (required for Telegram upload)."
}

send_to_telegram_personal() {
  local file="$1" caption="$2" config_file="$3"
  local py_bin
  py_bin="$(select_python_for_telegram "$TG_PYTHON_MIN")"
  python_module_available "$py_bin" "telethon" || die "Python module 'telethon' is not installed for $py_bin. Install it before using -s."

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/send_telegram_personal.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  local -a cmd
  local -a py_cmd
  py_cmd=("$py_bin" "-u")
  # Git Bash + Windows console Python can lose interactive prompts without winpty.
  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$config_file"
    --to "$TG_TO"
    --file "$file"
  )
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi
  if [[ -n "$TG_PHONE" ]]; then
    cmd+=(--phone "$TG_PHONE")
  fi
  if [[ -n "$TG_CODE" ]]; then
    cmd+=(--code "$TG_CODE")
  fi
  if [[ -n "$TG_PASSWORD" ]]; then
    cmd+=(--password "$TG_PASSWORD")
  fi
  if [[ -n "$caption" ]]; then
    cmd+=(--caption "$caption")
  fi

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}" || die "Telegram personal upload failed."
  else
    "${cmd[@]}" || die "Telegram personal upload failed."
  fi
}

gitpath() { git -C "$1" rev-parse --git-path "$2"; }

repo_roots_fingerprint() {
  local repo="$1"
  local roots
  roots="$(git -C "$repo" rev-list --max-parents=0 --all 2>/dev/null | tr -d '\r' | sort)"
  [[ -n "$roots" ]] || die "Failed to compute repo roots (is the repo shallow or corrupt?)"
  sha256_text "$roots"
}

ensure_repo_ok_and_clean() {
  local repo="$1"
  [[ -d "$repo" ]] || die "Repository path is not a directory: $repo"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository: $repo"
  local is_bare
  is_bare="$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null || echo true)"
  [[ "$is_bare" == "false" ]] || die "Repository is bare (not supported): $repo"

  git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1 || die "HEAD is invalid/missing (empty repo?): $repo"

  local branch_count
  branch_count="$(git -C "$repo" show-ref --heads | wc -l | awk '{print $1}')"
  [[ "${branch_count:-0}" -gt 0 ]] || die "No local branches found (refs/heads/*)."

  local p
  p="$(gitpath "$repo" MERGE_HEAD)";        [[ ! -f "$p" ]] || die "Merge in progress. Finish/abort."
  p="$(gitpath "$repo" CHERRY_PICK_HEAD)";  [[ ! -f "$p" ]] || die "Cherry-pick in progress. Finish/abort."
  p="$(gitpath "$repo" REVERT_HEAD)";       [[ ! -f "$p" ]] || die "Revert in progress. Finish/abort."
  p="$(gitpath "$repo" rebase-apply)";      [[ ! -d "$p" ]] || die "Rebase in progress (rebase-apply). Finish/abort."
  p="$(gitpath "$repo" rebase-merge)";      [[ ! -d "$p" ]] || die "Rebase in progress (rebase-merge). Finish/abort."
  p="$(gitpath "$repo" BISECT_LOG)";        [[ ! -f "$p" ]] || die "Bisect in progress. Finish/reset."
  p="$(gitpath "$repo" index.lock)";        [[ ! -f "$p" ]] || die "index.lock exists. Another git process running?"

  local st
  st="$(git -C "$repo" status --porcelain)"
  [[ -z "$st" ]] || die "Repo has uncommitted/untracked changes. Commit/stash first."
}

usage() {
  cat >&2 <<'EOF'
pack.sh — create FULL git bundle pack (all branches + tags) into a .tgz
File name: <prefix>_<project>_<timestamp>.tgz

Optional (defaults):
  --output-dir PATH          (default: ~/syncpacks)
  --pack-prefix PREFIX       (default: syncpack)
  --machine-name NAME        (default: auto-detected; written to manifest only)
  -s                         send archive from personal account using <tool_dir>/conf/telegram.conf
  --help

Config:
  <tool_dir>/conf/pack.conf (if present) overrides pack options above.
  <tool_dir>/conf/telegram.conf used only with -s.
                       Missing values are requested interactively on first run
                       and persisted back to telegram.conf automatically.
                       supported keys:
                       telegram_api_id, telegram_api_hash, telegram_to
                       telegram_session or telegram_session_string
                       telegram_phone, telegram_code, telegram_password
                       (code can be entered interactively)
                       telegram_caption, telegram_python_min
                       default caption (if not set): From **machine_name**
                       (default python minimum: 3.8)

Example:
  ./pack -s
EOF
  exit 2
}

# ---- parse args ----
require_tools

OUTPUT_DIR="${HOME:+$HOME/syncpacks}"
PACK_PREFIX="syncpack"
MACHINE_NAME=""
SEND_TO_TELEGRAM="0"
TG_API_ID=""
TG_API_HASH=""
TG_TO=""
TG_SESSION=""
TG_CAPTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)      OUTPUT_DIR="${2:-}"; shift 2;;
    --output-dir=*)    OUTPUT_DIR="${1#*=}"; shift 1;;
    --pack-prefix)     PACK_PREFIX="${2:-}"; shift 2;;
    --pack-prefix=*)   PACK_PREFIX="${1#*=}"; shift 1;;
    --machine-name)    MACHINE_NAME="${2:-}"; shift 2;;
    --machine-name=*)  MACHINE_NAME="${1#*=}"; shift 1;;
    -s)               SEND_TO_TELEGRAM="1"; shift 1;;
    --help|-h)         usage;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_DIR" ]] || die "Run pack.sh inside a git repository."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$TOOL_DIR/conf/pack.conf"
load_config_overrides "$CONFIG_FILE"

[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"
[[ -n "$OUTPUT_DIR" ]] || die "HOME is not set; use --output-dir PATH."

if [[ -z "$MACHINE_NAME" ]]; then
  MACHINE_NAME="$(detect_machine_name)"
fi
MACHINE_NAME="$(sanitize_for_manifest "$MACHINE_NAME")"

PROJECT_NAME="$(basename "$REPO_DIR")"
PROJECT_NAME="$(sanitize_for_manifest "$PROJECT_NAME")"

mkdir -p "$OUTPUT_DIR" || die "Cannot create --output-dir: $OUTPUT_DIR"
ensure_repo_ok_and_clean "$REPO_DIR"
log_pack "Repository: $REPO_DIR"
log_pack "Project: $PROJECT_NAME"
log_pack "Output directory: $OUTPUT_DIR"

repo_roots_sha="$(repo_roots_fingerprint "$REPO_DIR")"

tmp="$(mktemp_dir)"
cleanup() { rm -rf "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

bundle="$tmp/bundle.bundle"
manifest="$tmp/manifest.tsv"

log_git "Creating full git bundle (branches + tags)..."
create_out="$tmp/git_bundle_create.txt"
if ! git -C "$REPO_DIR" bundle create "$bundle" --branches --tags >"$create_out" 2>&1; then
  cat "$create_out" >&2
  die "git bundle create failed"
fi

verify_out="$tmp/bundle_verify.txt"
if ! git -C "$REPO_DIR" bundle verify "$bundle" >"$verify_out" 2>&1; then
  cat "$verify_out" >&2
  die "Bundle verification failed (unexpected for full bundle)."
fi

bundle_sha="$(sha256_file "$bundle")"

{
  echo -e "key\tvalue"
  echo -e "pack_prefix\t$PACK_PREFIX"
  echo -e "project_name\t$PROJECT_NAME"
  echo -e "machine_name\t$MACHINE_NAME"
  echo -e "created_at\t$(date -Iseconds 2>/dev/null || date)"
  echo -e "git_version\t$(git --version)"
  echo -e "repo_head\t$(git -C "$REPO_DIR" rev-parse HEAD)"
  echo -e "repo_roots_sha256\t$repo_roots_sha"
  echo -e "bundle_sha256\t$bundle_sha"
  echo -e "branches_count\t$(git -C "$REPO_DIR" show-ref --heads | wc -l | awk '{print $1}')"
  echo -e "tags_count\t$(git -C "$REPO_DIR" show-ref --tags 2>/dev/null | wc -l | awk '{print $1}')"
} > "$manifest"

ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%Y%m%d_%H%M%S)"
final="${PACK_PREFIX}_${PROJECT_NAME}_${ts}.tgz"
final_path="$OUTPUT_DIR/$final"

tmp_out="$OUTPUT_DIR/.${final}.tmp.$$"
rm -f "$tmp_out" 2>/dev/null || true

log_tar "Building archive: $final"
tar -czf "$tmp_out" -C "$tmp" "bundle.bundle" "manifest.tsv" || die "tar failed"

tar -tzf "$tmp_out" | tr -d '\r' | awk 'BEGIN{b=0;m=0;bad=0}
  $0=="bundle.bundle"{b=1;next}
  $0=="manifest.tsv"{m=1;next}
  {bad=1}
  END{exit(!(b&&m&&!bad))}' || die "Archive sanity check failed"

mv -f "$tmp_out" "$final_path" || die "Cannot move archive to output dir"

if [[ "$SEND_TO_TELEGRAM" == "1" ]]; then
  TELEGRAM_CONFIG_FILE="$TOOL_DIR/conf/telegram.conf"
  load_telegram_config "$TELEGRAM_CONFIG_FILE"
  if [[ -z "$TG_CAPTION" ]]; then
    TG_CAPTION="From **$(escape_md "$MACHINE_NAME")**"
  fi

  log_py "Sending archive to Telegram..."
  send_to_telegram_personal "$final_path" "$TG_CAPTION" "$TELEGRAM_CONFIG_FILE"
  rm -f -- "$final_path" || die "Uploaded to Telegram, but failed to delete local pack: $final_path"
  log_ok "Uploaded to Telegram and removed local file: $final_path"
else
  log_ok "Pack created: $final_path"
fi
