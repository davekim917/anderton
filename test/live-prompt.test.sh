#!/usr/bin/env bash
# Drives prompt.sh against real Claude Code sessions blocked on real prompts, each in a pane of a private tmux server.
# Not part of CI: it needs a logged-in claude and tmux, and spends a little usage. Run it by hand before changing
# prompt.sh. PROMPT_SH picks the script under test, so a check can be removed from a copy to see this suite fail.
#   bash test/live-prompt.test.sh
# Bash 3.2 and BSD userland, like the scripts it drives.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../skills/anderton/scripts"
prompt_sh="${PROMPT_SH:-$scripts/prompt.sh}"
for tool in claude tmux jq git; do command -v "$tool" >/dev/null 2>&1 || { echo "needs $tool"; exit 1; }; done

work=$(mktemp -d "${TMPDIR:-/tmp}/anderton-live.XXXXXX")
work=$(cd "$work" && pwd -P)
sock="anderton-live-$$"
home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
holder_record="" herdr_tab=""
cleanup() {
  tmux -L "$sock" kill-server 2>/dev/null || true
  if [ -n "$holder_record" ]; then rm -f "$holder_record"; fi
  if [ -n "$herdr_tab" ]; then herdr tab close "$herdr_tab" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

repo="$work/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m init
# A hook that asks is how a session with permissions bypassed still blocks on a person.
cat > "$work/hook.sh" <<'HOOK'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"live test"}}'
HOOK
chmod +x "$work/hook.sh"
jq -n --arg c "$work/hook.sh" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}}' > "$work/hook-settings.json"

failures=0
check() { # check <description> <command...>
  local what=$1
  shift
  if "$@"; then
    echo "ok   $what"
  else
    echo "FAIL $what"
    failures=$((failures + 1))
    if [ -n "${LIVE_FAIL_FAST:-}" ]; then exit 1; fi
  fi
}
# The server's environment reaches panes, and $TMUX reaches prompt.sh, so nothing here touches the user's own tmux.
t() { tmux -L "$sock" "$@"; }

start_session() { # start_session <name> [mode] [claude args...]: a real interactive session in a new window, ready for input
  local name=$1 mode=${2:-default} trusted="" reg
  shift 2 || shift
  t new-window -d -n "$name" -c "$repo" "claude -n $name --permission-mode $mode --model haiku $*"
  for _ in $(seq 1 60); do
    sleep 1
    pane_text=$(t capture-pane -p -t "live:$name" 2>/dev/null || true)
    case $pane_text in
      *"Yes, I trust"* | *"trust this folder"*)
        if [ -z "$trusted" ]; then
          t send-keys -t "live:$name" Down
          sleep 1
          t send-keys -t "live:$name" Enter
          trusted=1
        fi
        ;;
    esac
    reg=$(registry_of "$name")
    if [ -n "$reg" ] && [ "$(jq -r '.status // empty' "$reg")" = idle ]; then return 0; fi
  done
  echo "session $name never became ready"
  exit 1
}

