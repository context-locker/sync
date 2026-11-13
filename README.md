# Context Locker sync

The open source parts of [Context Locker](https://context.locker): the setup steps an AI app follows, the scripts that keep each app's files in step with your context, and the compilers that decide what those files hold. MIT licence.

Context Locker keeps your preferences, skills, projects and notes in one place, and every AI app you use reads the same ones. Apps that read files on your computer, such as Claude Code and Codex, get them from the script here, so you can see exactly what lands in them.

This repository is a published copy of the code Context Locker runs. It's updated with each release.

## Setting up an app

Paste this line into the AI app you want to connect: `Set up Context Locker: download https://context.locker/setup/SKILL.md with curl and follow the steps in it`. That address always has the newest steps, now [`setup/v63`](setup/v63), which runs `context-locker@0.1.18`, bundling script 40, then takes script 50, the newest, with `update`. The setup command 0.1.20, on npm since 10 Nov 2026, bundles script 49, and takes script 50 the same way. Connect an AI app in Context Locker gives any app the same steps with a one-time code: `Connect to Context Locker: read https://context.locker/setup/SKILL.md and follow its steps for the app you are, with this one-time code: <code>`. Since setup 37, their first step finds each app's own way in: device sync, as below, for an app that runs commands on a computer it keeps; a key it claims with the code, for an app in the cloud that adds an MCP server with a header; or the person's account connector, whose steps it gives them in the chat, for a chat app or any other app.

Setup configures only the app running it, when reliable session markers identify it. Otherwise select one explicitly, for example `npx context-locker@0.1.20 setup --app codex`. Installed folders and commands never select other apps. Connection registration, credentials, pending approval, synced files and hooks all belong to the selected app; the shared sync script stays reusable. Run setup separately in another app to connect it. Repeating setup preserves existing connections and does not duplicate hooks.

The browser approval names that app and lets you name the connection. The command takes a cloud session it recognises to run in the Cloud, and any other app to run on its computer, unless you pass `--environment computer` or `--environment cloud`. It writes the selected app's files, adds its sync hook and runs the doctor. Import is separate, with an agreed scope and approval: an app imports only its own files, and reading them doesn't connect or configure anything. When you tick Bring in as you approve the connection, or as you make its one-time code, setup's last line tells the app to import now, and a Claude Code or Codex session start says so once. The import waits in your inbox, where you pick what comes in. Existing connections and hooks are never removed automatically.

Without Node, the pinned steps have the app download the script, check its hash, sign in, show what a sync would write and add only its own hooks.

Any other app connects over MCP instead, at `https://mcp.context.locker`, even one that can run commands, such as Claude in Cowork. The steps say how to add it in Claude and ChatGPT, as [context.locker/docs](https://context.locker/docs) does.

A published version never changes. When a script changes, it's published as a new version, with the hashes of its files in its `SKILL.md`. The tests fail until the newest version matches the scripts in [`scripts`](scripts) and its steps name that script's version, as they do from setup 49.

## Tasks

A project's task board stays online. Script 24 in setup 29 added its commands, which script 49 in setup 62 names for tasks: `tasks <app> list|read|write|places [request.json] [--project <id>] [--json]`, using the same arguments and approval rules as MCP. Only `list` can omit its JSON file. Read, create, import, edit, move, claim, release, comment, delete and restore tasks through these commands; never edit a board in synced files. A request holds at most 100 imported tasks and 4 MiB, with each task kept whole. Take only ready tasks and claim one before work.

```sh
sh ~/.contextlocker/sync.sh tasks codex list --project <project-id>
sh ~/.contextlocker/sync.sh tasks codex read read.json
sh ~/.contextlocker/sync.sh tasks codex write change.json --json
```

`read.json` can hold `{"project":"Context Locker","task":"G1-151"}`. Only the person's explicit instruction permits `person_confirmed: true` to make a task ready. The credential controls access and the actor recorded in Activity. Task commands never run during a hook or daily file sync, and never queue or retry a mutation automatically. If a connection drops after sending a write, read the task before retrying. PowerShell uses the same arguments with `sync.ps1`; `-Json` also selects structured output.

## Decisions from chat

Script 28 in setup 33 adds `requests <app> list|read|answer [request.json] [--json]`, so the person can answer a request in their inbox from a chat, with the connection's existing credential:

```sh
sh ~/.contextlocker/sync.sh requests codex list --json
sh ~/.contextlocker/sync.sh requests codex read request.json --json
sh ~/.contextlocker/sync.sh requests codex answer decision.json --json
```

The JSON matches MCP's `pending_changes`, `read_request` and `decide_request`, and the server applies exactly their rules. Read everything relevant first. An answer names the request's source, id and binding, a fresh `request_id` kept for identical retries, the answer, and `consent: {"source":"human_in_chat","instruction":"the person's specific instruction"}`. An import's answer names the exact items picked and where each goes. The person must turn on Chat decisions for the connection, and an answer never makes a ticket ready or completes one. Security and access changes stay with the person, in Context Locker. Request commands never run from a hook or a daily sync, never queue offline and never retry on their own. PowerShell uses the same arguments with `sync.ps1`.

## Notes, suggestions and facts from the script

Script 32 in setup 39 adds `notes <app> search|read|write <request.json>` and `suggest <app> <request.json>`, and script 33 in setup 40 adds `remember <app> <request.json>`, so an app that syncs on a computer can do what MCP's `search_notes`, `read_note`, `write_note`, `suggest` and `remember` do, with the connection's existing credential:

```sh
sh ~/.contextlocker/sync.sh notes codex search search.json --json
sh ~/.contextlocker/sync.sh notes codex read note.json
sh ~/.contextlocker/sync.sh notes codex write change.json
sh ~/.contextlocker/sync.sh suggest codex suggestion.json
sh ~/.contextlocker/sync.sh remember codex fact.json
```

Each takes the matching tool's JSON arguments, and the server applies exactly its rules, recording the change as coming by sync. A notes search takes the current folder's project when the request names none; a suggestion names its own, so a fact never lands in a project by accident. Archived notes aren't synced, so `notes search` with `include: archive` and `notes read` are how an app reads one when asked, and `notes write` with an `action` archives, deletes or restores one. `remember` keeps one fact or preference, a single line with its name and a reason. A suggestion, a note's write and each item of an import carry a `brief` for the person's inbox: what changes, then why, in two or three sentences. These commands never run from a hook or a daily sync, and never queue offline or retry on their own. No hooks or schedules change, so script 20 and later update in place. PowerShell uses the same arguments with `sync.ps1`.

## Claude cloud sessions and taking Context Locker off a computer

Script 34, in setup 41, and the setup command 0.1.16 stop with exit 1 in Claude in Cowork, where `CLAUDE_CODE_REMOTE` is `true` and `CLAUDE_CODE_ENTRYPOINT` is `remote_cowork`, as Cowork gets Context Locker from the person's Claude account connector, which covers every chat. To connect that sandbox on purpose, add `--environment cloud`. In any other Claude cloud session they say the sandbox may not last, as a connection made there ends with it, and go on. The script's `signin` takes `--environment computer|cloud` and sends it with the sign-in.

When the connection was revoked in Context Locker, the doctor says so and offers `remove <app>`, never signing in again. Without `--yes` it only says what it would take out, so the app can ask the person first:

```sh
sh ~/.contextlocker/sync.sh remove codex
sh ~/.contextlocker/sync.sh remove codex --yes
```

With `--yes` it takes out the hook that runs the sync, the files the sync wrote that are still as it wrote them, after a backup, and the app's folder, with the shared script once no other app uses it. It keeps what changed since the sync wrote it, and the backups, says what's left to do by hand, and never revokes or deletes the connection in Context Locker. PowerShell uses `-Environment` and `-Yes`.

## When a sync stops working

Script 35, in setup 43, puts the reason first in what the app reads at the start of a session, the hook's JSON for Claude Code and what the sync prints for Codex, whenever a sync can't get Context Locker's answer. It gives the day of the last sync that did, or says nothing has synced yet, and what the app offers you, doing it only once you say yes: taking Context Locker off the computer with `remove` when the connection was revoked, connecting again from the newest setup steps for any other refused or missing token, or setting up again for a script too old to read the answer. When Context Locker can't be reached, the next sync tries again, and a newer script's line starts "as of the last sync, on <day>", so an old answer doesn't read as live.

Wherever an app reads that more than the script changed, in the session start, the doctor, `update` and every command's refusal, it's told to offer to set Context Locker up again, and once you say yes, to download the newest steps with `curl -fsSL https://context.locker/setup/SKILL.md` and follow them.

## A skill the app also loads from elsewhere

Script 36, in setup 45, lists a skill once when the app also loads one of the same name from a place Context Locker doesn't write: for Claude Code, the skills the Claude app hands it from claude.ai and those of its installed plugins; for Codex, `~/.codex/skills` and its system skills; for Hermes, the skills in its category folders; and for OpenClaw, its workspace's skills and `~/.openclaw/skills`. A project's skill also meets your own copy that applies everywhere. While the two copies are the same, by their files' hashes, Context Locker's is left out on that computer, after a backup, and written again as soon as either changes or the other goes. When they differ, Context Locker keeps its copy up to date, and the session start says once that the skill is listed twice and how to turn the other off. The doctor names every such skill. The script only reads those places, and never writes to, moves or removes anything there.

## Asks: working, recaps and questions back

When you ask an app to look at something in your inbox, scripts 37 to 39 let it say where it has got to with `fix`:

```sh
sh ~/.contextlocker/sync.sh fix codex --working <id> --reason "<what it's doing>"
sh ~/.contextlocker/sync.sh fix codex --done <id> --recap "<what's now true, then what isn't done>"
sh ~/.contextlocker/sync.sh fix codex --waiting <id> --reason "<question>" --choice "<label>" --choice "<label>"
```

`--working`, from script 37 in setup 46, says it has started, so the request reads Working in your inbox. `--recap`, from script 38 in setup 47, adds what's now true and what isn't done or checked to any mark, in at most 300 characters, and the request's row shows it. `--choice`, from script 39 in setup 48, two to four times with `--waiting`, asks you a question you answer in one press, or in your own words, and the answer comes back to the same app in its next `fix`. It answers that question only, and approves nothing. Choices without `--waiting`, or fewer than two or more than four, are a usage error. With a recap or choices, the script sends the mark as JSON, with a fresh `request_id` it makes for a question. No hooks or schedules change, so script 20 and later update in place. PowerShell uses the same arguments with `sync.ps1`, as `-Working` and `-Recap`, and takes `--choice` as written.

## The per-prompt hook, and how apps ask

Script 40 adds a hook that runs on each prompt while a session runs: `prompt <app>`, which Claude Code and Codex run on UserPromptSubmit and Hermes before each model call. At most once a minute, it asks Context Locker whether someone left the app something new it hasn't been told of, such as an answer to its ask, a request or an ask to import, and if so says it in one line, as each app reads a hook. Otherwise it says nothing, and every way out exits 0, so it never holds up or stops a prompt. OpenClaw has no hook event that hands the model a line, so it hears at its next session start. The plan shows the hook, the doctor checks it, and `remove` takes it out with the session start's.

As the hook changes what setup adds, scripts 39 and older are told to set Context Locker up again rather than update. Setup 51 runs the setup command 0.1.17, then saves script 40 and adds the hook by hand; setup 52 runs 0.1.18, which does both in one command.

Script 41 lets the person switch the per-prompt hook off for each connection, on its page in Context Locker's Connections. Off, the connection's global manifest says `prompt-line off` and Context Locker turns the hook away with `prompt_line_off`, so the script keeps `prompt-off` in the app's folder and the hook asks nothing until a sync says it's on again, and the doctor says it's off. It changes no hook, so script 40 updates in place: setup 53 runs 0.1.18, then takes script 41 with `update`.

Script 40's tickets help also says how an app asks you, in the same 120 words as every app's instructions: assume first and record what it decided on its own, unless a preference says to ask; one decision per ask and one open ask per task, asking first what unblocks most; the reading done and the evidence attached; choices that are outcomes, one recommended with why, or an approval or a step only you can take; finished work and news on the task, never in an ask; Something else answered with the work or a revised ask; and, after the same answer three times, a suggested preference.

## An app's own memory, and the computer by its name

Script 42 syncs an app's own memory files with its connection's memory in Context Locker: Claude Code's memory folders, Codex's memories, Hermes's `SOUL.md`, `USER.md`, `MEMORY.md` and `memories`, and OpenClaw's `AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `USER.md` and `MEMORY.md`, leaving out its daily logs (`MEMORY_PLACES` in [`src/memory-places.ts`](src/memory-places.ts), with a marked copy in each script that a test keeps equal). The first time a sync finds some, it says how many, once, and your inbox asks whether to bring them in; until you answer, or if you keep them where they are, syncs leave them alone. Brought in, each file is one note in the connection's memory, both ways, as the notes folder syncs: a new file or an edit goes up, a change made in Context Locker comes down after a backup, and a file the app deletes archives its note, while a file goes away only when Context Locker says its note was archived. Hermes's `SOUL.md` and OpenClaw's workspace `AGENTS.md` hold Context Locker's block too, so their notes hold the text outside it, and the sync builds each file from both. A run that prints nothing, as hooks and daily jobs do, never settles a clash, but holds it for a run that can say so. Setup 54 runs `context-locker@0.1.18`, then takes script 42 with `update`.

Script 43 changes only its words: what it says names the computer, as the approval page shows it, or says its computer, and never says this computer, as you may read it on another computer or your phone. Setup 55 runs 0.1.18, then takes script 43 with `update`. The setup command's own words change the same way in 0.1.19, which [`cli`](cli) holds.

Script 44 measures the room in Hermes's `SOUL.md` and OpenClaw's workspace `AGENTS.md`, which each app trims as a whole file past 20,000 characters, your own text included, and sends it with every request of the global sync, so their global block takes the smaller of 14,000 bytes and the room the file's own text leaves. Setup 56 runs 0.1.18, then takes script 44 with `update`; 0.1.19 bundles script 44.

## One guide for how an app works with Context Locker

How an app does each operation with Context Locker is one guide, written once in [`src/guide.ts`](src/guide.ts): an index and one topic to a file, such as asking you, tasks, notes and links, keeping what it learns, requests for it, sync on a computer and what to do when something breaks, each within 4,000 characters and filled for chat apps or for apps on device sync. An app on device sync gets it as the skill `context-locker` in its skills folder with every sync, beside the Import skill; a chat app reads it with `get_skill`; and [context.locker/docs](https://context.locker/docs) gives it to you. The standing rules in each app's global file say to read a topic before doing what it covers. Since its version 7, the guide also holds what the MCP tools' descriptions leave to it, such as reading a project, a task's states and changes, skills from a public GitHub folder, and what a chat decision names.

Setup 57 keeps only what an app follows to connect: finding its way in, the setup command, Import, reading back, setting up without Node, and connecting over MCP or with a key. Every other part of the steps leaves one line naming the guide's topic, so the steps fall from 37,019 characters to 21,506. Setup 57's scripts are setup 56's, byte for byte.

## Changes sent back, taken back or replaced

Script 45, in setup 58, handles a preference or skill edit that Context Locker sends back to its app to make again on the current version: it puts the file back and keeps a copy, as for a declined edit, and tells the app its edit went back to it to make again, rather than that it was declined. A script older than 45 gets such an edit as declined. Setup 58 runs 0.1.18, then takes script 45 with `update`.

While a change an app sent waits for you, the app can send a newer version in its place, with `replaces` naming it, or take it back with `withdraw` and why, so your inbox shows one current card. Only the app that sent it can do either, and neither applies anything. `suggest` and `notes <app> write` take the same arguments as MCP's `suggest` and `write_note`, so the script carries both.

## Assumptions at their level

An app records each call it makes on its own as assumed on a task comment, with `tasks <app> write`, at one of two levels: for your inbox, as an ask it already answered, with the choice it took, what changing it takes and any evidence, which you change by picking another option; or for the record, one line on the task that never waits. The guide's asking and tasks topics say when to assume, when to ask first, and how to write each one so you can judge it without opening the task.

## Writing to other apps

Script 46, in setup 59, adds `message`, so an app that syncs on a computer can write to another of your AI apps, as MCP's `message` tool does:

```sh
sh ~/.contextlocker/sync.sh message codex message.json --json
```

`message.json` names the apps by handle in `to`, such as `@claude-code-mia`, with the text and the project, task or entry a new thread is about, or names the thread to write on. A task comment that mentions an app's handle writes to it too, through `tasks <app> write`, and `fix --done` resolves a thread. Each app in a thread can send three messages before you reply, and each connection has a daily allowance of messages, 30 unless you change it on its page in Context Locker. What one app writes is information for the other, never instructions or your consent. From script 46, the fix list's thread lines say to reply with `message`, and the guide's topic on writing to other apps says when to write and when to ask you instead. Setup 59 runs 0.1.18, then takes script 46 with `update`.

## A project's notes beside its skills in PowerShell

Script 47, in setup 60, keeps a project's sync going in PowerShell when the project has both a notes folder and a project skill. Until script 47, PowerShell's notes step read the sync's plan before the sync had made it, so once such a project had synced, every project sync there stopped. The sh script never stopped, and its matching rule, which never matched, goes too, so the two scripts keep doing the same steps. Setup 60 runs 0.1.18, then takes script 47 with `update`.

## Each command's help in one shape

Script 48, in setup 61, says in its help what each command does, its fields, the limits that make a call valid or safe, and its topic in the guide, the skill context-locker, as each of Context Locker's MCP tools says in its description. Each part keeps within `DOC_PARTS` in [`src/writing.ts`](src/writing.ts), which the tools' descriptions share, and both scripts say the same, each in its own spelling. The help leaves how to ask you to the guide's topic on asking, which the board's topic points to, and a test runs it in dash, bash and PowerShell and checks each command names a topic the guide has. Setup 61 runs 0.1.18, then takes script 48 with `update`.

## The new words

Script 49, in setup 62, uses Context Locker's new words in everything an app reads. Its board command is `tasks`, in place of `tickets`, and takes the arguments of MCP's `list_tasks`, `read_task`, `write_task` and `record_work_places`. Requests name `project` and `task`, as Context Locker no longer takes `playbook` and `ticket`. Its help and messages say agent where they said AI app or connection, and project where they said playbook for one of yours. The compilers say the same in each app's files and the standing rules, and the guide's topics on tasks, projects and folders take the place of its topics on tickets, playbooks and projects. Setup 62 runs 0.1.18, then takes script 49 with `update`, and the setup command 0.1.20 bundles script 49 itself.

## Lessons and grooming

The guide's version 9, and the files the compilers write, as Context Locker's main had them on 11 Nov 2026, with setup 62 and script 49 as they are. An app keeps what it works out on a project, such as a trap or a tested rule, as one line in the project's lessons note, with `remember` and kind lesson, without asking you: the guide's part on lessons says how, and the standing rules keep it to one line. A project's lessons note comes first in its Start here and counts for nothing against its 10. When you give a Tidy-up item about notes to an app to groom, the guide's part on grooming says what it does: the work in fixed words, changing no meaning, keeping every dated decision and deleting nothing, with every change waiting for you.

## A command for every MCP tool

Script 50, in setup 63, gives every one of Context Locker's MCP tools a twin in the sync script, so nothing an app can do over MCP is out of reach on a computer. One table, `TOOL_COMMANDS` in `src/tool-commands.ts`, pairs each tool with its command or says why it has none, and `test/tool-commands.test.ts` checks every command it names is in both scripts' help. Each command takes its tool's fields as a JSON file, as the app's own connection, and gives its reply:

- `context <app> [request.json]`: get_context, for All projects, or with a project, in the project's folder or named in the request. It gives the same parts in the same order, naming the script's commands where get_context names tools.
- `notes <app> list|search|read|write`, `versions <app> list|read`, `projects <app> manage|docs-home`, `skills <app> source`, `requests <app> list|read|answer|decide` and `whoami <app>`, beside the `tasks`, `remember`, `suggest`, `message`, `map`, `fix` and `import-submit` commands from before.
- get_skill needs none, as the sync puts every skill, the guide too, in the skills folder, and upload needs none, as the script sends a big import plan in parts itself.

A file with too little room for its block, or none, names `context <app>` in place of get_context, and Start here and the docs home name the script's `map`, `notes <app> read` and `notes <app> write`, as every app that reads a synced file has the script. The guide's version 10 lists every command in its topic on the sync, and names them where an app on a computer uses them.

## All projects and your context

Script 51, in setup 64, retires the word playbook in everything an app reads, as Context Locker's tools and synced files do from the same release. All projects is the level above projects, whose entries apply in every project, for the person and for each team, and your context stands for preferences, skills and notes together. The script's help, the session start's line when something changed, export's reply and OpenClaw's hook file say so, as do the standing rules, the guide, version 13, and the Import skill, version 24. Requests name `all projects` where they named `my playbook`, and a notes list takes `include_all_projects`. A team's part of a project's block is headed `### All projects in <team>`, and the older heading is still read as one until the next sync writes the block again. Synced notes keep their `everywhere` folder. Setup 64 still runs the setup command 0.1.18, which saves script 40, then takes script 51 with `update`.

## Skill file transfers

Script 27 in setup 32 transfers only changed skill files. It reads an
authenticated index from `GET /v1/sync/skills/:hash`, checks the hashes of local
files before reusing them, downloads changed bytes and verifies the complete
staged tree before installing it. Deleted paths stay out of that tree. An older
API's 404 falls back to the complete-tree protocol; a failed check preserves the
installed copy.

Edits use bundle version 2 where the base index is available: `keep hash path`
retains an unchanged file from that authorised base, and `file bytes path`
carries changed bytes. Omitted paths are removed. The server still checks the
whole reconstructed skill, its limits, approval rules and concurrent changes.

Existing scripts from version 20 can update in place after the person agrees.
CLI 0.1.13 remains supported; the newest setup steps run the script update after
setup. No new hooks or schedules are added. Free allows 100 MB of current active
skills and Pro 1 GB, counted from original file sizes, excluding older versions
and encoding, compression and encryption overhead.

## How much of a file each app reads

Apps stop reading long instruction files at their own limits, and Context Locker's block usually sits at the end of a file that holds other text. So script 30 in setup 35 measures the whole file each app loads, not the block alone. It says what an app would miss when it writes a block, and the doctor says it every time it runs:

- Codex reads one instruction file a folder, `AGENTS.override.md` before `AGENTS.md`, from the top of the git work tree down, and stops at `project_doc_max_bytes` in all: 32 KiB, unless its `config.toml` sets another number above its first table. So the files in the folders above a linked folder use its room first, and an `AGENTS.override.md` in the linked folder means Codex never reads the block. A Codex session that misses part of the block is told at its start to read the block in the file. The global `~/.codex/AGENTS.md` doesn't count towards the limit.
- Hermes loads one kind of project file: the nearest `.hermes.md` or `HERMES.md` up to the top of the repo, then `AGENTS.override.md`, then `AGENTS.md`. It keeps the first 70% and last 20% of a file over its limit, which is `context_file_max_chars` in its `config.yaml`, or else grows with its model's context window from 20,000 characters. `SOUL.md` is measured the same way.
- OpenClaw reads up to 20,000 characters of each startup file, 4,000 of `USER.md`, and 60,000 across them.

The checks don't read Codex's fallback file names or root markers, or OpenClaw's own limits, so those settings can make an app read more or less than the warning says.

## Fitting shared project instructions

Script 31, setup 38 and CLI 0.1.15 fit Context Locker's project block into the room the rest of `AGENTS.md` leaves. Codex and Hermes calculate the same budget, including Codex's ancestor files and Hermes's head/tail reading windows, round it down to 1,000-byte steps and send it to the API. Alternating their syncs therefore writes the same block without treating omitted preferences as removals.

When space is tight, the block tells the app to fetch guidance and Start here summaries that did not fit. When no block fits, the session output says it is not loaded and names what to read. Existing text outside the block is preserved. Files with room keep their existing output. An override file can still hide `AGENTS.md`; the existing warning says so rather than changing the app's configuration. No new hooks or schedules are added.

## The scripts

[`scripts/sync.sh`](scripts/sync.sh) (POSIX sh, for macOS and Linux) and [`scripts/sync.ps1`](scripts/sync.ps1) (Windows PowerShell 5.1 and PowerShell 7) do the same steps. State lives in `~/.contextlocker`: the API address in `config`, the computer's random id in `machine-id`, each app's token in `<app>/token`, a sign-in that's still waiting in `<app>/device`, what each sync wrote in `<app>/global.lock` and `<app>/projects/<id>.lock`, copies of anything replaced in `backups/`, and the script an update replaced in `sync.sh.previous` or `sync.ps1.previous`.

```sh
sh ~/.contextlocker/sync.sh codex             # from the app's hooks, such as at session start
sh ~/.contextlocker/sync.sh codex --now       # brings changes in while auto sync is off
sh ~/.contextlocker/sync.sh hermes --hook     # from an app's hook: prints only what the hook reads
sh ~/.contextlocker/sync.sh codex --project <id>
sh ~/.contextlocker/sync.sh map codex         # the project's map, for the folder it runs in
sh ~/.contextlocker/sync.sh map codex --all   # the whole map
```

Each app runs the sync on its own events: Claude Code and Codex when a session starts, resumes or clears, and after compaction; Hermes when a session starts and after compaction, from hooks in its `config.yaml`; and OpenClaw when its gateway starts, when a session starts or resets, and before compaction, from a hook in `~/.openclaw/hooks`. Each connection has its own selected projects and auto-sync control on its page in Agents. Selection restricts both reading and writing. With auto sync on, a sync brings in changes and sends edits within that selection. With it off, automatic sync does neither and the session start says once that changes are waiting. An explicit `--now` sync still uses only All projects and the projects that connection may use.

The script finds a folder's project in this order: the one `--project` names, the one a `.contextlocker.json` in the repo names, a folder linked on the computer, and then the project whose git remote is the repo's origin. A clone found by its remote is linked on the computer, as `--project` links it. Hermes's hooks sync the project of the folder Hermes runs in. A run with `--daily` also syncs the projects linked on the computer, as far as the app works in projects: OpenClaw doesn't, and Hermes only in repos with a `.contextlocker.json`. A daily run honours that connection's auto-sync pause in both directions.

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

The first `signin` returns at once, because an AI app usually shows a command's output only when it ends. A one-time code works once, for 15 minutes. The connection takes the name the person gave the code, or, for a code made without one, is named after the app and its computer, such as Claude Code on MacBook Air. Polling never runs faster than the server asks, even across runs. In PowerShell the same modes are `sync.ps1 signin codex` and so on, and sync.sh's spellings of the options work too.

The doctor checks the script, the connection, the app's hooks and its daily job. It says when Hermes hasn't approved the hooks, when OpenClaw's hook is turned off, or when a daily job is missing, paused or disabled. It keeps existing jobs. It also says how full each limit is, and what has drifted since the last sync: edits not yet saved, files a sync wrote that are gone, and a last sync more than 7 days ago. It asks once about each instruction file, or folder of memories, with lines outside Context Locker's blocks: bring them in with Import, or keep them in the app only with `keep`. The answers stay on the computer, in `~/.contextlocker/sources`, by each file's path and the SHA-256 of its lines outside the blocks, and what an Import read counts once its plan is in, so it asks again only about a file that's new or changed. It leaves out a project file Context Locker links to, and one that only points at one. It ends with a line that sums it up.

Import brings in what an AI app already knows:

```sh
sh ~/.contextlocker/sync.sh import codex                     # copies the app's own files into a private working set
sh ~/.contextlocker/sync.sh import-submit codex <plan.json>  # stages the plan for you to pick from in the inbox
```

`import` only reads, and only the app's own files: its instructions, memories and skills, the skills folder Codex and OpenClaw write, and the instruction files it reads in the project it runs in (`CLAUDE.md`, `CLAUDE.local.md` and `.claude/CLAUDE.md` for Claude Code, `AGENTS.md` and `AGENTS.override.md` for Codex, `AGENTS.md` for Hermes, none for OpenClaw). Each app imports its own, so it knows what it brought in. `gather` and `gather-submit` still work, and `--apps` is taken and left unused. It copies the files into a folder only this account can read, and lists every source with its kind, path, date and hash. It follows no links, leaves out files over 4 MB and anything past 64 MB in all, as one plan holds, and never copies a file with a password, key or token that could work. A placeholder, such as `your-api-key-here`, or a value cut short or masked, such as `sk-live-abc...`, doesn't count: Context Locker checks those when the plan comes in, as it does for every change. Every file it leaves out is listed with the reason. Your agent merges the sources into one plan with the `context-locker-import` skill and stages it with `import-submit`. The plan waits in your inbox and nothing in Context Locker changes until you pick what to bring in. The working sets are deleted once the plan is submitted.

What you pick moves, so the app doesn't read it twice. Each item names the exact lines it came from in the app's own files, and what's left out, or not picked, stays where it is. The app's next sync asks `GET /v1/sync/moves` for the lines to move and takes them out where they're still exactly as imported, there once and outside Context Locker's blocks, after a copy of the file goes in `backups/`. It never edits a file in a git repository, nor one that isn't the app's own: it lists their lines for you instead, in a sync whose output the app reads, so a quiet hook or daily run leaves them waiting. It tells Context Locker what came of each with `POST /v1/sync/moves/<id>`: `moved`, `listed`, `changed` or `gone`. With auto sync off, lines wait for a sync with `--now`, and `plan` says what a sync would do. An import made before script 29 carries no lines, so it moves nothing.

Two more modes take things out:

```sh
sh ~/.contextlocker/sync.sh export codex [--to <folder>]               # All projects and every project, as plain files
sh ~/.contextlocker/sync.sh notes-move-out codex --to docs/decisions # a project's notes into its repo
```

`export` unpacks everything you keep in Context Locker, with its history as JSON Lines, into a new folder that only this account can read: `Context Locker export <date>` in the current folder, or the one `--to` names. It never writes into a folder that holds anything.

`notes-move-out` writes a project's notes into a folder in its repo, never over a file, never through a link, and never into `.git` or `.context-locker`. Only then does it ask Context Locker to turn each one into a pointer to its file, keeping its id, and to make that folder the project's docs home. Notes that changed meanwhile stay as they are. The notes that apply everywhere never move.

Tidy-up lists what in your context may need a look, such as a preference nobody has touched in 90 days or a limit that's nearly full:

```sh
sh ~/.contextlocker/sync.sh fix codex                                # the project's items and the ones everywhere
sh ~/.contextlocker/sync.sh fix codex --all                          # every item
sh ~/.contextlocker/sync.sh fix codex --request <id> --offset 0      # read the original proposal
sh ~/.contextlocker/sync.sh fix codex --working <id>                 # once it starts on one
sh ~/.contextlocker/sync.sh fix codex --waiting <id> --reason "<question or blocker>"
sh ~/.contextlocker/sync.sh fix codex --allow-auto-approve <id> --reason "<explicit human instruction>"
sh ~/.contextlocker/sync.sh fix codex --done <id>                    # once it's fixed
sh ~/.contextlocker/sync.sh fix codex --skip <id> --reason "<why>"   # left for you to decide
```

Any mark can carry `--recap`, and a question with `--waiting` can carry two to four `--choice` options, as [Asks](#asks-working-recaps-and-questions-back) says.

`fix` prints the list as Context Locker words it, each item with its id, the evidence, a fix and its risk, and how the app makes a change: in the files the sync writes, which the next sync sends back. The app reads requests immediately and resolves authorised work or proposes the concrete next step. Questions and temporary failures stay open. A revision responding to feedback waits for review by default, even with Auto-approve on. Only an explicit human instruction recorded for that response permits the normal approval checks; it never bypasses risk checks. Repeated submissions return the same linked revision. A configured scheduled agent follows the same workflow at its existing cadence and stays quiet when nothing needs attention. A plain file-sync job is not an agent. `--done` checks the item again at once, and `--skip` leaves it in Tidy-up with the app's reason.

When changes wait for your approval, the script says so once at the start of a Claude Code or Codex session, with a link to your inbox, and again only when a newer one comes in. `map` and `fix` end with a line when All projects or a project changed since the app last synced, once for each change. When you ask the app to work through Tidy-up, the session start says so, with the `fix` command, for up to 24 hours. When a newer script is out, the session start and the doctor say so, and nothing changes on its own. From script 20, when only the script changed, they name one command, which the app runs once you say yes:

```sh
sh ~/.contextlocker/sync.sh update codex     # takes the newest script, checked, keeping this one beside it
```

`update` asks Context Locker which script is the newest and whether this one can take it in place. It downloads it from setup's folder for that version at context.locker/setup, and nowhere else, without the connection's token, and uses it only if it matches the SHA-256 Context Locker gives, says it's that version and reads as a script in its shell. The old one stays beside it, the new one takes its place in one step, and nothing else changes. When a release changes more than the script, such as a hook, the session start says to offer to set Context Locker up again instead, from the newest steps, once you say yes.

The scripts only write where an app reads its files, and refuse anything else the server sends.

## The compilers

`compile()` in [`src`](src) turns one scope (All projects, everything that applies everywhere, or one project's own items) into the files for one app:

| App         | Always-loaded preferences                                         | Skills             | Project files                                       |
| ----------- | ----------------------------------------------------------------- | ------------------ | --------------------------------------------------- |
| Claude Code | `{claude}/rules/context-locker.md`, a file of our own             | `{claude}/skills/` | `{project}/.claude/rules/context-locker.md`, skills |
| Codex       | a block in `{codex}/AGENTS.md`, or `AGENTS.override.md` when used | `{agents}/skills/` | a block in `{project}/AGENTS.md`, `.agents/skills/` |
| Hermes      | a block in `{hermes}/SOUL.md`                                     | `{hermes}/skills/` | a block in `{project}/AGENTS.md`                    |
| OpenClaw    | a block in the workspace's `AGENTS.md`, leaving `USER.md` to you  | `{agents}/skills/` | none yet                                            |

Roots in braces are worked out on the computer: `{claude}` is `CLAUDE_CONFIG_DIR` or `~/.claude`, `{codex}` is `CODEX_HOME` or `~/.codex`, `{hermes}` is `HERMES_HOME` or `~/.hermes`, `{agents}` is `~/.agents`, `{openclaw}` is the configured workspace, and `{project}` is the repo.

Project files go into a repo only when it holds a `.contextlocker.json` naming the same workspace. Otherwise the session-start output carries the project's preferences, and only the notes folder, which git leaves out, is written there.

Facts in About come first, under `### About the user` in an app's own files and `### About this project` in a project's block, then the rest under `### Preferences`. A preference can run over several lines, each further line indented under its first, and an edit to it reads back the same way.

Since setup 44, each app's own file, after its intro, asks it to speak to you in plain English: to say what is so and what you need to decide, in the present tense, with the main points only, and to leave ticket, change, version, requirement and section numbers out unless you ask or need one to act, giving one link to the detail. OpenClaw's whole block is in its workspace's `AGENTS.md`, where there's room, and `USER.md` is yours.

Each app's global file gives Context Locker's standing rules after its intro, under `### Standing rules`: written once in [`src/standing-rules.ts`](src/standing-rules.ts), filled for device sync, and the same ones, filled for MCP, that open the server's instructions and `get_context`. They include what to do when a task is done, such as fixing a preference or skill that misled the app, and where a fact goes: what only that connection needs in its memory, what's about you or a project in the narrowest project that fits, or All projects, and how a repo's code works in the repo's own docs. Each app's own file also has `### This connection's memory`, the preferences only that connection keeps, from its memory in Context Locker. A project whose owner allows personal details says so in its block, with what an app may keep there; nothing scans for them.

A managed block sits between `<!-- context-locker:start v1 -->` and `<!-- context-locker:end -->`, and nothing outside the markers changes. Each block has a size limit for its app (see `DEVICE_APPS` in [`src/device-apps.ts`](src/device-apps.ts), which holds each app's targets, block size, memory places and hooks as one entry, and `BUDGETS`). Preferences that don't fit are counted in a line saying where they are, and a repo's `AGENTS.md` block leaves out wording that Hermes would refuse, saying so in the block.

A project's block also carries its map: up to 10 Start here entries, notes or pointers, and once the project has a docs home, where its lasting docs go. A pointer stands in for a note kept somewhere else, a file in the repo or a page on the web, and the block links to its address. Every entry goes through the same filter as the rest of the block, as an AI app may have written it.

The hooks setup adds for each app come from [`src/hooks.ts`](src/hooks.ts), which the setup command uses too. They're the same hooks each script's `plan` shows.

Every app's sync also writes Context Locker's own skill, `context-locker-import` (see [`src/import-skill.ts`](src/import-skill.ts)), with the steps for Import, and takes away the old `context-locker-gather` folder as it writes the new one. Import keeps a line only the connection needs straight in that connection's memory, and leaves a line in one of the app's own synced memory files to come in whole with its file. Skill names that start with `context-locker-` are kept for Context Locker's own.

A project's sync mirrors its notes into `{project}/.context-locker/notes`, one Markdown file per note with YAML front matter, whose `use_as` says how to use it (source-of-truth or reference), and never a pointer, which has no text of its own, and the notes that apply everywhere in `everywhere/`, with a README on how to edit and add notes (see [`src/notes.ts`](src/notes.ts)). Current source-of-truth notes are standing guidance, including adopted imports. Reference notes are information only, and archived ones, which aren't synced, are evidence of what held before; the current conversation takes precedence, and conflicting sources of truth about a decision call for the person. A starred onboarding note is a natural home for long-form rules. An edited or new file there goes to Context Locker at the next sync, and a deleted one comes back: a note is archived or deleted with `notes write`, or in Context Locker. An edit merges with what changed in Context Locker since. Where both changed the same part, the sync writes the newer version in the note's place, keeps the edit beside it as `<name>.md.conflict`, which it never sends, and the session start says so. The first time a sync writes there in a git work tree, it adds `.context-locker/` to `.git/info/exclude`, and it never changes `.gitignore`.

## The sync protocol

1. `GET /v1/sync[?project=<id>&layer=repo|personal]` with `If-None-Match` answers `304` or a manifest (see [`src/manifest.ts`](src/manifest.ts)). Its ETag is the SHA-256 of the text. The global manifest names the newest script, and for a script that can take it with `update`, the setup version it's published in and its SHA-256 for that script's shell. A project's lists its pointers to paths in the repo, which the script checks are there. A manifest says `auto-sync off` when auto sync is off for it.
2. `POST /v1/sync/notes` with `Context-Locker-Target` sends a note's file changed in the notes folder, or a new `.md` file there, before anything is written. Context Locker normally saves it at once, or refuses it with a message naming every gap. Source-of-truth changes run wording checks after merging, on added or changed text; promotion checks the complete note. A flagged write waits in the inbox as a complete proposal and returns `approval_required` with its change reference and request link. The local edit stays intact until a decision; an identical retry reuses the request. Agents should help resolve it without assuming approval. An edit names the version the file started from in `Context-Locker-Base` and merges with what changed since; where both changed the same part, it's refused as `version_conflict`, naming each place.
3. `POST /v1/sync/blobs` with the hashes it needs, one per line, answers one tar archive: a file per block or note, a folder per skill, each named by its hash.
4. `POST /v1/sync/edits` with `Context-Locker-Target` sends an edit found in a synced file: a block's text, or a skill folder as a bundle (see [`src/bundle.ts`](src/bundle.ts)). It merges with what changed in Context Locker since the file was written: a skill file by file, and by lines where both changed a file, and a block preference by preference. The answer is `accepted` (it applied straight away), `pending` (it waits for the owner's approval, so keep it), `rejected` (put the synced version back), `same` or `gone`.
5. `POST /v1/sync/done` reports what was applied, and in a project, the pointers whose path isn't in the folder.

Around a sync, `POST /v1/sync/remote` with a git remote answers the project that has it, and `POST /v1/sync/map?project=<id>` answers the project's map as plain text. The script sends only the remote, without a user name, password, query or fragment, and never a path on the computer.

For the other modes:

- `GET /v1/sync/caps` answers a `PASS`, `WARN` or `FAIL` line for each of the limits, which the doctor prints as they are.
- `GET /v1/sync/script` answers the global manifest's lines about the newest script, for `update`, without a sync.
- `GET /v1/sync/fixes[?project=<id>]` answers assigned requests and Tidy-up as text: the project's items and the ones that apply everywhere, or with no project every item. `?request=<id>&offset=0` reads a bounded page of one original proposal. `POST /v1/sync/fixes/<id>` with `done`, or `skipped` and the reason on the next line, marks one. `working` says the app has started on it. `waiting` keeps it open with a question or temporary blocker; `auto_approve_allowed` records the person's explicit words for that feedback response only. A mark with a recap or choices goes as JSON instead: `outcome`, `reason`, `recap`, and for a question, `choices` and a fresh `request_id`.
- `POST /v1/gather` takes the plan `import-submit` sends, checks it whole, and stages it in the inbox for the person to pick from.
- `GET /v1/sync/moves` answers the lines an import moves out of the app's own files, as `move <id> <count>`, the file's path, then its lines, and `POST /v1/sync/moves/<id>` says what came of one.
- `POST /v1/sync/tickets/<command>` and `POST /v1/sync/requests/<command>` take the JSON of the matching MCP tool, with the connection's credential as the actor.
- `POST /v1/sync/schedule` records the app's reported hooks and daily job separately from the result of a scheduled run. A completed daily run reports `ran`; a failed run reports why when Context Locker can next be reached.
- One request to Context Locker holds at most 4.5 MB, so a body over 4 MB, a skill's bundle or an import's plan, goes up in parts. `POST /v1/uploads` with its purpose (`sync-edit` or `gather`), size, SHA-256 and number of parts answers the upload's id, `PUT /v1/uploads/<id>/parts/<n>` sends each part of up to 4 MB, and the request that would have carried the body names the upload with `Context-Locker-Upload: <id>` instead. Context Locker checks the parts add up to the size and hash it was given, uses the upload once and deletes it. An upload runs out an hour after it starts.
- `GET /v1/export` answers everything the token can read as a `.tar.gz`.
- `GET /v1/sync/move-out?project=<id>` answers a tar of the project's own notes, as the repo will keep them, and an index. Once every file is written, `POST /v1/sync/move-out?project=<id>` says what was written, and in one transaction Context Locker turns each note still at the version written into a pointer to its file, keeping its id, and makes the folder the docs home. A script before version 6 is asked to update before it writes anything.

## The setup command

[`cli`](cli) is the source of `context-locker` on npm, the setup command that setup steps run with `npx`. It signs one AI app in, saves the sync script from [`scripts`](scripts), writes that app's files, adds its hooks and runs the doctor.

[`cli/package.json`](cli/package.json) names 0.1.19, on npm since 9 Nov 2026, which bundles script 44 and the compilers in [`src`](src), and adds the per-prompt hook with the session start's. Its own words name the computer, or say its computer, and never this computer. When the person ticked Bring in, its last line is the session start's: importing is the app's to do in this session, and the Import skill asks nothing in chat. Setup 56's steps still run 0.1.18, then take script 44 with `update`.

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

`npm test` checks the compilers against the expected files in `test/golden` (`UPDATE_GOLDEN=1` rewrites them), runs the scripts against a fake API to check they refuse anything they may not write, runs `import` against a fake home folder with every app's files, to check each app reads only its own, runs the doctor, an import's moves, `export`, `notes-move-out`, `fix` and `update` against a fake API, checks what a session start says when a sync can't get Context Locker's answer, that a skill the app also loads from elsewhere is listed once and what the per-prompt hook says, checks every topic of the guide against its budget, and checks the published setup files. Then it runs the setup command's tests, in [`cli/test`](cli/test). When `pwsh` and PSScriptAnalyzer are installed, it also checks `sync.ps1` against Windows PowerShell 5.1's syntax and commands.

## Licence

MIT. See [LICENSE](LICENSE).
