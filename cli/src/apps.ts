// The supported apps, their configuration paths and invoking session markers.
import { statSync } from "node:fs";
import { join } from "node:path";

import { COMPILED_HARNESSES, type CompiledHarness } from "@internal/compilers";
import { HARNESS_NAMES } from "@internal/shared";

import type { Place } from "./place.js";

export type App = CompiledHarness;

/** Every app setup works for, in the order it lists them */
export const APPS: readonly App[] = COMPILED_HARNESSES;

/** The command each app installs */
const COMMANDS: Readonly<Record<App, string>> = Object.freeze({
  "claude-code": "claude",
  codex: "codex",
  hermes: "hermes",
  openclaw: "openclaw",
});

export function appName(app: App): string {
  return HARNESS_NAMES[app];
}

/** "Claude Code", "Claude Code and Codex", or "Claude Code, Codex and Hermes" */
export function namesOf(apps: readonly App[]): string {
  const names = apps.map(appName);
  if (names.length < 2) return names.join("");
  return `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

/** Each app's name as setup takes it, as a list: "claude-code, codex, hermes or openclaw" */
export function appList(): string {
  return `${APPS.slice(0, -1).join(", ")} or ${APPS.at(-1)}`;
}

export function parseApp(name: string): App | null {
  return (APPS as readonly string[]).includes(name) ? (name as App) : null;
}

/** The folder each app keeps its settings in, as the sync scripts find it */
export function appFolder(app: App, place: Place): string {
  switch (app) {
    case "claude-code":
      return place.env.CLAUDE_CONFIG_DIR || join(place.home, ".claude");
    case "codex":
      return place.env.CODEX_HOME || join(place.home, ".codex");
    case "hermes":
      return place.env.HERMES_HOME || join(place.home, ".hermes");
    case "openclaw":
      return join(place.home, ".openclaw");
  }
}

/** Where a command is on the PATH, or null */
export function onPath(command: string, place: Place): string | null {
  const path = place.env.PATH ?? place.env.Path ?? "";
  const dirs = path.split(place.windows ? ";" : ":").filter(Boolean);
  const endings = place.windows
    ? (place.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";").filter(Boolean)
    : [""];
  for (const dir of dirs) {
    for (const ending of endings) {
      const candidate = join(dir, `${command}${ending}`);
      try {
        const stat = statSync(candidate);
        if (stat.isFile() && (place.windows || (stat.mode & 0o111) !== 0)) {
          return candidate;
        }
      } catch {
        // Not here
      }
    }
  }
  return null;
}

/** Whether an app's command is on the PATH, such as openclaw for turning its hook on */
export function appCommand(app: App, place: Place): string | null {
  return onPath(COMMANDS[app], place);
}

/**
 * Session markers identify the invoking app, unlike installed folders or PATH.
 * Nested agents can inherit more than one marker; that needs an explicit choice.
 * OpenClaw and any runtime without a session marker use --app.
 */
export function selectApp(
  requested: readonly App[],
  env: NodeJS.ProcessEnv,
): { app: App } | { problem: string } {
  if (requested.length > 1) {
    return {
      problem:
        "Setup connects one app at a time. Use --app once, then run setup separately in each other app you want to connect.",
    };
  }
  if (requested.length === 1) return { app: requested[0] as App };
  const found: App[] = [];
  if (env.CLAUDECODE === "1") found.push("claude-code");
  if (env.CODEX_THREAD_ID?.trim()) found.push("codex");
  if (env.HERMES_SESSION_ID?.trim()) found.push("hermes");
  if (found.length === 1) return { app: found[0] as App };
  return {
    problem: `${found.length ? "More than one invoking app is indicated." : "Setup can't tell which app is running it."} Choose one with --app: ${appList()}. No connection or files have been changed.`,
  };
}
