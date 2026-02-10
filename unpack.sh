#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
  have git  || die "git not found"
  have tar  || die "tar not found"
  have awk  || die "awk not found"
  have sort || die "sort not found"
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

gitpath() { git -C "$1" rev-parse --git-path "$2"; }

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
  roots="$(git -C "$repo" rev-list --max-parents=0 --all 2>/dev/null | tr -d '\r' | sort)"
  [[ -n "$roots" ]] || die "Failed to compute repo roots (is the repo shallow or corrupt?)"
  sha256_text "$roots"
}

pick_latest_pack() {
  local dir="$1" prefix="$2" project="$3"
  [[ -d "$dir" ]] || die "--pack-dir is not a directory: $dir"

  shopt -s nullglob
  local files=( "$dir"/"${prefix}_${project}_"*.tgz )
  shopt -u nullglob

  [[ "${#files[@]}" -gt 0 ]] || die "No packs found in $dir for project '$project' and prefix '$prefix'"

  local best="" best_ts="" f base ts
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    ts="${base#${prefix}_${project}_}"
    ts="${ts%.tgz}"
    if [[ "$ts" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
      if [[ -z "$best_ts" || "$ts" > "$best_ts" ]]; then
        best_ts="$ts"
        best="$f"
      fi
    fi
  done

  [[ -n "$best" ]] || die "No packs with valid timestamp in name: ${prefix}_${project}_YYYYMMDD_HHMMSS.tgz"
  printf '%s' "$best"
}

usage() {
  cat >&2 <<'EOF'
unpack.sh — apply latest .tgz pack from a directory, update ALL branches + tags
Must be run inside the target git repository.

Optional (defaults):
  --pack-dir PATH             (default: ~/syncpacks)
  --pack-prefix PREFIX         (default: syncpack)
  --peer NAME                  (default: sync)
  --ff-only 0|1                (default: 1)
  --force-tags 0|1             (default: 0)
  --prune-remote-refs 0|1      (default: 1)
  --prune-local-branches 0|1   (default: 0)
  --help

Example:
  ./unpack.sh --pack-dir /c/Work/in
EOF
  exit 2
}

# ---- parse args ----
require_tools

PACK_DIR="${HOME:+$HOME/syncpacks}"
PACK_PREFIX="syncpack"

# defaults per your request
PEER="sync"
FF_ONLY="1"
FORCE_TAGS="0"
PRUNE_REMOTE_REFS="1"
PRUNE_LOCAL_BRANCHES="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack-dir)               PACK_DIR="${2:-}"; shift 2;;
    --pack-dir=*)             PACK_DIR="${1#*=}"; shift 1;;
    --pack-prefix)            PACK_PREFIX="${2:-}"; shift 2;;
    --pack-prefix=*)          PACK_PREFIX="${1#*=}"; shift 1;;

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

    --help|-h)                usage;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

