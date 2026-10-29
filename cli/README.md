# Context Locker

Context Locker keeps your preferences, skills and project notes in one playbook at [context.locker](https://context.locker), and syncs it to every AI app you use.

This command sets it up on your computer:

```sh
npx context-locker setup --app claude-code
```

Choose `claude-code`, `codex`, `hermes` or `openclaw`. Setup connects and configures only that app. Inside Claude Code, Codex or Hermes, you can omit `--app` when its session marker identifies it unambiguously. Otherwise setup asks for an explicit selection and changes nothing.

## What it does

1. Selects exactly one app before registering a connection or writing files. Installed apps do not grant permission to configure them.
2. Saves the sync script in `~/.contextlocker`. The hooks run that copy, so a session never waits for npm.
3. Shows a link and a code for that app and opens the link in your browser. You check the code and approve it. Its pending approval and credentials are separate from other apps.
4. Writes the selected app's files, the same way the sync script always does: only in Context Locker's own files and marked blocks, with a copy of anything it replaces kept first.
5. Adds the selected app's hook, keeping everything else in the file, with a copy in `~/.contextlocker/backups` first.
6. Runs the doctor for that app and shows anything to fix.
7. For Hermes and OpenClaw, says how to add a daily job to the app's own scheduler, which runs the sync once a day with no model call, if you want one: `sh ~/.contextlocker/sync.sh daily-job hermes`, for example. It adds the job once.
8. When you ticked Bring in as you approved it, or as you made its one-time code, tells your AI app to bring in what your AI apps on this computer already know, now. The import waits in your inbox, where you pick what comes in.

Then ask your AI app to bring in what your AI apps already know, with Context Locker's Import skill. Nothing comes in until you approve its plan.

## Options

- `--app <name>`: set up only this app, such as `--app claude-code`. One app per installation. Run setup separately to connect another.
- `--environment <computer|cloud>`: where the app runs. Known Claude cloud sessions and Codespaces report Cloud; otherwise the approval page asks. You can correct this later from the connection menu.
- `--code <code>`: connect one app with a one-time code made in Context Locker, with nothing to approve.
- `--no-browser`: show the approval link without opening it.
- `--wait <seconds>`: how long to wait for the approval. Run the command again to keep waiting.

It exits with 0 when everything's set up, 1 when something needs fixing, 2 when an option is wrong, and 3 while it's still waiting for your approval.

Run setup again for the same app to check or repair its setup without duplicating hooks or connections. Setting up another app later reuses the shared sync script. Existing connections and hooks are never removed automatically.

## Without Node

Setup works without Node too: your AI app follows the steps at [context.locker/setup](https://context.locker/setup) with the sync script alone.

MIT licence.
