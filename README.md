# Context Locker sync

The open source parts of [Context Locker](https://context.locker): the setup steps an AI app follows, the scripts that keep each app's files in step with your playbook, and the compilers that decide what those files hold. MIT licence.

Context Locker keeps your preferences, skills and projects in one place, and every AI app you use reads the same ones. Apps that read files on your computer, such as Claude Code and Codex, get them from the script here, so you can see exactly what lands in them.

This repository is a published copy of the code Context Locker runs. It's updated with each release.

## Setting up an app

Ask your AI app to follow the steps at `https://context.locker/setup/v2/SKILL.md`. The steps download the script, check its hash, sign the app in with a link and a code you approve, show what a sync would write, and add a hook so the app syncs at the start of each session. The same files are in [`setup/v2`](setup/v2).

A published version never changes. When a script changes, it's published as a new version, with the hashes of its files in its `SKILL.md`. The tests fail until the newest version matches the scripts in [`scripts`](scripts).

## The scripts

[`scripts/sync.sh`](scripts/sync.sh) (POSIX sh, for macOS and Linux) and [`scripts/sync.ps1`](scripts/sync.ps1) (Windows PowerShell 5.1 and PowerShell 7) do the same steps. State lives in `~/.contextlocker`: the API address in `config`, this computer's random id in `machine-id`, each app's token in `<app>/token`, a sign-in that's still waiting in `<app>/device`, what each sync wrote in `<app>/global.lock` and `<app>/projects/<id>.lock`, and copies of anything replaced in `backups/`.

```sh
sh ~/.contextlocker/sync.sh codex             # at session start
sh ~/.contextlocker/sync.sh hermes --daily    # from a scheduled job
sh ~/.contextlocker/sync.sh codex --project <id>
```

Setup uses four more modes:

```sh
sh ~/.contextlocker/sync.sh signin codex      # prints a link and a code to approve, exit 3
sh ~/.contextlocker/sync.sh signin codex      # again: waits up to 50 s, exit 0 once connected
sh ~/.contextlocker/sync.sh plan codex        # what a sync would write, and the hook to add
sh ~/.contextlocker/sync.sh doctor codex      # PASS, WARN or FAIL for each part
sh ~/.contextlocker/sync.sh readback codex    # what the app's files now hold
```

The first `signin` returns at once, because an AI app usually shows a command's output only when it ends. Polling never runs faster than the server asks, even across runs. In PowerShell the same modes are `sync.ps1 signin codex` and so on, and sync.sh's spellings of the options work too.

When changes wait for your approval, the script says so at the start of a Claude Code or Codex session, with a link to your inbox.

The scripts only write where an app reads its files, and refuse anything else the server sends.

## The compilers

`compile()` in [`src`](src) turns one playbook scope (everything that applies everywhere, or one project's own items) into the files for one app:

| App         | Always-loaded preferences                                         | Skills             | Project files                                       |
| ----------- | ----------------------------------------------------------------- | ------------------ | --------------------------------------------------- |
| Claude Code | `{claude}/rules/context-locker.md`, a file of our own             | `{claude}/skills/` | `{project}/.claude/rules/context-locker.md`, skills |
| Codex       | a block in `{codex}/AGENTS.md`, or `AGENTS.override.md` when used | `{agents}/skills/` | a block in `{project}/AGENTS.md`, `.agents/skills/` |
| Hermes      | a block in `{hermes}/SOUL.md`                                     | `{hermes}/skills/` | a block in `{project}/AGENTS.md`                    |
| OpenClaw    | a block in the workspace's `USER.md`, the rest in its `AGENTS.md` | `{agents}/skills/` | none yet                                            |

Roots in braces are worked out on the computer: `{claude}` is `CLAUDE_CONFIG_DIR` or `~/.claude`, `{codex}` is `CODEX_HOME` or `~/.codex`, `{hermes}` is `HERMES_HOME` or `~/.hermes`, `{agents}` is `~/.agents`, `{openclaw}` is the configured workspace, and `{project}` is the repo.

Project files go into a repo only when it holds a `.contextlocker.json` naming the same workspace. Otherwise the session-start output carries the project's preferences and nothing is written to the repo.

A managed block sits between `<!-- context-locker:start v1 -->` and `<!-- context-locker:end -->`, and nothing outside the markers changes. Each block has a size limit for its app (see `BUDGETS`). Preferences that don't fit are counted in a line saying where they are, and a repo's `AGENTS.md` block leaves out wording that Hermes would refuse, saying so in the block.

## The sync protocol

1. `GET /v1/sync[?project=<id>&layer=repo|personal]` with `If-None-Match` answers `304` or a manifest (see [`src/manifest.ts`](src/manifest.ts)). Its ETag is the SHA-256 of the text.
2. `POST /v1/sync/blobs` with the hashes it needs, one per line, answers one tar archive: a file per block, a folder per skill, each named by its hash.
3. `POST /v1/sync/edits` with `Context-Locker-Target` sends an edit found in a synced file: a block's text, or a skill folder as a bundle (see [`src/bundle.ts`](src/bundle.ts)). The answer is `accepted` (it applied straight away), `pending` (it waits for the owner's approval, so keep it), `rejected` (put the synced version back), `same` or `gone`.
4. `POST /v1/sync/done` reports what was applied.

## Tests

You need Node 22. The script tests run in whichever of dash, bash and PowerShell (`pwsh`) are installed.

```sh
npm install
npm run typecheck
npm test
```

`npm test` checks the compilers against the expected files in `test/golden` (`UPDATE_GOLDEN=1` rewrites them), runs the scripts against a fake API to check they refuse anything they may not write, and checks the published setup files.

## Licence

MIT. See [LICENSE](LICENSE).
