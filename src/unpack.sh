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

LAST_ERROR=""
die() {
  LAST_ERROR="$*"
  printf '%b[ERR]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2
  exit 1
}
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

escape_html() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

format_list() {
  local max=15
  local -a items=("$@")
  local count="${#items[@]}"
  if [[ "$count" -eq 0 ]]; then
    printf '%s' ""
    return 0
  fi
  local out=""
  local limit="$count"
  if [[ "$count" -gt "$max" ]]; then
    limit="$max"
  fi
  local i
  for ((i=0; i<limit; i++)); do
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="${items[$i]}"
  done
  if [[ "$count" -gt "$max" ]]; then
    out+="...(+$((count - max)))"
  fi
  printf '%s' "$out"
}

format_list_lines() {
  local max=15
  local -a items=("$@")
  local count="${#items[@]}"
  if [[ "$count" -eq 0 ]]; then
    printf '%s' ""
    return 0
  fi
  local limit="$count"
  if [[ "$count" -gt "$max" ]]; then
    limit="$max"
  fi
  local out=""
  local i
  for ((i=0; i<limit; i++)); do
    out+="- $(escape_html "${items[$i]}")"$'\n'
  done
  if [[ "$count" -gt "$max" ]]; then
    out+="- ...(+$((count - max)))"$'\n'
  fi
  printf '%s' "$out"
}

append_list_section() {
  local label="$1"; shift
  local -a items=("$@")
  [[ "${#items[@]}" -gt 0 ]] || return 0
  details_lines+=("$(escape_html "$label"):")
  local list
  list="$(format_list_lines "${items[@]}")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    details_lines+=("$line")
  done <<< "$list"
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

validate_telegram_proxy_mode() {
  local cfg="${1:-runtime arguments}"
  case "$TG_PROXY_TYPE" in
    none)
      [[ -z "$TG_SOCKS5_HOST$TG_SOCKS5_PORT$TG_SOCKS5_USER$TG_SOCKS5_PASSWORD$TG_HTTP_HOST$TG_HTTP_PORT$TG_HTTP_USER$TG_HTTP_PASSWORD$TG_MTPROTO_HOST$TG_MTPROTO_PORT$TG_MTPROTO_SECRET" ]] || die "Proxy keys are not allowed when telegram_proxy_type=none in $cfg"
      ;;
    socks5)
      [[ -n "$TG_SOCKS5_HOST" ]] || die "telegram_socks5_host is required when telegram_proxy_type=socks5 in $cfg"
      [[ -n "$TG_SOCKS5_PORT" ]] || die "telegram_socks5_port is required when telegram_proxy_type=socks5 in $cfg"
      [[ -z "$TG_HTTP_HOST$TG_HTTP_PORT$TG_HTTP_USER$TG_HTTP_PASSWORD$TG_MTPROTO_HOST$TG_MTPROTO_PORT$TG_MTPROTO_SECRET" ]] || die "telegram_http_* and telegram_mtproto_* keys are not allowed when telegram_proxy_type=socks5 in $cfg"
      ;;
    http)
      [[ -n "$TG_HTTP_HOST" ]] || die "telegram_http_host is required when telegram_proxy_type=http in $cfg"
      [[ -n "$TG_HTTP_PORT" ]] || die "telegram_http_port is required when telegram_proxy_type=http in $cfg"
      [[ -z "$TG_SOCKS5_HOST$TG_SOCKS5_PORT$TG_SOCKS5_USER$TG_SOCKS5_PASSWORD$TG_MTPROTO_HOST$TG_MTPROTO_PORT$TG_MTPROTO_SECRET" ]] || die "telegram_socks5_* and telegram_mtproto_* keys are not allowed when telegram_proxy_type=http in $cfg"
      ;;
    mtproto)
      [[ -n "$TG_MTPROTO_HOST" ]] || die "telegram_mtproto_host is required when telegram_proxy_type=mtproto in $cfg"
      [[ -n "$TG_MTPROTO_PORT" ]] || die "telegram_mtproto_port is required when telegram_proxy_type=mtproto in $cfg"
      [[ -n "$TG_MTPROTO_SECRET" ]] || die "telegram_mtproto_secret is required when telegram_proxy_type=mtproto in $cfg"
      [[ -z "$TG_SOCKS5_HOST$TG_SOCKS5_PORT$TG_SOCKS5_USER$TG_SOCKS5_PASSWORD$TG_HTTP_HOST$TG_HTTP_PORT$TG_HTTP_USER$TG_HTTP_PASSWORD" ]] || die "telegram_socks5_* and telegram_http_* keys are not allowed when telegram_proxy_type=mtproto in $cfg"
      ;;
    *)
      die "telegram_proxy_type must be one of: none, socks5, http, mtproto in $cfg"
      ;;
  esac
}

