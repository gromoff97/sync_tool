#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_APP=$'\033[36m'
  C_WRN=$'\033[33m'
  C_ERR=$'\033[31m'
else
  C_RESET=''
  C_APP=''
  C_WRN=''
  C_ERR=''
fi

die() { printf '%b[ERR]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }
warn() { printf '%b[WRN]%b %s\n' "$C_WRN" "$C_RESET" "$*" >&2; }
info() { printf '%b[APP]%b %s\n' "$C_APP" "$C_RESET" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

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

usage() {
  cat >&2 <<'EOF'
unpack.sh — apply latest .tgz pack from a directory, update ALL branches + tags
If run inside a git repository, updates that repository.
If run outside a git repository, creates a new repository from the latest pack.

Optional (defaults):
  --pack-dir PATH             (default: ~/syncpacks)
  --pack-prefix PREFIX         (default: syncpack)
  --project-name NAME          (default: autodetect from current repo or selected pack)
  --peer NAME                  (default: sync)
  --ff-only 0|1                (default: 1)
  --force-tags 0|1             (default: 0)
  --prune-remote-refs 0|1      (default: 1)
  --prune-local-branches 0|1   (default: 0)
  --clean-peer-refs 0|1        (default: 1) remove refs/remotes/<peer>/*
  --help

Config:
  <tool_dir>/conf/unpack.conf (if present) overrides CLI options.
  Supported keys include:
    pack_dir, pack_prefix, project_name, peer,
    ff_only, force_tags, prune_remote_refs, prune_local_branches, clean_peer_refs

Example:
  ./unpack --pack-dir /c/Work/in
EOF
  exit 2
}

# ---- parse args ----
require_tools

PACK_DIR="${HOME:+$HOME/syncpacks}"
PACK_PREFIX="syncpack"

# defaults per your request
PROJECT_NAME=""
PEER="sync"
FF_ONLY="1"
FORCE_TAGS="0"
PRUNE_REMOTE_REFS="1"
PRUNE_LOCAL_BRANCHES="0"
CLEAN_PEER_REFS="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack-dir)               PACK_DIR="${2:-}"; shift 2;;
    --pack-dir=*)             PACK_DIR="${1#*=}"; shift 1;;
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

    --help|-h)                usage;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$TOOL_DIR/conf/unpack.conf"
load_config_overrides "$CONFIG_FILE"

[[ -n "$PEER" ]] || die "--peer cannot be empty"
[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"
[[ -n "$PACK_DIR" ]] || die "HOME is not set; use --pack-dir PATH."
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

PACK_FILE="$(pick_latest_pack "$PACK_DIR" "$PACK_PREFIX" "$PROJECT_NAME")"
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
fi

tmp="$(mktemp_dir)"
cleanup() { rm -rf "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

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
  if [[ "$local_repo_roots_sha" != "$expected_repo_roots_sha" ]]; then
    local_repo_roots_all_sha="$(repo_roots_fingerprint_all "$REPO_DIR" || true)"
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
    cleanup_peer_refs
    if ! rm -f -- "$PACK_FILE"; then
      warn "Matched, but failed to delete pack: $PACK_FILE"
    else
      info "Pack deleted: $PACK_FILE"
    fi
    exit 0
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
# Always force-update peer namespace from bundle. Local branch safety is handled separately by --ff-only.
if ! git -C "$REPO_DIR" fetch --force "$bundle" "refs/heads/*:refs/remotes/$PEER/*" >/dev/null 2>"$fetch_err"; then
  cat "$fetch_err" >&2
  die "Fetch failed."
fi

if [[ "$FORCE_TAGS" == "1" ]]; then
  git -C "$REPO_DIR" fetch --force "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
else
  git -C "$REPO_DIR" fetch "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
fi

if [[ "$FORCE_TAGS" == "0" ]]; then
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
    warn "Tag conflicts (not updated without --force-tags 1): ${tag_conflicts[*]}"
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

mapfile -t branches < <(git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$PEER/" | tr -d '\r' | sort)
if [[ "${#branches[@]}" -eq 0 ]]; then
  warn "No branches after fetch. Done."
  exit 0
fi

current_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
forced_updates=0

if [[ "$FF_ONLY" == "1" ]]; then
  diverged=()
  for b in "${branches[@]}"; do
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$b"; then
      if ! git -C "$REPO_DIR" merge-base --is-ancestor "$b" "$PEER/$b"; then
        diverged+=("$b")
      fi
    fi
  done
  if [[ "${#diverged[@]}" -gt 0 ]]; then
    warn "DIVERGED branches (fast-forward impossible): ${diverged[*]}"
    die "Resolve manually (merge/rebase), or use --ff-only 0 (dangerous)."
  fi
fi

for b in "${branches[@]}"; do
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

if [[ "$FF_ONLY" == "0" && "$forced_updates" -gt 0 ]]; then
  warn "FORCED updates may discard local commits."
fi

if [[ "$PRUNE_LOCAL_BRANCHES" == "1" && -s "$old_remote" ]]; then
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
          info "Deleted local branch: $b"
        else
          warn "Failed to delete local branch: $b"
        fi
      fi
    fi
  done < "$old_remote"
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
