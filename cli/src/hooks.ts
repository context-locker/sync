// Adding each app's hook, so it syncs on its own events: the hooks the sync
// scripts' plan shows, from the compilers package, added to the files it
// names. Everything else in those files stays as it is, a copy of each goes in
// the backups first, and a file setup can't read safely is left for the app
// to change, with the hook to add.
import { execFile } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  HOOK_EVENTS,
  OPENCLAW_HOOK_NAME,
  SYNC_SCRIPT_PATTERN,
  hermesHookYaml,
  installedScript,
  openclawHandler,
  openclawHookMd,
  sessionStartHook,
  type SessionStartHook,
} from "@internal/compilers";

import { appCommand, appFolder, type App } from "./apps.js";
import { backUp, writeFile } from "./files.js";
import { hookTargetOf, shown, type Place } from "./place.js";

export interface HookOutcome {
  /** added: setup added it; present: it was already there; manual: the app or the person adds it */
  state: "added" | "present" | "manual";
  /** What to tell the person */
  said: string;
}

type Json = Record<string, unknown>;

const isObject = (value: unknown): value is Json =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function readText(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

/** Whether some text runs the sync script: the doctor's test for a hook */
function runsScript(text: string, installed: string): boolean {
  return SYNC_SCRIPT_PATTERN.test(text) || text.includes(installed);
}

/** Whether a SessionStart hook in a JSON settings file runs the script */
export function jsonHookIn(settings: Json, installed: string): boolean {
  const groups = isObject(settings.hooks) ? settings.hooks.SessionStart : null;
  if (!Array.isArray(groups)) return false;
  return groups.some(
    (group) =>
      isObject(group) &&
      Array.isArray(group.hooks) &&
      group.hooks.some((hook) => {
        if (!isObject(hook)) return false;
        const words = [hook.command, hook.commandWindows, hook.args]
          .flat()
          .filter((word) => typeof word === "string");
        return runsScript(words.join(" "), installed);
      }),
  );
}

/** Whether Codex's config.toml has a SessionStart hook that runs the script */
export function tomlHookIn(text: string, installed: string): boolean {
  let start = false;
  for (const line of text.split(/\r?\n/)) {
    const table = /^\s*\[\[?hooks\.(\w+)/.exec(line);
    if (table) start = table[1] === "SessionStart";
    else if (
      start &&
      /^\s*command(_windows|Windows)?\s*=/.test(line) &&
      runsScript(line, installed)
    ) {
      return true;
    }
  }
  return false;
}

/** The indent a JSON file uses, so it's written back the same way */
function indentOf(text: string): string | number {
  const found = /^([ \t]+)"/m.exec(text);
  return found?.[1] ?? 2;
}

/**
 * Adds a session-start hook to a JSON settings file, after any already
 * there, keeping everything else in it
 */
function addJsonHook(
  place: Place,
  app: App,
  file: string,
  hook: SessionStartHook,
  when: string,
): "added" | "present" | { problem: string } {
  const installed = installedScript(hookTargetOf(place));
  let raw: string | null;
  try {
    raw = readText(file);
  } catch {
    return { problem: `setup couldn't read ${shown(place, file)}` };
  }
  let settings: Json = {};
  if (raw !== null && raw.trim() !== "") {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (!isObject(parsed)) {
        return { problem: `${shown(place, file)} isn't a JSON object` };
      }
      settings = parsed;
    } catch {
      return { problem: `${shown(place, file)} isn't valid JSON` };
    }
  }
  if (jsonHookIn(settings, installed)) return "present";
  const hooks = settings.hooks ?? {};
  if (!isObject(hooks)) {
    return { problem: `the hooks in ${shown(place, file)} aren't an object` };
  }
  const groups = hooks.SessionStart ?? [];
  if (!Array.isArray(groups)) {
    return {
      problem: `SessionStart in ${shown(place, file)} isn't a list`,
    };
  }
  hooks.SessionStart = [...groups, { hooks: [hook] }];
  settings.hooks = hooks;
  if (raw !== null) backUp(place, app, file, when);
  mkdirSync(dirname(file), { recursive: true });
  writeFile(
    file,
    `${JSON.stringify(settings, null, indentOf(raw ?? ""))}\n`,
    0o600,
  );
  return "added";
}

/** Each of Hermes's events that its config.yaml runs the script on, as the doctor reads it */
export function hermesEventsIn(text: string, installed: string): Set<string> {
  const found = new Set<string>();
  let inHooks = false;
  let event = "";
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (/^[^\s#]/.test(line)) {
      inHooks = /^hooks:\s*$/.test(line);
      event = "";
      continue;
    }
    const key = /^\s+([a-z_]+):\s*$/.exec(line);
    if (inHooks && key) {
      event = key[1] as string;
      continue;
    }
    if (
      inHooks &&
      event &&
      line.includes("command:") &&
      runsScript(line, installed)
    ) {
      found.add(event);
    }
  }
  return found;
}

const indentOfLine = (line: string) => /^ */.exec(line)?.[0].length ?? 0;
const blankOrComment = (line: string) => /^\s*(#.*)?$/.test(line);

/**
 * config.yaml with a hook added under each of these events, in its hooks
 * section, or null when the file is laid out in a way setup won't change,
 * such as hooks: {} or tabs
 */
export function withHermesHooks(
  text: string,
  value: string,
  events: readonly string[],
): string | null {
  const newline = text.includes("\r\n") ? "\r\n" : "\n";
  let lines = text === "" ? [] : text.replace(/\r\n/g, "\n").split("\n");
  if (lines.at(-1) === "") lines = lines.slice(0, -1);

  for (const event of events) {
    const tops = lines
      .map((line, index) => ({ line, index }))
      .filter(({ line }) => /^hooks\s*:/.test(line));
    if (tops.length > 1) return null;
    const top = tops[0];
    if (top && !/^hooks:\s*$/.test(top.line)) return null;
    const item = (indent: number) => `${" ".repeat(indent)}- command: ${value}`;

    if (!top) {
      lines.push("hooks:", `  ${event}:`, item(4));
      continue;
    }
    // The hooks section runs to the next line that starts at the margin
    let end = lines.length;
    for (let index = top.index + 1; index < lines.length; index += 1) {
      if (/^[^\s#]/.test(lines[index] as string)) {
        end = index;
        break;
      }
    }
    const section = lines.slice(top.index + 1, end);
    if (section.some((line) => /^ *\t/.test(line))) return null;
    const first = section.find((line) => !blankOrComment(line));
    const indent = first ? indentOfLine(first) : 2;
    if (indent === 0) return null;

    const at = section.findIndex(
      (line) =>
        indentOfLine(line) === indent &&
        new RegExp(`^ *${event}\\s*:`).test(line),
    );
    if (at === -1) {
      // A new event, after the last line of the section that isn't blank
      let last = section.length - 1;
      while (last >= 0 && blankOrComment(section[last] as string)) last -= 1;
      const after = top.index + 1 + last;
      lines.splice(
        after + 1,
        0,
        `${" ".repeat(indent)}${event}:`,
        item(indent + 2),
      );
      continue;
    }
    if (!new RegExp(`^ *${event}:\\s*$`).test(section[at] as string)) {
      return null;
    }
    // The event's own lines are the ones indented further below it
    let last = at;
    for (let index = at + 1; index < section.length; index += 1) {
      const line = section[index] as string;
      if (blankOrComment(line)) continue;
      if (indentOfLine(line) <= indent) break;
      last = index;
    }
    const listed = section
      .slice(at + 1, last + 1)
      .find((line) => /^ *- /.test(line));
    const itemIndent = listed ? indentOfLine(listed) : indent + 2;
    if (listed === undefined && last > at) return null;
    lines.splice(top.index + 1 + last + 1, 0, item(itemIndent));
  }
  return `${lines.join(newline)}${newline}`;
}

/** Adds Hermes's hooks to config.yaml, keeping everything else in it */
function addHermesHooks(
  place: Place,
  when: string,
): "added" | "present" | { problem: string } {
  const target = hookTargetOf(place);
  const installed = installedScript(target);
  const file = join(appFolder("hermes", place), "config.yaml");
  let raw: string | null;
  try {
    raw = readText(file);
  } catch {
    return { problem: `setup couldn't read ${shown(place, file)}` };
  }
  const missing = HOOK_EVENTS.hermes.filter(
    (event) => !hermesEventsIn(raw ?? "", installed).has(event),
  );
  if (missing.length === 0) return "present";
  // Only the events still missing get a hook
  const updated = withHermesHooks(raw ?? "", hermesHookYaml(target), missing);
  if (
    updated === null ||
    HOOK_EVENTS.hermes.some(
      (event) => !hermesEventsIn(updated, installed).has(event),
    )
  ) {
    return {
      problem: `setup couldn't find its way round the hooks section of ${shown(place, file)}`,
    };
  }
  if (raw !== null) backUp(place, "hermes", file, when);
  mkdirSync(dirname(file), { recursive: true });
  writeFile(file, updated, 0o600);
  return "added";
}

/** Whether OpenClaw's hook folder holds HOOK.md with each event, and a handler that runs the script */
function openclawHookIn(folder: string, installed: string): boolean {
  const md = readText(join(folder, "HOOK.md"));
  if (md === null) return false;
  if (!HOOK_EVENTS.openclaw.every((event) => md.includes(`"${event}"`))) {
    return false;
  }
  for (const name of ["handler.ts", "handler.js", "index.ts", "index.js"]) {
    const handler = readText(join(folder, name));
    if (handler !== null) return runsScript(handler, installed);
  }
  return false;
}

/** Runs openclaw hooks enable, saying whether it worked */
function enableOpenclawHook(command: string): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      command,
      ["hooks", "enable", OPENCLAW_HOOK_NAME],
      { timeout: 30_000, windowsHide: true },
      (error) => resolve(!error),
    );
  });
}