registry_of() { # registry_of <name>: prints the path of the live session's registry entry
  local f
  for f in "$home"/sessions/*.json; do
    if [ "$(jq -r '.name // empty' "$f" 2>/dev/null)" = "$1" ] && [ "$(jq -r '.cwd // empty' "$f" 2>/dev/null)" = "$repo" ]; then
      printf '%s\n' "$f"
      return
    fi
  done
}

wait_blocked() { # wait_blocked <name>: until its registry says it waits on a permission prompt
  local f
  for _ in $(seq 1 90); do
    f=$(registry_of "$1")
    if [ -n "$f" ] && [ "$(jq -r '.waitingFor // empty' "$f")" = "permission prompt" ]; then return 0; fi
    sleep 1
  done
  echo "session $1 never blocked on a prompt"
  exit 1
}

ask_for() { # ask_for <name> <command>: makes the session run <command>, which stops at a permission prompt
  t send-keys -t "live:$1" -l "Use the Bash tool to run exactly this command and nothing else, with no commentary: $2"
  sleep 1
  t send-keys -t "live:$1" Enter
  wait_blocked "$1"
}

ran() { # ran <marker>: the blocked command ran, which only an allowed prompt can do
  for _ in 1 2 3 4 5 6 7 8; do
    if [ -e "$repo/$1" ]; then return 0; fi
    sleep 1
  done
  return 1
}
never_ran() { sleep 3; [ ! -e "$repo/$1" ]; }

answer() { # answer [args...]: runs prompt.sh as the holder; sets $out and $status
  set +e
  out=$(cd "$repo" && env TMUX="$tmux_env" CLAUDE_PID="$lead_pid" CLAUDE_CODE_SESSION_ID="$lead_sid" "$prompt_sh" "$@" 2>&1)
  status=$?
  set -e
}
contains() { case $out in *"$1"*) return 0 ;; *) return 1 ;; esac; }
fingerprint_of() { printf '%s\n' "$out" | sed -n 's/^Fingerprint: //p'; }
screen_of() { t capture-pane -p -t "live:$1"; }

# A window keeps the server alive for the whole run.
t -f /dev/null new-session -d -s live -n idle -x 130 -y 50 "sleep 3600"
tmux_env="$(t display-message -p -t live '#{socket_path},#{pid},0')"

start_session live-lead
lead_reg=$(registry_of live-lead)
lead_pid=$(jq -r .pid "$lead_reg")
lead_sid=$(jq -r .sessionId "$lead_reg")
(cd "$repo" && env CLAUDE_PID="$lead_pid" CLAUDE_CODE_SESSION_ID="$lead_sid" "$scripts/claim.sh" >/dev/null)
# shellcheck source=../skills/anderton/scripts/session-lib.sh
holder_record=$(. "$scripts/session-lib.sh"; holder_path "$(project_root "$repo")")

start_session live-a
start_session live-b

# One session blocks on the prompt every refusal below reads, so no refusal needs a prompt of its own.
ask_for live-a 'touch marker-yes'
answer live-a
fp=$(fingerprint_of)
check "reading names the session" contains "Session: live-a"
check "and shows the prompt's exact text" contains "touch marker-yes"
check "and matches what the pane shows" eval 'screen_of live-a | grep -qF "touch marker-yes"'
check "and gives a fingerprint" [ -n "$fp" ]
check "and answers nothing" never_ran marker-yes
check "the dialog offers an option wider than this call" eval 'screen_of live-a | grep -Eq "don.t ask again|always allow"'

# Scope: only the role holder runs it, and only the pane that session runs in is touched.
set +e
out=$(cd "$repo" && env TMUX="$tmux_env" CLAUDE_PID="$(jq -r .pid "$(registry_of live-b)")" CLAUDE_CODE_SESSION_ID="$(jq -r .sessionId "$(registry_of live-b)")" "$prompt_sh" live-a yes "$fp" 2>&1)
status=$?
set -e
check "a session holding no role is refused" [ "$status" -eq 3 ]
check "  and its yes does not run the command" never_ran marker-yes
answer live-b yes "$fp"
check "a session that isn't blocked is refused" eval '[ "$status" -eq 3 ] && contains "not blocked"'
check "  and a fingerprint from another session answers nothing" never_ran marker-yes

# Which key: a cursor moved onto "don't ask again" must not be pressed.
t send-keys -t live:live-a Down
sleep 1
check "the cursor has moved to the wider option" eval 'screen_of live-a | grep -q "❯ 2\."'
answer live-a
check "a prompt read with the cursor off '1. Yes' is refused" eval '[ "$status" -eq 3 ] && contains "open its tab"'
moved_fp=$(fingerprint_of)
answer live-a yes "${moved_fp:-$fp}"
check "and answering it is refused" [ "$status" -eq 3 ]
check "  and nothing ran" never_ran marker-yes
check "  and no permission was widened" eval '! grep -qs "touch" "$repo/.claude/settings.local.json"'
t send-keys -t live:live-a Up
sleep 1

# Right before the press: a fingerprint that isn't this prompt's is refused.
answer live-a yes 0000000000000000000000000000000000000000000000000000000000000000
check "a fingerprint that doesn't match is refused" eval '[ "$status" -eq 3 ] && contains "changed since it was read"'
check "  and nothing ran" never_ran marker-yes

# The press itself: a key that never reaches the pane must not read as answered.
mkdir -p "$work/nokeys"
cat > "$work/nokeys/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = send-keys ]; then exit 0; fi
exec "$(command -v tmux)" "\$@"
EOF
chmod +x "$work/nokeys/tmux"
real_path=$PATH
PATH="$work/nokeys:$PATH"
answer live-a yes "$fp"
PATH=$real_path
check "a press that doesn't land exits 4, with the prompt still open" eval '[ "$status" -eq 4 ] && screen_of live-a | grep -qF "Do you want to proceed"'

answer live-a yes "$fp"
check "yes answers the prompt" [ "$status" -eq 0 ]
check "  and the command ran" ran marker-yes
check "  and the dialog has gone" eval '! screen_of live-a | grep -qF "Do you want to proceed"'
check "  and the answer allowed that one call" eval '! grep -qs "touch" "$repo/.claude/settings.local.json"'
answer live-a yes "$fp"
check "the same answer can't be replayed" [ "$status" -eq 3 ]

# An identical second prompt is a new prompt: the first one's fingerprint must not answer it.
ask_for live-a 'touch marker-yes'
answer live-a
fp_second=$(fingerprint_of)
check "an identical later prompt reads a new fingerprint" [ "$fp_second" != "$fp" ]
rm -f "$repo/marker-yes"
answer live-a yes "$fp"
check "  and the old one is refused" [ "$status" -eq 3 ]
check "  and nothing ran" never_ran marker-yes
answer live-a no "$fp_second"
check "no answers the prompt" [ "$status" -eq 0 ]
check "  and the command did not run" never_ran marker-yes

# Two blocked sessions: an answer lands only in the session it names.
ask_for live-a 'touch marker-a'
ask_for live-b 'touch marker-b'
answer live-b
fp_b=$(fingerprint_of)
check "the second pane's prompt reads its own text" contains "touch marker-b"
answer live-b yes "$fp_b"
check "yes in one of two blocked sessions runs that session's command" ran marker-b
check "  and not the other's" never_ran marker-a
check "  whose prompt stays open" eval 'screen_of live-a | grep -qF "touch marker-a"'
answer live-a
answer live-a no "$(fingerprint_of)"

# Permissions bypassed: a prompt a hook raises is answered the same way.
start_session live-hook bypassPermissions --settings "$work/hook-settings.json"
ask_for live-hook 'touch marker-hook'
answer live-hook
check "a hook's prompt in a bypassed session reads" contains "touch marker-hook"
answer live-hook yes "$(fingerprint_of)"
check "  and yes runs its command" ran marker-hook

# A real herdr tab, when this runs inside herdr.
if [ -n "${HERDR_SOCKET_PATH:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -z "${LIVE_TMUX_ONLY:-}" ]; then
  created=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$repo" --label live-h --no-focus)
  herdr_tab=$(printf '%s' "$created" | jq -r '.result.tab.tab_id')
  herdr agent start live-h --kind claude --pane "$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')" \
    --timeout 120000 -- -n live-h --permission-mode default --model haiku >/dev/null
  herdr agent prompt live-h "Use the Bash tool to run exactly this command and nothing else, with no commentary: touch marker-herdr" >/dev/null
  wait_blocked live-h
  answer live-h
  fp=$(fingerprint_of)
  check "herdr: reading shows the prompt" contains "touch marker-herdr"
  check "herdr: and answers nothing" never_ran marker-herdr
  answer live-h yes "$fp"
  check "herdr: yes answers the prompt" [ "$status" -eq 0 ]
  check "herdr: and the command ran" ran marker-herdr
  herdr agent prompt live-h "Use the Bash tool to run exactly this command and nothing else, with no commentary: touch marker-herdr-no" >/dev/null
  wait_blocked live-h
  answer live-h
  answer live-h no "$(fingerprint_of)"
  check "herdr: no answers the prompt" [ "$status" -eq 0 ]
  check "herdr: and the command did not run" never_ran marker-herdr-no
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all live checks passed"
