// Writing files as the sync scripts do: Context Locker's own only this account
// can read, each in one step so a file is never half written, a symlinked
// file kept a symlink, and a copy of any file of the person's in the backups
// before it changes.
import {
  copyFileSync,
  lstatSync,
  mkdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { randomBytes } from "node:crypto";
import { basename, dirname, join } from "node:path";

import type { Place } from "./place.js";

/** A folder only this account can read, made with any folders it's in */
export function privateFolder(path: string): void {
  mkdirSync(path, { recursive: true, mode: 0o700 });
}

/**
 * Writes a file in one step: a new file beside it, moved into its place. A
 * file that's a symlink, such as a dotfiles setup's, is written through, so it
 * stays a symlink. A new file gets the mode given; one that's there keeps its own.
 */
export function writeFile(path: string, content: string, mode = 0o600): void {
  let existing: ReturnType<typeof lstatSync> | null = null;
  try {
    existing = lstatSync(path);
  } catch {
    existing = null;
  }
  if (existing?.isSymbolicLink()) {
    writeFileSync(path, content);
    return;
  }
  const keep = existing ? existing.mode & 0o777 : mode;
  const temp = join(
    dirname(path),
    `.${basename(path)}.${randomBytes(6).toString("hex")}.tmp`,
  );
  writeFileSync(temp, content, { mode: keep, flag: "wx" });
  try {
    renameSync(temp, path);
  } catch (error) {
    rmSync(temp, { force: true });
    throw error;
  }
}

/** The time a run started, as the scripts name a folder of backups: 20261025T120102Z */
export function stamp(date = new Date()): string {
  return date
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d+Z$/, "Z");
}

/**
 * Copies a file of the person's into Context Locker's backups before it
 * changes, as the sync scripts do: backups/<time>/<app>/<name>
 */
export function backUp(
  place: Place,
  app: string,
  path: string,
  when: string,
): string | null {
  try {
    if (!statSync(path).isFile()) return null;
  } catch {
    return null;
  }
  const folder = join(place.clHome, "backups", when, app);
  privateFolder(folder);
  const copy = join(folder, basename(path));
  copyFileSync(path, copy);
  return copy;
}
