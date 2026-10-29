# anderton

`/anderton` is one invoke-only Claude Code skill for the session the user picks to own a project's
line to production. It watches the project's other sessions and PRs, reviews against the bar in
`skills/anderton/references/good-code.md`, and turns each repeated correction into a check.

It is Claude Code only, run on the host: its two scripts read Claude Code's own session registry,
and there is no Codex manifest. The skill sets `disable-model-invocation: true`, so only the user
starts it.

## Install

It is listed in the `davekim917-bootstrap` marketplace:

```
/plugin marketplace add davekim917/bootstrap
/plugin install anderton@davekim917-bootstrap
```

The manifest carries no `version`, so each install or update takes this repository's latest commit.

## What a project is

A project is the session's repository, named by its main checkout (or, for a bare repository, its
git dir), so every worktree of it belongs to one project. Outside a repository, it is the session's
directory.

## Scripts

- `scripts/claim.sh` records the claiming session as the project's holder in
  `~/.claude/anderton/<key>.json`. The key is `git hash-object` of the project root, which the record
  also holds. It exits 3 while another live session holds that project; `--take-over` replaces it.
  A holder in the machine-wide `~/.claude/anderton.json` that earlier versions wrote still holds its
  project until that project's next claim, which retires the file to `anderton.json.migrated`.
  `--scope <name>` claims a named scope within the project instead, with its own holder and a key
  hashed from the root and the name. One session holds one role per project: a session holding the
  project or another scope is refused (exit 3), `--take-over` included.
- `scripts/waiting.sh` lists the live sessions in the caller's project (`--all`: every project) that
  wait on a person, leaving out every holder in the caller's project, the project's and each scope's:
  - the turn ended with Claude's text;
  - the registry's `status` says the session is blocked on a permission prompt or an
    `AskUserQuestion`, in the main thread or a sub-agent;
  - without that status, a tool call has gone unanswered for over a minute (`PERMISSION PROMPT?`,
    with the tool and the first 200 characters of its input).

  It reads `~/.claude/sessions/*.json`, keeps sessions whose process is alive and started when the
  registry says, finds each transcript under `~/.claude/projects/*/<session id>.jsonl`, and leaves
  out the project's holder.

  Background sessions have no registry entry, so it also reads `claude agents --json`. It lists one
  that is `blocked`, and one that is `done` with a turn in the last two days. It leaves out the
  workers `spawn.sh` started, which report to the Anderton instead.
- `scripts/spawn.sh [--bg] [--model M] [--effort E] [--mode MODE] [--base REF] <name> [brief-file]`
  starts a worker: a full Claude Code session named `<name>`, in a new git worktree at
  `$ANDERTON_WORKTREES/wt-<name>` (default: the folder that holds the repository). The base is
  `origin/HEAD`, else `origin/main`, `origin/master` or `HEAD`.
  - When the caller runs inside [herdr](https://herdr.dev) (`HERDR_ENV=1`), the worker opens in a new
    tab of the caller's workspace, labelled `<name>`, where the user can watch it and type into it
    (`herdr tab create`, `herdr agent start --kind claude`, then `herdr agent prompt` with the brief).
    If Claude Code stops at a startup prompt there, the spawn shows the screen, closes the tab and
    fails. Elsewhere, or with `--bg`, it is a background session (`claude --bg`).
  - It runs in the caller's permission mode, read from the caller's transcript, because a session
    in another mode holds the caller's messages for its user's approval.
  - The brief, from the file or stdin, gets a closing rule: report to the caller by name with
    SendMessage, and don't deploy, restart or message anyone off the machine.
  - The worker is recorded in `~/.claude/anderton/workers/<name>.json`.
- `scripts/retire.sh <name>` stops that worker (closing its herdr tab, or `claude stop` for a
  background one) and removes its worktree and record. It exits 3 and
  keeps the worktree when the worktree has uncommitted changes, or commits since it started that
  no remote branch has.

The role belongs to a Claude Code process (its pid plus its registry start time), not a session id,
so it survives `/clear`. Both scripts honour `CLAUDE_CONFIG_DIR`, need `jq`, `git` and a POSIX `ps`,
and run under macOS's bash 3.2 and BSD userland as well as Linux.

## Tests

```
bash test/structure.test.sh
bash test/scripts.test.sh
```

`scripts.test.sh` drives both scripts against a throwaway Claude Code home with sessions in several
projects. CI runs both on Linux and on macOS's own `/bin/bash`, and runs shellcheck.

## License

MIT. Parts are adapted from pstack; see [NOTICE.md](NOTICE.md).
