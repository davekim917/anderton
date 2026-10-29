#!/usr/bin/env bash
# Stop a worker spawn.sh started and remove the worktree it made for it. A worktree with uncommitted work, or
# commits since it started that no remote branch has, is kept and the worker stays recorded: push or discard
# that work, then rerun.
# usage: retire.sh <name>   Exit 0: retired. Exit 3: stopped, worktree kept.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools retire.sh
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "usage: retire.sh <name>" >&2; exit 2 ;;
esac
record="$holders/workers/$name.json"
if [ ! -f "$record" ]; then
  echo "No worker named '$name' was started by spawn.sh; nothing to retire." >&2
  exit 1
fi
dir=$(jq -r .dir "$record")
root=$(jq -r .root "$record")
worktree=$(jq -r .worktree "$record")
id=$(jq -r '.id // empty' "$record")

if [ -n "$id" ] && command -v claude >/dev/null 2>&1; then
  claude stop "$id" >/dev/null 2>&1 || true
fi

if [ "$worktree" = true ] && [ -d "$dir" ]; then
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "Stopped '$name'. Kept $dir: it has uncommitted changes."
    exit 3
  fi
  if [ -n "$(git -C "$dir" rev-list -1 HEAD --not --remotes "$(jq -r .base "$record")" 2>/dev/null)" ]; then
    echo "Stopped '$name'. Kept $dir: it has commits no remote branch has."
    exit 3
  fi
  git -C "$root" worktree remove "$dir"
fi
if [ -n "$id" ] && command -v claude >/dev/null 2>&1 && ! claude rm "$id" >/dev/null 2>&1; then
  echo "retire.sh: claude rm $id failed; remove the session by hand." >&2
fi
rm -f "$record"
echo "Retired '$name'."