require_telegram_config() {
  local cfg="${1:-runtime arguments}"
  [[ -n "$TG_API_ID" ]] || die "telegram_api_id missing in $cfg. Populate [telegram.common] in conf.toml."
  [[ -n "$TG_API_HASH" ]] || die "telegram_api_hash missing in $cfg. Populate [telegram.common] in conf.toml."
  validate_telegram_proxy_mode "$cfg"
}

append_telegram_proxy_args() {
  local -n _cmd_ref="$1"
  _cmd_ref+=(--proxy-type "$TG_PROXY_TYPE")
  if [[ "$TG_PROXY_TYPE" == "socks5" ]]; then
    _cmd_ref+=(--socks5-host "$TG_SOCKS5_HOST" --socks5-port "$TG_SOCKS5_PORT")
    [[ -n "$TG_SOCKS5_USER" ]] && _cmd_ref+=(--socks5-user "$TG_SOCKS5_USER")
    [[ -n "$TG_SOCKS5_PASSWORD" ]] && _cmd_ref+=(--socks5-password "$TG_SOCKS5_PASSWORD")
  elif [[ "$TG_PROXY_TYPE" == "http" ]]; then
    _cmd_ref+=(--http-host "$TG_HTTP_HOST" --http-port "$TG_HTTP_PORT")
    [[ -n "$TG_HTTP_USER" ]] && _cmd_ref+=(--http-user "$TG_HTTP_USER")
    [[ -n "$TG_HTTP_PASSWORD" ]] && _cmd_ref+=(--http-password "$TG_HTTP_PASSWORD")
  elif [[ "$TG_PROXY_TYPE" == "mtproto" ]]; then
    _cmd_ref+=(--mtproto-host "$TG_MTPROTO_HOST" --mtproto-port "$TG_MTPROTO_PORT" --mtproto-secret "$TG_MTPROTO_SECRET")
  fi
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

python_proxy_support_cmd() {
  local proxy_type="$1"; shift
  local -a cmd=("$@")
  if [[ "$proxy_type" != "socks5" && "$proxy_type" != "http" ]]; then
    return 0
  fi
  "${cmd[@]}" -c 'import importlib.util,sys; sys.exit(0 if (importlib.util.find_spec("python_socks") or importlib.util.find_spec("socks")) else 1)' >/dev/null 2>&1
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
    if [[ "$ok" == "1" ]] && ! python_proxy_support_cmd "$TG_PROXY_TYPE" "${cmd[@]}"; then
      ok="0"
    fi
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
    if [[ "$ok" == "1" ]] && ! python_proxy_support_cmd "$TG_PROXY_TYPE" "${cmd[@]}"; then
      ok="0"
    fi
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
    if [[ "$ok" == "1" ]] && ! python_proxy_support_cmd "$TG_PROXY_TYPE" "${cmd[@]}"; then
      ok="0"
    fi
    if [[ "$ok" == "1" ]]; then
      PY_CMD=("${cmd[@]}")
      return 0
    fi
  done < <(python_candidates_from_globs)

  if [[ "${#required[@]}" -gt 0 ]]; then
    if [[ "$TG_PROXY_TYPE" == "socks5" || "$TG_PROXY_TYPE" == "http" ]]; then
      die "Python >= $min_ver with modules (${required[*]}) and transport proxy support (python-socks or PySocks) not found in PATH, py launcher list, or common install dirs."
    fi
    die "Python >= $min_ver with modules (${required[*]}) not found in PATH, py launcher list, or common install dirs."
  fi
  die "Python >= $min_ver not found in PATH, py launcher list, or common install dirs."
}

download_pack_from_telegram() {
  local out_dir="$1" prefix="$2" project="$3" machine_name="$4" ack_text="$5" meta_file="$6"
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
    --pull-latest
    --pack-dir "$out_dir"
    --pack-prefix "$prefix"
    --project-name "$project"
    --path-file "$path_file"
    --machine-name "$machine_name"
    --ack-text "$ack_text"
    --meta-file "$meta_file"
    --no-tmp-rename
  )
  append_telegram_proxy_args cmd
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi
  if [[ -n "$TG_FROM" ]]; then
    cmd+=(--from "$TG_FROM")
  fi

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 FORCE_LIVE_STATUS=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 FORCE_LIVE_STATUS=1 "${cmd[@]}"
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
  if [[ -f "$PACK_FILE_OVERRIDE" ]]; then
    PACK_DOWNLOADED="1"
  fi
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
  st="$(git -C "$repo" status --porcelain | awk '
    {
      path = substr($0, 4)
      if (path == "conf.toml" || path == "conf.example.toml") next
      print
    }'
  )"
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
  take                         download latest pack from Telegram and apply it
                               (see: unpack take --help)

