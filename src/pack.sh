#!/usr/bin/env bash
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

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
    C_APP=$'\033[38;5;45m'
    C_ERR=$'\033[38;5;196m'
  else
    USE_256_COLOR="0"
    C_APP=$'\033[34m'
    C_ERR=$'\033[31m'
  fi
else
  USE_256_COLOR="0"
  C_RESET=''
  C_APP=''
  C_ERR=''
fi

log_line()  { local color="$1" tag="$2"; shift 2; printf '%b[%s]%b %s\n' "$color" "$tag" "$C_RESET" "$*"; }
err_line()  { local color="$1" tag="$2"; shift 2; printf '%b[%s]%b %s\n' "$color" "$tag" "$C_RESET" "$*" >&2; }
log_pack()  { log_line "$C_APP" "APP" "$*"; }
log_git()   { log_line "$C_APP" "APP" "$*"; }
log_tar()   { log_line "$C_APP" "APP" "$*"; }
log_ok()    { log_line "$C_APP" "APP" "$*"; }
die()       { err_line "$C_ERR" "ERR" "$*"; exit 1; }

require_tools() {
  have git || die "git not found"
  have tar || die "tar not found"
  have awk || die "awk not found"
  have sort || die "sort not found"
  have tr  || die "tr not found"
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

is_within_repo() {
  local repo="$1" path="$2"
  repo="${repo%/}/"
  path="${path%/}/"
  [[ "$path" == "$repo"* ]]
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
      output_dir|OUTPUT_DIR)       OUTPUT_DIR="$(expand_user_path "$value")" ;;
      pack_prefix|PACK_PREFIX)     PACK_PREFIX="$value" ;;
      machine_name|MACHINE_NAME)   MACHINE_NAME="$value" ;;
      branches|BRANCHES)           BRANCHES_RAW="$value" ;;
      branch|BRANCH)               BRANCHES_RAW="$value" ;;
      with_tags|WITH_TAGS)         WITH_TAGS="$value" ;;
      update_remote|UPDATE_REMOTE) UPDATE_REMOTE="$value" ;;
      remote|REMOTE)               REMOTE_NAME="$value" ;;
      recent_months|RECENT_MONTHS) RECENT_MONTHS="$value" ;;
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
  TG_PROXY=""
  TG_ACK_REQUIRED="1"
  TG_ACK_TEXT="Closed by"
  TG_ACK_SCAN_LIMIT="32"
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
      telegram_proxy|TELEGRAM_PROXY|proxy|PROXY) TG_PROXY="$value" ;;
      telegram_ack_scan_limit|TELEGRAM_ACK_SCAN_LIMIT|ack_scan_limit|ACK_SCAN_LIMIT) TG_ACK_SCAN_LIMIT="$value" ;;
      telegram_caption|TELEGRAM_CAPTION|caption|CAPTION) TG_CAPTION="$value" ;;
      telegram_python_min|TELEGRAM_PYTHON_MIN|python_min|PYTHON_MIN) TG_PYTHON_MIN="$value" ;;
      *) ;;
    esac
  done < "$cfg"

  if looks_like_placeholder "$TG_PROXY"; then
    TG_PROXY=""
  fi
  [[ -z "$TG_API_ID" || "$TG_API_ID" =~ ^[0-9]+$ ]] || die "telegram_api_id must be an integer in $cfg"
  [[ "$TG_PYTHON_MIN" =~ ^[0-9]+\.[0-9]+$ ]] || die "telegram_python_min must be MAJOR.MINOR in $cfg"
  [[ "$TG_ACK_SCAN_LIMIT" =~ ^[0-9]+$ ]] || die "telegram_ack_scan_limit must be an integer in $cfg"
}

require_telegram_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || die "telegram.conf not found. Run: pack --mproto-login"
  [[ -n "$TG_API_ID" ]] || die "telegram_api_id missing in $cfg. Run: pack --mproto-login"
  [[ -n "$TG_API_HASH" ]] || die "telegram_api_hash missing in $cfg. Run: pack --mproto-login"
  if looks_like_placeholder "$TG_API_ID" || looks_like_placeholder "$TG_API_HASH"; then
    die "telegram.conf has placeholder values. Run: pack --mproto-login"
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

