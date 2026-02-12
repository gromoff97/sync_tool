#!/usr/bin/env bash
set -euo pipefail

supports_256_color() {
  [[ "${FORCE_256_COLOR:-0}" != "0" ]] && return 0
  [[ "${TERM:-}" == *256color* ]] && return 0
  [[ -n "${COLORTERM:-}" ]] && return 0
  [[ -n "${WT_SESSION:-}" ]] && return 0
  [[ -n "${MSYSTEM:-}" ]] && return 0
  [[ -n "${ANSICON:-}" ]] && return 0
  [[ "${ConEmuANSI:-}" == "ON" ]] && return 0
  return 1
}

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  if supports_256_color; then
    USE_256_COLOR="1"
    C_APP=$'\033[36m'
    C_WRN=$'\033[33m'
    C_ERR=$'\033[38;5;196m'
  else
    USE_256_COLOR="0"
    C_APP=$'\033[36m'
    C_WRN=$'\033[33m'
    C_ERR=$'\033[31m'
  fi
else
  USE_256_COLOR="0"
  C_RESET=''
  C_APP=''
  C_WRN=''
  C_ERR=''
fi

die() { printf '%b[ERR]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }
warn() { printf '%b[WRN]%b %s\n' "$C_WRN" "$C_RESET" "$*" >&2; }
info() { printf '%b[APP]%b %s\n' "$C_APP" "$C_RESET" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

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

to_posix_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  if have cygpath; then
    cygpath -u "$p"
    return 0
  fi
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    printf '/%s/%s' "${drive,,}" "$rest"
    return 0
  fi
  printf '%s' "$p"
}

require_tools() {
  have git  || die "git not found"
  have tar  || die "tar not found"
  have awk  || die "awk not found"
  have sort || die "sort not found"
  have tr   || die "tr not found"
  have grep || die "grep not found"
  have cmp  || die "cmp not found"
}

mktemp_dir() {
  if have mktemp; then
    mktemp -d 2>/dev/null && return 0
  fi
  local d="./.tmp_unpack_$$"
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

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
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

looks_like_placeholder() {
  local v="${1^^}"
  [[ "$v" == REPLACE* || "$v" == *XXXXXXXX* ]]
}

expand_user_path() {
  local p="$1"
  local h="${HOME:-}"
  if [[ -n "$h" && "$h" == */~ ]]; then
    h="${h%/~}"
  fi
  case "$p" in
    "~")
      [[ -n "$h" ]] || die "HOME is not set; cannot expand '~' in config."
      printf '%s' "$h"
      ;;
    "~/"*)
      [[ -n "$h" ]] || die "HOME is not set; cannot expand '~/' in config."
      printf '%s' "$h/${p#~/}"
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
      pack_dir|PACK_DIR)                         PACK_DIR="$(expand_user_path "$value")" ;;
      pack_prefix|PACK_PREFIX)                   PACK_PREFIX="$value" ;;
      project_name|PROJECT_NAME)                 PROJECT_NAME="$value" ;;
      peer|PEER)                                 PEER="$value" ;;
      ff_only|FF_ONLY)                           FF_ONLY="$value" ;;
      force_tags|FORCE_TAGS)                     FORCE_TAGS="$value" ;;
      prune_remote_refs|PRUNE_REMOTE_REFS)       PRUNE_REMOTE_REFS="$value" ;;
      prune_local_branches|PRUNE_LOCAL_BRANCHES) PRUNE_LOCAL_BRANCHES="$value" ;;
      clean_peer_refs|CLEAN_PEER_REFS)           CLEAN_PEER_REFS="$value" ;;
      *) ;;
    esac
  done < "$cfg"
}

load_telegram_config() {
  local cfg="$1"
  TG_API_ID=""
  TG_API_HASH=""
  TG_FROM=""
  TG_SESSION=""
  TG_SESSION_STRING=""
  TG_PHONE=""
  TG_CODE=""
  TG_PASSWORD=""
  TG_PROXY=""
  TG_ACK_TEXT="Closed by"
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
      telegram_from|TELEGRAM_FROM|from|FROM|telegram_peer|TELEGRAM_PEER|peer|PEER) TG_FROM="$value" ;;
      telegram_session|TELEGRAM_SESSION|session|SESSION) TG_SESSION="$(expand_user_path "$value")" ;;
      telegram_session_string|TELEGRAM_SESSION_STRING|session_string|SESSION_STRING) TG_SESSION_STRING="$value" ;;
      telegram_phone|TELEGRAM_PHONE|phone|PHONE) TG_PHONE="$value" ;;
      telegram_code|TELEGRAM_CODE|code|CODE) TG_CODE="$value" ;;
      telegram_password|TELEGRAM_PASSWORD|password|PASSWORD) TG_PASSWORD="$value" ;;
      telegram_proxy|TELEGRAM_PROXY|proxy|PROXY) TG_PROXY="$value" ;;
      telegram_python_min|TELEGRAM_PYTHON_MIN|python_min|PYTHON_MIN) TG_PYTHON_MIN="$value" ;;
      *) ;;
    esac
  done < "$cfg"

  [[ -z "$TG_API_ID" || "$TG_API_ID" =~ ^[0-9]+$ ]] || die "telegram_api_id must be an integer in $cfg"
  [[ "$TG_PYTHON_MIN" =~ ^[0-9]+\.[0-9]+$ ]] || die "telegram_python_min must be MAJOR.MINOR in $cfg"
}

