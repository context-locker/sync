import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  lstatSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";

import { parse as parseYaml } from "yaml";

import {
  addHook,
  hermesEventsIn,
  tomlHookIn,
  withHermesHooks,
} from "../src/hooks.js";
import { placeFrom } from "../src/place.js";

const work = mkdtempSync(join(tmpdir(), "ctx-cli-hooks-"));
after(() => rmSync(work, { recursive: true, force: true }));

function computer() {
  const home = mkdtempSync(join(work, "home-"));
  // No PATH, so no openclaw command to turn its hook on
  return { home, place: placeFrom({ HOME: home, PATH: "" }, "linux") };
}

const read = (path: string) => readFileSync(path, "utf8");
const CLAUDE_HOOK = {
  type: "command",
  command: "sh ~/.contextlocker/sync.sh claude-code",
  timeout: 60,
};

describe("adding Claude Code's and Codex's hooks", () => {
  it("makes the settings file when there's none", async () => {
    const { home, place } = computer();
    const added = await addHook("claude-code", place, "20261025T120000Z");
    assert.equal(added.state, "added");
    assert.equal(
      added.said,
      "Added the session-start hook to ~/.claude/settings.json.",
    );
    assert.deepEqual(JSON.parse(read(join(home, ".claude", "settings.json"))), {
      hooks: { SessionStart: [{ hooks: [CLAUDE_HOOK] }] },
    });
    // Nothing of the person's to back up
    assert.equal(existsSync(join(home, ".contextlocker", "backups")), false);

    const again = await addHook("claude-code", place, "20261025T120100Z");
    assert.equal(again.state, "present");
  });

  it("keeps everything else, with a copy in the backups first", async () => {
    const { home, place } = computer();
    mkdirSync(join(home, ".claude"));
    const file = join(home, ".claude", "settings.json");
    const mine = {
      permissions: { allow: ["Bash(sh ~/.contextlocker/sync.sh claude-code)"] },
      hooks: {
        PreToolUse: [
          { matcher: "Bash", hooks: [{ type: "command", command: "x" }] },
        ],
        SessionStart: [
          { matcher: "startup", hooks: [{ type: "command", command: "y" }] },
        ],
      },
    };
    writeFileSync(file, `${JSON.stringify(mine, null, "\t")}\n`);
    const added = await addHook("claude-code", place, "20261025T120000Z");
    // A permission rule that names the script isn't the hook
    assert.equal(added.state, "added");
    const now = JSON.parse(read(file));
    assert.deepEqual(now.permissions, mine.permissions);
    assert.deepEqual(now.hooks.PreToolUse, mine.hooks.PreToolUse);
    assert.deepEqual(now.hooks.SessionStart, [
      ...mine.hooks.SessionStart,
      { hooks: [CLAUDE_HOOK] },
    ]);
    assert.match(read(file), /^\t"permissions"/m);
    assert.deepEqual(
      JSON.parse(
        read(
          join(
            home,
            ".contextlocker",
            "backups",
            "20261025T120000Z",
            "claude-code",
            "settings.json",
          ),
        ),
      ),
      mine,
    );
  });

  it("writes through a symlinked settings file", async () => {
    const { home, place } = computer();
    mkdirSync(join(home, ".claude"));
    const real = join(home, "dotfiles-settings.json");
    writeFileSync(real, "{}\n");
    const link = join(home, ".claude", "settings.json");
    symlinkSync(real, link);
    assert.equal((await addHook("claude-code", place, "t")).state, "added");
    assert.ok(lstatSync(link).isSymbolicLink());
    assert.equal(JSON.parse(read(real)).hooks.SessionStart.length, 1);
  });

  it("leaves a file it can't read safely for the app, saying why", async () => {
    const { home, place } = computer();
    mkdirSync(join(home, ".claude"));
    const file = join(home, ".claude", "settings.json");
    writeFileSync(file, "{ // a comment\n}\n");
    const left = await addHook("claude-code", place, "t");
    assert.equal(left.state, "manual");
    assert.match(left.said, /isn't valid JSON/);
    assert.equal(read(file), "{ // a comment\n}\n");

    writeFileSync(file, JSON.stringify({ hooks: { SessionStart: {} } }));
    assert.match(
      (await addHook("claude-code", place, "t")).said,
      /isn't a list/,
    );
    writeFileSync(file, "[]");
    assert.match(
      (await addHook("claude-code", place, "t")).said,
      /isn't a JSON object/,
    );
  });

  it("finds Codex's hook in config.toml or hooks.json, and adds it to hooks.json", async () => {
    const { home, place } = computer();
    mkdirSync(join(home, ".codex"));
    writeFileSync(
      join(home, ".codex", "config.toml"),
      '[[hooks.PreToolUse]]\ncommand = "sh ~/.contextlocker/sync.sh codex"\n',
    );
    const added = await addHook("codex", place, "t");
    assert.equal(added.state, "added");
    assert.match(added.said, /open \/hooks in Codex and trust it/);
    assert.deepEqual(JSON.parse(read(join(home, ".codex", "hooks.json"))), {
      hooks: {
        SessionStart: [
          {
            hooks: [
              {
                type: "command",
                command: "sh ~/.contextlocker/sync.sh codex",
                timeout: 60,
              },
            ],
          },
        ],
      },
    });

    const other = computer();
    mkdirSync(join(other.home, ".codex"));
    writeFileSync(
      join(other.home, ".codex", "config.toml"),
      'model = "x"\n\n[[hooks.SessionStart]]\ncommand = "sh ~/.contextlocker/sync.sh codex"\n',
    );
    assert.equal((await addHook("codex", other.place, "t")).state, "present");
    assert.equal(existsSync(join(other.home, ".codex", "hooks.json")), false);
  });

  it("reads Codex's config.toml as the doctor does", () => {
    const installed = "/home/a/.contextlocker/sync.sh";
    assert.equal(
      tomlHookIn(
        '[[hooks.SessionStart]]\ncommand_windows = "x"\ncommand = "sh /home/a/.contextlocker/sync.sh codex"\n',
        installed,
      ),
      true,
    );
    assert.equal(
      tomlHookIn(
        '[[hooks.SessionStart]]\ncommand = "echo"\n[[hooks.Stop]]\ncommand = "sh ~/.contextlocker/sync.sh codex"\n',
        installed,
      ),
      false,
    );
  });
});

describe("adding Hermes's hooks", () => {
  const value = '"sh /home/a/.contextlocker/sync.sh hermes --hook"';
  const installed = "/home/a/.contextlocker/sync.sh";
  const events = ["on_session_start", "post_compaction"];
  const command = "sh /home/a/.contextlocker/sync.sh hermes --hook";

  it("adds a hooks section, or adds to the one there", () => {
    const fresh = withHermesHooks("", value, events) as string;
    assert.deepEqual(parseYaml(fresh), {
      hooks: {
        on_session_start: [{ command }],
        post_compaction: [{ command }],
      },
    });

    const other = withHermesHooks(
      "model:\n  default: x\n",
      value,
      events,
    ) as string;
    assert.deepEqual(parseYaml(other), {
      model: { default: "x" },
      hooks: {
        on_session_start: [{ command }],
        post_compaction: [{ command }],
      },
    });

    // Under events already there, after their own hooks, at their indent
    const mine = [
      "hooks:",
      "    on_session_start:",
      "        - command: echo one",
      "          timeout: 5",
      "",
      "    # Hermes's own",
      "    pre_tool_call:",
      "        - command: echo two",
      "display:",
      "  theme: dark",
      "",
    ].join("\n");
    const added = withHermesHooks(mine, value, events) as string;
    assert.deepEqual(parseYaml(added), {
      hooks: {
        on_session_start: [{ command: "echo one", timeout: 5 }, { command }],
        pre_tool_call: [{ command: "echo two" }],
        post_compaction: [{ command }],
      },
      display: { theme: "dark" },
    });
    assert.ok(added.includes("    # Hermes's own\n"));
    assert.deepEqual([...hermesEventsIn(added, installed)].sort(), events);
  });

  it("keeps Windows line endings", () => {
    const crlf =
      "model: x\r\nhooks:\r\n  on_session_start:\r\n    - command: echo\r\n";
    const added = withHermesHooks(crlf, value, events) as string;
    assert.ok(!/[^\r]\n/.test(added));
    assert.deepEqual(parseYaml(added).hooks.on_session_start, [
      { command: "echo" },
      { command },
    ]);
  });

  it("won't change a layout it doesn't follow", () => {
    assert.equal(withHermesHooks("hooks: {}\n", value, events), null);
    assert.equal(
      withHermesHooks("hooks:\n\ton_session_start:\n", value, events),
      null,
    );
    assert.equal(
      withHermesHooks("hooks:\n  on_session_start: []\n", value, events),
      null,
    );
    assert.equal(withHermesHooks("hooks:\nhooks:\n", value, events), null);
  });

  it("adds only the events still missing, in config.yaml", async () => {
    const { home, place } = computer();
    const config = join(home, ".hermes", "config.yaml");
    mkdirSync(join(home, ".hermes"));
    const ours = `sh ${join(home, ".contextlocker", "sync.sh")} hermes --hook`;
    writeFileSync(
      config,
      `hooks:\n  on_session_start:\n    - command: "${ours}"\n`,
    );
    const added = await addHook("hermes", place, "20261025T120000Z");
    assert.equal(added.state, "added");
    assert.match(added.said, /approve them in a chat first/);
    assert.deepEqual(parseYaml(read(config)), {
      hooks: {
        on_session_start: [{ command: ours }],
        post_compaction: [{ command: ours }],
      },
    });
    assert.equal((await addHook("hermes", place, "t")).state, "present");
    assert.ok(
      readdirSync(
        join(home, ".contextlocker", "backups", "20261025T120000Z", "hermes"),
      ).includes("config.yaml"),
    );
  });
});

describe("adding OpenClaw's hook", () => {
  it("saves HOOK.md and handler.js, and says how to turn it on", async () => {
    const { home, place } = computer();
    const added = await addHook("openclaw", place, "t");
    assert.equal(added.state, "added");
    assert.match(added.said, /openclaw hooks enable context-locker-sync/);
    const folder = join(home, ".openclaw", "hooks", "context-locker-sync");
    assert.match(read(join(folder, "HOOK.md")), /"session:compact:before"/);
    assert.ok(
      read(join(folder, "handler.js")).includes(
        `execFile("sh", ["${join(home, ".contextlocker", "sync.sh")}", "openclaw", "--hook"]`,
      ),
    );
    assert.equal((await addHook("openclaw", place, "t")).state, "present");
  });

  it("turns the hook on with OpenClaw's own command", async () => {
    const { home } = computer();
    const bin = mkdtempSync(join(work, "bin-"));
    const log = join(work, `enabled-${Date.now()}`);
    writeFileSync(join(bin, "openclaw"), `#!/bin/sh\necho "$@" > ${log}\n`, {
      mode: 0o755,
    });
    const place = placeFrom({ HOME: home, PATH: bin }, "linux");
    const added = await addHook("openclaw", place, "t");
    assert.match(added.said, /and turned it on\. Restart the OpenClaw gateway/);
    assert.equal(read(log).trim(), "hooks enable context-locker-sync");
  });
});
