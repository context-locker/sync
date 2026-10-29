// Where things are on this computer: the person's home folder, Context
// Locker's folder and the address of its API, found as the sync scripts find
// them, so the setup command and the scripts always agree.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { HookTarget } from "@internal/compilers";

export const DEFAULT_API = "https://api.context.locker";

export interface Place {
  /** The person's home folder: the profile folder on Windows */
  home: string;
  /** Context Locker's folder: the sync script, its settings and each app's connection */
  clHome: string;
  /** Whether that's the usual folder, ~/.contextlocker */
  usualHome: boolean;
  windows: boolean;
  mac: boolean;
  env: NodeJS.ProcessEnv;
}

export function placeFrom(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): Place {
  const windows = platform === "win32";
  const home = (windows ? undefined : env.HOME) || homedir();
  const usual = join(home, ".contextlocker");
  const clHome = env.CONTEXT_LOCKER_HOME || usual;
  return {
    home,
    clHome,
    usualHome: clHome === usual,
    windows,
    mac: platform === "darwin",
    env,
  };
}

/** A setting from Context Locker's config file, a key=value line, as the scripts read it */
export function readSetting(place: Place, key: string): string | null {
  let text: string;
  try {
    text = readFileSync(join(place.clHome, "config"), "utf8");
  } catch {
    return null;
  }
  for (const line of text.split(/\r?\n/)) {
    if (line.startsWith(`${key}=`)) return line.slice(key.length + 1).trim();
  }
  return null;
}

/** The API's address: CONTEXT_LOCKER_API, then the config file, then the usual one */
export function apiOf(place: Place): string {
  const api =
    place.env.CONTEXT_LOCKER_API || readSetting(place, "api") || DEFAULT_API;
  return api.replace(/\/+$/, "");
}

/** How this computer's hooks run the sync script */
export function hookTargetOf(place: Place): HookTarget {
  return {
    shell: place.windows ? "windows" : "sh",
    clHome: place.clHome,
    usualHome: place.usualHome,
  };
}

/** A path as people read it, with the home folder as ~ */
export function shown(place: Place, path: string): string {
  if (path === place.home) return "~";
  const prefix = place.home.endsWith("/") ? place.home : `${place.home}/`;
  if (!place.windows && path.startsWith(prefix)) {
    return `~/${path.slice(prefix.length)}`;
  }
  return path;
}
