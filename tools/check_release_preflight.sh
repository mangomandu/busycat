#!/bin/bash
# Official packages must be built from a clean, tested commit.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPECTED=""
if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--verify-commit" ] || [ -z "$2" ]; then
    echo "Usage: $0 [--verify-commit SHA]" >&2
    exit 2
  fi
  EXPECTED="$2"
fi

assert_clean() {
  local current changes
  current="$(git rev-parse --verify HEAD)" || return 1
  changes="$(git status --porcelain --untracked-files=all)" || return 1
  if [ -n "$changes" ]; then
    echo "Official packaging requires a clean checkout, including untracked files. Commit or move your changes first." >&2
    return 1
  fi
  if [ -n "$EXPECTED" ] && [ "$current" != "$EXPECTED" ]; then
    echo "HEAD changed during packaging; rerun tests and packaging from the intended commit." >&2
    return 1
  fi
}

assert_clean
if [ -n "$EXPECTED" ]; then
  echo "Verified unchanged release commit $EXPECTED."
else
  EXPECTED="$(git rev-parse --verify HEAD)"
  ./test.sh
  assert_clean
  echo "Release preflight passed for $EXPECTED."
fi
