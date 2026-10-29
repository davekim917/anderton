<h1 align="center">Anderton</h1>

<p align="center"><b>One Claude Code session that runs all the others.</b></p>

<p align="center">
It starts real worker sessions, keeps track of every one, reviews what they build,<br>
and is the only session allowed to ship.
</p>

<p align="center">
  <a href="https://github.com/davekim917/anderton/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/davekim917/anderton/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-d97757">
  <img alt="macOS and Linux" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/flow-dark.svg">
  <img src="assets/flow.svg" width="100%" alt="You talk to one session, the Anderton. It watches your other sessions, starts a worker session for each task, and is the only session that ships to production. Every worker's brief ends with: report to Anderton by name, never deploy.">
</picture>

## The problem

Run three Claude Code sessions on one repo and you become the router. You hop between tabs to
find the one stuck on a permission prompt. You paste context from one session into another. You
approve a deploy in a tab you forgot was open, while two other sessions ask you the same thing.
Each session is good at its task. Nobody owns the whole.

Anderton makes one session the owner. You talk to it. It does the rest.

## What it does

- **Starts real sessions, not sub-agents.** Each task gets its own git worktree and a full Claude
  Code session that loads your CLAUDE.md, project memory, skills, hooks and plugins. Inside
  [herdr](https://herdr.dev) or tmux, each worker opens in its own tab you can watch and type into.
  Elsewhere it runs in the background.
- **Keeps workers talking to it, not to you.** Every brief ends the same way: message the Anderton
  by name with any question or blocker, and with the PR when done. A question left in a tab nobody
  reads is never answered, so the brief rules that out.
- **Finds everything waiting on you.** Before each status report it lists every session in the
  project that has stopped for a person: a finished reply, a permission prompt, a question with
  options, a tool call stuck for over a minute, a background session that is blocked. That list
  comes first.
- **Reviews before anything ships.** Every change gets three questions: is it the right thing to
  build, is it built right ([the engineering bar](skills/anderton/references/good-code.md)), and
  are its numbers right. Green tests and a clean bot review are inputs, not the verdict. Work that
  falls short goes back to the session that wrote it, with the file, the defect and the check that
  proves the fix.
- **Owns the line to production.** Workers stop at a PR and report. Only the Anderton deploys, and
  a restart still needs your OK.
- **Turns repeat mistakes into checks.** The second time something goes wrong, the instruction
  failed. The fix climbs a ladder: make the mistake impossible, then make the compiler reject it,
  then CI, then a test, and only last a written rule. The new check has to fail on the real past
  mistake.
- **Cleans up after itself.** Retiring a worker closes its tab, stops the session and removes the
  worktree, unless the worktree holds commits or changes no remote has.

There is one Anderton per repository. A second `/anderton` in the same repo is refused and told
which session holds the role.

## Quick start

Install the plugin:

```
/plugin marketplace add davekim917/anderton
/plugin install anderton@anderton
```

In the session you want in charge, give it a name (workers report to it by name), then start it:

```
/rename anderton
/anderton
```

Then talk to it like a lead, not a terminal:

> Fix the flaky login test and add rate limiting to signup. Separate PRs.

It writes a brief for each task and opens a worker for each, in its own tab. From there the
workers ask the Anderton, not you. It answers what it can, brings you only the calls that are
yours, reviews each PR when it lands, and ships what passes.

**Requirements:** Claude Code with background sessions (`claude --bg`, `claude agents`), built and
tested on 2.1.312; `git` and `jq`; optionally herdr or tmux for workers in visible tabs. It runs on
Linux and on macOS, including macOS's stock bash 3.2.

## Questions

**Why full sessions instead of sub-agents?**

A sub-agent runs inside the Anderton's own session and hands back a summary. You can't open it or
talk to it. A worker is an ordinary Claude Code session with its own context, in its own tab, so
you can watch it, steer it, and leave it running for hours.

**Is it safe to let it run?**

Workers run in the Anderton's permission mode, because a session in a different mode holds
incoming messages until you approve them. If your Anderton runs with permissions bypassed, so do
its workers. The rule against deploying is part of every worker's brief, not a sandbox. Retiring a
worker never deletes work that no remote has.

**Does it work with Codex or other agents?**

No. The scripts read Claude Code's own session registry and `claude agents`, so it is Claude Code
only.

**How is it different from firstmate?**

[firstmate](https://github.com/kunchenguid/firstmate) inspired it, and it's a great project: a
full agent distro that runs from its own directory, supports many harnesses and backends, and adds
second mates. Anderton is the lighter take for people who live in Claude Code. It is one skill and
four shell scripts inside the setup you already have: no separate home and no watcher process. The
session you talk to is one of your own, in your own repo, with your memory and config.

**Can I have more than one?**

One per repository owns the line to production. A named scope gives a second lead its own lock
beside it, for example one session per team whose chat threads it watches
(`claim.sh --scope <name>`). One session holds one role.

<details>
<summary><b>How it works</b></summary>

The skill is [`skills/anderton/SKILL.md`](skills/anderton/SKILL.md); the bar it reviews against is
[`references/good-code.md`](skills/anderton/references/good-code.md). Four scripts do the
mechanical parts.

**What a project is.** The session's repository, named by its main checkout (or, for a bare
repository, its git dir), so every worktree of it belongs to one project. Outside a repository, it
is the session's directory.

**`claim.sh`** records the claiming session as the project's holder in
`~/.claude/anderton/<key>.json`. The key is `git hash-object` of the project root, which the
record also holds. It exits 3 while another live session holds that project; `--take-over`
replaces it. A holder in the machine-wide `~/.claude/anderton.json` that earlier versions wrote
still holds its project until that project's next claim, which retires the file to
`anderton.json.migrated`. `--scope <name>` claims a named scope within the project instead, with
its own holder and a key hashed from the root and the name. One session holds one role per
project: a session holding the project or another scope is refused (exit 3), `--take-over`
included. The role belongs to a Claude Code process (its pid plus its registry start time), not a
session id, so it survives `/clear`.

**`waiting.sh`** lists the live sessions in the caller's project (`--all`: every project) that wait
on a person, leaving out every holder in the caller's project, the project's and each scope's:

- the turn ended with Claude's text;
- the registry's `status` says the session is blocked on a permission prompt or an
  `AskUserQuestion`, in the main thread or a sub-agent;
- without that status, a tool call has gone unanswered for over a minute (`PERMISSION PROMPT?`,
  with the tool and the first 200 characters of its input).

It reads `~/.claude/sessions/*.json`, keeps sessions whose process is alive and started when the
registry says, and finds each transcript under `~/.claude/projects/*/<session id>.jsonl`.
Background sessions have no registry entry, so it also reads `claude agents --json`. It lists one
that is `blocked`, and one that is `done` with a turn in the last two days. It leaves out the
workers `spawn.sh` started, which report to the Anderton instead.

**`spawn.sh [--bg] [--model M] [--effort E] [--mode MODE] [--base REF] <name> [brief-file]`**
starts a worker: a full Claude Code session named `<name>`, in a new git worktree at
`$ANDERTON_WORKTREES/wt-<name>` (default: the folder that holds the repository). The base is
`origin/HEAD`, else `origin/main`, `origin/master` or `HEAD`.

- Inside herdr (`HERDR_ENV=1`), the worker opens in a new tab of the caller's workspace, labelled
  `<name>` (`herdr tab create`, `herdr agent start --kind claude`, then `herdr agent prompt` with
  the brief). If Claude Code stops at a startup prompt there, the spawn shows the screen, closes the
  tab and fails, unless the session cannot be confirmed stopped, when it keeps the worktree and
  record for `retire.sh`.
- Inside tmux (`$TMUX`, and not herdr), it opens in a new detached window named `<name>`. The spawn
  waits up to `$ANDERTON_START_WAIT` seconds (default 30) for the session to register: a window
  that closes first fails the spawn, and one still open is kept with a note that it may wait at a
  startup prompt.
- Elsewhere, or with `--bg`, it is a background session (`claude --bg`).
- It runs in the caller's permission mode, read from the caller's transcript.
- The brief, from the file or stdin, gets a closing rule: report to the caller by name with
  SendMessage, and don't deploy, restart or message anyone off the machine unless the task says to.
- The worker is recorded in `~/.claude/anderton/workers/<name>.json`, with the herdr or tmux server
  it was opened in.

**`retire.sh <name>`** stops that worker and removes its worktree and record. A herdr tab or tmux
window is closed only when it still carries the worker's name in the server recorded at spawn, and
the worker counts as stopped only when that tab or window is gone and its name has left
`claude agents`; a background worker is stopped with `claude stop`. It exits 3 and keeps the
worktree when the worktree has uncommitted changes, or commits since it started that no remote
branch has.

All four honour `CLAUDE_CONFIG_DIR` and need `jq`, `git` and a POSIX `ps`.

**Tests.** `bash test/structure.test.sh` and `bash test/scripts.test.sh`. The second drives the
scripts against a throwaway Claude Code home, with fake `claude`, `herdr` and `tmux` commands and
sessions in several projects. CI runs both on Linux and on macOS's own `/bin/bash`, and runs
shellcheck.

</details>

## Built with it

Anderton runs the development of [Anderton Agent](https://github.com/davekim917/anderton-agent), a
personal fleet of AI agents in Slack and Discord, where it is the one session that deploys.

## Credits

The name is John Anderton, Tom Cruise's character in *Minority Report*: the one at the wall of
screens who sees everything coming in and steps in before it goes wrong. Parts of the skill are
adapted from [pstack](https://github.com/cursor/plugins) by Lauren Tan; see
[NOTICE.md](NOTICE.md). MIT licensed.