/** Saves OpenClaw's hook, HOOK.md and handler.js, and turns it on */
async function addOpenclawHook(
  place: Place,
  when: string,
): Promise<HookOutcome> {
  const target = hookTargetOf(place);
  const installed = installedScript(target);
  const folder = join(place.home, ".openclaw", "hooks", OPENCLAW_HOOK_NAME);
  if (openclawHookIn(folder, installed)) {
    return {
      state: "present",
      said: `OpenClaw's hook is already in ${shown(place, folder)}.`,
    };
  }
  // Another handler there would run instead of handler.js
  for (const name of ["handler.ts"]) {
    if (readText(join(folder, name)) !== null) {
      return {
        state: "manual",
        said: `OpenClaw's hook folder, ${shown(place, folder)}, has a ${name} that doesn't run the sync. Run the sync script's plan for openclaw and save the hook it shows there.`,
      };
    }
  }
  mkdirSync(folder, { recursive: true });
  const files: Array<[string, string]> = [
    ["HOOK.md", openclawHookMd()],
    ["handler.js", openclawHandler(target)],
  ];
  for (const [name, content] of files) {
    const file = join(folder, name);
    const before = readText(file);
    if (before === content) continue;
    if (before !== null) backUp(place, "openclaw", file, when);
    writeFile(file, content, 0o644);
  }
  const command = appCommand("openclaw", place);
  const enabled = command ? await enableOpenclawHook(command) : false;
  return {
    state: "added",
    said: enabled
      ? `Saved OpenClaw's hook in ${shown(place, folder)} and turned it on. Restart the OpenClaw gateway if it's running, so it loads the hook.`
      : `Saved OpenClaw's hook in ${shown(place, folder)}. Turn it on with \`openclaw hooks enable ${OPENCLAW_HOOK_NAME}\` on the computer where the gateway runs, then restart the gateway if it's running.`,
  };
}

