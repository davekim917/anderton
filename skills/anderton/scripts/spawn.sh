#!/usr/bin/env bash
# Start a real Claude Code session in the background to do one task: in its own worktree of the caller's
# repository (outside the checkout), in the caller's permission mode, told to report to the caller by name.
# usage: spawn.sh [--model M] [--effort E] [--mode MODE] [--base REF] <name> [brief-file]   (else the brief on stdin)
# Worktrees go under $ANDERTON_WORKTREES, default the folder that holds the repository, as wt-<name>.
# Portable to macOS's bash 3.2 and BSD userland.
set -euo pipefail
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

require_tools spawn.sh
command -v claude >/dev/null 2>&1 || {
  echo "spawn.sh needs the claude CLI on PATH." >&2
  exit 1
}

usage="usage: spawn.sh [--model M] [--effort E] [--mode MODE] [--base REF] <name: a-z 0-9 -> [brief-file]"
model="" effort="" mode="" base=""
while [ $# -gt 0 ]; do
  case $1 in
    --model | --effort | --mode | --base)
      [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }
      case $1 in
        --model) model=$2 ;;
        --effort) effort=$2 ;;
        --mode) mode=$2 ;;
        --base) base=$2 ;;
      esac
      shift 2
      ;;
    -*) echo "$usage" >&2; exit 2 ;;
    *) break ;;
  esac
done
name="${1:-}"
case $name in
  '' | -* | *[!a-z0-9-]*) echo "$usage" >&2; exit 2 ;;
esac
if [ -n "${2:-}" ]; then brief=$(cat "$2"); else brief=$(cat); fi
if [ -z "$(printf '%s' "$brief" | tr -d '[:space:]')" ]; then
  echo "spawn.sh: the brief is empty." >&2
  exit 2
fi

sid="${CLAUDE_CODE_SESSION_ID:?not running inside a Claude Code session}"
pid="${CLAUDE_PID:-$(session_pid "$sid")}"
if [ -z "$pid" ]; then
  echo "Cannot find the pid of session $sid under $sessions." >&2
  exit 1
fi
me=$(jq -r '.name // empty' "$sessions/$pid.json" 2>/dev/null || true)
if [ -z "$me" ]; then
  echo "This session has no name for the worker to report to. Name it with /rename, then rerun." >&2
  exit 1
fi

# A peer in another permission mode holds this session's messages for its user's approval, so the worker
# runs in this session's mode, which its transcript records on each prompt.
if [ -z "$mode" ]; then
  for t in "$home"/projects/*/"$sid".jsonl; do
    [ -e "$t" ] || continue
    mode=$(tail -n 2000 "$t" | jq -r 'select(.permissionMode != null) | .permissionMode' 2>/dev/null | tail -n 1)
    break
  done
fi
if [ -z "$mode" ]; then
  echo "Cannot read this session's permission mode from its transcript; pass --mode." >&2
  exit 1
fi

mkdir -p "$holders/workers"
record="$holders/workers/$name.json"
# Creating the record exclusively reserves the name, so two spawns of one name cannot both pass the checks below.
if ! (set -C && : > "$record") 2>/dev/null; then
  echo "A worker named '$name' was started before and not retired: run retire.sh $name first." >&2
  exit 1
fi
reserved=1
trap '[ -z "$reserved" ] || rm -f "$record"' EXIT
if claude agents --json 2>/dev/null | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
  echo "A live session is already named '$name'; pick another name." >&2
  exit 1
fi

root=$(invoking_root)
dir=$root
worktree=false
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$base" ]; then
    for ref in "$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)" origin/main origin/master HEAD; do
      if [ -n "$ref" ] && git -C "$root" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
        base=$ref
        break
      fi
    done
  fi
  case $base in origin/*) git -C "$root" fetch -q origin 2>/dev/null || echo "spawn.sh: could not fetch origin; starting from the cached $base." >&2 ;; esac
  parent="${ANDERTON_WORKTREES:-$(dirname "$root")}"
  mkdir -p "$parent"
  parent=$(cd "$parent" && pwd -P)
  dir="$parent/wt-$name"
  if [ -e "$dir" ]; then
    echo "$dir already exists; pick another name." >&2
    exit 1
  fi
  git -C "$root" worktree add -q --detach "$dir" "$base"
  worktree=true
  base=$(git -C "$dir" rev-parse HEAD)
fi

brief="$brief

---
You are a worker the Anderton session \"$me\" started for the task above, in $dir.
- Tell \"$me\" by SendMessage the moment you have a question or a blocker, with your recommendation, and when you finish: the PR link and what you verified. Nobody reads this session, so a question left only in your reply is never answered.
- Do not deploy, restart a service, or message anyone off this machine unless the task says to; \"$me\" owns those."

set -- --bg -n "$name" --permission-mode "$mode"
[ -z "$model" ] || set -- "$@" --model "$model"
[ -z "$effort" ] || set -- "$@" --effort "$effort"
if ! out=$(cd "$dir" && claude "$@" "$brief" 2>&1); then
  echo "$out" >&2
  if [ "$worktree" = true ]; then git -C "$root" worktree remove "$dir"; fi
  exit 1
fi

# `claude stop` and `claude rm` take the session's id, not its name.
id=$(claude agents --json 2>/dev/null | jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty' 2>/dev/null || true)
[ -n "$id" ] || id=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f]*\) · .*/\1/p' | head -n 1)
jq -nc --arg name "$name" --arg id "$id" --arg dir "$dir" --arg root "$root" --arg base "$base" --arg spawner "$me" \
  --argjson worktree "$worktree" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{name: $name, id: $id, dir: $dir, root: $root, base: $base, worktree: $worktree, spawner: $spawner, startedAt: $at}' >| "$record"
reserved=""
printf '%s\n' "$out"
echo "Started worker '$name' (${id:-id unknown}) in $dir ($mode). It reports to '$me'."
