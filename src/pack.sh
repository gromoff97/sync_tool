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

expand_home_path() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf '%s' "${HOME:-$path}"
    return 0
  fi
  if [[ "$path" == "~/"* && -n "${HOME:-}" ]]; then
    printf '%s/%s' "$HOME" "${path#"~/"}"
    return 0
  fi
  printf '%s' "$path"
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

escape_html() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
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
  if looks_like_placeholder "$TG_API_ID" || looks_like_placeholder "$TG_API_HASH"; then
    die "Telegram config in $cfg still has placeholder values."
  fi
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

compute_cutoff_epoch_days() {
  local days="$1"
  local cutoff=""
  if date -d "now - ${days} days" +%s >/dev/null 2>&1; then
    cutoff="$(date -d "now - ${days} days" +%s)"
  elif have python; then
    cutoff="$(python - <<'PY' "$days"
import sys, datetime
days=int(sys.argv[1])
now=datetime.datetime.utcnow()
cut=now - datetime.timedelta(days=days)
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
  local days="$2"
  [[ -n "$remote" ]] || die "--remote is required with -u"
  if [[ -n "$days" ]]; then
    log_git "Fetch remote: $remote (recent ${days} days)"
  else
    log_git "Fetch remote: $remote (existing local branches only)"
  fi
  git -C "$REPO_DIR" fetch --prune "$remote" >/dev/null 2>&1 || die "Failed to fetch remote '$remote'"

  if [[ -z "$days" ]]; then
    mapfile -t recent_branches < <(git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=2)' "refs/heads/*" | tr -d '\r')
    if [[ "${#recent_branches[@]}" -eq 0 ]]; then
      log_git "No local branches to update from remote."
      REMOTE_RECENT_BRANCHES=()
      REMOTE_RECENT_COUNT="0"
      return 0
    fi
  else
    local cutoff
    cutoff="$(compute_cutoff_epoch_days "$days")"
    [[ -n "$cutoff" ]] || die "Failed to compute recent cutoff."

    mapfile -t recent_branches < <(
      git -C "$REPO_DIR" for-each-ref --format='%(committerdate:unix) %(refname:strip=3)' "refs/remotes/$remote/" \
        | tr -d '\r' \
        | awk -v cutoff="$cutoff" -v r="$remote/" '$1>=cutoff {ref=$2; sub("^" r, "", ref); if(ref!="HEAD") print ref}'
    )
  fi

  if [[ "${#recent_branches[@]}" -eq 0 ]]; then
    if [[ -n "$days" ]]; then
      log_git "No remote branches updated in the last ${days} days."
    else
      log_git "No local branches matched remote refs."
    fi
    REMOTE_RECENT_BRANCHES=()
    REMOTE_RECENT_COUNT="0"
    return 0
  fi

  REMOTE_RECENT_BRANCHES=("${recent_branches[@]}")
  REMOTE_RECENT_COUNT="${#recent_branches[@]}"

  local current_branch
  current_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

  local diverged=()
  for b in "${recent_branches[@]}"; do
    if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/$remote/$b"; then
      continue
    fi
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
      if ! git -C "$REPO_DIR" merge-base --is-ancestor "refs/heads/$b" "refs/remotes/$remote/$b"; then
        diverged+=("$b")
      fi
    fi
  done
  if [[ "${#diverged[@]}" -gt 0 ]]; then
    err_line "$C_ERR" "ERR" "Diverged branches: ${diverged[*]}"
    err_line "$C_ERR" "ERR" "Run: git branch -D ${diverged[*]}"
    die "Cannot update branches from '$remote' (diverged)."
  fi

  local updated=0 created=0
  for b in "${recent_branches[@]}"; do
    if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/$remote/$b"; then
      continue
    fi
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
      if ! git -C "$REPO_DIR" merge-base --is-ancestor "refs/heads/$b" "refs/remotes/$remote/$b"; then
        die "Cannot update branch '$b' from '$remote/$b' (diverged)."
      fi
      if [[ -n "${current_branch:-}" && "$b" == "$current_branch" ]]; then
        git -C "$REPO_DIR" merge --ff-only "$remote/$b" >/dev/null 2>&1 \
          || die "Failed to fast-forward current branch '$b' from '$remote/$b'."
      else
        git -C "$REPO_DIR" update-ref "refs/heads/$b" "refs/remotes/$remote/$b" >/dev/null 2>&1 \
          || die "Failed to fast-forward branch '$b' from '$remote/$b'."
      fi
      updated=$((updated + 1))
    else
      git -C "$REPO_DIR" branch "$b" "$remote/$b" >/dev/null 2>&1 \
        || die "Failed to create branch '$b' from '$remote/$b'."
      created=$((created + 1))
    fi
  done

  log_git "Updated local branches from remote: $updated updated, $created created"
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

send_to_telegram_personal() {
  local file="$1" caption="$2"
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
    --to "$TG_TO"
    --pack-prefix "$PACK_PREFIX"
    --project-name "$PROJECT_NAME"
    --file "$file"
    --parse-mode html
  )
  if [[ "$TG_ACK_REQUIRED" == "1" ]]; then
    cmd+=(--require-ack --ack-text "$TG_ACK_TEXT" --scan-limit "$TG_ACK_SCAN_LIMIT")
  fi
  append_telegram_proxy_args cmd
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
  st="$(git -C "$repo" status --porcelain | awk '
    {
      path = substr($0, 4)
      if (path == "conf.toml" || path == "conf.example.toml") next
      print
    }'
  )"
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
  -u, --update [N]         fetch remote before pack; no value updates only existing local branches, positive N includes recent remote branches
  --remote NAME            remote name (default: origin; required with -u)
  --branch NAME            pack only this branch (no tags by default)
  --branches LIST          pack only these branches (comma-separated)
  --with-tags 0|1          include tags (default: 1 for all branches, 0 for selected branches)
  --dry-run                show what would be done without creating/sending
  --help