Config:
  Use the top-level `unpack` wrapper with `conf.toml` in the repo root.

Example:
  ./unpack --pack-dir /c/Work/in
  ./unpack take
EOF
  exit 2
}

usage_take() {
  cat >&2 <<'EOF'
unpack take — download latest pack from Telegram and apply it

Options (same as unpack):
  --pack-dir PATH              default: ~/syncpacks
  --pack-prefix PREFIX         default: syncpack
  --project-name NAME          default: autodetect from current repo or selected pack
  --peer NAME                  default: sync
  --dry-run                    show what would be done without applying
  --help

  Config:
  Use the top-level `unpack take` wrapper with root `conf.toml`.
  The internal runner expects normalized Telegram/common/proxy runtime arguments.

  Example:
  ./unpack take
EOF
  exit 2
}

# ---- parse args ----
require_tools

PACK_DIR="${HOME:+$HOME/syncpacks}"
PACK_DIR_POSIX=""
DEFAULT_PACK_DIR="${HOME:+$HOME/syncpacks}"
PACK_PREFIX="syncpack"
PACK_FILE_OVERRIDE=""
PULL_MSG_ID=""
PULL_FILE_NAME=""
LOG_FILE=""
META_FILE=""
PULL_ALREADY_ACKED="0"
PULL_SKIP_ACK="0"
PULL_SKIP_FAILLOG="0"
PACK_DOWNLOADED="0"
DRY_RUN="0"
PULL_MODE="0"
TELEGRAM_DOCTOR="0"
TG_API_ID=""
TG_API_HASH=""
TG_FROM=""
TG_SESSION=""
TG_SESSION_STRING=""
TG_PROXY_TYPE="none"
TG_SOCKS5_HOST=""
TG_SOCKS5_PORT=""
TG_SOCKS5_USER=""
TG_SOCKS5_PASSWORD=""
TG_HTTP_HOST=""
TG_HTTP_PORT=""
TG_HTTP_USER=""
TG_HTTP_PASSWORD=""
TG_MTPROTO_HOST=""
TG_MTPROTO_PORT=""
TG_MTPROTO_SECRET=""
TG_ACK_TEXT="Closed by"
TG_PYTHON_MIN="3.8"

# defaults per your request
PROJECT_NAME=""
PEER="sync"
FF_ONLY="1"
FORCE_TAGS="0"
PRUNE_REMOTE_REFS="1"
PRUNE_LOCAL_BRANCHES="0"
CLEAN_PEER_REFS="1"

want_take_help="0"
want_help="0"
for _a in "$@"; do
  case "$_a" in
    take) want_take_help="1" ;;
    --help|-h) want_help="1" ;;
  esac
done
if [[ "$want_take_help" == "1" && "$want_help" == "1" ]]; then
  usage_take