compute_cutoff_epoch() {
  local months="$1"
  local cutoff=""
  if date -d "now - ${months} months" +%s >/dev/null 2>&1; then
    cutoff="$(date -d "now - ${months} months" +%s)"
  elif have python; then
    cutoff="$(python - <<'PY' "$months"
import sys, datetime
months=int(sys.argv[1])
now=datetime.datetime.utcnow()
year=now.year
month=now.month-months
while month<=0:
    month+=12
    year-=1
day=min(now.day, 28)
cut=datetime.datetime(year, month, day, now.hour, now.minute, now.second)
print(int(cut.timestamp()))
PY
)"
  else
    die "Cannot compute recent cutoff date (no GNU date -d, no python)."
  fi
  printf '%s' "$cutoff"
}

fetch_recent_remote_branches() {
  local remote="$1"
  local months="$2"
  [[ -n "$remote" ]] || die "--remote is required with -u"
  [[ -n "$months" ]] || months="3"
  log_git "Fetch remote: $remote (recent ${months} months)"
  git -C "$REPO_DIR" fetch --prune "$remote" >/dev/null 2>&1 || die "Failed to fetch remote '$remote'"

  local cutoff
  cutoff="$(compute_cutoff_epoch "$months")"
  [[ -n "$cutoff" ]] || die "Failed to compute recent cutoff."

  mapfile -t recent_branches < <(
    git -C "$REPO_DIR" for-each-ref --format='%(committerdate:unix) %(refname:strip=3)' "refs/remotes/$remote/" \
      | tr -d '\r' \
      | awk -v cutoff="$cutoff" -v r="$remote/" '$1>=cutoff {ref=$2; sub("^" r, "", ref); if(ref!="HEAD") print ref}'
  )

  if [[ "${#recent_branches[@]}" -eq 0 ]]; then
    die "No remote branches updated in the last ${months} months."
  fi

  for b in "${recent_branches[@]}"; do
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
      if git -C "$REPO_DIR" merge-base --is-ancestor "$b" "$remote/$b"; then
        if [[ "$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)" == "$b" ]]; then
          git -C "$REPO_DIR" merge --ff-only "$remote/$b" >/dev/null || die "Cannot fast-forward branch '$b' from '$remote'."
        else
          git -C "$REPO_DIR" update-ref "refs/heads/$b" "$remote/$b" >/dev/null
        fi
      else
        die "Local branch '$b' diverged from '$remote/$b'. Resolve before pack -u."
      fi
    else
      git -C "$REPO_DIR" branch "$b" "$remote/$b" >/dev/null 2>&1 || true
    fi
  done
  BRANCHES_RAW="$(IFS=','; printf '%s' "${recent_branches[*]}")"
}

select_default_remote() {
  local remotes
  remotes="$(git -C "$REPO_DIR" remote 2>/dev/null | tr -d '\r')"
  [[ -n "$remotes" ]] || return 1
  if echo "$remotes" | awk 'NR==1{first=$0} END{print NR, first}' | awk '{exit ($1==1)?0:1}'; then
    printf '%s' "$remotes" | awk 'NR==1{print; exit}'
    return 0
  fi
  if git -C "$REPO_DIR" remote | grep -qx "origin"; then
    printf '%s' "origin"
    return 0
  fi
  printf '%s' "$remotes" | awk 'NR==1{print; exit}'
}

