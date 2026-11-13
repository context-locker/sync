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
//
// A second hook tells a session that's running of a new ask (G1-271): the
// script's prompt mode, on Claude Code's and Codex's UserPromptSubmit and
// Hermes's pre_llm_call, which runs before each turn. OpenClaw has no hook
// that hands the model a line, only a plugin's, so it has none.
import { posix, win32 } from "node:path";

import type { CompiledHarness } from "./types.js";
import { DEVICE_APPS, byApp } from "./device-apps.js";

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

/** The events each app's hook runs on, from its entry in DEVICE_APPS */
export const HOOK_EVENTS: Readonly<Record<CompiledHarness, readonly string[]>> =
  byApp((app) => app.hooks);

/**
 * The event each app's per-prompt hook runs on (G1-271), where it has one,
 * from its entry in DEVICE_APPS, and how long the app waits for it, in
 * seconds
 */
export const PROMPT_HOOK_EVENTS: Readonly<
  Partial<Record<CompiledHarness, string>>
> = Object.freeze(
  Object.fromEntries(
    Object.entries(DEVICE_APPS).flatMap(([id, app]) =>
      app.promptHook ? [[id, app.promptHook]] : [],
    ),
  ),
);
export const PROMPT_HOOK_TIMEOUT = 10;

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

/** One command in Claude Code's or Codex's SessionStart or UserPromptSubmit hooks */
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

/**
 * The per-prompt hook for Claude Code or Codex (G1-271): the script's prompt
 * mode, which prints a line only when someone left the app something new
 */
export function promptHook(
  harness: "claude-code" | "codex",
  target: HookTarget,
): SessionStartHook {
  if (target.shell === "windows" && harness === "claude-code") {
    const [program, ...args] = hookArgs(target) as [string, ...string[]];
    return {
      type: "command",
      command: program,
      args: [...args, "prompt", harness],
      timeout: PROMPT_HOOK_TIMEOUT,
    };
  }
  const command = `${hookRun(target)} prompt ${harness}`;
  return target.shell === "windows"
    ? {
        type: "command",
        command,
        commandWindows: command,
        timeout: PROMPT_HOOK_TIMEOUT,
      }
    : { type: "command", command, timeout: PROMPT_HOOK_TIMEOUT };
}

/** How Hermes's hooks run the script, with no shell */
function hermesRun(target: HookTarget): string {
  return target.shell === "sh"
    ? `sh ${shellQuote(installedScript(target))}`
    : target.shell === "pwsh"
      ? `pwsh -NoProfile -File ${shellQuote(installedScript(target))}`
      : `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${installedScript(target)}"`;
}

/** What Hermes's hooks run, for each of its events */
export function hermesHookCommand(target: HookTarget): string {
  return `${hermesRun(target)} hermes ${hookOption(target)}`;
}

/** What Hermes's per-prompt hook runs, before each turn (G1-271) */
export function hermesPromptCommand(target: HookTarget): string {
  return `${hermesRun(target)} prompt hermes`;
}

/**
 * Hermes's command as config.yaml holds it: in double quotes from sync.sh,
 * and from sync.ps1 in single quotes, which keep backslashes, unless it has
 * one. The per-prompt hook's with prompt (G1-271).
 */
export function hermesHookYaml(
  target: HookTarget,
  options: { prompt?: boolean } = {},
): string {
  const command = options.prompt
    ? hermesPromptCommand(target)
    : hermesHookCommand(target);
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
    `description: "Keeps OpenClaw's files in step with your context in Context Locker"`,
    `metadata: { "openclaw": { "events": [${events}] } }`,
    "---",
    "",
    "# Context Locker sync",
    "",
    "Runs Context Locker's sync when the gateway starts, when a session starts or resets, and before compaction, so OpenClaw's files hold your context as it is now.",
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
