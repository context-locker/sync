// The hooks that run the sync. What sync.sh and sync.ps1 print in sh and pwsh
// is checked against these in the API's sync script tests; Windows, which the
// tests can't run, is checked here against what sync.ps1 prints there.
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  HOOK_EVENTS,
  hermesHookCommand,
  hermesHookYaml,
  hookRun,
  installedScript,
  openclawHandler,
  openclawHookMd,
  sessionStartHook,
  shellQuote,
  type HookTarget,
} from "../src/index.js";

const windows: HookTarget = {
  shell: "windows",
  clHome: "C:\\Users\\Ada\\.contextlocker",
  usualHome: true,
};
const sh: HookTarget = {
  shell: "sh",
  clHome: "/Users/ada/.contextlocker",
  usualHome: true,
};

describe("hooks", () => {
  it("runs sync.ps1 in Windows PowerShell on Windows", () => {
    const script = "C:\\Users\\Ada\\.contextlocker\\sync.ps1";
    assert.equal(installedScript(windows), script);
    assert.equal(
      hookRun(windows),
      `powershell -NoProfile -ExecutionPolicy Bypass -File "${script}"`,
    );
    // Claude Code runs the program and its arguments with no shell
    assert.deepEqual(sessionStartHook("claude-code", windows), {
      type: "command",
      command: "powershell.exe",
      args: [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script,
        "claude-code",
      ],
      timeout: 60,
    });
    const codex = `powershell -NoProfile -ExecutionPolicy Bypass -File "${script}" codex`;
    assert.deepEqual(sessionStartHook("codex", windows), {
      type: "command",
      command: codex,
      commandWindows: codex,
      timeout: 60,
    });
    assert.equal(
      hermesHookCommand(windows),
      `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${script}" hermes -Hook`,
    );
    // Single quotes keep the backslashes as they are
    assert.equal(
      hermesHookYaml(windows),
      `'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${script}" hermes -Hook'`,
    );
    assert.ok(
      openclawHandler(windows).includes(
        `    execFile("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\\\Users\\\\Ada\\\\.contextlocker\\\\sync.ps1", "openclaw", "-Hook"], { timeout: 60000, windowsHide: true }, () => resolve());\n`,
      ),
      openclawHandler(windows),
    );
  });

  it("puts a value with a single quote in double quotes, in YAML", () => {
    const quoted: HookTarget = {
      shell: "windows",
      clHome: "C:\\Users\\O'Brien\\.contextlocker",
      usualHome: true,
    };
    assert.equal(
      hermesHookYaml(quoted),
      `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \\"C:\\\\Users\\\\O'Brien\\\\.contextlocker\\\\sync.ps1\\" hermes -Hook"`,
    );
  });

  it("names the usual folder with ~, and quotes any other for sh", () => {
    assert.deepEqual(sessionStartHook("claude-code", sh), {
      type: "command",
      command: "sh ~/.contextlocker/sync.sh claude-code",
      timeout: 60,
    });
    const elsewhere: HookTarget = {
      shell: "sh",
      clHome: "/Users/ada/My Locker's",
      usualHome: false,
    };
    assert.equal(
      sessionStartHook("codex", elsewhere).command,
      "sh '/Users/ada/My Locker'\\''s/sync.sh' codex",
    );
    // Hermes and OpenClaw run it with no shell to expand ~
    assert.equal(
      hermesHookCommand(sh),
      "sh /Users/ada/.contextlocker/sync.sh hermes --hook",
    );
    assert.equal(
      hermesHookYaml(elsewhere),
      `"sh '/Users/ada/My Locker'\\\\''s/sync.sh' hermes --hook"`,
    );
    assert.ok(
      openclawHandler(sh).includes(
        'execFile("sh", ["/Users/ada/.contextlocker/sync.sh", "openclaw", "--hook"], { timeout: 60000 }, () => resolve());',
      ),
    );
  });

  it("quotes words for sh only when they need it", () => {
    assert.equal(shellQuote("/a/b-c_d.e~"), "/a/b-c_d.e~");
    assert.equal(shellQuote(""), "''");
    assert.equal(shellQuote("a b"), "'a b'");
    assert.equal(shellQuote("it's"), "'it'\\''s'");
  });

  it("names OpenClaw's events in its HOOK.md", () => {
    const md = openclawHookMd();
    assert.match(md, /^---\nname: context-locker-sync\n/);
    for (const event of HOOK_EVENTS.openclaw) {
      assert.ok(md.includes(`"${event}"`), event);
    }
    assert.ok(md.endsWith("as it is now.\n"));
  });
});