fi

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "take" ]]; then
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
    --telegram-doctor)        TELEGRAM_DOCTOR="1"; shift 1;;
    --api-id)                 TG_API_ID="${2:-}"; shift 2;;
    --api-id=*)               TG_API_ID="${1#*=}"; shift 1;;
    --api-hash)               TG_API_HASH="${2:-}"; shift 2;;
    --api-hash=*)             TG_API_HASH="${1#*=}"; shift 1;;
    --session)                TG_SESSION="${2:-}"; shift 2;;
    --session=*)              TG_SESSION="${1#*=}"; shift 1;;
    --session-string)         TG_SESSION_STRING="${2:-}"; shift 2;;
    --session-string=*)       TG_SESSION_STRING="${1#*=}"; shift 1;;
    --from)                   TG_FROM="${2:-}"; shift 2;;
    --from=*)                 TG_FROM="${1#*=}"; shift 1;;
    --python-min)             TG_PYTHON_MIN="${2:-}"; shift 2;;
    --python-min=*)           TG_PYTHON_MIN="${1#*=}"; shift 1;;
    --proxy-type)             TG_PROXY_TYPE="${2:-}"; shift 2;;
    --proxy-type=*)           TG_PROXY_TYPE="${1#*=}"; shift 1;;
    --socks5-host)            TG_SOCKS5_HOST="${2:-}"; shift 2;;
    --socks5-host=*)          TG_SOCKS5_HOST="${1#*=}"; shift 1;;
    --socks5-port)            TG_SOCKS5_PORT="${2:-}"; shift 2;;
    --socks5-port=*)          TG_SOCKS5_PORT="${1#*=}"; shift 1;;
    --socks5-user)            TG_SOCKS5_USER="${2:-}"; shift 2;;
    --socks5-user=*)          TG_SOCKS5_USER="${1#*=}"; shift 1;;
    --socks5-password)        TG_SOCKS5_PASSWORD="${2:-}"; shift 2;;
    --socks5-password=*)      TG_SOCKS5_PASSWORD="${1#*=}"; shift 1;;
    --http-host)              TG_HTTP_HOST="${2:-}"; shift 2;;
    --http-host=*)            TG_HTTP_HOST="${1#*=}"; shift 1;;
    --http-port)              TG_HTTP_PORT="${2:-}"; shift 2;;
    --http-port=*)            TG_HTTP_PORT="${1#*=}"; shift 1;;
    --http-user)              TG_HTTP_USER="${2:-}"; shift 2;;
    --http-user=*)            TG_HTTP_USER="${1#*=}"; shift 1;;
    --http-password)          TG_HTTP_PASSWORD="${2:-}"; shift 2;;
    --http-password=*)        TG_HTTP_PASSWORD="${1#*=}"; shift 1;;
    --mtproto-host)           TG_MTPROTO_HOST="${2:-}"; shift 2;;
    --mtproto-host=*)         TG_MTPROTO_HOST="${1#*=}"; shift 1;;
    --mtproto-port)           TG_MTPROTO_PORT="${2:-}"; shift 2;;
    --mtproto-port=*)         TG_MTPROTO_PORT="${1#*=}"; shift 1;;
    --mtproto-secret)         TG_MTPROTO_SECRET="${2:-}"; shift 2;;
    --mtproto-secret=*)       TG_MTPROTO_SECRET="${1#*=}"; shift 1;;

    --help|-h)                usage_main;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
  if [[ "$TELEGRAM_DOCTOR" != "1" ]]; then
    ensure_repo_ok_and_clean "$REPO_DIR"
  fi
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
  md_name="$(escape_html "$MACHINE_NAME")"
  local details="${ACK_DETAILS:-}"
  local text="${prefix} <b>${md_name}</b>"$'\n'"reason: $(escape_html "$reason_text")"
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
    --to "$TG_FROM"
    --text "$text"
    --reply-to "$PULL_MSG_ID"
    --parse-mode html
  )
  append_telegram_proxy_args cmd
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi

  "${cmd[@]}" >/dev/null 2>&1 || true
}

send_failure_log() {
  [[ "$PULL_MODE" == "1" ]] || return 0
  [[ -n "$TG_FROM" && -n "$PULL_MSG_ID" ]] || return 0
  [[ -f "$LOG_FILE" ]] || return 0
  local reason="${LAST_ERROR:-failed}"
  reason="${reason//$'\r'/}"
  reason="${reason//$'\n'/ }"
  if [[ -z "$reason" ]]; then
    reason="failed"
  fi
  if [[ ${#reason} -gt 160 ]]; then
    reason="${reason:0:160}..."
  fi
  local caption="Unpack failed on <b>$(escape_html "$MACHINE_NAME")</b>"$'\n'"reason: $(escape_html "$reason")"
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
    --to "$TG_FROM"
    --file "$LOG_FILE"
    --caption "$caption"
    --reply-to "$PULL_MSG_ID"
    --parse-mode html
  )
  append_telegram_proxy_args cmd
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi

  "${cmd[@]}" >/dev/null 2>&1 || true
}

telegram_doctor() {
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")
  info "Telegram python: $(python_exec_path_cmd "${PY_CMD[@]}")"

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --doctor
    --from "$TG_FROM"
  )
  append_telegram_proxy_args cmd
  if [[ -n "$TG_SESSION_STRING" ]]; then
    cmd+=(--session-string "$TG_SESSION_STRING")
  fi

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi
}

save_failed_pack() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local dest_dir="${DEFAULT_PACK_DIR:-}"
  if [[ -z "$dest_dir" ]]; then
    warn "Cannot save failed pack: HOME is not set."
    return 0
  fi
  dest_dir="$(to_posix_path "$dest_dir")"
  mkdir -p "$dest_dir" 2>/dev/null || {
    warn "Cannot create syncpacks dir: $dest_dir"
    return 0
  }
  local base dest
  base="$(basename "$src")"
  dest="$dest_dir/$base"
  if [[ "$src" == "$dest" ]]; then
    info "Failed pack already in syncpacks: $dest"
    return 0
  fi
  if cp -f "$src" "$dest" 2>/dev/null; then
    info "Saved failed pack to syncpacks: $dest"
  else
    warn "Failed to save pack to syncpacks: $dest"
  fi
}