Subcommands:
  send                     send archive via Telegram (see: pack send --help)

Config:
  Use the top-level `pack` wrapper with the global `conf.toml` in the sync_tool directory.

Example:
  ./pack
  ./pack send
EOF
  exit 2
}

usage_send() {
  cat >&2 <<'EOF'
pack send — send the created pack via Telegram (personal account)

Options (same as pack):
  --output-dir PATH        default: ~/syncpacks
  --pack-prefix PREFIX     default: syncpack
  --machine-name NAME      default: auto-detected; written to manifest only
  -u, --update [N]         fetch remote before pack; no value updates only existing local branches, positive N includes recent remote branches
  --remote NAME            remote name (default: origin; required with -u)
  --branch NAME            pack only this branch (no tags by default)
  --branches LIST          pack only these branches (comma-separated)
  --with-tags 0|1          include tags (default: 1 for all branches, 0 for selected branches)
  --dry-run                show what would be done without creating/sending
  --help

Config:
  Use the top-level `pack send` wrapper with the global `conf.toml` in the sync_tool directory.
  The internal runner expects normalized Telegram/common/proxy runtime arguments.

Examples:
  ./pack send
  ./pack send --dry-run
EOF
  exit 2
}

telegram_doctor() {
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
    --doctor
    --to "$TG_TO"
  )
  append_telegram_proxy_args cmd

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi
}

check_telegram_ack() {
  local meta_file="$1" current_sha="$2"
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
    --to "$TG_TO"
    --pack-prefix "$PACK_PREFIX"
    --project-name "$PROJECT_NAME"
    --scan-limit "$TG_ACK_SCAN_LIMIT"
    --ack-text "$TG_ACK_TEXT"
    --check-ack
    --meta-file "$meta_file"
    --current-sha "$current_sha"
  )
  append_telegram_proxy_args cmd

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi
}

send_telegram_close() {
  local msg_id="$1" reason="$2"
  local -a py_cmd cmd
  select_python_for_telegram "$TG_PYTHON_MIN" "telethon" "colorama"
  py_cmd=("${PY_CMD[@]}" "-u")

  local script_dir script_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_path="$script_dir/tg_send.py"
  [[ -f "$script_path" ]] || die "Telegram sender script not found: $script_path"

  local text="Closed by <b>$(escape_html "$MACHINE_NAME")</b>"
  if [[ -n "$reason" ]]; then
    text="${text}"$'\n'"reason: $(escape_html "$reason")"
  fi

  if have winpty && [[ -t 0 && -t 1 ]]; then
    py_cmd=("winpty" "${py_cmd[@]}")
  fi

  cmd=("${py_cmd[@]}" "$script_path"
    --api-id "$TG_API_ID"
    --api-hash "$TG_API_HASH"
    --session "$TG_SESSION"
    --to "$TG_TO"
    --text "$text"
    --reply-to "$msg_id"
    --parse-mode html
  )
  append_telegram_proxy_args cmd

  if [[ -z "$C_RESET" ]]; then
    NO_COLOR=1 "${cmd[@]}"
  elif [[ "$USE_256_COLOR" == "1" ]]; then
    FORCE_COLOR=1 FORCE_256_COLOR=1 "${cmd[@]}"
  else
    FORCE_COLOR=1 "${cmd[@]}"
  fi
}

