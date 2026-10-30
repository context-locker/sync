# Context Locker sync

The open source parts of [Context Locker](https://context.locker): the setup steps an AI app follows, the scripts that keep each app's files in step with your playbook, and the compilers that decide what those files hold. MIT licence.

Context Locker keeps your preferences, skills, projects and notes in one place, and every AI app you use reads the same ones. Apps that read files on your computer, such as Claude Code and Codex, get them from the script here, so you can see exactly what lands in them.

This repository is a published copy of the code Context Locker runs. It's updated with each release.

## Setting up an app

Paste this line into the AI app you want to connect: `Set up Context Locker: download https://context.locker/setup/SKILL.md with curl and follow the steps in it`. That address always has the newest steps, now [`setup/v26`](setup/v26), using `context-locker@0.1.10`.

Setup configures only the app running it, when reliable session markers identify it. Otherwise select one explicitly, for example `npx context-locker@0.1.10 setup --app codex`. Installed folders and commands never select other apps. Connection registration, credentials, pending approval, synced files and hooks all belong to the selected app; the shared sync script stays reusable. Run setup separately in another app to connect it. Repeating setup preserves existing connections and does not duplicate hooks.

The browser approval names that app, lets you name the connection, and asks whether it runs on a Computer or in the Cloud. A supported cloud runtime can suggest the location, or pass `--environment computer` or `--environment cloud`. Unknown environments need a human choice. The command writes the selected app's files, adds its sync hook and runs the doctor. Gather is a separate import with an agreed scope and approval; reading another app's information does not connect or configure it. When you tick Bring in as you approve the connection, or as you make its one-time code, setup's last line tells the app to import now, and a Claude Code or Codex session start says so once. The import waits in your inbox, where you pick what comes in. Existing connections and hooks are never removed automatically.

Without Node, the pinned steps have the app download the script, check its hash, sign in, show what a sync would write and add only its own hooks.

Any other app connects over MCP instead, at `https://mcp.context.locker`, even one that can run commands, such as Claude in Cowork. The steps say how to add it in Claude and ChatGPT, as [context.locker/docs](https://context.locker/docs) does.

A published version never changes. When a script changes, it's published as a new version, with the hashes of its files in its `SKILL.md`. The tests fail until the newest version matches the scripts in [`scripts`](scripts).

## The scripts

[`scripts/sync.sh`](scripts/sync.sh) (POSIX sh, for macOS and Linux) and [`scripts/sync.ps1`](scripts/sync.ps1) (Windows PowerShell 5.1 and PowerShell 7) do the same steps. State lives in `~/.contextlocker`: the API address in `config`, this computer's random id in `machine-id`, each app's token in `<app>/token`, a sign-in that's still waiting in `<app>/device`, what each sync wrote in `<app>/global.lock` and `<app>/projects/<id>.lock`, copies of anything replaced in `backups/`, and the script an update replaced in `sync.sh.previous` or `sync.ps1.previous`.

```sh
sh ~/.contextlocker/sync.sh codex             # from the app's hooks, such as at session start
sh ~/.contextlocker/sync.sh codex --now       # brings changes in while auto sync is off
sh ~/.contextlocker/sync.sh hermes --hook     # from an app's hook: prints only what the hook reads
sh ~/.contextlocker/sync.sh codex --project <id>
sh ~/.contextlocker/sync.sh map codex         # the project's map, for the folder it runs in
sh ~/.contextlocker/sync.sh map codex --all   # the whole map
```

Each app runs the sync on its own events: Claude Code and Codex when a session starts, resumes or clears, and after compaction; Hermes when a session starts and after compaction, from hooks in its `config.yaml`; and OpenClaw when its gateway starts, when a session starts or resets, and before compaction, from a hook in `~/.openclaw/hooks`. Each connection has its own selected playbooks and auto-sync control on its page in Connections. Selection restricts both reading and writing. With auto sync on, a sync brings in changes and sends edits within that selection. With it off, automatic sync does neither and the session start says once that changes are waiting. An explicit `--now` sync still uses only the playbooks that connection may access.

The script finds a folder's project in this order: the one `--project` names, the one a `.contextlocker.json` in the repo names, a folder linked on this computer, and then the project whose git remote is the repo's origin. A clone found by its remote is linked on the computer, as `--project` links it. Hermes's hooks sync the project of the folder Hermes runs in. A run with `--daily` also syncs the projects linked on the computer, as far as the app works in projects: OpenClaw doesn't, and Hermes only in repos with a `.contextlocker.json`. A daily run honours that connection's auto-sync pause in both directions.

Hermes and OpenClaw can run a daily job through their own schedulers. After the person agrees, `sh ~/.contextlocker/sync.sh daily-job <app>` adds it once, leaving any existing job alone. Claude Code and Codex report that background scheduling is unsupported. The connection page distinguishes the hooks and job the app reported from a scheduled run Context Locker actually saw finish; it also shows paused, overdue and failed runs. The doctor, plan and `daily-job` inspect the scheduler and cache its configuration, so hooks never wait on their own scheduler.

Setup uses four more modes:

```sh
sh ~/.contextlocker/sync.sh signin codex      # prints a link and a code to approve, exit 3
sh ~/.contextlocker/sync.sh signin codex      # again: waits up to 50 s, exit 0 once connected
sh ~/.contextlocker/sync.sh signin codex --code <code>  # with a one-time code from Context Locker
sh ~/.contextlocker/sync.sh plan codex        # what a sync would write, and the hooks to add
sh ~/.contextlocker/sync.sh doctor codex      # PASS, WARN or FAIL for each check, exit 1 if one fails
sh ~/.contextlocker/sync.sh readback codex    # what the app's files now hold, with each skill's version
sh ~/.contextlocker/sync.sh keep codex ~/.codex/memories  # the doctor's other answer: keep them in Codex only
```

The first `signin` returns at once, because an AI app usually shows a command's output only when it ends. A one-time code works once, for 15 minutes, and the connection takes the name the person gave it. Polling never runs faster than the server asks, even across runs. In PowerShell the same modes are `sync.ps1 signin codex` and so on, and sync.sh's spellings of the options work too.

The doctor checks the script, the connection, the app's hooks and its daily job. It says when Hermes hasn't approved the hooks, when OpenClaw's hook is turned off, or when a daily job is missing, paused or disabled. It keeps existing jobs. It also says how full each of the playbook's limits is, and what has drifted since the last sync: edits not yet saved, files a sync wrote that are gone, and a last sync more than 7 days ago. It asks once about each instruction file, or folder of memories, with lines outside Context Locker's blocks: bring them in with Import, or keep them in the app only with `keep`. The answers stay on the computer, in `~/.contextlocker/sources`, by each file's path and the SHA-256 of its lines outside the blocks, and what an Import read counts once its plan is in, so it asks again only about a file that's new or changed. It leaves out a project file the playbook links to, and one that only points at one. It ends with a line that sums it up.

Gather brings in what your AI apps already know:

```sh
sh ~/.contextlocker/sync.sh gather codex                     # copies every AI app's sources into a private working set
sh ~/.contextlocker/sync.sh gather-submit codex <plan.json>  # stages the plan for you to pick from in the inbox
```

`gather` only reads. It copies each app's instructions, skills and memories, and the project's own, into a folder only this account can read, and lists every source with its app, kind, path, date and hash. It follows no links, leaves out files over 4 MB and anything past 64 MB in all, as one plan holds, and never copies a file with a password, key or token that could work. A placeholder, such as `your-api-key-here`, or a value cut short or masked, such as `sk-live-abc...`, doesn't count: Context Locker checks those when the plan comes in, as it does for every change. Every file it leaves out is listed with the reason. Your agent merges the sources into one plan with the `context-locker-gather` skill and stages it with `gather-submit`. The plan waits in your inbox and nothing in the playbook changes until you pick what to bring in. The working sets are deleted once the plan is submitted.

Two more modes take things out:

```sh
sh ~/.contextlocker/sync.sh export codex [--to <folder>]               # the whole playbook as plain files
sh ~/.contextlocker/sync.sh notes-move-out codex --to docs/decisions # a project's notes into its repo
```

`export` unpacks everything in the playbook, with its history as JSON Lines, into a new folder that only this account can read: `Context Locker export <date>` in the current folder, or the one `--to` names. It never writes into a folder that holds anything.

`notes-move-out` writes a project's notes into a folder in its repo, never over a file, never through a link, and never into `.git` or `.context-locker`. Only then does it ask Context Locker to turn each one into a pointer to its file, keeping its id, and to make that folder the project's docs home. Notes that changed meanwhile stay as they are. The notes that apply everywhere never move.

Tidy-up lists what in your playbook may need a look, such as a preference nobody has touched in 90 days or a limit that's nearly full:

```sh
sh ~/.contextlocker/sync.sh fix codex                                # the project's items and the ones everywhere
sh ~/.contextlocker/sync.sh fix codex --all                          # every item
sh ~/.contextlocker/sync.sh fix codex --done <id>                    # once it's fixed
sh ~/.contextlocker/sync.sh fix codex --skip <id> --reason "<why>"   # left for you to decide
```

`fix` prints the list as Context Locker words it, each item with its id, the evidence, a fix and its risk, and how the app makes a change: in the files the sync writes, which the next sync sends back. The app works through it with you. `--done` checks the item again at once, and `--skip` leaves it in Tidy-up with the app's reason.

When changes wait for your approval, the script says so once at the start of a Claude Code or Codex session, with a link to your inbox, and again only when a newer one comes in. `map` and `fix` end with a line when the playbook changed since the app last synced, once for each change. When you ask the app to work through Tidy-up, the session start says so, with the `fix` command, for up to 24 hours. When a newer script is out, the session start and the doctor say so, and nothing changes on its own. From script 20, when only the script changed, they name one command, which the app runs once you say yes:

```sh
sh ~/.contextlocker/sync.sh update codex     # takes the newest script, checked, keeping this one beside it
```

`update` asks Context Locker which script is the newest and whether this one can take it in place. It downloads it from setup's folder for that version at context.locker/setup, and nowhere else, without the connection's token, and uses it only if it matches the SHA-256 Context Locker gives, says it's that version and reads as a script in its shell. The old one stays beside it, the new one takes its place in one step, and nothing else changes. When a release changes more than the script, such as a hook, the session start says to set Context Locker up again instead.

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

Project files go into a repo only when it holds a `.contextlocker.json` naming the same workspace. Otherwise the session-start output carries the project's preferences, and only the notes folder, which git leaves out, is written there.

Facts in About come first, under `### About the user` in an app's own files and `### About this project` in a project's block, then the rest under `### Preferences`. A preference can run over several lines, each further line indented under its first, and an edit to it reads back the same way.

A managed block sits between `<!-- context-locker:start v1 -->` and `<!-- context-locker:end -->`, and nothing outside the markers changes. Each block has a size limit for its app (see `BUDGETS`). Preferences that don't fit are counted in a line saying where they are, and a repo's `AGENTS.md` block leaves out wording that Hermes would refuse, saying so in the block.

A project's block also carries its map: up to 10 Start here entries, notes or pointers, and once the project has a docs home, where its lasting docs go. A pointer stands in for a note kept somewhere else, a file in the repo or a page on the web, and the block links to its address. Every entry goes through the same filter as the rest of the block, as an AI app may have written it.

The hooks setup adds for each app come from [`src/hooks.ts`](src/hooks.ts), which the setup command uses too. They're the same hooks each script's `plan` shows.

Every app's sync also writes Context Locker's own skill, `context-locker-gather` (see [`src/gather.ts`](src/gather.ts)), with the steps for Gather. Skill names that start with `context-locker-` are kept for Context Locker's own.

A project's sync mirrors its notes into `{project}/.context-locker/notes`, one Markdown file per note with YAML front matter, whose `use_as` says how to use it (source-of-truth, reference or historic), and never a pointer, which has no text of its own, and the notes that apply everywhere in `everywhere/`, with a README on how to edit and add notes (see [`src/notes.ts`](src/notes.ts)). An edited or new file there goes to Context Locker at the next sync, and a deleted one comes back, as only Context Locker retires a note. An edit merges with what changed in Context Locker since. Where both changed the same part, the sync writes the newer version in the note's place, keeps the edit beside it as `<name>.md.conflict`, which it never sends, and the session start says so. The first time a sync writes there in a git work tree, it adds `.context-locker/` to `.git/info/exclude`, and it never changes `.gitignore`.

## The sync protocol

1. `GET /v1/sync[?project=<id>&layer=repo|personal]` with `If-None-Match` answers `304` or a manifest (see [`src/manifest.ts`](src/manifest.ts)). Its ETag is the SHA-256 of the text. The global manifest names the newest script, and for a script that can take it with `update`, the setup version it's published in and its SHA-256 for that script's shell. A project's lists its pointers to paths in the repo, which the script checks are there. A manifest says `auto-sync off` when auto sync is off for it.
2. `POST /v1/sync/notes` with `Context-Locker-Target` sends a note's file changed in the notes folder, or a new `.md` file there, before anything is written. Context Locker saves it at once, or refuses it with a message naming every gap. An edit names the version the file started from in `Context-Locker-Base` and merges with what changed since; where both changed the same part, it's refused as `version_conflict`, naming each place.
3. `POST /v1/sync/blobs` with the hashes it needs, one per line, answers one tar archive: a file per block or note, a folder per skill, each named by its hash.
4. `POST /v1/sync/edits` with `Context-Locker-Target` sends an edit found in a synced file: a block's text, or a skill folder as a bundle (see [`src/bundle.ts`](src/bundle.ts)). It merges with what changed in Context Locker since the file was written: a skill file by file, and by lines where both changed a file, and a block preference by preference. The answer is `accepted` (it applied straight away), `pending` (it waits for the owner's approval, so keep it), `rejected` (put the synced version back), `same` or `gone`.
5. `POST /v1/sync/done` reports what was applied, and in a project, the pointers whose path isn't in the folder.

Around a sync, `POST /v1/sync/remote` with a git remote answers the project that has it, and `POST /v1/sync/map?project=<id>` answers the project's map as plain text. The script sends only the remote, without a user name, password, query or fragment, and never a path on the computer.

For the other modes:

- `GET /v1/sync/caps` answers a `PASS`, `WARN` or `FAIL` line for each of the playbook's limits, which the doctor prints as they are.
- `GET /v1/sync/script` answers the global manifest's lines about the newest script, for `update`, without a sync.
- `GET /v1/sync/fixes[?project=<id>]` answers Tidy-up as text: the project's items and the ones that apply everywhere, or with no project every item. `POST /v1/sync/fixes/<id>` with `done`, or `skipped` and the reason on the next line, marks one.
- `POST /v1/gather` takes the plan `gather-submit` sends, checks it whole, and stages it in the inbox for the person to pick from.
- `POST /v1/sync/schedule` records the app's reported hooks and daily job separately from the result of a scheduled run. A completed daily run reports `ran`; a failed run reports why when Context Locker can next be reached.
- One request to Context Locker holds at most 4.5 MB, so a body over 4 MB, a skill's bundle or a Gather plan, goes up in parts. `POST /v1/uploads` with its purpose (`sync-edit` or `gather`), size, SHA-256 and number of parts answers the upload's id, `PUT /v1/uploads/<id>/parts/<n>` sends each part of up to 4 MB, and the request that would have carried the body names the upload with `Context-Locker-Upload: <id>` instead. Context Locker checks the parts add up to the size and hash it was given, uses the upload once and deletes it. An upload runs out an hour after it starts.
- `GET /v1/export` answers everything the token can read as a `.tar.gz`.
- `GET /v1/sync/move-out?project=<id>` answers a tar of the project's own notes, as the repo will keep them, and an index. Once every file is written, `POST /v1/sync/move-out?project=<id>` says what was written, and in one transaction Context Locker turns each note still at the version written into a pointer to its file, keeping its id, and makes the folder the docs home. A script before version 6 is asked to update before it writes anything.

## The setup command

[`cli`](cli) is the source of `context-locker` on npm, the setup command that setup steps run with `npx`, at the version [`cli/package.json`](cli/package.json) names. It signs one AI app in, saves the sync script from [`scripts`](scripts), writes that app's files, adds its hooks and runs the doctor.

Its files are copied unchanged from the platform's repo with each release of the command. So they build here as they do there, [`compilers/scripts`](compilers/scripts) links to `scripts`, and [`cli/tsconfig.json`](cli/tsconfig.json) points `@internal/compilers` at [`src`](src) and `@internal/shared` at [`cli/shared.ts`](cli/shared.ts), a copy of the few things the command uses from the platform's shared package.

```sh
npm run build:cli   # cli/dist: cli.js, with sync.sh and sync.ps1 beside it, as the npm package has them
```

## Tests

You need Node 22. The script tests run in whichever of dash, bash and PowerShell (`pwsh`) are installed.

```sh
npm install
npm run typecheck
npm test
```

`npm test` checks the compilers against the expected files in `test/golden` (`UPDATE_GOLDEN=1` rewrites them), runs the scripts against a fake API to check they refuse anything they may not write, runs `gather` against a fake home folder with every app's files, runs the doctor, `export`, `notes-move-out`, `fix` and `update` against a fake API, and checks the published setup files. Then it runs the setup command's tests, in [`cli/test`](cli/test). When `pwsh` and PSScriptAnalyzer are installed, it also checks `sync.ps1` against Windows PowerShell 5.1's syntax and commands.

## Licence

MIT. See [LICENSE](LICENSE).