require_telegram_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || die "telegram.conf not found. Run: pack --mproto-login"
  [[ -n "$TG_API_ID" ]] || die "telegram_api_id missing in $cfg. Run: pack --mproto-login"
  [[ -n "$TG_API_HASH" ]] || die "telegram_api_hash missing in $cfg. Run: pack --mproto-login"
}

python_version_at_least_cmd() {
  local min_major="$1" min_minor="$2"; shift 2
  local -a cmd=("$@")
  "${cmd[@]}" -c 'import sys; min_major=int(sys.argv[1]); min_minor=int(sys.argv[2]); sys.exit(0 if (sys.version_info.major, sys.version_info.minor) >= (min_major, min_minor) else 1)' "$min_major" "$min_minor" >/dev/null 2>&1
}

python_module_available_cmd() {
  local module="$1"; shift
  local -a cmd=("$@")
  "${cmd[@]}" -c 'import importlib,sys; importlib.import_module(sys.argv[1])' "$module" >/dev/null 2>&1
}

python_exec_path_cmd() {
  local -a cmd=("$@")
  local out
  out="$("${cmd[@]}" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
  else
    printf '%s' "${cmd[0]}"
  fi
}

py_launcher_paths() {
  local py_cmd="py"
  if ! have "$py_cmd"; then
    if [[ -x "/c/Windows/py.exe" ]]; then
      py_cmd="/c/Windows/py.exe"
    else
      return 0
    fi
  fi
  "$py_cmd" -0p 2>/dev/null | tr -d '\r' | awk 'NF{ $1=""; if ($2=="*") $2=""; sub(/^ +/,""); print }'
}

python_candidates_from_globs() {
  local home="${HOME:-}"
  local -a globs=()
  if [[ -n "$home" ]]; then
    globs+=("$home/AppData/Local/Programs/Python/Python*/python.exe")
    globs+=("$home/AppData/Local/Microsoft/WindowsApps/python.exe")
  fi
  globs+=("/c/Program Files/Python*/python.exe")
  globs+=("/c/Program Files (x86)/Python*/python.exe")
  globs+=("/c/Python*/python.exe")

  shopt -s nullglob
  local g p
  for g in "${globs[@]}"; do
    for p in $g; do
      printf '%s\n' "$p"
    done
  done
  shopt -u nullglob
}

select_python_for_telegram() {
  local min_ver="$1"
  shift
  local -a required=("$@")
  local min_major="${min_ver%%.*}"
  local min_minor="${min_ver##*.}"
  local cand
  local -a cmd
  PY_CMD=()

  for cand in "python3" "python" "py -3" "py"; do
    read -r -a cmd <<< "$cand"
    have "${cmd[0]}" || continue
    python_version_at_least_cmd "$min_major" "$min_minor" "${cmd[@]}" || continue
    local ok="1"
    local m
    for m in "${required[@]}"; do
      if ! python_module_available_cmd "$m" "${cmd[@]}"; then
        ok="0"
        break
      fi
    done
    if [[ "$ok" == "1" ]]; then
      PY_CMD=("${cmd[@]}")
      return 0
    fi
  done

  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    cmd=("$cand")
    python_version_at_least_cmd "$min_major" "$min_minor" "${cmd[@]}" || continue
    local ok="1"
    local m
    for m in "${required[@]}"; do
      if ! python_module_available_cmd "$m" "${cmd[@]}"; then
        ok="0"
        break
      fi
    done
    if [[ "$ok" == "1" ]]; then
      PY_CMD=("${cmd[@]}")
      return 0
    fi
  done < <(py_launcher_paths)

  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    cmd=("$cand")
    python_version_at_least_cmd "$min_major" "$min_minor" "${cmd[@]}" || continue
    local ok="1"
    local m
    for m in "${required[@]}"; do
      if ! python_module_available_cmd "$m" "${cmd[@]}"; then
        ok="0"
        break
      fi
    done
    if [[ "$ok" == "1" ]]; then
      PY_CMD=("${cmd[@]}")
      return 0
    fi
  done < <(python_candidates_from_globs)

  if [[ "${#required[@]}" -gt 0 ]]; then
    die "Python >= $min_ver with modules (${required[*]}) not found in PATH, py launcher list, or common install dirs."
  fi
  die "Python >= $min_ver not found in PATH, py launcher list, or common install dirs."
}

download_pack_from_telegram() {
  local out_dir="$1" prefix="$2" project="$3" config_file="$4" machine_name="$5" ack_text="$6" meta_file="$7"
  local -a py_cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")
  info "Telegram python: $(python_exec_path_cmd "${PY_CMD[@]}")"

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  local path_file
  path_file="$tmp/pulled_path.txt"
  rm -f -- "$path_file" 2>/dev/null || true
  [[ -n "$meta_file" ]] && rm -f -- "$meta_file" 2>/dev/null || true

  local -a cmd
  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$config_file"
    --pull-latest
    --pack-dir "$out_dir"
    --pack-prefix "$prefix"
    --project-name "$project"
    --path-file "$path_file"
    --machine-name "$machine_name"
    --ack-text "$ack_text"
    --meta-file "$meta_file"
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
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
  if [[ -n "$TG_FROM" ]]; then
    cmd+=(--from "$TG_FROM")
  fi

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi

  if [[ -n "$meta_file" && -f "$meta_file" ]]; then
    PULL_MSG_ID="$(awk -F= '$1=="message_id"{print $2}' "$meta_file" | tr -d '\r')"
    PULL_FILE_NAME="$(awk -F= '$1=="file_name"{print $2}' "$meta_file" | tr -d '\r')"
    status="$(awk -F= '$1=="status"{print $2}' "$meta_file" | tr -d '\r')"
    if [[ "$status" == "acked" ]]; then
      PULL_ALREADY_ACKED="1"
      return 0
    fi
  fi

  [[ -f "$path_file" ]] || die "Telegram download completed but path file missing."
  PACK_FILE_OVERRIDE="$(tr -d '\r' < "$path_file")"
  [[ -n "$PACK_FILE_OVERRIDE" ]] || die "Telegram download completed but pack path is empty."
  PACK_FILE_OVERRIDE="$(to_posix_path "$PACK_FILE_OVERRIDE")"
}

