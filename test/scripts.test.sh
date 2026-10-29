#!/usr/bin/env bash
# Drives claim.sh and waiting.sh against a throwaway Claude Code home with sessions in two projects.
# Runs under macOS's bash 3.2 as well as Linux: bash test/scripts.test.sh
set -euo pipefail

scripts="$(cd "$(dirname "$0")/../skills/anderton/scripts" && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/anderton-test.XXXXXX")
work=$(cd "$work" && pwd -P)
sleepers=""
cleanup() {
  for p in $sleepers; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

export CLAUDE_CONFIG_DIR="$work/claude"
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID HERDR_SOCKET_PATH TMUX
# A fake claude CLI, so no test reaches this machine's real sessions: `agents --json` prints $FAKE_AGENTS,
# `--bg` logs its directory and arguments, `stop` and `rm` log themselves.
mkdir -p "$work/bin"
cat > "$work/bin/claude" <<'FAKE'
#!/usr/bin/env bash
case $1 in
  agents) cat "$FAKE_AGENTS" ;;
  --bg)
    { pwd; printf '%s\n' "$@"; } > "$FAKE_LOG.bg"
    if [ -n "${FAKE_BG_FAIL:-}" ]; then echo "could not start" >&2; exit 1; fi
    echo "backgrounded · a1b2c3d4 · $3"
    ;;
  stop | rm)
    echo "$*" >> "$FAKE_LOG.life"
    if [ "$1" = stop ] && [ -n "${FAKE_STOP_FAIL:-}" ]; then exit 1; fi
    if [ "$1" = rm ] && [ -n "${FAKE_RM_FAIL:-}" ]; then exit 1; fi
    ;;
esac
FAKE
chmod +x "$work/bin/claude"
# A fake herdr. Open tabs are lines "<server socket> <tab id> <label>" in $FAKE_LOG.tabs-open, so a tab is
# found only in the server ($HERDR_SOCKET_PATH) it was opened in, under its own label.
# `tab create` opens tab $FAKE_HERDR_TAB (default w9:t5). `agent start` and `agent prompt` log what they got;
# with $FAKE_HERDR_START_LIVE, start lists the session as live. `tab get` reports the tab, or tab_not_found, or
# with $FAKE_HERDR_GET_GARBAGE an unreadable answer, or with $FAKE_HERDR_NO_SERVER server_not_running. `tab close` logs the tab and its server, closes it (not with
# $FAKE_HERDR_CLOSE_FAIL) and, with $FAKE_HERDR_CLOSE_ENDS, ends the session in it.
cat > "$work/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
sock=${HERDR_SOCKET_PATH:-}
case "$1 $2" in
  "tab create")
    printf '%s\n' "$@" > "$FAKE_LOG.tab"
    label=""
    while [ $# -gt 0 ]; do
      if [ "$1" = --label ]; then label=$2; fi
      shift
    done
    tab=${FAKE_HERDR_TAB:-w9:t5}
    echo "$sock $tab $label" >> "$FAKE_LOG.tabs-open"
    printf '{"id":"cli:tab:create","result":{"root_pane":{"pane_id":"w9:p5","tab_id":"%s"},"tab":{"tab_id":"%s"},"type":"tab_created"}}\n' "$tab" "$tab"
    ;;
  "agent start")
    printf '%s\n' "$@" > "$FAKE_LOG.start"
    if [ -n "${FAKE_HERDR_START_LIVE:-}" ]; then printf '[{"kind":"interactive","name":"%s","id":null}]\n' "$3" > "$FAKE_AGENTS"; fi
    if [ -n "${FAKE_HERDR_START_FAIL:-}" ]; then echo '{"error":{"code":"agent_not_ready"}}'; exit 1; fi
    ;;
  "agent prompt") printf '%s' "$4" > "$FAKE_LOG.prompt" ;;
  "agent read") echo "Quick safety check: Is this a project you trust?" ;;
  "tab get")
    if [ -n "${FAKE_HERDR_GET_GARBAGE:-}" ]; then echo "permission denied" >&2; exit 1; fi
    if [ -n "${FAKE_HERDR_NO_SERVER:-}" ]; then echo '{"error":{"code":"server_not_running"}}'; exit 1; fi
    label=$(awk -v s="$sock" -v t="$3" '$1 == s && $2 == t { print $3; exit }' "$FAKE_LOG.tabs-open" 2>/dev/null)
    if [ -n "$label" ]; then printf '{"result":{"tab":{"tab_id":"%s","label":"%s"}}}\n' "$3" "$label"; exit 0; fi
    echo '{"error":{"code":"tab_not_found"}}'
    exit 1
    ;;
  "tab close")
    echo "$3" >> "$FAKE_LOG.closed"
    echo "$sock" >> "$FAKE_LOG.closed-socket"
    if [ -n "${FAKE_HERDR_CLOSE_FAIL:-}" ]; then exit 1; fi
    awk -v s="$sock" -v t="$3" '!($1 == s && $2 == t)' "$FAKE_LOG.tabs-open" > "$FAKE_LOG.tabs-open.tmp" 2>/dev/null || true
    mv "$FAKE_LOG.tabs-open.tmp" "$FAKE_LOG.tabs-open"
    if [ -n "${FAKE_HERDR_CLOSE_ENDS:-}" ]; then echo '[]' > "$FAKE_AGENTS"; fi
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$work/bin/herdr"
# A fake tmux. Open windows are lines "<server socket> <server pid> <window id> <name>" in
# $FAKE_LOG.windows-open; `new-window` takes the server from $TMUX ("socket,pid,session"), the others from -S.
# `new-window` logs its arguments and opens window $FAKE_TMUX_WINDOW (default @7); with $FAKE_TMUX_LIVE the
# session in it registers, with $FAKE_TMUX_GONE the window has already closed. `list-windows` prints
# "<pid> <id> <name>" for that server's windows, or reports it dead ($FAKE_TMUX_NO_SERVER, its socket left
# behind), its socket missing ($FAKE_TMUX_NO_SOCKET) or an answer the check cannot read ($FAKE_TMUX_GARBAGE). `kill-window` logs the server and target, closes it (not
# with $FAKE_TMUX_KILL_FAIL) and, with $FAKE_TMUX_KILL_ENDS, ends the session.
cat > "$work/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
sock=""
if [ "$1" = -S ]; then sock=$2; shift 2; fi
case $1 in
  new-window)
    printf '%s\n' "$@" > "$FAKE_LOG.window"
    if [ -n "${FAKE_TMUX_FAIL:-}" ]; then echo "no server" >&2; exit 1; fi
    if [ -n "${FAKE_TMUX_LIVE:-}" ]; then printf '[{"kind":"interactive","name":"%s","id":null}]\n' "$7" > "$FAKE_AGENTS"; fi
    window=${FAKE_TMUX_WINDOW:-@7}
    if [ -z "${FAKE_TMUX_GONE:-}" ]; then
      echo "${TMUX%%,*} $(printf '%s' "$TMUX" | cut -d, -f2) $window $7" >> "$FAKE_LOG.windows-open"
    fi
    echo "$window"
    ;;
  list-windows)
    if [ -n "${FAKE_TMUX_NO_SERVER:-}" ]; then echo "no server running on $sock" >&2; exit 1; fi
    if [ -n "${FAKE_TMUX_NO_SOCKET:-}" ]; then echo "error connecting to $sock (No such file or directory)" >&2; exit 1; fi
    if [ -n "${FAKE_TMUX_GARBAGE:-}" ]; then echo "error connecting to $sock (Permission denied)" >&2; exit 1; fi
    awk -v s="$sock" '$1 == s { print $2, $3, $4 }' "$FAKE_LOG.windows-open" 2>/dev/null || true
    ;;
  kill-window)
    echo "$sock $3" >> "$FAKE_LOG.killed"
    if [ -n "${FAKE_TMUX_KILL_FAIL:-}" ]; then exit 1; fi
    awk -v s="$sock" -v w="$3" '!($1 == s && $3 == w)' "$FAKE_LOG.windows-open" > "$FAKE_LOG.windows-open.tmp" 2>/dev/null || true
    mv "$FAKE_LOG.windows-open.tmp" "$FAKE_LOG.windows-open"
    if [ -n "${FAKE_TMUX_KILL_ENDS:-}" ]; then echo '[]' > "$FAKE_AGENTS"; fi
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$work/bin/tmux"
export PATH="$work/bin:$PATH" FAKE_AGENTS="$work/agents.json" FAKE_LOG="$work/claude-log"
echo '[]' > "$FAKE_AGENTS"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_CONFIG_DIR/projects/p" "$work/beta"