/** Adds an app's hook, so it syncs on its own events */
export async function addHook(
  app: App,
  place: Place,
  when: string,
): Promise<HookOutcome> {
  const target = hookTargetOf(place);
  switch (app) {
    case "claude-code": {
      const file = join(appFolder(app, place), "settings.json");
      const done = addJsonHook(
        place,
        app,
        file,
        sessionStartHook(app, target),
        when,
      );
      if (done === "present") {
        return {
          state: "present",
          said: `The session-start hook is already in ${shown(place, file)}.`,
        };
      }
      if (done === "added") {
        return {
          state: "added",
          said: `Added the session-start hook to ${shown(place, file)}.`,
        };
      }
      return manual(app, done.problem);
    }
    case "codex": {
      const dir = appFolder(app, place);
      const toml = readTextSafely(join(dir, "config.toml"));
      if (toml !== null && tomlHookIn(toml, installedScript(target))) {
        return {
          state: "present",
          said: `The session-start hook is already set up in ${shown(place, dir)}.`,
        };
      }
      const file = join(dir, "hooks.json");
      const done = addJsonHook(
        place,
        app,
        file,
        sessionStartHook(app, target),
        when,
      );
      if (done === "present") {
        return {
          state: "present",
          said: `The session-start hook is already in ${shown(place, file)}.`,
        };
      }
      if (done === "added") {
        return {
          state: "added",
          said: `Added the session-start hook to ${shown(place, file)}. Codex skips a new hook until it's trusted: open /hooks in Codex and trust it.`,
        };
      }
      return manual(app, done.problem);
    }
    case "hermes": {
      const file = join(appFolder(app, place), "config.yaml");
      const done = addHermesHooks(place, when);
      if (done === "present") {
        return {
          state: "present",
          said: `${shown(place, file)} already runs the sync when a session starts and after compaction.`,
        };
      }
      if (done === "added") {
        return {
          state: "added",
          said: `Added the hooks to ${shown(place, file)}. Hermes asks you to approve each one the first time it sees it, in a hermes chat. Its gateway never asks, so approve them in a chat first.`,
        };
      }
      return manual(app, done.problem);
    }
    case "openclaw":
      return addOpenclawHook(place, when);
  }
}

function readTextSafely(path: string): string | null {
  try {
    return readText(path);
  } catch {
    return null;
  }
}

function manual(app: App, problem: string): HookOutcome {
  return {
    state: "manual",
    said: `The hook wasn't added, as ${problem}. Run the sync script's plan for ${app} and add the hook it shows.`,
  };
}