cleanup() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$PULL_SKIP_FAILLOG" != "1" ]]; then
      send_failure_log
    fi
    if [[ "$PULL_MODE" == "1" && "$PACK_DOWNLOADED" == "1" && -n "${PACK_FILE:-}" ]]; then
      save_failed_pack "$PACK_FILE"
    fi
  else
    if [[ "$PULL_SKIP_ACK" != "1" ]]; then
      [[ -n "${ACK_NOTE:-}" ]] || ACK_NOTE="UNPACKED"
      send_ack_message
    fi
  fi
  if [[ "$PULL_MODE" == "1" && -n "${PACK_FILE:-}" && -f "$PACK_FILE" ]]; then
    if rm -f -- "$PACK_FILE" 2>/dev/null; then
      info "Pack deleted after take: $PACK_FILE"
    else
      warn "Failed to delete pack after take: $PACK_FILE"
    fi
  fi
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT
on_err() {
  local cmd="$BASH_COMMAND"
  cmd="${cmd//$'\r'/}"
  cmd="${cmd//$'\n'/ }"
  if [[ -z "${LAST_ERROR:-}" ]]; then
    if [[ ${#cmd} -gt 160 ]]; then
      cmd="${cmd:0:160}..."
    fi
    LAST_ERROR="command failed: $cmd"
  fi
}
trap on_err ERR

if [[ "$PULL_MODE" == "1" && -n "$LOG_FILE" ]] && have tee; then
  exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

if [[ "$TELEGRAM_DOCTOR" == "1" ]]; then
  require_telegram_config "runtime arguments"
  [[ -n "$TG_FROM" ]] || die "telegram_from is required. Set [unpack.take.telegram].from in conf.toml or run unpack take setup."
  info "Telegram doctor..."
  telegram_doctor
  exit $?
fi

if [[ "$PULL_MODE" == "1" && -n "$PACK_FILE_OVERRIDE" ]]; then
  die "--pack-file cannot be used together with take."
fi

if [[ "$PULL_MODE" == "1" ]]; then
  [[ -n "$PROJECT_NAME" ]] || die "Project name required for take. Use --project-name or run inside repo."
  require_telegram_config "runtime arguments"
  MACHINE_NAME="$(detect_machine_name)"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry-run: would take latest pack from Telegram for project '$PROJECT_NAME'."
    PULL_SKIP_ACK="1"
    PULL_SKIP_FAILLOG="1"
    exit 0
  fi
  info "Telegram take..."
  download_pack_from_telegram "$PACK_DIR" "$PACK_PREFIX" "$PROJECT_NAME" "$MACHINE_NAME" "$TG_ACK_TEXT" "$META_FILE"
  if [[ "$PULL_ALREADY_ACKED" == "1" ]]; then
    info "Latest pack already acknowledged. Nothing to take."
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

pack_content_branches="$(read_manifest_value "$manifest" content_branches || true)"
pack_content_tags="$(read_manifest_value "$manifest" content_tags || true)"
pack_content_remote_name="$(read_manifest_value "$manifest" content_remote_name || true)"
pack_content_remote_branches="$(read_manifest_value "$manifest" content_remote_branches || true)"
if [[ -z "$pack_content_branches" ]]; then
  pack_content_branches="all"
fi
if [[ "$pack_content_tags" != "0" ]]; then
  pack_content_tags="1"
fi
PACK_TAGS_INCLUDED="$pack_content_tags"
PACK_HAS_ALL_BRANCHES="1"
if [[ "$pack_content_branches" != "all" ]]; then
  PACK_HAS_ALL_BRANCHES="0"
fi
PACK_HAS_REMOTE="0"
PACK_REMOTE_NAME=""
PACK_REMOTE_BRANCHES=()
PACK_REMOTE_COUNT="0"
if [[ -n "$pack_content_remote_name" && -n "$pack_content_remote_branches" ]]; then
  PACK_REMOTE_NAME="$pack_content_remote_name"
  IFS=',' read -r -a PACK_REMOTE_BRANCHES <<< "$pack_content_remote_branches"
  PACK_REMOTE_COUNT="${#PACK_REMOTE_BRANCHES[@]}"
  if [[ "$PACK_REMOTE_COUNT" -gt 0 ]]; then
    PACK_HAS_REMOTE="1"
  fi
fi

content_desc="branches"
if [[ "$pack_content_branches" != "all" ]]; then
  if [[ "$pack_content_branches" == *","* ]]; then
    content_desc="branches ${pack_content_branches}"
  else
    content_desc="branch ${pack_content_branches}"
  fi
fi
if [[ "$PACK_TAGS_INCLUDED" == "1" ]]; then
  content_desc="${content_desc} + tags"
else
  content_desc="${content_desc} (no tags)"
fi
if [[ "$PACK_HAS_REMOTE" == "1" ]]; then
  content_desc="${content_desc} + remote refs ${PACK_REMOTE_NAME} (${PACK_REMOTE_COUNT})"
fi
info "Content: $content_desc"

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
  if [[ "$PACK_HAS_ALL_BRANCHES" == "0" ]]; then
    if [[ "$PRUNE_REMOTE_REFS" == "1" || "$PRUNE_LOCAL_BRANCHES" == "1" ]]; then
      warn "Partial pack: disabling prune of remote/local branches."
    fi
    PRUNE_REMOTE_REFS="0"
    PRUNE_LOCAL_BRANCHES="0"
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
  info "Compare pack refs with local refs"
  incoming_heads="$tmp/incoming_heads.tsv"
  incoming_tags="$tmp/incoming_tags.tsv"
  local_heads="$tmp/local_heads.tsv"
  local_tags="$tmp/local_tags.tsv"
  incoming_heads_list="$tmp/incoming_heads.txt"
  incoming_tags_list="$tmp/incoming_tags.txt"
  local_heads_list="$tmp/local_heads.txt"
  local_tags_list="$tmp/local_tags.txt"
  incoming_remote="$tmp/incoming_remote.tsv"
  local_remote="$tmp/local_remote.tsv"

  awk '$2 ~ /^refs\/heads\// {sub("^refs/heads/","",$2); print $2 "\t" $1}' "$incoming_refs" | sort -u > "$incoming_heads"
  awk '$2 ~ /^refs\/tags\// {sub("^refs/tags/","",$2); print $2 "\t" $1}' "$incoming_refs" | sort -u > "$incoming_tags"

  git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads | tr -d '\r' \
    | awk '{print $1 "\t" $2}' | sort -u > "$local_heads"
  git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/tags | tr -d '\r' \
    | awk '{print $1 "\t" $2}' | sort -u > "$local_tags"

  if [[ "$PACK_HAS_REMOTE" == "1" ]]; then
    awk -v r="refs/remotes/$PACK_REMOTE_NAME/" '$2 ~ "^" r {sub("^" r, "", $2); print $2 "\t" $1}' \
      "$incoming_refs" | sort -u > "$incoming_remote"
    git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=4) %(objectname)' "refs/remotes/$PEER/$PACK_REMOTE_NAME" \
      | tr -d '\r' | awk '{print $1 "\t" $2}' | sort -u > "$local_remote"
  fi

  identical="1"
  if [[ "$PACK_HAS_ALL_BRANCHES" == "1" ]]; then
    if ! cmp -s "$incoming_heads" "$local_heads"; then
      identical="0"
    elif [[ "$PACK_TAGS_INCLUDED" == "1" && ! -s "$incoming_tags" ]]; then
      :
    elif [[ "$PACK_TAGS_INCLUDED" == "1" ]] && ! cmp -s "$incoming_tags" "$local_tags"; then
      identical="0"
    elif [[ "$PACK_HAS_REMOTE" == "1" ]] && ! cmp -s "$incoming_remote" "$local_remote"; then
      identical="0"
    fi

    if [[ "$identical" == "1" ]]; then
      awk -F'\t' '{print $1}' "$incoming_heads" > "$incoming_heads_list"
      awk -F'\t' '{print $1}' "$incoming_tags" > "$incoming_tags_list"
      awk -F'\t' '{print $1}' "$local_heads" > "$local_heads_list"
      awk -F'\t' '{print $1}' "$local_tags" > "$local_tags_list"

      if ! cmp -s "$incoming_heads_list" "$local_heads_list"; then
        identical="0"
      elif [[ "$PACK_TAGS_INCLUDED" == "1" ]] && ! cmp -s "$incoming_tags_list" "$local_tags_list"; then
        identical="0"
      elif [[ "$PACK_HAS_REMOTE" == "1" ]]; then
        incoming_remote_list="$tmp/incoming_remote_list.txt"
        local_remote_list="$tmp/local_remote_list.txt"
        awk -F'\t' '{print $1}' "$incoming_remote" > "$incoming_remote_list"
        awk -F'\t' '{print $1}' "$local_remote" > "$local_remote_list"
        if ! cmp -s "$incoming_remote_list" "$local_remote_list"; then
          identical="0"
        fi
      fi
    fi
  else
    # Partial pack: compare only refs present in the pack.
    if ! awk -F'\t' 'FNR==NR {m[$1]=$2; next} {if(!( $1 in m) || m[$1] != $2) {exit 1}}' \
      "$local_heads" "$incoming_heads"; then
      identical="0"
    elif [[ "$PACK_TAGS_INCLUDED" == "1" ]]; then
      if ! awk -F'\t' 'FNR==NR {m[$1]=$2; next} {if(!( $1 in m) || m[$1] != $2) {exit 1}}' \
        "$local_tags" "$incoming_tags"; then
        identical="0"
      fi
    fi
    if [[ "$PACK_HAS_REMOTE" == "1" ]]; then
      if ! awk -F'\t' 'FNR==NR {m[$1]=$2; next} {if(!( $1 in m) || m[$1] != $2) {exit 1}}' \
        "$local_remote" "$incoming_remote"; then
        identical="0"
      fi
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

if [[ "$PACK_HAS_REMOTE" == "1" ]]; then
  info "Fetch remote refs from pack: $PACK_REMOTE_NAME"
  if ! git -C "$REPO_DIR" fetch --force "$bundle" \
    "refs/remotes/$PACK_REMOTE_NAME/*:refs/remotes/$PEER/$PACK_REMOTE_NAME/*" >/dev/null 2>/dev/null; then
    die "Failed to fetch remote refs from pack."
  fi
fi

bundle_tag_count="$(grep -E '^[0-9a-f]+[[:space:]]+refs/tags/' "$incoming_refs" 2>/dev/null | wc -l | awk '{print $1}' || true)"
local_tag_count="$(git -C "$REPO_DIR" show-ref --tags 2>/dev/null | wc -l | awk '{print $1}' || true)"
[[ -n "${bundle_tag_count:-}" ]] || bundle_tag_count="unknown"
[[ -n "${local_tag_count:-}" ]] || local_tag_count="unknown"
info "Tags in bundle: $bundle_tag_count | local tags: $local_tag_count"
if [[ "$PACK_TAGS_INCLUDED" == "1" ]]; then
  if [[ "$FORCE_TAGS" == "1" ]]; then
    info "Update tags (force)"
    git -C "$REPO_DIR" fetch --force "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
  else
    info "Update tags"
    git -C "$REPO_DIR" fetch "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
  fi
  info "Tags updated"
else
  info "Skip tags (not included in pack)"
fi

tag_conflicts=()
if [[ "$PACK_TAGS_INCLUDED" == "1" && ( "$FORCE_TAGS" == "0" || "$FF_ONLY" == "1" ) ]]; then
  info "Check tag conflicts"
  local_tags="$tmp/local_tags.tsv"
  git -C "$REPO_DIR" show-ref --tags 2>/dev/null | tr -d '\r' > "$local_tags" || true
  conflicts_file="$tmp/tag_conflicts.txt"
  awk '
    FNR==NR {
      if ($2 ~ /^refs\/tags\//) {
        sub("^refs/tags/","",$2);
        local[$2]=$1
      }
      next
    }
    $2 ~ /^refs\/tags\// {
      sub("^refs/tags/","",$2);
      if (($2 in local) && local[$2] != $1) print $2
    }
  ' "$local_tags" "$incoming_refs" > "$conflicts_file"
  mapfile -t tag_conflicts < "$conflicts_file"
fi

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

local_heads_before="$tmp/local_heads_before.tsv"
local_tags_before="$tmp/local_tags_before.tsv"
local_remote_before="$tmp/local_remote_before.tsv"
git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads | tr -d '\r' \
  | awk '{print $1 "\t" $2}' > "$local_heads_before"
if [[ "$PACK_TAGS_INCLUDED" == "1" ]]; then
  git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/tags | tr -d '\r' \
    | awk '{print $1 "\t" $2}' > "$local_tags_before"
fi
if [[ "$PACK_HAS_REMOTE" == "1" ]]; then
  git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=4) %(objectname)' "refs/remotes/$PEER/$PACK_REMOTE_NAME" \
    | tr -d '\r' | awk '{print $1 "\t" $2}' > "$local_remote_before"