# Project alpha is a repository with a linked worktree; project beta is a plain directory.
alpha="$work/alpha"
git init -q "$alpha"
git -C "$alpha" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$alpha" worktree add -q "$work/alpha-wt" 2>/dev/null
beta="$work/beta"
# Project gamma is a bare repository with two worktrees and no main checkout.
gamma="$work/gamma.git"
git init -q --bare "$gamma"
git -C "$alpha" push -q "$gamma" HEAD:refs/heads/main 2>/dev/null
git -C "$gamma" worktree add -q "$work/gamma-a" main 2>/dev/null
git -C "$gamma" worktree add -q -b other "$work/gamma-b" main 2>/dev/null

failures=0
check() { # check <description> <command...>
  local what=$1
  shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}

# Sets $pid to a process that stays alive until cleanup, or with "dead" to one that has exited.
# The dead one exits on its own: a signal can land before the fork execs, and that fork would run this
# shell's EXIT trap.
spawn() {
  if [ "${1:-}" = dead ]; then
    sleep 0 >/dev/null 2>&1 &
    pid=$!
    wait "$pid"
  else
    sleep 300 >/dev/null 2>&1 &
    pid=$!
    sleepers="$sleepers $pid"
  fi
}

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now_s=$(date +%s)
recent=$(iso "$now_s")
five_min_ago=$(iso $((now_s - 300)))
now_ms="${now_s}000"
long_ago_ms=1577836800000

# session <pid> <id> <cwd> <name> [startedAt ms, default now]
session() {
  printf '{"pid":%s,"startedAt":%s,"sessionId":"%s","cwd":"%s","name":"%s","kind":"interactive"}\n' \
    "$1" "${5:-$now_ms}" "$2" "$3" "$4" > "$CLAUDE_CONFIG_DIR/sessions/$1.json"
}

# registry <pid> <status> [waitingFor]: set a registry entry's status as Claude Code does.
registry() {
  local f="$CLAUDE_CONFIG_DIR/sessions/$1.json"
  jq -c --arg status "$2" --arg why "${3:-}" --argjson at "$now_ms" \
    '.status = $status | .statusUpdatedAt = $at | if $why != "" then .waitingFor = $why else . end' "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
}

# transcript <id> <timestamp> <last entry: assistant|user|user-blocks|harness|working|asking|calling> <text>
transcript() {
  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"start"}}\n' "$2"
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"t0","name":"Bash"}]}}\n' "$2"
    printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"t0","content":"x"}]}}\n' "$2"
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"Earlier question."}]}}\n' "$2"
    case $3 in
      assistant) printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$2" "$4" ;;
      user) printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$2" "$4" ;;
      user-blocks) printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"text","text":"%s"},{"type":"image"}]}}\n' "$2" "$4" ;;
      harness)
        printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$2" "$4"
        printf '{"type":"user","isMeta":true,"timestamp":"%s","message":{"role":"user","content":"Base directory for this skill"}}\n' "$2"
        printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<task-notification>\\n<status>failed</status>\\n</task-notification>"}}\n' "$2"
        printf '{"type":"user","isSidechain":true,"timestamp":"%s","message":{"role":"user","content":"sub-agent brief"}}\n' "$2"
        ;;
      working)
        printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"%s"},{"type":"tool_use","id":"t1","name":"Bash"}]}}\n' "$2" "$4"
        printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}\n' "$2"
        ;;
      asking)
        printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$2" "$4"
        printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"t2","name":"AskUserQuestion","input":{"questions":[{"question":"Ship it today?","options":[{"label":"Yes"},{"label":"No"}]}]}}]}}\n' "$2"
        ;;
      calling)
        printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"%s"}}]}}\n' "$2" "$4"
        ;;
    esac
    printf '{"type":"system","timestamp":"%s"}\n{"type":"assistant","timestamp":"%s",' "$2" "$2"
  } > "$CLAUDE_CONFIG_DIR/projects/p/$1.jsonl"
}

# Project alpha: the repository and its linked worktree.
spawn; p_alpha=$pid;    session "$p_alpha" aaaa-1 "$alpha" alpha-session
spawn; p_holder=$pid;   session "$p_holder" cccc-3 "$alpha" holder-session
spawn; p_wt=$pid;       session "$p_wt" wwww-1 "$work/alpha-wt" worktree-session
spawn; p_harness=$pid;  session "$p_harness" hhhh-8 "$alpha" harness-session
spawn; p_asking=$pid;   session "$p_asking" llll-2 "$alpha" asking-session
spawn; p_subagent=$pid; session "$p_subagent" mmmm-3 "$alpha" subagent-session
spawn; p_prompt=$pid;   session "$p_prompt" nnnn-4 "$alpha" prompt-session
spawn; p_running=$pid;  session "$p_running" oooo-5 "$alpha" running-session
spawn; p_busy=$pid;     session "$p_busy" qqqq-6 "$alpha" busy-session
spawn; p_writing=$pid;  session "$p_writing" rrrr-7 "$alpha" writing-session
spawn; p_gamma_a=$pid;  session "$p_gamma_a" gaaa-1 "$work/gamma-a" gamma-a-session
spawn; p_gamma_b=$pid;  session "$p_gamma_b" gbbb-2 "$work/gamma-b" gamma-b-session
# Project beta: a plain directory.
spawn; p_beta=$pid;     session "$p_beta" bbbb-2 "$beta" ""
spawn; p_replied=$pid;  session "$p_replied" dddd-4 "$beta" replied-session
spawn; p_blocks=$pid;   session "$p_blocks" gggg-7 "$beta" blocks-session
spawn; p_stale=$pid;    session "$p_stale" eeee-5 "$beta" stale-session
spawn; p_reused=$pid;   session "$p_reused" iiii-9 "$beta" reused-session "$long_ago_ms"
spawn; p_working=$pid;  session "$p_working" jjjj-0 "$beta" working-session
spawn dead; p_dead=$pid; session "$p_dead" ffff-6 "$beta" dead-session
# pid 1 belongs to root, so a non-root kill -0 gets EPERM, as a sandboxed shell does for a peer.
# shellcheck source=SCRIPTDIR/../skills/anderton/scripts/session-lib.sh
. "$scripts/session-lib.sh"
session 1 kkkk-1 "$beta" unsignalled-session "$(( $(date +%s) - $(proc_age 1) ))000"