ensure_branch_available() {
  local b="$1"
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
    return 0
  fi

  local remote
  remote="$(select_default_remote || true)"
  [[ -n "$remote" ]] || die "Branch not found locally and no git remotes to fetch from: $b"

  log_git "Fetching branch '$b' from '$remote'..."
  if ! git -C "$REPO_DIR" fetch "$remote" "$b" >/dev/null 2>&1; then
    die "Failed to fetch branch '$b' from '$remote'."
  fi
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/$remote/$b"; then
    git -C "$REPO_DIR" branch "$b" "$remote/$b" >/dev/null 2>&1 || true
  fi
  git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b" || die "Branch not found after fetch: $b"
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

send_to_telegram_personal() {
  local file="$1" caption="$2" config_file="$3"
  local -a py_cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")
  log_pack "Telegram python: $(python_exec_path_cmd "${PY_CMD[@]}")"

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  local -a cmd
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
    --pack-prefix "$PACK_PREFIX"
    --project-name "$PROJECT_NAME"
    --file "$file"
    --non-interactive
  )
  if [[ "$TG_ACK_REQUIRED" == "1" ]]; then
    cmd+=(--require-ack --ack-text "$TG_ACK_TEXT" --scan-limit "$TG_ACK_SCAN_LIMIT")
  fi
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
  if [[ -n "$caption" ]]; then
    cmd+=(--caption "$caption")
  fi

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi
}

send_mproto_login() {
  local config_file="$1"
  local -a py_cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")
  log_pack "Telegram python: $(python_exec_path_cmd "${PY_CMD[@]}")"

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  local -a cmd
  # Git Bash + Windows console Python can lose interactive prompts without winpty.
  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$config_file"
    --mproto-login
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
  if [[ -n "$TG_TO" ]]; then
    cmd+=(--to "$TG_TO")
  fi

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi
}

gitpath() { git -C "$1" rev-parse --git-path "$2"; }