delete_telegram_message() {
  local msg_id="$1"
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
    --to "$TG_TO"
    --delete-message "$msg_id"
  )
  append_telegram_proxy_args cmd

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
TELEGRAM_DOCTOR="0"
OTHER_OPTS_USED="0"
TG_API_ID=""
TG_API_HASH=""
TG_TO=""
TG_SESSION=""
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
TG_ACK_REQUIRED="1"
TG_ACK_TEXT="Closed by"
TG_ACK_SCAN_LIMIT="32"
TG_PYTHON_MIN="3.8"
TG_CAPTION=""
final_path=""
DELETE_FINAL_ON_EXIT="0"
DRY_RUN="0"
BRANCHES_RAW=""
WITH_TAGS=""
UPDATE_REMOTE="0"
REMOTE_NAME=""
RECENT_DAYS=""

want_send_help="0"
want_help="0"
for _a in "$@"; do
  case "$_a" in
    send) want_send_help="1" ;;
    --help|-h) want_help="1" ;;
  esac
done
if [[ "$want_send_help" == "1" && "$want_help" == "1" ]]; then
  usage_send
fi

while [[ $# -gt 0 ]]; do
  if [[ "$1" == "send" ]]; then
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
    -u|--update)
      UPDATE_REMOTE="1"
      OTHER_OPTS_USED="1"
      if [[ $# -ge 2 && "${2:-}" =~ ^-?[0-9]+$ ]]; then
        if [[ "${2:-}" != "-1" ]]; then
          RECENT_DAYS="${2:-}"
        else
          RECENT_DAYS=""
        fi
        shift 2
      else
        shift 1
      fi
      ;;
    --remote)          REMOTE_NAME="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --remote=*)        REMOTE_NAME="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --update=*)
      UPDATE_REMOTE="1"
      OTHER_OPTS_USED="1"
      if [[ "${1#*=}" != "-1" ]]; then
        RECENT_DAYS="${1#*=}"
      else
        RECENT_DAYS=""
      fi
      shift 1
      ;;
    --branch)          BRANCHES_RAW="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --branch=*)        BRANCHES_RAW="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --branches)        BRANCHES_RAW="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --branches=*)      BRANCHES_RAW="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --with-tags)       WITH_TAGS="${2:-}"; OTHER_OPTS_USED="1"; shift 2;;
    --with-tags=*)     WITH_TAGS="${1#*=}"; OTHER_OPTS_USED="1"; shift 1;;
    --dry-run)         DRY_RUN="1"; shift 1;;
    --telegram-doctor) TELEGRAM_DOCTOR="1"; shift 1;;
    --api-id)          TG_API_ID="${2:-}"; shift 2;;
    --api-id=*)        TG_API_ID="${1#*=}"; shift 1;;
    --api-hash)        TG_API_HASH="${2:-}"; shift 2;;
    --api-hash=*)      TG_API_HASH="${1#*=}"; shift 1;;
    --session)         TG_SESSION="${2:-}"; shift 2;;
    --session=*)       TG_SESSION="${1#*=}"; shift 1;;
    --to)              TG_TO="${2:-}"; shift 2;;
    --to=*)            TG_TO="${1#*=}"; shift 1;;
    --ack-scan-limit)  TG_ACK_SCAN_LIMIT="${2:-}"; shift 2;;
    --ack-scan-limit=*) TG_ACK_SCAN_LIMIT="${1#*=}"; shift 1;;
    --caption)         TG_CAPTION="${2:-}"; shift 2;;
    --caption=*)       TG_CAPTION="${1#*=}"; shift 1;;
    --python-min)      TG_PYTHON_MIN="${2:-}"; shift 2;;
    --python-min=*)    TG_PYTHON_MIN="${1#*=}"; shift 1;;
    --proxy-type)      TG_PROXY_TYPE="${2:-}"; shift 2;;
    --proxy-type=*)    TG_PROXY_TYPE="${1#*=}"; shift 1;;
    --socks5-host)     TG_SOCKS5_HOST="${2:-}"; shift 2;;
    --socks5-host=*)   TG_SOCKS5_HOST="${1#*=}"; shift 1;;
    --socks5-port)     TG_SOCKS5_PORT="${2:-}"; shift 2;;
    --socks5-port=*)   TG_SOCKS5_PORT="${1#*=}"; shift 1;;
    --socks5-user)     TG_SOCKS5_USER="${2:-}"; shift 2;;
    --socks5-user=*)   TG_SOCKS5_USER="${1#*=}"; shift 1;;
    --socks5-password) TG_SOCKS5_PASSWORD="${2:-}"; shift 2;;
    --socks5-password=*) TG_SOCKS5_PASSWORD="${1#*=}"; shift 1;;
    --http-host)       TG_HTTP_HOST="${2:-}"; shift 2;;
    --http-host=*)     TG_HTTP_HOST="${1#*=}"; shift 1;;
    --http-port)       TG_HTTP_PORT="${2:-}"; shift 2;;
    --http-port=*)     TG_HTTP_PORT="${1#*=}"; shift 1;;
    --http-user)       TG_HTTP_USER="${2:-}"; shift 2;;
    --http-user=*)     TG_HTTP_USER="${1#*=}"; shift 1;;
    --http-password)   TG_HTTP_PASSWORD="${2:-}"; shift 2;;
    --http-password=*) TG_HTTP_PASSWORD="${1#*=}"; shift 1;;
    --mtproto-host)    TG_MTPROTO_HOST="${2:-}"; shift 2;;
    --mtproto-host=*)  TG_MTPROTO_HOST="${1#*=}"; shift 1;;
    --mtproto-port)    TG_MTPROTO_PORT="${2:-}"; shift 2;;
    --mtproto-port=*)  TG_MTPROTO_PORT="${1#*=}"; shift 1;;
    --mtproto-secret)  TG_MTPROTO_SECRET="${2:-}"; shift 2;;
    --mtproto-secret=*) TG_MTPROTO_SECRET="${1#*=}"; shift 1;;
    --help|-h)         usage_main;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_DIR" && "$TELEGRAM_DOCTOR" != "1" ]]; then
  die "Run pack.sh inside a git repository."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"