registry "$p_asking" waiting "input needed"
registry "$p_subagent" waiting "permission prompt"
registry "$p_busy" busy
registry "$p_writing" busy

transcript aaaa-1 "$recent" assistant "Should I merge the alpha change?"
transcript cccc-3 "$recent" assistant "Holder question."
transcript wwww-1 "$recent" assistant "Question from the worktree."
transcript hhhh-8 "$recent" harness "Question before harness records."
transcript llll-2 "$recent" asking "Two options for the release."
transcript mmmm-3 "$recent" assistant "Sub-agent is checking the branch."
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p/mmmm-3/subagents"
printf '{"type":"assistant","isSidechain":true,"timestamp":"%s","message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{"command":"git push --force"}}]}}\n' \
  "$recent" > "$CLAUDE_CONFIG_DIR/projects/p/mmmm-3/subagents/agent-x1.jsonl"
transcript nnnn-4 "$five_min_ago" calling "rm -rf build"
transcript oooo-5 "$recent" calling "pnpm test"
transcript qqqq-6 "$five_min_ago" calling "sleep 600"
transcript rrrr-7 "$recent" assistant "Next I will run the tests."
transcript gaaa-1 "$recent" assistant "Question from gamma's first worktree."
transcript gbbb-2 "$recent" assistant "Question from gamma's second worktree."
transcript kkkk-1 "$recent" assistant "Question from a session this shell cannot signal."
transcript bbbb-2 "$recent" assistant "Beta needs a decision on the schema."
transcript dddd-4 "$recent" user "Yes, go ahead."
transcript gggg-7 "$recent" user-blocks "Here is the screenshot."
transcript eeee-5 2020-01-01T00:00:00Z assistant "Stale question."
transcript iiii-9 "$recent" assistant "Question from a crashed session."
transcript jjjj-0 "$recent" working "Running the build now."
transcript ffff-6 "$recent" assistant "Dead question."

state=$(holder_path "$alpha")
claim_status() { # claim_status <session id> <pid> [args...]: sets $out and $status
  local id=$1 p=$2
  shift 2
  set +e
  out=$(env CLAUDE_CODE_SESSION_ID="$id" CLAUDE_PID="$p" "$scripts/claim.sh" "$@" 2>&1)
  status=$?
  set -e
}
contains() { grep -qF -- "$1" <<EOF
$out
EOF
}

# A holder left by an earlier version in the machine-wide file still holds its project.
printf '{"pid":%s,"sessionId":"cccc-3","claimedAt":"%s"}\n' "$p_holder" "$recent" > "$CLAUDE_CONFIG_DIR/anderton.json"
claim_status aaaa-1 "$p_alpha"
check "a holder in the machine-wide file of earlier versions still holds its project" [ "$status" -eq 3 ]
check "the refusal names the holder and the project" contains "Anderton for $alpha is held by live session 'holder-session'"
claim_status bbbb-2 "$p_beta"
check "it does not hold another project" [ "$status" -eq 0 ]
check "the other project's holder is recorded in its own file" [ "$(jq -r .sessionId "$(holder_path "$beta")")" = bbbb-2 ]
check "the machine-wide file is left alone by another project's claim" [ -f "$CLAUDE_CONFIG_DIR/anderton.json" ]

# claim.sh in project alpha
check "the holder re-claims, its pid read from the registry when CLAUDE_PID is unset" \
  env CLAUDE_CODE_SESSION_ID=cccc-3 "$scripts/claim.sh"
check "the claim moves the holder into the project's own file" \
  [ "$(jq -r '"\(.root) \(.pid) \(.startedAt) \(.sessionId)"' "$state")" = "$alpha $p_holder $now_ms cccc-3" ]
check "the machine-wide file is retired" [ ! -e "$CLAUDE_CONFIG_DIR/anderton.json" ]
claim_status wwww-1 "$p_wt"
check "a session in a linked worktree of the same repository is refused" [ "$status" -eq 3 ]
mkdir "$state.lock"
echo "$p_dead" > "$state.lock/pid"
claim_status cccc-3 "$p_holder"
if command -v flock >/dev/null 2>&1; then
  # The kernel drops a dead claim's flock, so nothing it leaves behind can stop a later claim.
  check "with flock, a lock directory left by a dead claim does not stop the claim" [ "$status" -eq 0 ]
  rm -rf "$state.lock"
else
  check "a lock left by a dead claim stops the claim" [ "$status" -eq 1 ]
  check "that lock is not deleted" [ -d "$state.lock" ]
  check "the report names the lock to remove" contains "was left by claim process $p_dead"
  rm -f "$state.lock/pid"
  rmdir "$state.lock"
  check "the holder claims once the lock is removed" env CLAUDE_CODE_SESSION_ID=cccc-3 "$scripts/claim.sh"
  check "the lock is released" [ ! -e "$state.lock" ]
fi

# /clear: the holder's process keeps its pid and gets a new session id and transcript.
session "$p_holder" cccc-9 "$alpha" holder-session
transcript cccc-9 "$recent" assistant "Holder question after clear."
claim_status aaaa-1 "$p_alpha"
check "after the holder runs /clear, a second session is still refused" [ "$status" -eq 3 ]

# waiting.sh, called from project alpha, with the cleared holder process holding alpha
out=$(env CLAUDE_PID="$p_alpha" "$scripts/waiting.sh")
check "lists a waiting session in the caller's project" contains "=== alpha-session  $alpha"
check "shows the tail of the last assistant text" contains "Should I merge the alpha change?"
check "counts a linked worktree as the same project" contains "=== worktree-session"
check "leaves out another project by default" eval '! contains "Beta needs a decision"'
check "leaves out the project's Anderton, after /clear too" eval '! contains "Holder question after clear."'
check "skill loads, task notifications and sidechains are not replies" contains "Question before harness records."
check "lists a session blocked on AskUserQuestion, with its question" contains "Ship it today? [Yes / No]"
check "names what an AskUserQuestion session waits for" contains "=== asking-session  $alpha  (waiting: input needed"
check "shows a sub-agent's open call when the registry says it waits on a prompt" \
  contains "[sub-agent agent-x1] Bash (pending"