repo_roots_fingerprint() {
  local repo="$1"
  local roots
  roots="$(git -C "$repo" rev-list --max-parents=0 --branches --tags 2>/dev/null | tr -d '\r' | sort)"
  [[ -n "$roots" ]] || die "Failed to compute repo roots (branches/tags)."
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

usage_main() {
  cat >&2 <<'EOF'
pack.sh — create FULL git bundle pack (all branches + tags) into a .tgz
File name: <prefix>_<project>_<timestamp>.tgz

Options:
  --output-dir PATH        default: ~/syncpacks
  --pack-prefix PREFIX     default: syncpack
  --machine-name NAME      default: auto-detected; written to manifest only
  -u, --update-remote      fetch recent branches from remote before pack
  --remote NAME            remote name (default: origin; required with -u)
  --recent-months N        how many months back is "recent" (default: 6)
  --branch NAME            pack only this branch (no tags by default)
  --branches LIST          pack only these branches (comma-separated)
  --with-tags 0|1          include tags (default: 1 for all branches, 0 for selected branches)
  --dry-run                show what would be done without creating/sending
  --mproto-login           interactive MTProto login + connection test, writes <tool_dir>/conf/telegram.conf
  --list-chat TEXT         list Telegram chats containing TEXT (name or username)
  --help

Subcommands:
  push                     send archive via Telegram (see: pack push --help)

Config:
  <tool_dir>/conf/pack.conf (if present) overrides pack options above.

Example:
  ./pack
  ./pack push
EOF
  exit 2
}

usage_push() {
  cat >&2 <<'EOF'
pack push — send the created pack via Telegram (personal account)

Options (same as pack):
  --output-dir PATH        default: ~/syncpacks
  --pack-prefix PREFIX     default: syncpack
  --machine-name NAME      default: auto-detected; written to manifest only
  -u, --update-remote      fetch recent branches from remote before pack
  --remote NAME            remote name (default: origin; required with -u)
  --recent-months N        how many months back is "recent" (default: 6)
  --branch NAME            pack only this branch (no tags by default)
  --branches LIST          pack only these branches (comma-separated)
  --with-tags 0|1          include tags (default: 1 for all branches, 0 for selected branches)
  --dry-run                show what would be done without creating/sending
  --help

Config:
  <tool_dir>/conf/telegram.conf is required for push.
  push is non-interactive for Telegram auth; run --mproto-login to create/refresh telegram.conf.
  If telegram_to is missing, push will prompt for it and save for next time.
  Supported keys:
    telegram_api_id, telegram_api_hash, telegram_to
    telegram_session or telegram_session_string
    telegram_phone, telegram_code, telegram_password
    telegram_proxy (optional, e.g. socks5://user:pass@host:1080)
    telegram_ack_scan_limit (default: 32)
    telegram_caption, telegram_python_min
  Default caption: Packed by **machine_name**
  Python modules for push: telethon, colorama

Examples:
  ./pack push
  ./pack push --dry-run
EOF
  exit 2
}

list_telegram_chats() {
  local config_file="$1" filter_text="$2"
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")
  log_pack "Telegram python: $(python_exec_path_cmd "${PY_CMD[@]}")"

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  # Git Bash + Windows console Python can lose interactive prompts without winpty.
  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$config_file"
    --list-chats
    --chat-filter "$filter_text"
    --non-interactive
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
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

check_telegram_ack() {
  local config_file="$1" meta_file="$2" current_sha="$3"
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")
  log_pack "Telegram python: $(python_exec_path_cmd "${PY_CMD[@]}")"

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

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
    --pack-prefix "$PACK_PREFIX"
    --project-name "$PROJECT_NAME"
    --scan-limit "$TG_ACK_SCAN_LIMIT"
    --ack-text "$TG_ACK_TEXT"
    --check-ack
    --meta-file "$meta_file"
    --current-sha "$current_sha"
    --non-interactive
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
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

send_telegram_close() {
  local config_file="$1" msg_id="$2" reason="$3"
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  local text="Closed by **$(escape_md "$MACHINE_NAME")**"
  if [[ -n "$reason" ]]; then
    text="${text}"$'\n'"reason: ${reason}"
  fi

  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --config-file "$config_file"
    --to "$TG_TO"
    --text "$text"
    --reply-to "$msg_id"
    --parse-mode md
    --non-interactive
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
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

delete_telegram_message() {
  local config_file="$1" msg_id="$2"
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")

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
    --config-file "$config_file"
    --to "$TG_TO"
    --delete-message "$msg_id"
    --non-interactive
  )
  if [[ -n "$TG_PROXY" ]]; then
    cmd+=(--proxy "$TG_PROXY")
  fi
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

# ---- parse args ----
require_tools

OUTPUT_DIR="${HOME:+$HOME/syncpacks}"
PACK_PREFIX="syncpack"
MACHINE_NAME=""
SEND_TO_TELEGRAM="0"
MPROTO_LOGIN="0"
LIST_CHATS="0"
LIST_CHAT_FILTER=""
OTHER_OPTS_USED="0"
TG_API_ID=""
TG_API_HASH=""
TG_TO=""
TG_SESSION=""
TG_CAPTION=""
final_path=""
DELETE_FINAL_ON_EXIT="0"
DRY_RUN="0"
BRANCHES_RAW=""
WITH_TAGS=""
UPDATE_REMOTE="0"
REMOTE_NAME=""
RECENT_MONTHS="6"

want_push_help="0"
want_help="0"
for _a in "$@"; do
  case "$_a" in
    push) want_push_help="1" ;;
    --help|-h) want_help="1" ;;
  esac
done
if [[ "$want_push_help" == "1" && "$want_help" == "1" ]]; then
  usage_push
fi

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "push" ]]; then
    SEND_TO_TELEGRAM="1"
    OTHER_OPTS_USED="1"
    shift 1
    continue
  fi
  case "$1" in
    --output-dir)      OUTPUT_DIR="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --output-dir=*)    OUTPUT_DIR="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --pack-prefix)     PACK_PREFIX="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --pack-prefix=*)   PACK_PREFIX="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --machine-name)    MACHINE_NAME="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --machine-name=*)  MACHINE_NAME="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    -u|--update-remote) UPDATE_REMOTE="1"; OTHER_OPTS_USED="1"; shift 1;;
    --remote)          REMOTE_NAME="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --remote=*)        REMOTE_NAME="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --recent-months)   RECENT_MONTHS="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --recent-months=*) RECENT_MONTHS="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --branch)          BRANCHES_RAW="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --branch=*)        BRANCHES_RAW="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --branches)        BRANCHES_RAW="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --branches=*)      BRANCHES_RAW="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --with-tags)       WITH_TAGS="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --with-tags=*)     WITH_TAGS="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --dry-run)         DRY_RUN="1"; shift 1;;
    --mproto-login)    MPROTO_LOGIN="1"; shift 1;;
    --list-chats)      LIST_CHATS="1"; LIST_CHAT_FILTER=""; shift 1;;
    --list-chat)       LIST_CHATS="1"; LIST_CHAT_FILTER="${2:-}"; shift 2;;
    --list-chat=*)     LIST_CHATS="1"; LIST_CHAT_FILTER="${1#*=}"; shift 1;;
    --help|-h)         usage_main;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