gitpath() { git -C "$1" rev-parse --git-path "$2"; }

cleanup_peer_refs() {
  [[ "$CLEAN_PEER_REFS" == "1" ]] || return 0

  local refs
  mapfile -t refs < <(git -C "$REPO_DIR" for-each-ref --format='%(refname)' "refs/remotes/$PEER/" | tr -d '\r')
  if [[ "${#refs[@]}" -gt 0 ]]; then
    for r in "${refs[@]}"; do
      git -C "$REPO_DIR" update-ref -d "$r" >/dev/null || warn "Failed to delete peer ref: $r"
    done
    info "Peer refs removed: ${#refs[@]}"
  fi

  local fetch_head
  fetch_head="$(gitpath "$REPO_DIR" FETCH_HEAD)"
  if [[ -f "$fetch_head" ]]; then
    rm -f "$fetch_head" 2>/dev/null || warn "Failed to delete FETCH_HEAD"
  fi
}

ensure_repo_ok_and_clean() {
  local repo="$1"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository: $repo"
  local is_bare
  is_bare="$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null || echo true)"
  [[ "$is_bare" == "false" ]] || die "Repository is bare (not supported): $repo"

  git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1 || die "HEAD is invalid/missing (empty repo?): $repo"

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
  [[ -z "$st" ]] || die "Repo has uncommitted/untracked changes. Clean it first."
}

read_manifest_value() {
  local mf="$1" key="$2"
  awk -F'\t' -v k="$key" 'NR>1 && $1==k {print $2; exit}' "$mf" | tr -d '\r'
}

repo_roots_fingerprint() {
  local repo="$1"
  local roots
  roots="$(git -C "$repo" rev-list --max-parents=0 --branches --tags 2>/dev/null | tr -d '\r' | sort)"
  [[ -n "$roots" ]] || die "Failed to compute repo roots (branches/tags)."
  sha256_text "$roots"
}

repo_roots_fingerprint_all() {
  local repo="$1"
  local roots
  roots="$(git -C "$repo" rev-list --max-parents=0 --all 2>/dev/null | tr -d '\r' | sort)"
  [[ -n "$roots" ]] || return 1
  sha256_text "$roots"
}

pick_latest_pack() {
  local dir="$1" prefix="$2" project="${3:-}"
  [[ -d "$dir" ]] || die "--pack-dir is not a directory: $dir"

  shopt -s nullglob
  local files=( "$dir"/"${prefix}_"*.tgz )
  shopt -u nullglob

  [[ "${#files[@]}" -gt 0 ]] || die "No packs found in $dir for prefix '$prefix'"

  local best="" best_ts="" f base rest pack_project ts
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    rest="${base#${prefix}_}"
    [[ "$rest" != "$base" ]] || continue

    if [[ "$rest" =~ ^(.+)_([0-9]{8}_[0-9]{6})\.tgz$ ]]; then
      pack_project="${BASH_REMATCH[1]}"
      ts="${BASH_REMATCH[2]}"
      if [[ -n "$project" && "$pack_project" != "$project" ]]; then
        continue
      fi
      if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
        best_ts="$ts"
        best="$f"
      fi
    fi
  done

  if [[ -n "$project" ]]; then
    [[ -n "$best" ]] || die "No packs found in $dir for project '$project' and prefix '$prefix'"
  else
    [[ -n "$best" ]] || die "No packs with valid timestamp in name: ${prefix}_<project>_YYYYMMDD_HHMMSS.tgz"
  fi

  printf '%s' "$best"
}