check "names what a permission-prompt session waits for" contains "=== subagent-session  $alpha  (waiting: permission prompt"
check "flags a tool call unanswered for over a minute as a likely permission prompt" \
  contains "=== prompt-session  $alpha  PERMISSION PROMPT? (pending 3"
check "shows that call's tool and input" contains 'Bash (pending 3'
check "shows the input text" contains '{"command":"rm -rf build"}'
check "does not flag a tool call made seconds ago" eval '! contains "running-session"'
check "does not flag a long call when the registry says the session is busy" eval '! contains "busy-session"'
check "does not list a busy session whose newest block is text" eval '! contains "writing-session"'

out=$(env CLAUDE_PID="$p_alpha" "$scripts/waiting.sh" --all)
check "--all lists other projects, a session named by id when unnamed" contains "=== bbbb  $beta"
check "--all still flags permission prompts" contains "PERMISSION PROMPT? (pending"
check "--all still leaves out the caller's Anderton" eval '! contains "Holder question after clear."'
check "leaves out a session whose user replied last" eval '! contains "replied-session"'
check "leaves out a session whose user replied with text and an image" eval '! contains "blocks-session"'
check "leaves out a turn older than two days" eval '! contains "Stale question."'
check "leaves out a session whose process is gone" eval '! contains "Dead question."'
check "leaves out a stale registry entry whose pid now runs another process" eval '! contains "Question from a crashed session."'
check "leaves out a session whose last assistant record is a tool call" eval '! contains "working-session"'
check "lists a live session this shell may not signal" contains "=== unsignalled-session"

out=$(env CLAUDE_PID="$p_beta" "$scripts/waiting.sh")
check "from project beta, lists beta's sessions" contains "=== unsignalled-session  $beta"
check "from project beta, leaves out beta's own Anderton" eval '! contains "Beta needs a decision"'
check "from project beta, leaves out alpha" eval '! contains "alpha-session"'

claim_status gaaa-1 "$p_gamma_a"
check "a worktree of a bare repository claims for the repository" [ "$status" -eq 0 ]
claim_status gbbb-2 "$p_gamma_b"
check "another worktree of the same bare repository is refused" [ "$status" -eq 3 ]
out=$(env CLAUDE_PID="$p_gamma_a" "$scripts/waiting.sh")
check "lists the other worktree of a bare repository as the same project" contains "Question from gamma's second worktree."

check "the cleared holder re-claims under its new session id" env CLAUDE_CODE_SESSION_ID=cccc-9 "$scripts/claim.sh"

# A holder whose pid now belongs to a later Claude Code process no longer holds the role.
jq -c '.startedAt = 1' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
claim_status aaaa-1 "$p_alpha"
check "a holder pid reused by a later session does not block a claim" [ "$status" -eq 0 ]

# A holder that crashed leaves its registry file; its pid now runs an unrelated process.
session "$p_reused" iiii-9 "$alpha" reused-session "$long_ago_ms"
jq -nc --argjson pid "$p_reused" --argjson started "$long_ago_ms" '{pid: $pid, startedAt: $started, sessionId: "iiii-9"}' > "$state"
claim_status wwww-1 "$p_wt"
check "a crashed holder whose pid was reused does not block a claim" [ "$status" -eq 0 ]

# A record from an earlier version has no start time; a later process given its pid is not the holder.
mkdir "$work/delta"
spawn; p_delta=$pid;  session "$p_delta" dlta-1 "$work/delta" delta-reused
spawn; p_delta2=$pid; session "$p_delta2" dlta-2 "$work/delta" delta-claimant
printf '{"pid":%s,"sessionId":"gone-1","claimedAt":"%s"}\n' "$p_delta" "$five_min_ago" > "$CLAUDE_CONFIG_DIR/anderton.json"
claim_status dlta-2 "$p_delta2"
check "a pid from an earlier version's record, now running a later process, does not block a claim" [ "$status" -eq 0 ]

# A project root too long to be one file name still gets a holder file.
long="$work/$(printf 'l%.0s' {1..120})/$(printf 'm%.0s' {1..120})/$(printf 'n%.0s' {1..120})"
mkdir -p "$long"
spawn; p_long=$pid; session "$p_long" long-1 "$long" long-session
claim_status long-1 "$p_long"
check "a project whose root is longer than a file name can be claimed" [ "$status" -eq 0 ]
check "its record keeps the full root" [ "$(jq -r .root "$(holder_path "$long")")" = "$long" ]

# Without git, worktrees of one repository would be separate projects: refuse instead.
nogit="$work/nogit"
mkdir "$nogit"
for t in jq ps tr dirname; do ln -s "$(command -v "$t")" "$nogit/$t"; done
set +e
out=$(env PATH="$nogit" "$BASH" "$scripts/waiting.sh" 2>&1)
status=$?
set -e
check "refuses to run without git" [ "$status" -eq 1 ]
check "says git is missing" contains "needs: git."

# spawn.sh and retire.sh: a worker in its own worktree beside the repository.
spawn; p_lead=$pid; session "$p_lead" lead-1 "$alpha" lead-session
printf '{"type":"user","permissionMode":"acceptEdits","timestamp":"%s","message":{"role":"user","content":"go"}}\n' \
  "$recent" > "$CLAUDE_CONFIG_DIR/projects/p/lead-1.jsonl"
