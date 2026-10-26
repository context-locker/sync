// The hooks that run Context Locker's sync on each app's own events: what the
// sync scripts' plan shows for an app to add, and what the setup command adds
// itself. Each must match what sync.sh and sync.ps1 print, character for
// character, which the sync script tests check, so a hook added either way is
// one the scripts' doctor finds.
//
//   app          where the hook goes                     events
//   claude-code  settings.json, under SessionStart       startup, resume, clear, compact
//   codex        hooks.json, under SessionStart          startup, resume, clear, compact
//   hermes       config.yaml, under hooks                on_session_start, post_compaction
//   openclaw     ~/.openclaw/hooks/context-locker-sync   gateway:startup, command:new,
//                                                        command:reset, session:compact:before
import { posix, win32 } from "node:path";

import type { CompiledHarness } from "./types.js";

/**
 * Which script a hook runs, and how: sync.sh in sh on macOS and Linux,
 * sync.ps1 in PowerShell on Windows, or sync.ps1 in pwsh elsewhere
 */
export type HookShell = "sh" | "pwsh" | "windows";

export interface HookTarget {
  shell: HookShell;
  /** Context Locker's folder on the computer, where setup saves the script */
  clHome: string;
  /** Whether that's the usual folder, ~/.contextlocker, which hooks name with ~ */
  usualHome: boolean;
}

/** The events each app's hook runs on */
export const HOOK_EVENTS: Readonly<Record<CompiledHarness, readonly string[]>> =
  Object.freeze({
    "claude-code": ["startup", "resume", "clear", "compact"],
    codex: ["startup", "resume", "clear", "compact"],
    hermes: ["on_session_start", "post_compaction"],
    openclaw: [
      "gateway:startup",
      "command:new",
      "command:reset",
      "session:compact:before",
    ],
  });

/** Text that runs a sync script, as the doctor looks for it in a hook */
export const SYNC_SCRIPT_PATTERN = /contextlocker[/\\]+sync\.(sh|ps1)/;

/** OpenClaw's hook folder, in its managed hooks folder */
export const OPENCLAW_HOOK_NAME = "context-locker-sync";

/** The script a hook runs: sync.sh for sh, sync.ps1 for PowerShell */
export function scriptName(shell: HookShell): "sync.sh" | "sync.ps1" {
  return shell === "sh" ? "sync.sh" : "sync.ps1";
}

/** Where setup saves the script */
export function installedScript(target: HookTarget): string {
  const join = target.shell === "windows" ? win32.join : posix.join;
  return join(target.clHome, scriptName(target.shell));
}

/** A word as sh reads it, in single quotes when it needs them */
export function shellQuote(text: string): string {
  if (text !== "" && /^[A-Za-z0-9/._~-]+$/.test(text)) return text;
  return `'${text.replaceAll("'", "'\\''")}'`;
}

/** Text in double quotes, with backslashes and quotes escaped, as JSON and YAML read it */
function doubleQuoted(text: string): string {
  return `"${text.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

/**
 * How Claude Code's and Codex's hooks run the script, followed by the app's
 * name: through a shell, which expands ~
 */
export function hookRun(target: HookTarget): string {
  const installed = installedScript(target);
  switch (target.shell) {
    case "sh":
      return target.usualHome
        ? "sh ~/.contextlocker/sync.sh"
        : `sh ${shellQuote(installed)}`;
    case "pwsh":
      return target.usualHome
        ? "pwsh -NoProfile -File ~/.contextlocker/sync.ps1"
        : `pwsh -NoProfile -File ${shellQuote(installed)}`;
    case "windows":
      return `powershell -NoProfile -ExecutionPolicy Bypass -File "${installed}"`;
  }
}

/** The program and arguments a hook with no shell runs, as Hermes's and OpenClaw's do */
export function hookArgs(target: HookTarget): string[] {
  const installed = installedScript(target);
  switch (target.shell) {
    case "sh":
      return ["sh", installed];
    case "pwsh":
      return ["pwsh", "-NoProfile", "-File", installed];
    case "windows":
      return [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        installed,
      ];
  }
}

/** The option that keeps a hook's sync quiet, for apps that don't read what it prints */
function hookOption(target: HookTarget): string {
  return target.shell === "sh" ? "--hook" : "-Hook";
}

/** One command in Claude Code's or Codex's SessionStart hooks */
export interface SessionStartHook {
  type: "command";
  command: string;
  args?: string[];
  commandWindows?: string;
  timeout: number;
}

/** The session-start hook for Claude Code or Codex */
export function sessionStartHook(
  harness: "claude-code" | "codex",
  target: HookTarget,
): SessionStartHook {
  if (target.shell === "windows" && harness === "claude-code") {
    // Claude Code runs a command and its arguments directly, with no shell
    const [program, ...args] = hookArgs(target) as [string, ...string[]];
    return {
      type: "command",
      command: program,
      args: [...args, harness],
      timeout: 60,
    };
  }
  const command = `${hookRun(target)} ${harness}`;
  return target.shell === "windows"
    ? { type: "command", command, commandWindows: command, timeout: 60 }
    : { type: "command", command, timeout: 60 };
}

/** What Hermes's hooks run, for each of its events */
export function hermesHookCommand(target: HookTarget): string {
  const run =
    target.shell === "sh"
      ? `sh ${shellQuote(installedScript(target))}`
      : target.shell === "pwsh"
        ? `pwsh -NoProfile -File ${shellQuote(installedScript(target))}`
        : `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${installedScript(target)}"`;
  return `${run} hermes ${hookOption(target)}`;
}

/**
 * Hermes's command as config.yaml holds it: in double quotes from sync.sh,
 * and from sync.ps1 in single quotes, which keep backslashes, unless it has one
 */
export function hermesHookYaml(target: HookTarget): string {
  const command = hermesHookCommand(target);
  if (target.shell === "sh" || command.includes("'")) {
    return doubleQuoted(command);
  }
  return `'${command}'`;
}

/** OpenClaw's HOOK.md, which names the hook and the events it runs on */
export function openclawHookMd(): string {
  const events = HOOK_EVENTS.openclaw.map((event) => `"${event}"`).join(", ");
  return [
    "---",
    `name: ${OPENCLAW_HOOK_NAME}`,
    `description: "Keeps OpenClaw's files in step with your Context Locker playbook"`,
    `metadata: { "openclaw": { "events": [${events}] } }`,
    "---",
    "",
    "# Context Locker sync",
    "",
    "Runs Context Locker's sync when the gateway starts, when a session starts or resets, and before compaction, so OpenClaw's files hold your playbook as it is now.",
    "",
  ].join("\n");
}

/** OpenClaw's handler.js, which runs the sync and never stops OpenClaw */
export function openclawHandler(target: HookTarget): string {
  const [program, ...args] = hookArgs(target) as [string, ...string[]];
  const call =
    target.shell === "sh"
      ? `execFile("sh", [${[installedScript(target), "openclaw", "--hook"].map(doubleQuoted).join(", ")}], { timeout: 60000 }, () => resolve());`
      : `execFile(${doubleQuoted(program)}, [${[...args, "openclaw", "-Hook"].map(doubleQuoted).join(", ")}], { timeout: 60000, windowsHide: true }, () => resolve());`;
  return [
    'import { execFile } from "node:child_process";',
    "",
    "// Runs the sync, waiting at most a minute, and never stops OpenClaw",
    "export default function handler() {",
    "  return new Promise((resolve) => {",
    `    ${call}`,
    "  });",
    "}",
    "",
  ].join("\n");
}