if [[ "$MPROTO_LOGIN" == "1" && "$OTHER_OPTS_USED" == "1" ]]; then
  die "--mproto-login cannot be combined with other options."
fi
if [[ "$LIST_CHATS" == "1" && "$OTHER_OPTS_USED" == "1" ]]; then
  die "--list-chats cannot be combined with other options."
fi

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_DIR" && "$MPROTO_LOGIN" != "1" && "$LIST_CHATS" != "1" ]]; then
  die "Run pack.sh inside a git repository."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$TOOL_DIR/conf/pack.conf"
load_config_overrides "$CONFIG_FILE"

[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"
if [[ "$MPROTO_LOGIN" != "1" && "$LIST_CHATS" != "1" ]]; then
  [[ -n "$OUTPUT_DIR" ]] || die "HOME is not set; use --output-dir PATH."
fi
if [[ -n "$WITH_TAGS" && "$WITH_TAGS" != "0" && "$WITH_TAGS" != "1" ]]; then
  die "--with-tags must be 0|1"
fi
if [[ -n "$UPDATE_REMOTE" && "$UPDATE_REMOTE" != "0" && "$UPDATE_REMOTE" != "1" ]]; then
  die "update_remote must be 0|1"
fi
if [[ -n "$RECENT_MONTHS" && ! "$RECENT_MONTHS" =~ ^[0-9]+$ ]]; then
  die "--recent-months must be an integer"
fi

if [[ "$MPROTO_LOGIN" == "1" ]]; then
  TELEGRAM_CONFIG_FILE="$TOOL_DIR/conf/telegram.conf"
  if [[ -f "$TELEGRAM_CONFIG_FILE" && -s "$TELEGRAM_CONFIG_FILE" ]]; then
    read -r -p "telegram.conf exists. Overwrite? [y/N] " _ans
    case "${_ans:-}" in
      y|Y|yes|YES) rm -f -- "$TELEGRAM_CONFIG_FILE" ;;
      *) die "Aborted. Existing telegram.conf kept." ;;
    esac
  fi
  load_telegram_config "$TELEGRAM_CONFIG_FILE"
  log_pack "MTProto login..."
  send_mproto_login "$TELEGRAM_CONFIG_FILE"
  exit $?
fi

if [[ "$LIST_CHATS" == "1" ]]; then
  TELEGRAM_CONFIG_FILE="$TOOL_DIR/conf/telegram.conf"
  load_telegram_config "$TELEGRAM_CONFIG_FILE"
  require_telegram_config "$TELEGRAM_CONFIG_FILE"
  log_pack "Telegram chats..."
  list_telegram_chats "$TELEGRAM_CONFIG_FILE" "$LIST_CHAT_FILTER"
  exit $?
fi

if [[ -z "$MACHINE_NAME" ]]; then
  MACHINE_NAME="$(detect_machine_name)"
fi
MACHINE_NAME="$(sanitize_for_manifest "$MACHINE_NAME")"

PROJECT_NAME="$(basename "$REPO_DIR")"
PROJECT_NAME="$(sanitize_for_manifest "$PROJECT_NAME")"

if [[ "$UPDATE_REMOTE" == "1" ]]; then
  if [[ -z "$REMOTE_NAME" ]]; then
    REMOTE_NAME="origin"
  fi
  [[ -z "$BRANCHES_RAW" ]] || die "-u cannot be combined with --branch/--branches"
  fetch_recent_remote_branches "$REMOTE_NAME" "$RECENT_MONTHS"