fi

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
    append_list_section "old" "${older_list[@]}"
    append_list_section "new" "${newer_list[@]}"
    append_list_section "unknown" "${unknown_list[@]}"
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

local_heads_after="$tmp/local_heads_after.tsv"
local_tags_after="$tmp/local_tags_after.tsv"
local_remote_after="$tmp/local_remote_after.tsv"
git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/heads | tr -d '\r' \
  | awk '{print $1 "\t" $2}' > "$local_heads_after"
if [[ "$PACK_TAGS_INCLUDED" == "1" ]]; then
  git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2) %(objectname)' refs/tags | tr -d '\r' \
    | awk '{print $1 "\t" $2}' > "$local_tags_after"
fi
if [[ "$PACK_HAS_REMOTE" == "1" ]]; then
  git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=4) %(objectname)' "refs/remotes/$PEER/$PACK_REMOTE_NAME" \
    | tr -d '\r' | awk '{print $1 "\t" $2}' > "$local_remote_after"
fi

declare -A before_map after_map
while IFS=$'\t' read -r name sha; do
  [[ -n "$name" ]] || continue
  before_map["$name"]="$sha"
done < "$local_heads_before"
while IFS=$'\t' read -r name sha; do
  [[ -n "$name" ]] || continue
  after_map["$name"]="$sha"