if [[ "$TELEGRAM_DOCTOR" != "1" ]]; then
OUTPUT_DIR="$(expand_home_path "$OUTPUT_DIR")"
[[ -n "$OUTPUT_DIR" ]] || die "HOME is not set; use --output-dir PATH."
fi
if [[ -n "$WITH_TAGS" && "$WITH_TAGS" != "0" && "$WITH_TAGS" != "1" ]]; then
  die "--with-tags must be 0|1"
fi
if [[ -n "$RECENT_DAYS" ]]; then
  if [[ ! "$RECENT_DAYS" =~ ^-?[0-9]+$ ]]; then
    die "update must be -1 or a positive integer"
  fi
  if [[ "$RECENT_DAYS" == "0" || "$RECENT_DAYS" =~ ^- ]]; then
    die "update must be -1 or a positive integer"
  fi
fi

if [[ "$TELEGRAM_DOCTOR" != "1" ]]; then
  ensure_repo_ok_and_clean "$REPO_DIR"
fi

if [[ "$TELEGRAM_DOCTOR" == "1" ]]; then
  require_telegram_config "runtime arguments"
  [[ -n "$TG_TO" ]] || die "telegram_to is required. Set [pack.send.telegram].to in conf.toml or run pack send setup."
  log_pack "Telegram doctor..."
  telegram_doctor
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
  fetch_recent_remote_branches "$REMOTE_NAME" "$RECENT_DAYS"
fi

mkdir -p "$OUTPUT_DIR" || die "Cannot create --output-dir: $OUTPUT_DIR"
if is_within_repo "$REPO_DIR" "$OUTPUT_DIR"; then
  die "Refusing to write packs inside the repository. Use --output-dir outside repo."
fi
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
  require_telegram_config "runtime arguments"
  if looks_like_placeholder "$TG_TO"; then
    TG_TO=""
  fi
  if [[ -z "$TG_TO" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Enter telegram_to (@username/phone/id/me): " TG_TO
      TG_TO="$(trim_ws "$TG_TO")"
    fi
  fi
  [[ -n "$TG_TO" ]] || die "telegram_to is required. Set [pack.send.telegram].to in conf.toml or run pack send setup."
  if [[ -z "$TG_CAPTION" ]]; then
    TG_CAPTION="Packed by <b>$(escape_html "$MACHINE_NAME")</b>"$'\n'"project: $(escape_html "$PROJECT_NAME")"$'\n'"content: $(escape_html "$content_desc")"
  fi

  log_pack "Telegram send..."
  DELETE_FINAL_ON_EXIT="1"
  ack_meta="$tmp/ack_meta.txt"
  rm -f -- "$ack_meta" 2>/dev/null || true
  if ! check_telegram_ack "$ack_meta" "$bundle_sha_short"; then
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
                send_telegram_close "$ack_msg_id" "replaced"
                log_pack "Deleting previous pack message..."
                delete_telegram_message "$ack_msg_id"
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
  send_to_telegram_personal "$final_path" "$TG_CAPTION"
  rm -f -- "$final_path" || die "Uploaded to Telegram, but failed to delete local pack: $final_path"
  DELETE_FINAL_ON_EXIT="0"
  log_ok "Removed: $final_path"
else
  log_ok "Pack: $final_path"
fi
