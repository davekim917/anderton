#!/usr/bin/env bash
# The plugin's Stop hook, which Claude Code runs in the background in every session. In the session holding its
# project's Anderton role it keeps running, and exits 2 when another session in the project newly blocks on a
# person: Claude Code then wakes the holder with this script's stderr, and the next Stop runs it again. It only
# reports. waiting.sh --blocked decides what counts as blocked, and nothing here can answer a prompt. Anywhere
# else, and on any failure, it exits 0 and prints nothing.
# shellcheck source=SCRIPTDIR/session-lib.sh
. "$(dirname "$0")/session-lib.sh"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
if [ -z "$sid" ] || [ -z "$cwd" ]; then exit 0; fi

record=$(holder_record "$(project_root "$cwd")")
[ -n "$record" ] || exit 0
# The registry, not the record, says which session the holder's process runs now: /clear gives it a new id.
pid=$(jq -r '.pid // empty' "$record" 2>/dev/null)
[ -n "$pid" ] || exit 0
reg="$sessions/$pid.json"
[ "$(jq -r '.sessionId // empty' "$reg" 2>/dev/null)" = "$sid" ] || exit 0
is_holder "$reg" "$record" || exit 0

key=$(basename "$record" .json)
watcher="$holders/$key.watch"
reported="$holders/$key.reported"
take_watch() { (set -C; printf '%s\n' "$$" > "$watcher") 2>/dev/null; }
if ! take_watch; then
  other=$(cat "$watcher" 2>/dev/null)
  case $(ps -o command= -p "${other:-0}" 2>/dev/null) in *watch.sh*) exit 0 ;; esac
  rm -f "$watcher"
  take_watch || exit 0
fi
trap 'rm -f "$watcher"' EXIT

: >> "$reported" || exit 0
export CLAUDE_PID="$pid"
while is_holder "$reg" "$record"; do
  # A block's header carries when it began, so one that clears and returns is reported again.
  now=$(cd "$cwd" 2>/dev/null && "$(dirname "$0")/waiting.sh" --blocked 2>/dev/null | grep '^=== ')
  new=$(printf '%s\n' "$now" | grep -vxF -f "$reported" | grep .)
  printf '%s\n' "$now" > "$reported"
  if [ -n "$new" ]; then
    {
      echo "Anderton watch: another session in this project is blocked on a person. Nothing has been answered or approved."
      printf '%s\n' "$new"
      echo "Run waiting.sh to see what each one is asking."
    } >&2
    exit 2
  fi
  sleep "${ANDERTON_WATCH_TICK:-30}"
done
exit 0