done < "$local_heads_after"

updated_branches=()
created_branches=()
for b in "${branches[@]}"; do
  old_sha="${before_map[$b]-}"
  new_sha="${after_map[$b]-}"
  if [[ -z "$old_sha" && -n "$new_sha" ]]; then
    created_branches+=("$b")
  elif [[ -n "$old_sha" && "$old_sha" != "$new_sha" ]]; then
    updated_branches+=("$b")
  fi
done

details_lines=()
append_list_section "branches updated" "${updated_branches[@]}"
append_list_section "branches created" "${created_branches[@]}"
if [[ "$PACK_TAGS_INCLUDED" == "1" && -f "$local_tags_before" && -f "$local_tags_after" ]]; then
  tag_changes="$(awk -F'\t' 'FNR==NR {m[$1]=$2; next} {if(!( $1 in m) || m[$1] != $2) c++} END{print c+0}' \
    "$local_tags_before" "$local_tags_after")"
  if [[ "${tag_changes:-0}" -gt 0 ]]; then
    details_lines+=("tags updated: $tag_changes")
  fi
fi

if [[ "$PACK_HAS_REMOTE" == "1" && -f "$local_remote_before" && -f "$local_remote_after" ]]; then
  declare -A r_before r_after
  while IFS=$'\t' read -r name sha; do
    [[ -n "$name" ]] || continue
    r_before["$name"]="$sha"
  done < "$local_remote_before"
  while IFS=$'\t' read -r name sha; do
    [[ -n "$name" ]] || continue
    r_after["$name"]="$sha"
  done < "$local_remote_after"
  remote_updated=()
  remote_created=()
  for name in "${!r_after[@]}"; do
    old_sha="${r_before[$name]-}"
    new_sha="${r_after[$name]}"
    if [[ -z "$old_sha" ]]; then
      remote_created+=("$name")
    elif [[ "$old_sha" != "$new_sha" ]]; then
      remote_updated+=("$name")
    fi
  done
  append_list_section "remote updated" "${remote_updated[@]}"
  append_list_section "remote created" "${remote_created[@]}"
fi

if [[ -z "${ACK_NOTE:-}" || "$ACK_NOTE" == "UNPACKED" ]]; then
  if [[ "${#details_lines[@]}" -gt 0 ]]; then
    ACK_DETAILS="$(printf '%s\n' "${details_lines[@]}")"
  fi
fi

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
  updated_count="${#updated_branches[@]}"
  created_count="${#created_branches[@]}"
  changed_count=$((updated_count + created_count))
  info "Branch changes: $changed_count (updated: $updated_count, created: $created_count) | peer: $PEER"
fi
