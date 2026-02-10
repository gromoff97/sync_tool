#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

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
  --output-dir PATH          (default: syncpacks)
  --pack-prefix PREFIX       (default: syncpack)
  --machine-name NAME        (default: auto-detected; written to manifest only)
  --help

Example:
  ./pack.sh --output-dir /c/Work/out
EOF
  exit 2
}

# ---- parse args ----
require_tools

OUTPUT_DIR="syncpacks"
PACK_PREFIX="syncpack"
MACHINE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)      OUTPUT_DIR="${2:-}"; shift 2;;
    --output-dir=*)    OUTPUT_DIR="${1#*=}"; shift 1;;
    --pack-prefix)     PACK_PREFIX="${2:-}"; shift 2;;
    --pack-prefix=*)   PACK_PREFIX="${1#*=}"; shift 1;;
    --machine-name)    MACHINE_NAME="${2:-}"; shift 2;;
    --machine-name=*)  MACHINE_NAME="${1#*=}"; shift 1;;
    --help|-h)         usage;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

[[ -n "$OUTPUT_DIR" ]] || usage
[[ -n "$PACK_PREFIX" ]] || die "--pack-prefix cannot be empty"

if [[ -z "$MACHINE_NAME" ]]; then
  MACHINE_NAME="$(detect_machine_name)"
fi
MACHINE_NAME="$(sanitize_for_manifest "$MACHINE_NAME")"

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_DIR" ]] || die "Run pack.sh inside a git repository."

PROJECT_NAME="$(basename "$REPO_DIR")"
PROJECT_NAME="$(sanitize_for_manifest "$PROJECT_NAME")"

mkdir -p "$OUTPUT_DIR" || die "Cannot create --output-dir: $OUTPUT_DIR"
ensure_repo_ok_and_clean "$REPO_DIR"

repo_roots_sha="$(repo_roots_fingerprint "$REPO_DIR")"

tmp="$(mktemp_dir)"
cleanup() { rm -rf "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

bundle="$tmp/bundle.bundle"
manifest="$tmp/manifest.tsv"

git -C "$REPO_DIR" bundle create "$bundle" --branches --tags >/dev/null || die "git bundle create failed"

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

tmp_out="$OUTPUT_DIR/.${final}.tmp.$$"
rm -f "$tmp_out" 2>/dev/null || true

tar -czf "$tmp_out" -C "$tmp" "bundle.bundle" "manifest.tsv" || die "tar failed"

tar -tzf "$tmp_out" | tr -d '\r' | awk 'BEGIN{b=0;m=0;bad=0}
  $0=="bundle.bundle"{b=1;next}
  $0=="manifest.tsv"{m=1;next}
  {bad=1}
  END{exit(!(b&&m&&!bad))}' || die "Archive sanity check failed"

mv -f "$tmp_out" "$OUTPUT_DIR/$final" || die "Cannot move archive to output dir"

echo "OK: $OUTPUT_DIR/$final"