run() { # run <script> [args...]: as the lead session; sets $out and $status
  set +e
  out=$(env CLAUDE_CODE_SESSION_ID=lead-1 CLAUDE_PID="$p_lead" "$@" 2>&1)
  status=$?
  set -e
}
run "$scripts/spawn.sh" fix-login <<'BRIEF'
Fix the login redirect. Done when the redirect test passes.
BRIEF
check "spawn.sh starts the worker" [ "$status" -eq 0 ]
check "in a new worktree beside the repository" [ "$(sed -n 1p "$FAKE_LOG.bg")" = "$work/wt-fix-login" ]
check "that worktree belongs to the repository" [ "$(project_root "$work/wt-fix-login")" = "$alpha" ]
check "named, in the caller's permission mode" grep -qx -- "acceptEdits" "$FAKE_LOG.bg"
check "with the brief" grep -qF "Fix the login redirect." "$FAKE_LOG.bg"
check "telling it to report to the caller by name" grep -qF 'Tell "lead-session" by SendMessage' "$FAKE_LOG.bg"
check "recording its id, which claude stop and rm take" [ "$(jq -r .id "$CLAUDE_CONFIG_DIR/anderton/workers/fix-login.json")" = a1b2c3d4 ]
mkdir -p "$work/elsewhere"
set +e
out=$(cd "$work/elsewhere" && echo "Task." | env CLAUDE_CODE_SESSION_ID=lead-1 CLAUDE_PID="$p_lead" ANDERTON_WORKTREES=../workers "$scripts/spawn.sh" rel-worker 2>&1)
status=$?
set -e
check "a relative ANDERTON_WORKTREES is resolved from the caller's directory" [ "$status" -eq 0 ] && [ "$(sed -n 1p "$FAKE_LOG.bg")" = "$work/workers/wt-rel-worker" ]
run "$scripts/retire.sh" rel-worker
run "$scripts/spawn.sh" fix-login <<'BRIEF'
Again.
BRIEF
check "a second worker of the same name is refused" [ "$status" -eq 1 ]
: > "$CLAUDE_CONFIG_DIR/anderton/workers/race-name.json"
run "$scripts/spawn.sh" race-name <<'BRIEF'
Task.
BRIEF
check "a name another spawn has reserved is refused" [ "$status" -eq 1 ]
check "and that reservation is left in place" [ -e "$CLAUDE_CONFIG_DIR/anderton/workers/race-name.json" ]
rm "$CLAUDE_CONFIG_DIR/anderton/workers/race-name.json"
set +e
out=$(echo "Task." | env CLAUDE_CODE_SESSION_ID=lead-1 CLAUDE_PID="$p_lead" FAKE_BG_FAIL=1 "$scripts/spawn.sh" fail-start 2>&1)
status=$?
set -e
check "a worker that fails to start releases its name" [ "$status" -eq 1 ] && [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/fail-start.json" ]
check "and its worktree" [ ! -e "$work/wt-fail-start" ]
echo '[{"kind":"background","name":"busy-name","sessionId":"x","cwd":"/","state":"working"}]' > "$FAKE_AGENTS"
run "$scripts/spawn.sh" busy-name <<'BRIEF'
Task.
BRIEF
check "a name a live session already has is refused" contains "already named 'busy-name'"
echo '[]' > "$FAKE_AGENTS"
spawn; p_anon=$pid; session "$p_anon" anon-1 "$alpha" ""
set +e
out=$(echo "Task." | env CLAUDE_CODE_SESSION_ID=anon-1 CLAUDE_PID="$p_anon" "$scripts/spawn.sh" anon-worker 2>&1)
status=$?
set -e
check "an unnamed caller is refused: the worker would have no one to report to" contains "has no name"

# waiting.sh: background sessions come from `claude agents --json`, which the registry does not list.
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"Blocked: which bucket?"}]}}\n' \
  "$recent" > "$CLAUDE_CONFIG_DIR/projects/p/bg-1.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"I will check the settings."}]}}\n{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Which bucket for prod?","options":[{"label":"east"},{"label":"west"}]}]}}]}}\n' \
  "$recent" "$recent" > "$CLAUDE_CONFIG_DIR/projects/p/bg-4.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"terraform apply"}}]}}\n' \
  "$recent" > "$CLAUDE_CONFIG_DIR/projects/p/bg-5.jsonl"
printf '{"type":"assistant","timestamp":"2020-01-01T00:00:00Z","message":{"content":[{"type":"text","text":"Old result."}]}}\n' \
  > "$CLAUDE_CONFIG_DIR/projects/p/bg-2.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"Worker question."}]}}\n' \
  "$recent" > "$CLAUDE_CONFIG_DIR/projects/p/bg-3.jsonl"
jq -nc --arg a "$alpha" --arg w "$work/wt-fix-login" --arg b "$beta" '[
  {kind: "background", name: "photo", sessionId: "bg-1", cwd: $a, state: "blocked"},
  {kind: "background", name: "stale-bg", sessionId: "bg-2", cwd: $a, state: "done"},
  {kind: "background", name: "fix-login", sessionId: "bg-3", cwd: $w, state: "blocked"},
  {kind: "background", name: "beta-bg", sessionId: "bg-1", cwd: $b, state: "blocked"},
  {kind: "background", name: "asking-bg", sessionId: "bg-4", cwd: $a, state: "blocked"},
  {kind: "background", name: "prompt-bg", sessionId: "bg-5", cwd: $a, state: "blocked"}]' > "$FAKE_AGENTS"
out=$(env CLAUDE_PID="$p_lead" "$scripts/waiting.sh")
check "lists a blocked background session in the project, with its last text" contains "=== photo  $alpha  (background, blocked"
check "shows what it said" contains "Blocked: which bucket?"
check "leaves out a background session done more than two days ago" eval '! contains "stale-bg"'
check "leaves out a worker spawn.sh started" eval '! contains "=== fix-login"'
check "leaves out another project's background session" eval '! contains "beta-bg"'
check "shows the question a blocked background session is asking" contains "Which bucket for prod? [east / west]"
check "not the text before it" eval '! contains "I will check the settings."'
check "shows the call a blocked background session waits on" contains 'Bash (pending): {"command":"terraform apply"}'
echo '[]' > "$FAKE_AGENTS"