[[ -n "$PEER" ]] || die "--peer cannot be empty"
[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"
[[ -n "$PACK_DIR" ]] || die "HOME is not set; use --pack-dir PATH."
[[ "$FF_ONLY" == "0" || "$FF_ONLY" == "1" ]] || die "--ff-only must be 0|1"
[[ "$FORCE_TAGS" == "0" || "$FORCE_TAGS" == "1" ]] || die "--force-tags must be 0|1"
[[ "$PRUNE_REMOTE_REFS" == "0" || "$PRUNE_REMOTE_REFS" == "1" ]] || die "--prune-remote-refs must be 0|1"
[[ "$PRUNE_LOCAL_BRANCHES" == "0" || "$PRUNE_LOCAL_BRANCHES" == "1" ]] || die "--prune-local-branches must be 0|1"

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_DIR" ]] || die "Run unpack.sh inside a git repository."

PROJECT_NAME="$(basename "$REPO_DIR")"

ensure_repo_ok_and_clean "$REPO_DIR"

PACK_FILE="$(pick_latest_pack "$PACK_DIR" "$PACK_PREFIX" "$PROJECT_NAME")"
echo "INFO: picked latest pack: $PACK_FILE"
echo "INFO: peer namespace: refs/remotes/$PEER/*"

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

expected_repo_roots_sha="$(read_manifest_value "$manifest" repo_roots_sha256 || true)"
if [[ -z "${expected_repo_roots_sha:-}" ]]; then
  die "Pack missing repo_roots_sha256. Recreate pack with updated pack.sh."
fi
local_repo_roots_sha="$(repo_roots_fingerprint "$REPO_DIR")"
if [[ "$local_repo_roots_sha" != "$expected_repo_roots_sha" ]]; then
  die "Repository identity mismatch (pack=$expected_repo_roots_sha, local=$local_repo_roots_sha)."
fi

expected_bundle_sha="$(read_manifest_value "$manifest" bundle_sha256 || true)"
if [[ -n "${expected_bundle_sha:-}" ]]; then
  actual_bundle_sha="$(sha256_file "$bundle")"
  [[ "$actual_bundle_sha" == "$expected_bundle_sha" ]] || die "Bundle SHA256 mismatch (corrupted transfer?)"
else
  warn "No bundle_sha256 in manifest (skipping integrity check)"
fi

verify_out="$tmp/bundle_verify.txt"
if ! git -C "$REPO_DIR" bundle verify "$bundle" >"$verify_out" 2>&1; then
  cat "$verify_out" >&2
  die "Bundle verification failed. Ask sender to send a FULL bundle (--branches --tags)."
fi

incoming_list="$tmp/incoming_branches.txt"
git bundle list-heads "$bundle" 2>/dev/null \
  | awk '{ref=$2; sub("^refs/heads/","",ref); if(length(ref)>0) print ref}' \
  | tr -d '\r' | sort -u > "$incoming_list" || die "Failed to list heads from bundle"

old_remote="$tmp/old_remote.tsv"
git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=3)\t%(objectname)' "refs/remotes/$PEER/" \
  | tr -d '\r' > "$old_remote" || true

fetch_err="$tmp/fetch_err.txt"
if ! git -C "$REPO_DIR" fetch "$bundle" "refs/heads/*:refs/remotes/$PEER/*" >/dev/null 2>"$fetch_err"; then
  cat "$fetch_err" >&2
  die "Fetch failed."
fi

if [[ "$FORCE_TAGS" == "1" ]]; then
  git -C "$REPO_DIR" fetch --force "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
else
  git -C "$REPO_DIR" fetch "$bundle" "refs/tags/*:refs/tags/*" >/dev/null 2>/dev/null || true
fi

if [[ "$PRUNE_REMOTE_REFS" == "1" ]]; then
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if ! grep -Fxq "$b" "$incoming_list"; then
      git -C "$REPO_DIR" update-ref -d "refs/remotes/$PEER/$b" || warn "Failed to delete remote ref: $PEER/$b"
    fi
  done < <(git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$PEER/" | tr -d '\r' | sort)
fi

mapfile -t branches < <(git -C "$REPO_DIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$PEER/" | tr -d '\r' | sort)
if [[ "${#branches[@]}" -eq 0 ]]; then
  warn "No branches under refs/remotes/$PEER/* after fetch. Done."
  exit 0
fi

current_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

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
    echo "DIVERGED branches (fast-forward impossible). Local branches NOT updated:" >&2
    printf '  - %s\n' "${diverged[@]}" >&2
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
        warn "--ff-only 0 -> resetting current branch '$b' to $PEER/$b (may discard local commits)"
        git -C "$REPO_DIR" reset --hard "$remote_sha" >/dev/null
      fi
    else
      if [[ "$FF_ONLY" == "0" ]]; then
        warn "--ff-only 0 -> forcing branch '$b' to $PEER/$b (may discard local commits)"
      fi
      git -C "$REPO_DIR" update-ref "refs/heads/$b" "$remote_sha"
    fi
  else
    git -C "$REPO_DIR" branch "$b" "$remote_sha" >/dev/null
  fi
done

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
        git -C "$REPO_DIR" branch -D "$b" >/dev/null || warn "Failed to delete local branch: $b"
      fi
    fi
  done < "$old_remote"
fi

echo "OK: updated ${#branches[@]} branch(es) and tags (peer=$PEER)."
