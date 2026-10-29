// The sync script: setup saves the one that comes with this command where
// the hooks run it, then runs it to write each app's files and to check them.
// The hooks keep running that copy, so a session never waits for npm, and
// the script works without Node.
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { installedScript, scriptName } from "@internal/compilers";

import { privateFolder, writeFile } from "./files.js";
import { hookTargetOf, type Place } from "./place.js";

/** Where the scripts that come with this command are: beside it once built, or in the compilers package */
export function bundledScripts(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  if (existsSync(join(here, "sync.sh"))) return here;
  return fileURLToPath(new URL("../../compilers/scripts/", import.meta.url));
}

/** The version a sync script says it is */
export function scriptVersion(text: string): number | null {
  const found =
    /^SCRIPT_VERSION=(\d+)\r?$/m.exec(text) ??
    /^\$ScriptVersion = (\d+)\r?$/m.exec(text);
  return found ? Number(found[1]) : null;
}

export interface Installed {
  path: string;
  /** The version now there */
  version: number | null;
  /** saved: this command's; same: it was already there; newer: a newer one was there, and stays */
  state: "saved" | "same" | "newer";
}

/** Saves the sync script where the hooks run it, unless a newer one is there */
export function installScript(place: Place, scripts: string): Installed {
  const target = hookTargetOf(place);
  const ours = readFileSync(join(scripts, scriptName(target.shell)), "utf8");
  const path = installedScript(target);
  let theirs: string | null = null;
  try {
    theirs = readFileSync(path, "utf8");
  } catch {
    theirs = null;
  }
  const version = scriptVersion(ours);
  if (theirs === ours) return { path, version, state: "same" };
  const installed = theirs === null ? null : scriptVersion(theirs);
  if (installed !== null && version !== null && installed > version) {
    return { path, version: installed, state: "newer" };
  }
  privateFolder(place.clHome);
  writeFile(path, ours, 0o600);
  return { path, version, state: "saved" };
}

/** Runs the saved script, as a hook would, passing each line it prints on */
export function runScript(
  place: Place,
  args: string[],
  line: (text: string) => void,
): Promise<number | null> {
  const path = installedScript(hookTargetOf(place));
  const [command, argv] = place.windows
    ? [
        "powershell.exe",
        ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path, ...args],
      ]
    : ["sh", [path, ...args]];
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(command, argv, {
        env: place.env,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch {
      resolve(null);
      return;
    }
    const lines = (stream: NodeJS.ReadableStream) => {
      let rest = "";
      stream.setEncoding("utf8");
      stream.on("data", (chunk: string) => {
        rest += chunk;
        const parts = rest.split("\n");
        rest = parts.pop() ?? "";
        for (const part of parts) line(part.replace(/\r$/, ""));
      });
      stream.on("end", () => {
        if (rest) line(rest.replace(/\r$/, ""));
      });
    };
    lines(child.stdout);
    lines(child.stderr);
    child.on("error", () => resolve(null));
    child.on("close", (status) => resolve(status));
  });
}