echo '[{"kind":"background","name":"fix-login","id":"a1b2c3d4","sessionId":"bg-3","cwd":"/","state":"working"}]' > "$FAKE_AGENTS"
run env FAKE_STOP_FAIL=1 "$scripts/retire.sh" fix-login
check "retire.sh keeps the worktree of a worker it could not stop" [ "$status" -eq 1 ] && [ -d "$work/wt-fix-login" ]
check "and its record" [ -f "$CLAUDE_CONFIG_DIR/anderton/workers/fix-login.json" ]
echo '[]' > "$FAKE_AGENTS"
echo "work" > "$work/wt-fix-login/notes.txt"
run "$scripts/retire.sh" fix-login
check "retire.sh keeps a worktree with uncommitted work" [ "$status" -eq 3 ] && [ -d "$work/wt-fix-login" ]
check "and says why" contains "uncommitted changes"
check "it stops the worker by id" grep -qx "stop a1b2c3d4" "$FAKE_LOG.life"
rm "$work/wt-fix-login/notes.txt"
git -C "$work/wt-fix-login" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m wip
run "$scripts/retire.sh" fix-login
check "it keeps a worktree with commits no remote has" [ "$status" -eq 3 ]
git -C "$work/wt-fix-login" reset -q --hard HEAD~1
run env FAKE_RM_FAIL=1 "$scripts/retire.sh" fix-login
check "a failed claude rm keeps the record, to rerun" [ "$status" -eq 1 ] && [ -f "$CLAUDE_CONFIG_DIR/anderton/workers/fix-login.json" ]
run "$scripts/retire.sh" fix-login
check "it retires a clean worker" [ "$status" -eq 0 ]
check "removing its worktree" [ ! -e "$work/wt-fix-login" ]
check "and its record" [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/fix-login.json" ]
check "and the session, by id" grep -qx "rm a1b2c3d4" "$FAKE_LOG.life"
run "$scripts/retire.sh" never-started
check "it refuses a worker spawn.sh did not start" [ "$status" -eq 1 ]

# Inside herdr a worker opens in its own tab; retire.sh closes the tab.
herdr_env=(HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 "HERDR_SOCKET_PATH=$work/herdr.sock")
rm -f "$FAKE_LOG.bg"
run env "${herdr_env[@]}" "$scripts/spawn.sh" tab-worker <<'BRIEF'
Tidy the README.
BRIEF
check "inside herdr, spawn.sh starts the worker" [ "$status" -eq 0 ]
check "in a new tab of the caller's workspace" grep -qx -- "w9" "$FAKE_LOG.tab"
check "opened on its worktree" grep -qx -- "$work/wt-tab-worker" "$FAKE_LOG.tab"
check "labelled with its name" grep -qx -- "tab-worker" "$FAKE_LOG.tab"
check "running claude in that tab's pane" [ "$(tr '\n' ' ' < "$FAKE_LOG.start")" = "agent start tab-worker --kind claude --pane w9:p5 --timeout 120000 -- -n tab-worker --permission-mode acceptEdits " ]
check "given the brief" grep -qF "Tidy the README." "$FAKE_LOG.prompt"
check "and told to report to the caller by name" grep -qF 'Tell "lead-session" by SendMessage' "$FAKE_LOG.prompt"
check "not started in the background" [ ! -e "$FAKE_LOG.bg" ]
check "recording its tab and herdr server, which retire.sh closes it in" [ "$(jq -r '"\(.launcher) \(.tab) \(.socket)"' "$CLAUDE_CONFIG_DIR/anderton/workers/tab-worker.json")" = "herdr w9:t5 $work/herdr.sock" ]

run env "${herdr_env[@]}" "$scripts/spawn.sh" --bg bg-in-herdr <<'BRIEF'
Task.
BRIEF
check "--bg starts it in the background even inside herdr" [ "$status" -eq 0 ] && [ "$(sed -n 1p "$FAKE_LOG.bg")" = "$work/wt-bg-in-herdr" ]
echo '[]' > "$FAKE_AGENTS"
run "$scripts/retire.sh" bg-in-herdr

: > "$FAKE_LOG.closed"
run env "${herdr_env[@]}" FAKE_HERDR_TAB=w9:t6 FAKE_HERDR_START_FAIL=1 "$scripts/spawn.sh" stuck-tab <<'BRIEF'
Task.
BRIEF
check "a tab whose claude never becomes ready fails the spawn" [ "$status" -eq 1 ]
check "showing what it is stuck on" contains "Is this a project you trust?"
check "and offering --bg" contains "Rerun with --bg"
check "closing that tab" grep -qx "w9:t6" "$FAKE_LOG.closed"
check "releasing its name" [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/stuck-tab.json" ]
check "and removing its worktree" [ ! -e "$work/wt-stuck-tab" ]
run env "${herdr_env[@]}" FAKE_HERDR_TAB=w9:t7 FAKE_HERDR_START_FAIL=1 FAKE_HERDR_START_LIVE=1 FAKE_HERDR_CLOSE_FAIL=1 "$scripts/spawn.sh" live-stuck <<'BRIEF'
Task.
BRIEF
check "a failed tab whose session is not confirmed stopped fails the spawn" [ "$status" -eq 1 ]
check "saying so" contains "not confirmed stopped"
check "keeping its worktree" [ -d "$work/wt-live-stuck" ]
check "and a record retire.sh can finish from" [ "$(jq -r '"\(.launcher) \(.tab)"' "$CLAUDE_CONFIG_DIR/anderton/workers/live-stuck.json" 2>/dev/null)" = "herdr w9:t7" ]
run env FAKE_HERDR_CLOSE_ENDS=1 "$scripts/retire.sh" live-stuck
check "which it does once the session ends" [ "$status" -eq 0 ]
check "removing that worktree" [ ! -e "$work/wt-live-stuck" ]

: > "$FAKE_LOG.closed"
: > "$FAKE_LOG.life"
echo '[{"kind":"interactive","name":"tab-worker","id":null,"cwd":"/","status":"busy"}]' > "$FAKE_AGENTS"
run "$scripts/retire.sh" tab-worker
check "retire.sh keeps a tab worker that is still running after its tab closed" [ "$status" -eq 1 ] && [ -d "$work/wt-tab-worker" ]
check "and its record" [ -f "$CLAUDE_CONFIG_DIR/anderton/workers/tab-worker.json" ]
: > "$FAKE_LOG.closed-socket"
echo '[]' > "$FAKE_AGENTS"
echo "$work/herdr.sock w9:t5 tab-worker" >> "$FAKE_LOG.tabs-open"
run env FAKE_HERDR_CLOSE_FAIL=1 "$scripts/retire.sh" tab-worker
check "retire.sh keeps a tab worker whose tab did not close, listed or not" [ "$status" -eq 1 ]
check "its worktree" [ -d "$work/wt-tab-worker" ]
echo '[{"kind":"interactive","name":"tab-worker","id":null,"cwd":"/","status":"busy"}]' > "$FAKE_AGENTS"
run env FAKE_HERDR_CLOSE_ENDS=1 HERDR_SOCKET_PATH=/elsewhere/herdr.sock "$scripts/retire.sh" tab-worker
check "it retires a tab worker by closing its tab" [ "$status" -eq 0 ] && grep -qx "w9:t5" "$FAKE_LOG.closed"
check "in the herdr server it was opened in, not the caller's" grep -qx "$work/herdr.sock" "$FAKE_LOG.closed-socket"
check "removing its worktree" [ ! -e "$work/wt-tab-worker" ]
check "and its record" [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/tab-worker.json" ]
check "without claude stop or rm, which need an id a tab session lacks" [ ! -s "$FAKE_LOG.life" ]

# Inside tmux a worker opens in its own window; retire.sh kills the window.
echo '[]' > "$FAKE_AGENTS"
rm -f "$FAKE_LOG.bg"
run env TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_LIVE=1 "$scripts/spawn.sh" tmux-worker <<'BRIEF'
Tidy the changelog.
BRIEF
check "inside tmux, spawn.sh starts the worker" [ "$status" -eq 0 ]
check "in a new window, detached, named for it, on its worktree, running claude in the caller's mode" \
  [ "$(head -n 14 "$FAKE_LOG.window" | tr '\n' ' ')" = "new-window -d -P -F #{window_id} -n tmux-worker -c $work/wt-tmux-worker claude -n tmux-worker --permission-mode acceptEdits " ]
check "with the brief and its report-by-name rule as one argument" grep -qF 'Tell "lead-session" by SendMessage' "$FAKE_LOG.window"
check "not started in the background" [ ! -e "$FAKE_LOG.bg" ]
check "recording its window and tmux server, which retire.sh kills it in" [ "$(jq -r '"\(.launcher) \(.tab) \(.socket)"' "$CLAUDE_CONFIG_DIR/anderton/workers/tmux-worker.json")" = "tmux @7 /tmp/fake-tmux" ]
run env TMUX=/tmp/fake-tmux,1,0 "${herdr_env[@]}" FAKE_HERDR_TAB=w9:t8 "$scripts/spawn.sh" both-muxes <<'BRIEF'
Task.
BRIEF
check "inside herdr and tmux at once, herdr opens it" [ "$(jq -r .launcher "$CLAUDE_CONFIG_DIR/anderton/workers/both-muxes.json" 2>/dev/null)" = herdr ]
echo '[]' > "$FAKE_AGENTS"
run "$scripts/retire.sh" both-muxes
check "and retire.sh closes that tab" [ "$status" -eq 0 ]
run env TMUX=/tmp/fake-tmux,1,0 HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 FAKE_TMUX_WINDOW=@13 FAKE_TMUX_LIVE=1 "$scripts/spawn.sh" no-herdr-socket <<'BRIEF'
Task.
BRIEF
check "herdr without its socket is not used: the worker opens in tmux" [ "$(jq -r .launcher "$CLAUDE_CONFIG_DIR/anderton/workers/no-herdr-socket.json" 2>/dev/null)" = tmux ]
run env FAKE_TMUX_KILL_ENDS=1 "$scripts/retire.sh" no-herdr-socket

run env TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_WINDOW=@9 FAKE_TMUX_GONE=1 "$scripts/spawn.sh" dead-window <<'BRIEF'
Task.
BRIEF
check "a tmux worker whose window closes at once fails the spawn" [ "$status" -eq 1 ]
check "saying claude exited" contains "exited at once"
check "releasing its name" [ ! -e "$CLAUDE_CONFIG_DIR/anderton/workers/dead-window.json" ]
check "and removing its worktree" [ ! -e "$work/wt-dead-window" ]
run env TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_WINDOW=@8 ANDERTON_START_WAIT=1 "$scripts/spawn.sh" slow-window <<'BRIEF'
Task.
BRIEF
check "a tmux worker still unregistered with its window open is kept" [ "$status" -eq 0 ] && [ -f "$CLAUDE_CONFIG_DIR/anderton/workers/slow-window.json" ]
check "with a note that it may wait at a startup prompt" contains "may be waiting at a startup prompt"
run env FAKE_TMUX_KILL_FAIL=1 "$scripts/retire.sh" slow-window
check "retire.sh keeps an unregistered tmux worker whose window did not close" [ "$status" -eq 1 ]
check "its worktree" [ -d "$work/wt-slow-window" ]
check "and its record" [ -f "$CLAUDE_CONFIG_DIR/anderton/workers/slow-window.json" ]
run env FAKE_TMUX_KILL_FAIL=1 FAKE_TMUX_NO_SERVER=1 "$scripts/retire.sh" slow-window
check "and retires it once its tmux server is gone, socket file or not" [ "$status" -eq 0 ]
check "removing its worktree" [ ! -e "$work/wt-slow-window" ]

: > "$FAKE_LOG.life"
echo '[{"kind":"interactive","name":"tmux-worker","id":null,"cwd":"/","status":"busy"}]' > "$FAKE_AGENTS"
run env TMUX=/tmp/other-tmux,2,0 FAKE_TMUX_KILL_ENDS=1 "$scripts/retire.sh" tmux-worker
check "retire.sh retires a tmux worker by killing its window" [ "$status" -eq 0 ]
check "that window, in the server it was opened in, not the caller's" grep -qx "/tmp/fake-tmux @7" "$FAKE_LOG.killed"
check "removing its worktree" [ ! -e "$work/wt-tmux-worker" ]
check "without claude stop or rm" [ ! -s "$FAKE_LOG.life" ]

# A restarted server reuses ids: retire.sh closes only a tab or window that is still the worker's.
echo '[]' > "$FAKE_AGENTS"
: > "$FAKE_LOG.killed"
run env TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_WINDOW=@10 FAKE_TMUX_LIVE=1 "$scripts/spawn.sh" reuse-window <<'BRIEF'
Task.
BRIEF
awk '$3 != "@10"' "$FAKE_LOG.windows-open" > "$FAKE_LOG.w.tmp" && mv "$FAKE_LOG.w.tmp" "$FAKE_LOG.windows-open"
echo "/tmp/fake-tmux 99 @10 someone-else" >> "$FAKE_LOG.windows-open"
echo '[]' > "$FAKE_AGENTS"
run "$scripts/retire.sh" reuse-window
check "a tmux window id now held by another server's window is not killed" eval '! grep -q "@10" "$FAKE_LOG.killed"'
check "and the worker counts as gone, so it is retired" [ "$status" -eq 0 ]
check "leaving that other window open" grep -q "99 @10 someone-else" "$FAKE_LOG.windows-open"
: > "$FAKE_LOG.closed"
run env "${herdr_env[@]}" FAKE_HERDR_TAB=w9:t9 "$scripts/spawn.sh" reuse-tab <<'BRIEF'
Task.
BRIEF
awk '$2 != "w9:t9"' "$FAKE_LOG.tabs-open" > "$FAKE_LOG.t.tmp" && mv "$FAKE_LOG.t.tmp" "$FAKE_LOG.tabs-open"
echo "$work/herdr.sock w9:t9 someone-else" >> "$FAKE_LOG.tabs-open"
run "$scripts/retire.sh" reuse-tab
check "a herdr tab id now labelled for something else is not closed" eval '! grep -qx "w9:t9" "$FAKE_LOG.closed"'
check "and the worker is retired" [ "$status" -eq 0 ]

# An answer the check cannot read keeps the worker; a missing tmux socket means its server is gone.
run env "${herdr_env[@]}" FAKE_HERDR_TAB=w9:t10 "$scripts/spawn.sh" murky-tab <<'BRIEF'
Task.
BRIEF
run env FAKE_HERDR_GET_GARBAGE=1 "$scripts/retire.sh" murky-tab
check "retire.sh keeps a tab worker whose herdr answer it cannot read" [ "$status" -eq 1 ]
check "with its worktree" [ -d "$work/wt-murky-tab" ]
run "$scripts/retire.sh" murky-tab
check "and retires it once herdr answers" [ "$status" -eq 0 ]
run env "${herdr_env[@]}" FAKE_HERDR_TAB=w9:t11 "$scripts/spawn.sh" dead-herdr <<'BRIEF'
Task.
BRIEF
run env FAKE_HERDR_CLOSE_FAIL=1 FAKE_HERDR_NO_SERVER=1 "$scripts/retire.sh" dead-herdr
check "a tab worker whose herdr server is not running is retired" [ "$status" -eq 0 ]
run env TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_WINDOW=@11 FAKE_TMUX_LIVE=1 "$scripts/spawn.sh" nosock-window <<'BRIEF'
Task.
BRIEF
echo '[]' > "$FAKE_AGENTS"
run env FAKE_TMUX_KILL_FAIL=1 FAKE_TMUX_NO_SOCKET=1 "$scripts/retire.sh" nosock-window
check "a tmux worker whose server socket is gone is retired" [ "$status" -eq 0 ]
run env TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_WINDOW=@14 FAKE_TMUX_LIVE=1 "$scripts/spawn.sh" murky-window <<'BRIEF'
Task.
BRIEF
echo '[]' > "$FAKE_AGENTS"
run env FAKE_TMUX_GARBAGE=1 "$scripts/retire.sh" murky-window
check "retire.sh keeps a tmux worker whose server answer it cannot read" [ "$status" -eq 1 ]
check "with its worktree" [ -d "$work/wt-murky-window" ]
run "$scripts/retire.sh" murky-window
check "and retires it once tmux answers" [ "$status" -eq 0 ]

# A spawn cut short after its window opened still leaves a record retire.sh can finish from.
echo "Task." | env CLAUDE_CODE_SESSION_ID=lead-1 CLAUDE_PID="$p_lead" TMUX=/tmp/fake-tmux,1,0 FAKE_TMUX_WINDOW=@12 \
  ANDERTON_START_WAIT=30 "$scripts/spawn.sh" cut-short >/dev/null 2>&1 &
cut=$!
for _ in $(seq 1 100); do
  if jq -e '.launcher == "tmux"' "$CLAUDE_CONFIG_DIR/anderton/workers/cut-short.json" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
kill -TERM "$cut" 2>/dev/null || true
wait "$cut" 2>/dev/null || true
check "a spawn killed while waiting keeps the worker's record" [ "$(jq -r '"\(.launcher) \(.tab)"' "$CLAUDE_CONFIG_DIR/anderton/workers/cut-short.json" 2>/dev/null)" = "tmux @12" ]
check "and its worktree" [ -d "$work/wt-cut-short" ]
run env FAKE_TMUX_KILL_ENDS=1 "$scripts/retire.sh" cut-short
check "which retire.sh then stops" [ "$status" -eq 0 ]

# The sections above take over a minute; sessions from here on start now, or their start time would
# drift past registered_alive's window.
now_ms="$(date +%s)000"

# A worker in a tab or window is an interactive session, so waiting.sh's registry pass must leave it out too.
spawn; p_tw=$pid; session "$p_tw" twrk-1 "$work/wt-watch-worker" watch-worker
spawn; p_tw2=$pid; session "$p_tw2" twrk-2 "$alpha" watch-worker
transcript twrk-1 "$recent" assistant "Worker in a tab asks something."
transcript twrk-2 "$recent" assistant "Unrelated session with the same name asks."
jq -nc --arg d "$work/wt-watch-worker" '{name: "watch-worker", launcher: "herdr", dir: $d}' \
  > "$CLAUDE_CONFIG_DIR/anderton/workers/watch-worker.json"
echo '[]' > "$FAKE_AGENTS"
out=$(env CLAUDE_PID="$p_lead" "$scripts/waiting.sh" --all)
check "waiting.sh leaves out a worker in a tab or window" eval '! contains "Worker in a tab asks something."'
check "but not another session that only shares its name" contains "Unrelated session with the same name asks."
rm "$CLAUDE_CONFIG_DIR/anderton/workers/watch-worker.json"

# Project epsilon: the project role plus named scopes, each with its own holder.
mkdir "$work/epsilon"
epsilon="$work/epsilon"
spawn; p_eh=$pid; session "$p_eh" eeh-1 "$epsilon" epsilon-host
spawn; p_ea=$pid; session "$p_ea" eea-1 "$epsilon" epsilon-fleet-a
spawn; p_eb=$pid; session "$p_eb" eeb-1 "$epsilon" epsilon-fleet-b
spawn; p_eo=$pid; session "$p_eo" eeo-1 "$epsilon" epsilon-other
transcript eeh-1 "$recent" assistant "Host Anderton question."
transcript eea-1 "$recent" assistant "Fleet A Anderton question."
transcript eeb-1 "$recent" assistant "Fleet B Anderton question."
transcript eeo-1 "$recent" assistant "Ordinary epsilon question."

claim_status eeh-1 "$p_eh"
check "the project role is claimed with no scope" [ "$status" -eq 0 ]
claim_status eea-1 "$p_ea" --scope fleet-a
check "a scope is claimed while another session holds the project role" [ "$status" -eq 0 ]
check "the scope's record names its scope" [ "$(jq -r .scope "$(holder_path "$epsilon" fleet-a)")" = fleet-a ]
check "the project role's record is untouched" [ "$(jq -r .sessionId "$(holder_path "$epsilon")")" = eeh-1 ]
claim_status eeb-1 "$p_eb" --scope fleet-a
check "a second session is refused a held scope" [ "$status" -eq 3 ]
check "the refusal names the scope and its holder" \
  contains "Anderton for $epsilon, scope fleet-a is held by live session 'epsilon-fleet-a'"
claim_status eeb-1 "$p_eb" --scope fleet-b
check "another scope in the same project is claimed" [ "$status" -eq 0 ]
claim_status eea-1 "$p_ea" --scope fleet-a
check "a scope's holder re-claims its scope" [ "$status" -eq 0 ]
claim_status eeh-1 "$p_eh" --scope fleet-c
check "the project role's holder is refused a scope" [ "$status" -eq 3 ]
check "that refusal names the role it holds" contains "already holds the project role"
check "and records nothing for the scope" [ ! -e "$(holder_path "$epsilon" fleet-c)" ]
claim_status eea-1 "$p_ea" --take-over
check "a scope's holder is refused the project role, --take-over included" [ "$status" -eq 3 ]
check "that refusal names its scope" contains "already holds scope fleet-a"
claim_status eeo-1 "$p_eo" --scope
check "--scope without a name is a usage error" [ "$status" -eq 2 ]

out=$(env CLAUDE_PID="$p_eh" "$scripts/waiting.sh")
check "from the project role, lists an ordinary session" contains "Ordinary epsilon question."
check "leaves out every scope's holder" eval '! contains "Fleet A Anderton question." && ! contains "Fleet B Anderton question."'
check "leaves out the project role's holder" eval '! contains "Host Anderton question."'
out=$(env CLAUDE_PID="$p_eo" "$scripts/waiting.sh")
check "from an ordinary session, still leaves out every holder" eval '! contains "Anderton question."'

# Two claims by one session for different scopes at once: the one-role check must see the other's record.
mkdir "$work/zeta"
zeta="$work/zeta"
spawn; p_z=$pid; session "$p_z" zzzz-1 "$zeta" zeta-session
both=0
for i in 1 2 3 4 5; do
  rm -f "$(holder_path "$zeta" "x$i")" "$(holder_path "$zeta" "y$i")"
  env CLAUDE_CODE_SESSION_ID=zzzz-1 CLAUDE_PID="$p_z" "$scripts/claim.sh" --scope "x$i" > "$work/zx" 2>&1 &
  a=$!
  env CLAUDE_CODE_SESSION_ID=zzzz-1 CLAUDE_PID="$p_z" "$scripts/claim.sh" --scope "y$i" > "$work/zy" 2>&1 &
  b=$!
  wait "$a" || true
  wait "$b" || true
  if [ -e "$(holder_path "$zeta" "x$i")" ] && [ -e "$(holder_path "$zeta" "y$i")" ]; then
    both=$((both + 1))
    echo "both claimed in round $i:"
    cat "$work/zx" "$work/zy"
  fi
  rm -f "$(holder_path "$zeta" "x$i")" "$(holder_path "$zeta" "y$i")"
done
check "concurrent claims of two scopes by one session never both succeed" [ "$both" -eq 0 ]

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all checks passed"