project_from_pack_name() {
  local prefix="$1" pack_file="$2"
  local base rest
  base="$(basename "$pack_file")"
  rest="${base#${prefix}_}"
  [[ "$rest" != "$base" ]] || return 1
  if [[ "$rest" =~ ^(.+)_([0-9]{8}_[0-9]{6})\.tgz$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

usage_main() {
  cat >&2 <<'EOF'
unpack.sh — apply latest .tgz pack from a directory, update ALL branches + tags
If run inside a git repository, updates that repository.
If run outside a git repository, creates a new repository from the latest pack.

Options:
  --pack-dir PATH              default: ~/syncpacks
  --pack-file PATH             use a specific pack file instead of scanning pack-dir
  --pack-prefix PREFIX         default: syncpack
  --project-name NAME          default: autodetect from current repo or selected pack
  --peer NAME                  default: sync
  --dry-run                    show what would be done without applying
  --ff-only 0|1                default: 1
  --force-tags 0|1             default: 0
  --prune-remote-refs 0|1      default: 1
  --prune-local-branches 0|1   default: 0
  --clean-peer-refs 0|1        default: 1 (remove refs/remotes/<peer>/*)
  --help

Subcommands:
  pull                         download latest pack from Telegram and apply it
                               (see: unpack pull --help)

Config:
  <tool_dir>/conf/unpack.conf (if present) overrides CLI options.
  Keys: pack_dir, pack_prefix, project_name, peer,
        ff_only, force_tags, prune_remote_refs, prune_local_branches, clean_peer_refs

Example:
  ./unpack --pack-dir /c/Work/in
  ./unpack pull
EOF
  exit 2
}

usage_pull() {
  cat >&2 <<'EOF'
unpack pull — download latest pack from Telegram and apply it

Options (same as unpack):
  --pack-dir PATH              default: ~/syncpacks
  --pack-prefix PREFIX         default: syncpack
  --project-name NAME          default: autodetect from current repo or selected pack
  --peer NAME                  default: sync
  --dry-run                    show what would be done without applying
  --help

Config:
  <tool_dir>/conf/telegram.conf is required for pull.
  Supported keys: telegram_api_id, telegram_api_hash, telegram_from (optional),
                  telegram_session/session_string, telegram_proxy, telegram_python_min

Example:
  ./unpack pull
EOF
  exit 2
}

# ---- parse args ----
require_tools

PACK_DIR="${HOME:+$HOME/syncpacks}"
PACK_DIR_POSIX=""
PACK_PREFIX="syncpack"
PACK_FILE_OVERRIDE=""
PULL_MSG_ID=""
PULL_FILE_NAME=""
LOG_FILE=""
META_FILE=""
PULL_ALREADY_ACKED="0"
PULL_SKIP_ACK="0"
PULL_SKIP_FAILLOG="0"
DRY_RUN="0"
PULL_MODE="0"

# defaults per your request
PROJECT_NAME=""
PEER="sync"
FF_ONLY="1"
FORCE_TAGS="0"
PRUNE_REMOTE_REFS="1"
PRUNE_LOCAL_BRANCHES="0"
CLEAN_PEER_REFS="1"

want_pull_help="0"
want_help="0"
for _a in "$@"; do
  case "$_a" in
    pull) want_pull_help="1" ;;
    --help|-h) want_help="1" ;;
  esac
done
if [[ "$want_pull_help" == "1" && "$want_help" == "1" ]]; then
  usage_pull
fi

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "pull" ]]; then
    PULL_MODE="1"
    shift 1
    continue
  fi
  case "$1" in
    --pack-dir)               PACK_DIR="${2:-}"; shift 2;;
    --pack-dir=*)             PACK_DIR="${1#*=}"; shift 1;;
    --pack-file)              PACK_FILE_OVERRIDE="${2:-}"; shift 2;;
    --pack-file=*)            PACK_FILE_OVERRIDE="${1#*=}"; shift 1;;
    --pack-prefix)            PACK_PREFIX="${2:-}"; shift 2;;
    --pack-prefix=*)          PACK_PREFIX="${1#*=}"; shift 1;;
    --project-name)           PROJECT_NAME="${2:-}"; shift 2;;
    --project-name=*)         PROJECT_NAME="${1#*=}"; shift 1;;

    --peer)                   PEER="${2:-}"; shift 2;;
    --peer=*)                 PEER="${1#*=}"; shift 1;;

    --ff-only)                FF_ONLY="${2:-}"; shift 2;;
    --ff-only=*)              FF_ONLY="${1#*=}"; shift 1;;
    --force-tags)             FORCE_TAGS="${2:-}"; shift 2;;
    --force-tags=*)           FORCE_TAGS="${1#*=}"; shift 1;;
    --prune-remote-refs)      PRUNE_REMOTE_REFS="${2:-}"; shift 2;;
    --prune-remote-refs=*)    PRUNE_REMOTE_REFS="${1#*=}"; shift 1;;
    --prune-local-branches)   PRUNE_LOCAL_BRANCHES="${2:-}"; shift 2;;
    --prune-local-branches=*) PRUNE_LOCAL_BRANCHES="${1#*=}"; shift 1;;
    --clean-peer-refs)        CLEAN_PEER_REFS="${2:-}"; shift 2;;
    --clean-peer-refs=*)      CLEAN_PEER_REFS="${1#*=}"; shift 1;;
    --dry-run)                DRY_RUN="1"; shift 1;;

    --help|-h)                usage_main;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$TOOL_DIR/conf/unpack.conf"
load_config_overrides "$CONFIG_FILE"

PACK_DIR_POSIX="$(to_posix_path "$PACK_DIR")"
if [[ -n "$PACK_FILE_OVERRIDE" ]]; then
  PACK_FILE_OVERRIDE="$(to_posix_path "$PACK_FILE_OVERRIDE")"
fi

[[ -n "$PEER" ]] || die "--peer cannot be empty"
[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"
[[ -n "$PACK_DIR_POSIX" ]] || die "HOME is not set; use --pack-dir PATH."
[[ "$FF_ONLY" == "0" || "$FF_ONLY" == "1" ]] || die "--ff-only must be 0|1"
[[ "$FORCE_TAGS" == "0" || "$FORCE_TAGS" == "1" ]] || die "--force-tags must be 0|1"
[[ "$PRUNE_REMOTE_REFS" == "0" || "$PRUNE_REMOTE_REFS" == "1" ]] || die "--prune-remote-refs must be 0|1"
[[ "$PRUNE_LOCAL_BRANCHES" == "0" || "$PRUNE_LOCAL_BRANCHES" == "1" ]] || die "--prune-local-branches must be 0|1"
[[ "$CLEAN_PEER_REFS" == "0" || "$CLEAN_PEER_REFS" == "1" ]] || die "--clean-peer-refs must be 0|1"

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
MODE="existing"
if [[ -n "$REPO_DIR" ]]; then
  local_project_name="$(basename "$REPO_DIR")"
  if [[ -n "$PROJECT_NAME" && "$PROJECT_NAME" != "$local_project_name" ]]; then
    warn "--project-name is ignored when running inside an existing repository."
  fi
  PROJECT_NAME="$local_project_name"
  ensure_repo_ok_and_clean "$REPO_DIR"
else
  MODE="bootstrap"
fi

tmp="$(mktemp_dir)"
LOG_FILE="$tmp/unpack.log"
META_FILE="$tmp/pull_meta.txt"

send_ack_message() {
  [[ "$PULL_MODE" == "1" ]] || return 0
  [[ -n "$TG_FROM" && -n "$PULL_MSG_ID" ]] || return 0
  local prefix="Closed by"
  local reason="${ACK_NOTE:-UNPACKED}"
  local reason_text=""
  case "$reason" in
    NO_CHANGES) reason_text="no changes" ;;
    DIVERGED) reason_text="diverged" ;;
    FAILED) reason_text="failed" ;;
    UNPACKED) reason_text="updated" ;;
    *) reason_text="${reason}" ;;
  esac
  local md_name
  md_name="$(escape_md "$MACHINE_NAME")"
  local details="${ACK_DETAILS:-}"
  if [[ -n "$details" ]]; then
    details="$(escape_md "$details")"
  fi
  local text="${prefix} **${md_name}**"$'\n'"reason: ${reason_text}"
  if [[ -n "$details" ]]; then
    text="${text}"$'\n'"${details}"
  fi
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || return 0

  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$TOOL_DIR/conf/telegram.conf"
    --to "$TG_FROM"
    --text "$text"
    --reply-to "$PULL_MSG_ID"
    --non-interactive
    --parse-mode md
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi

  "${cmd[@]}" >/dev/null 2>&1 || true
}

send_failure_log() {
  [[ "$PULL_MODE" == "1" ]] || return 0
  [[ -n "$TG_FROM" && -n "$PULL_MSG_ID" ]] || return 0
  [[ -f "$LOG_FILE" ]] || return 0
  local caption="Unpack failed on **$(escape_md "$MACHINE_NAME")**"$'\n'"reason: failed"
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || return 0

  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$TOOL_DIR/conf/telegram.conf"
    --to "$TG_FROM"
    --file "$LOG_FILE"
    --caption "$caption"
    --reply-to "$PULL_MSG_ID"
    --non-interactive
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi

  "${cmd[@]}" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$PULL_SKIP_FAILLOG" != "1" ]]; then
      send_failure_log
    fi
  else
    if [[ "$PULL_SKIP_ACK" != "1" ]]; then
      [[ -n "${ACK_NOTE:-}" ]] || ACK_NOTE="UNPACKED"
      send_ack_message
    fi
  fi
  if [[ "$PULL_MODE" == "1" && -n "${PACK_FILE:-}" && -f "$PACK_FILE" ]]; then
    if rm -f -- "$PACK_FILE" 2>/dev/null; then
      info "Pack deleted after pull: $PACK_FILE"
    else
      warn "Failed to delete pack after pull: $PACK_FILE"
    fi
  fi
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$PULL_MODE" == "1" && -n "$LOG_FILE" ]] && have tee; then
  exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

if [[ "$PULL_MODE" == "1" && -n "$PACK_FILE_OVERRIDE" ]]; then
  die "--pack-file cannot be used together with pull."
fi

if [[ "$PULL_MODE" == "1" ]]; then
  [[ -n "$PROJECT_NAME" ]] || die "Project name required for pull. Use --project-name or run inside repo."
  TELEGRAM_CONFIG_FILE="$TOOL_DIR/conf/telegram.conf"
  load_telegram_config "$TELEGRAM_CONFIG_FILE"
  require_telegram_config "$TELEGRAM_CONFIG_FILE"
  MACHINE_NAME="$(detect_machine_name)"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry-run: would pull latest pack from Telegram for project '$PROJECT_NAME'."
    PULL_SKIP_ACK="1"
    PULL_SKIP_FAILLOG="1"
    exit 0
  fi
  info "Telegram pull..."
  download_pack_from_telegram "$PACK_DIR" "$PACK_PREFIX" "$PROJECT_NAME" "$TELEGRAM_CONFIG_FILE" "$MACHINE_NAME" "$TG_ACK_TEXT" "$META_FILE"
  load_telegram_config "$TELEGRAM_CONFIG_FILE"
  if [[ "$PULL_ALREADY_ACKED" == "1" ]]; then
    info "Latest pack already acknowledged. Nothing to pull."
    PULL_SKIP_ACK="1"
    PULL_SKIP_FAILLOG="1"
    exit 0
  fi
  PACK_FILE="$PACK_FILE_OVERRIDE"
elif [[ -n "$PACK_FILE_OVERRIDE" ]]; then
  PACK_FILE="$PACK_FILE_OVERRIDE"
else
  PACK_FILE="$(pick_latest_pack "$PACK_DIR_POSIX" "$PACK_PREFIX" "$PROJECT_NAME")"
fi
[[ -f "$PACK_FILE" ]] || die "Pack file not found: $PACK_FILE"
pack_project="$(project_from_pack_name "$PACK_PREFIX" "$PACK_FILE" || true)"
[[ -n "$pack_project" ]] || die "Pack file has invalid name: $(basename "$PACK_FILE")"
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="$pack_project"
fi
[[ "$PROJECT_NAME" == "$pack_project" ]] || die "Selected pack project mismatch (expected '$PROJECT_NAME', got '$pack_project')."

TARGET_REPO=""
if [[ "$MODE" == "bootstrap" ]]; then
  TARGET_REPO="$(pwd)/$PROJECT_NAME"
  [[ ! -e "$TARGET_REPO" ]] || die "Target path already exists: $TARGET_REPO"
fi

info "Pack: $PACK_FILE"
info "Project: $PROJECT_NAME"
info "Peer: $PEER"
if [[ "$MODE" == "bootstrap" ]]; then
  info "Create repo: $TARGET_REPO"
else
  info "Repo: $REPO_DIR"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  info "Dry-run: would apply pack to $MODE repository."
  PULL_SKIP_ACK="1"
  PULL_SKIP_FAILLOG="1"
  exit 0
fi

# Safety: archive must contain only expected top-level files
list="$(tar -tzf "$PACK_FILE" | tr -d '\r')"
echo "$list" | awk '
  $0=="bundle.bundle"{b=1; next}
  $0=="manifest.tsv"{m=1; next}
  {bad=1}
  END{ if(b&&m&&!bad) exit 0; exit 1 }
' || die "Archive contains unexpected entries. Expected only: bundle.bundle, manifest.tsv"

tar -xzf "$PACK_FILE" -C "$tmp" || die "Failed to extract pack"

bundle="$tmp/bundle.bundle"
manifest="$tmp/manifest.tsv"
[[ -f "$bundle" ]] || die "bundle.bundle missing after extraction"
[[ -f "$manifest" ]] || die "manifest.tsv missing after extraction"

manifest_project_name="$(read_manifest_value "$manifest" project_name || true)"
if [[ -n "$manifest_project_name" && "$manifest_project_name" != "$PROJECT_NAME" ]]; then
  die "Project mismatch (pack='$manifest_project_name', expected='$PROJECT_NAME')."
fi

expected_bundle_sha="$(read_manifest_value "$manifest" bundle_sha256 || true)"
if [[ -n "${expected_bundle_sha:-}" ]]; then
  actual_bundle_sha="$(sha256_file "$bundle")"
  info "Bundle SHA256: pack=$expected_bundle_sha local=$actual_bundle_sha"
  [[ "$actual_bundle_sha" == "$expected_bundle_sha" ]] || die "Bundle SHA256 mismatch (corrupted transfer?)"
else
  warn "No bundle_sha256 in manifest (skipping integrity check)"
fi

if [[ "$MODE" == "existing" ]]; then
  expected_repo_roots_sha="$(read_manifest_value "$manifest" repo_roots_sha256 || true)"
  if [[ -z "${expected_repo_roots_sha:-}" ]]; then
    die "Pack missing repo_roots_sha256. Recreate pack with updated pack.sh."
  fi
  local_repo_roots_sha="$(repo_roots_fingerprint "$REPO_DIR")"
  info "Repo roots SHA256: pack=$expected_repo_roots_sha local=$local_repo_roots_sha"
  if [[ "$local_repo_roots_sha" != "$expected_repo_roots_sha" ]]; then
    local_repo_roots_all_sha="$(repo_roots_fingerprint_all "$REPO_DIR" || true)"
    if [[ -n "$local_repo_roots_all_sha" ]]; then
      info "Repo roots SHA256 (all refs): local=$local_repo_roots_all_sha"
    fi
    if [[ -n "$local_repo_roots_all_sha" && "$local_repo_roots_all_sha" == "$expected_repo_roots_sha" ]]; then
      warn "Pack identity matched legacy roots (includes remotes). Repack to update identity."
    else
      die "Repository identity mismatch (pack=$expected_repo_roots_sha, local=$local_repo_roots_sha)."
    fi
  fi
else
  mkdir -p "$TARGET_REPO" || die "Cannot create target directory: $TARGET_REPO"
  git -C "$TARGET_REPO" init >/dev/null || die "Failed to initialize repository: $TARGET_REPO"
  REPO_DIR="$TARGET_REPO"
fi

verify_out="$tmp/bundle_verify.txt"
if ! git -C "$REPO_DIR" bundle verify "$bundle" >"$verify_out" 2>&1; then
  cat "$verify_out" >&2
  die "Bundle verification failed. Ask sender to send a FULL bundle (--branches --tags)."
fi
incoming_refs="$tmp/incoming_refs.txt"
git bundle list-heads "$bundle" 2>/dev/null | tr -d '\r' > "$incoming_refs" || die "Failed to list heads from bundle"

if [[ "$MODE" == "existing" ]]; then
  identical="1"
  while read -r sha ref; do
    [[ -n "$sha" && -n "$ref" ]] || continue
    if [[ "$ref" == refs/heads/* ]]; then
      b="${ref#refs/heads/}"
      if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
        identical="0"
        break
      fi
      local_sha="$(git -C "$REPO_DIR" rev-parse "refs/heads/$b")"
      if [[ "$local_sha" != "$sha" ]]; then
        identical="0"
        break
      fi
    elif [[ "$ref" == refs/tags/* ]]; then
      t="${ref#refs/tags/}"
      if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/tags/$t"; then
        identical="0"
        break
      fi
      local_sha="$(git -C "$REPO_DIR" rev-parse "refs/tags/$t")"
      if [[ "$local_sha" != "$sha" ]]; then
        identical="0"
        break
      fi
    fi
  done < "$incoming_refs"

  if [[ "$identical" == "1" ]]; then
    incoming_heads="$tmp/incoming_heads.txt"
    incoming_tags="$tmp/incoming_tags.txt"
    local_heads="$tmp/local_heads.txt"
    local_tags="$tmp/local_tags.txt"

    awk '$2 ~ /^refs\/heads\// {sub("^refs/heads/","",$2); print $2}' "$incoming_refs" | sort -u > "$incoming_heads"
    awk '$2 ~ /^refs\/tags\// {sub("^refs/tags/","",$2); print $2}' "$incoming_refs" | sort -u > "$incoming_tags"

    git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2)' refs/heads | tr -d '\r' | sort -u > "$local_heads"
    git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2)' refs/tags  | tr -d '\r' | sort -u > "$local_tags"

    if ! cmp -s "$incoming_heads" "$local_heads"; then
      identical="0"
    elif ! cmp -s "$incoming_tags" "$local_tags"; then
      identical="0"
    fi
  fi

  if [[ "$identical" == "1" ]]; then
    info "No changes: repo matches pack."
    ACK_NOTE="NO_CHANGES"
    cleanup_peer_refs
    if ! rm -f -- "$PACK_FILE"; then
      warn "Matched, but failed to delete pack: $PACK_FILE"
    else
      info "Pack deleted: $PACK_FILE"
    fi
    exit 0
  else
    info "Changes detected: pack differs from local refs."
  fi
fi

incoming_list="$tmp/incoming_branches.txt"
awk '{ref=$2; sub("^refs/heads/","",ref); if(length(ref)>0) print ref}' \
  "$incoming_refs" | sort -u > "$incoming_list" || die "Failed to list heads from bundle"

old_remote="$tmp/old_remote.tsv"
tab=$'\t'
git -C "$REPO_DIR" for-each-ref --format="%(refname:strip=3)${tab}%(objectname)" "refs/remotes/$PEER/" \
  | tr -d '\r' > "$old_remote" || true

fetch_err="$tmp/fetch_err.txt"
info "Fetch bundle into refs/remotes/$PEER/*"
# Always force-update peer namespace from bundle. Local branch safety is handled separately by --ff-only.
if ! git -C "$REPO_DIR" fetch --force "$bundle" "refs/heads/*:refs/remotes/$PEER/*" >/dev/null 2>"$fetch_err"; then
  cat "$fetch_err" >&2
  die "Fetch failed."
fi

bundle_tag_count="$(grep -E '^[0-9a-f]+[[:space:]]+refs/tags/' "$incoming_refs" 2>/dev/null | wc -l | awk '{print $1}' || true)"
local_tag_count="$(git -C "$REPO_DIR" show-ref --tags 2>/dev/null | wc -l | awk '{print $1}' || true)"
[[ -n "${bundle_tag_count:-}" ]] || bundle_tag_count="unknown"
[[ -n "${local_tag_count:-}" ]] || local_tag_count="unknown"
info "Tags in bundle: $bundle_tag_count | local tags: $local_tag_count"
if [[ "$FORCE_TAGS" == "1" ]]; then
  info "Update tags (force)"
  git -C "$REPO_DIR" fetch --force "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
else
  info "Update tags"
  git -C "$REPO_DIR" fetch "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
fi
info "Tags updated"

tag_conflicts=()
while read -r sha ref; do
  [[ -n "$sha" && -n "$ref" ]] || continue
  [[ "$ref" == refs/tags/* ]] || continue
  tag="${ref#refs/tags/}"
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/tags/$tag"; then
    local_sha="$(git -C "$REPO_DIR" rev-parse "refs/tags/$tag")"
    if [[ "$local_sha" != "$sha" ]]; then
      tag_conflicts+=("$tag")
    fi
  fi
done < "$incoming_refs"

if [[ "${#tag_conflicts[@]}" -gt 0 ]]; then
  if [[ "$FORCE_TAGS" == "0" ]]; then
    warn "Tag conflicts (not updated without --force-tags 1): ${tag_conflicts[*]}"
  elif [[ "$FF_ONLY" == "1" ]]; then
    die "Tag conflicts with --ff-only 1: ${tag_conflicts[*]}"
  fi
fi

if [[ "$PRUNE_REMOTE_REFS" == "1" ]]; then
  removed_remote=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if ! grep -Fxq "$b" "$incoming_list"; then
      if git -C "$REPO_DIR" update-ref -d "refs/remotes/$PEER/$b"; then
        removed_remote=$((removed_remote + 1))
      else
        warn "Failed to delete remote ref: $PEER/$b"
      fi
    fi
  done < <(git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$PEER/" | tr -d '\r' | sort)
  [[ "$removed_remote" -gt 0 ]] && info "Remote refs pruned: $removed_remote"
fi

info "Collect remote branches list"
mapfile -t branches < <(git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$PEER/" | tr -d '\r' | sort)
if [[ "${#branches[@]}" -eq 0 ]]; then
  warn "No branches after fetch. Done."
  exit 0
fi
info "Remote branches: ${#branches[@]}"

current_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
forced_updates=0

if [[ "$FF_ONLY" == "1" ]]; then
  info "Check fast-forward safety"
  check_start=$SECONDS
  checked=0
  diverged=()
  diverged_status=()
  for b in "${branches[@]}"; do
    checked=$((checked + 1))
    if (( checked % 200 == 0 )); then
      info "Checked $checked/${#branches[@]} branches..."
    fi
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
      if ! git -C "$REPO_DIR" merge-base --is-ancestor "$b" "$PEER/$b"; then
        diverged+=("$b")
        if git -C "$REPO_DIR" merge-base --is-ancestor "$PEER/$b" "$b"; then
          diverged_status+=("pack older than local")
        elif git -C "$REPO_DIR" merge-base --is-ancestor "$b" "$PEER/$b"; then
          diverged_status+=("pack newer than local")
        else
          diverged_status+=("histories diverged")
        fi
      fi
    fi
  done
  info "Fast-forward check done in $((SECONDS - check_start))s"
  if [[ "${#diverged[@]}" -gt 0 ]]; then
    warn "DIVERGED branches (fast-forward impossible):"
    for i in "${!diverged[@]}"; do
      warn "  ${diverged[$i]} -> ${diverged_status[$i]}"
    done
    older_list=()
    newer_list=()
    unknown_list=()
    for i in "${!diverged[@]}"; do
      case "${diverged_status[$i]}" in
        "pack older than local") older_list+=("${diverged[$i]}") ;;
        "pack newer than local") newer_list+=("${diverged[$i]}") ;;
        *) unknown_list+=("${diverged[$i]}") ;;
      esac
    done
    details_lines=()
    if [[ "${#older_list[@]}" -gt 0 ]]; then
      details_lines+=("old: ${older_list[*]}")
    fi
    if [[ "${#newer_list[@]}" -gt 0 ]]; then
      details_lines+=("new: ${newer_list[*]}")
    fi
    if [[ "${#unknown_list[@]}" -gt 0 ]]; then
      details_lines+=("unknown: ${unknown_list[*]}")
    fi
    details=""
    if [[ "${#details_lines[@]}" -gt 0 ]]; then
      details="$(printf '%s\n' "${details_lines[@]}")"
      details="${details%$'\n'}"
    fi
    if [[ "$PULL_MODE" == "1" && -t 0 ]]; then
      read -r -p "Send close message to allow next pack? [y/N] " _close_ans
      case "${_close_ans:-}" in
        y|Y|yes|YES)
          ACK_NOTE="DIVERGED"
          ACK_DETAILS="$details"
          send_ack_message
          PULL_SKIP_ACK="1"
          PULL_SKIP_FAILLOG="1"
          ;;
      esac
    fi
    die "Resolve manually (merge/rebase), or use --ff-only 0 (dangerous)."
  fi
fi

info "Update local branches from $PEER/*"
update_start=$SECONDS
updated=0
for b in "${branches[@]}"; do
  updated=$((updated + 1))
  if (( updated % 200 == 0 )); then
    info "Updated $updated/${#branches[@]} branches..."
  fi
  remote_sha="$(git -C "$REPO_DIR" rev-parse "refs/remotes/$PEER/$b")"
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
    if [[ -n "${current_branch:-}" && "$b" == "$current_branch" ]]; then
      if [[ "$FF_ONLY" == "1" ]]; then
        git -C "$REPO_DIR" merge --ff-only "$PEER/$b" >/dev/null
      else
        warn "FORCING branch '$b' to $PEER/$b"
        git -C "$REPO_DIR" reset --hard "$remote_sha" >/dev/null
        forced_updates=$((forced_updates + 1))
      fi
    else
      if [[ "$FF_ONLY" == "0" ]]; then
        warn "FORCING branch '$b' to $PEER/$b"
        forced_updates=$((forced_updates + 1))
      fi
      git -C "$REPO_DIR" update-ref "refs/heads/$b" "$remote_sha"
    fi
  else
    git -C "$REPO_DIR" branch "$b" "$remote_sha" >/dev/null
  fi
done
info "Branch update done in $((SECONDS - update_start))s"

if [[ "$FF_ONLY" == "0" && "$forced_updates" -gt 0 ]]; then
  warn "FORCED updates may discard local commits."
fi

if [[ "$PRUNE_LOCAL_BRANCHES" == "1" && -s "$old_remote" ]]; then
  info "Prune local branches"
  prune_start=$SECONDS
  pruned=0
  while IFS=$'\t' read -r b old_sha; do
    [[ -n "$b" && -n "$old_sha" ]] || continue
    if grep -Fxq "$b" "$incoming_list"; then
      continue
    fi
    if [[ -n "${current_branch:-}" && "$b" == "$current_branch" ]]; then
      continue
    fi
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
      local_sha="$(git -C "$REPO_DIR" rev-parse "refs/heads/$b")"
      if [[ "$local_sha" == "$old_sha" ]]; then
        if git -C "$REPO_DIR" branch -D "$b" >/dev/null; then
          pruned=$((pruned + 1))
          info "Deleted local branch: $b"
        else
          warn "Failed to delete local branch: $b"
        fi
      fi
    fi
  done < "$old_remote"
  info "Prune done: $pruned branches in $((SECONDS - prune_start))s"
fi

if [[ "$MODE" == "bootstrap" ]]; then
  checkout_branch=""
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/main"; then
    checkout_branch="main"
  elif git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/master"; then
    checkout_branch="master"
  else
    checkout_branch="${branches[0]}"
  fi
  git -C "$REPO_DIR" checkout -f "$checkout_branch" >/dev/null || die "Failed to checkout '$checkout_branch' in $REPO_DIR"
fi

cleanup_peer_refs

if ! rm -f -- "$PACK_FILE"; then
  warn "Applied, but failed to delete pack: $PACK_FILE"
else
  info "Pack deleted: $PACK_FILE"
fi

if [[ "$MODE" == "bootstrap" ]]; then
  info "Created repo: $REPO_DIR | branches: ${#branches[@]} | peer: $PEER"
else
  info "Updated branches: ${#branches[@]} | peer: $PEER"
fi