fi

mkdir -p "$OUTPUT_DIR" || die "Cannot create --output-dir: $OUTPUT_DIR"
if is_within_repo "$REPO_DIR" "$OUTPUT_DIR"; then
  die "Refusing to write packs inside the repository. Use --output-dir outside repo."
fi
ensure_repo_ok_and_clean "$REPO_DIR"
log_pack "Repo: $REPO_DIR | Project: $PROJECT_NAME"
log_pack "Out: $OUTPUT_DIR"

repo_roots_sha="$(repo_roots_fingerprint "$REPO_DIR")"

# Resolve branch selection and content description
branches_selected=()
if [[ -n "$BRANCHES_RAW" ]]; then
  tmp_br="${BRANCHES_RAW//,/ }"
  read -r -a branches_selected <<< "$tmp_br"
  cleaned=()
  for b in "${branches_selected[@]}"; do
    b="$(trim_ws "$b")"
    [[ -n "$b" ]] && cleaned+=("$b")
  done
  branches_selected=("${cleaned[@]}")
fi

if [[ "${#branches_selected[@]}" -gt 0 ]]; then
  if [[ -z "$WITH_TAGS" ]]; then
    WITH_TAGS="0"
  fi
  for b in "${branches_selected[@]}"; do
    ensure_branch_available "$b"
  done
else
  if [[ -z "$WITH_TAGS" ]]; then
    WITH_TAGS="1"
  fi
fi

content_branches="all"
content_desc="branches"
if [[ "${#branches_selected[@]}" -gt 0 ]]; then
  content_branches="$(IFS=','; printf '%s' "${branches_selected[*]}")"
  if [[ "${#branches_selected[@]}" -eq 1 ]]; then
    content_desc="branch ${branches_selected[0]}"
  else
    content_desc="branches ${content_branches}"
  fi
fi
if [[ "$WITH_TAGS" == "1" ]]; then
  content_desc="${content_desc} + tags"
fi
log_pack "Content: $content_desc"

tmp="$(mktemp_dir)"
cleanup() {
  local exit_code=$?
  rm -rf "$tmp" 2>/dev/null || true
  if [[ "${DELETE_FINAL_ON_EXIT:-0}" == "1" && -n "${final_path:-}" && -f "$final_path" ]]; then
    if rm -f -- "$final_path" 2>/dev/null; then
      if [[ "$exit_code" -ne 0 ]]; then
        log_pack "Removed local file after failure: $final_path"
      fi
    else
      err_line "$C_ERR" "ERR" "Failed to delete local pack after failure: $final_path"
    fi
  fi
}
trap cleanup EXIT

bundle="$tmp/bundle.bundle"
manifest="$tmp/manifest.tsv"

log_git "Bundle ($content_desc)..."
create_out="$tmp/git_bundle_create.txt"
bundle_args=()
if [[ "${#branches_selected[@]}" -gt 0 ]]; then
  for b in "${branches_selected[@]}"; do
    bundle_args+=("refs/heads/$b")
  done
else
  bundle_args+=(--branches)
fi
if [[ "$WITH_TAGS" == "1" ]]; then
  bundle_args+=(--tags)
fi
if ! git -C "$REPO_DIR" bundle create "$bundle" "${bundle_args[@]}" >"$create_out" 2>&1; then
  cat "$create_out" >&2
  die "git bundle create failed"
fi

verify_out="$tmp/bundle_verify.txt"
if ! git -C "$REPO_DIR" bundle verify "$bundle" >"$verify_out" 2>&1; then
  cat "$verify_out" >&2
  die "Bundle verification failed (unexpected for full bundle)."
fi

