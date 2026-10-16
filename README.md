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
- `scripts/waiting.sh` lists the live sessions in the caller's project (`--all`: every project) that
  wait on a person:
  - the turn ended with Claude's text;
  - the registry's `status` says the session is blocked on a permission prompt or an
    `AskUserQuestion`, in the main thread or a sub-agent;
  - without that status, a tool call has gone unanswered for over a minute (`PERMISSION PROMPT?`,
    with the tool and the first 200 characters of its input).

  It reads `~/.claude/sessions/*.json`, keeps sessions whose process is alive and started when the
  registry says, finds each transcript under `~/.claude/projects/*/<session id>.jsonl`, and leaves
  out the project's holder.

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