bundle_sha="$(sha256_file "$bundle")"
bundle_sha_short="${bundle_sha:0:12}"

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
  echo -e "content_branches\t$content_branches"
  echo -e "content_tags\t$WITH_TAGS"
  echo -e "branches_count\t$(git -C "$REPO_DIR" show-ref --heads | wc -l | awk '{print $1}')"
  if [[ "$WITH_TAGS" == "1" ]]; then
    echo -e "tags_count\t$(git -C "$REPO_DIR" show-ref --tags 2>/dev/null | wc -l | awk '{print $1}')"
  else
    echo -e "tags_count\t0"
  fi
} > "$manifest"

ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || date +%Y%m%d_%H%M%S)"
final="${PACK_PREFIX}_${PROJECT_NAME}_${ts}.tgz"
final_path="$OUTPUT_DIR/$final"

if [[ "$DRY_RUN" == "1" ]]; then
  log_pack "Dry-run: would create $final_path"
  if [[ "$SEND_TO_TELEGRAM" == "1" ]]; then
    log_pack "Dry-run: would send to Telegram"
  fi
  exit 0
fi

tmp_out="$OUTPUT_DIR/.${final}.tmp.$$"
rm -f "$tmp_out" 2>/dev/null || true

if [[ -e "$final_path" ]]; then
  die "Pack already exists: $final_path"
fi

log_tar "Archive: $final"
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
  require_telegram_config "$TELEGRAM_CONFIG_FILE"
  if looks_like_placeholder "$TG_TO"; then
    TG_TO=""
  fi
  if [[ -z "$TG_TO" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Enter telegram_to (@username/phone/id/me): " TG_TO
      TG_TO="$(trim_ws "$TG_TO")"
    fi
  fi
  [[ -n "$TG_TO" ]] || die "telegram_to is required. Set it in telegram.conf or enter it interactively."
  if [[ -z "$TG_CAPTION" ]]; then
    TG_CAPTION="Packed by **$(escape_md "$MACHINE_NAME")**"$'\n'"project: $(escape_md "$PROJECT_NAME")"$'\n'"content: $(escape_md "$content_desc")"
  fi

  log_pack "Telegram send..."
  DELETE_FINAL_ON_EXIT="1"
  ack_meta="$tmp/ack_meta.txt"
  rm -f -- "$ack_meta" 2>/dev/null || true
  if ! check_telegram_ack "$TELEGRAM_CONFIG_FILE" "$ack_meta" "$bundle_sha_short"; then
    ack_rc=$?
    if [[ "$ack_rc" == "5" ]]; then
      die "Latest pack already closed with same SHA."
    elif [[ "$ack_rc" == "4" ]]; then
      if [[ -f "$ack_meta" ]]; then
        ack_status="$(awk -F= '$1=="status"{print $2}' "$ack_meta" | tr -d '\r')"
        if [[ "$ack_status" == "unacked" ]]; then
          ack_msg_id="$(awk -F= '$1=="message_id"{print $2}' "$ack_meta" | tr -d '\r')"
          ack_file="$(awk -F= '$1=="file_name"{print $2}' "$ack_meta" | tr -d '\r')"
          [[ -n "$ack_msg_id" ]] || die "Previous pack is unacked, but message_id is missing."
          log_pack "Previous pack unprocessed: ${ack_file:-unknown}"
          if [[ -t 0 ]]; then
            read -r -p "Delete old pack and continue? [y/N] " _ack_ans
            case "${_ack_ans:-}" in
              y|Y|yes|YES)
                log_pack "Closing previous pack as replaced..."
                send_telegram_close "$TELEGRAM_CONFIG_FILE" "$ack_msg_id" "replaced"
                log_pack "Deleting previous pack message..."
                delete_telegram_message "$TELEGRAM_CONFIG_FILE" "$ack_msg_id"
                ;;
              *)
                die "Previous pack not acknowledged."
                ;;
            esac
          else
            die "Previous pack not acknowledged."
          fi
        fi
      fi
    else
      die "Telegram ack check failed."
    fi
  fi
  send_to_telegram_personal "$final_path" "$TG_CAPTION" "$TELEGRAM_CONFIG_FILE"
  rm -f -- "$final_path" || die "Uploaded to Telegram, but failed to delete local pack: $final_path"
  DELETE_FINAL_ON_EXIT="0"
  log_ok "Removed: $final_path"
else
  log_ok "Pack: $final_path"
fi
