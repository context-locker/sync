import { createHash } from "node:crypto";

import type { SkillFile } from "./types.js";

/** The marker file the sync script writes in each skill folder it manages. */
export const MANAGED_MARKER = ".ctx-managed";

/**
 * Files that tools leave in folders on their own: Finder's and Explorer's
 * folder settings, and editors' backup, lock and swap files. They never count
 * as part of a skill, so opening a skill folder isn't an edit. The sync
 * scripts skip the same names.
 */
export function isIgnoredFile(path: string): boolean {
  if (path === MANAGED_MARKER) return true;
  const name = path.slice(path.lastIndexOf("/") + 1);
  return (
    name === ".DS_Store" ||
    name === "Thumbs.db" ||
    name === "desktop.ini" ||
    name === "4913" ||
    name.endsWith("~") ||
    name.startsWith(".#") ||
    /^\..+\.sw[a-p]$/.test(name)
  );
}

export function sha256(data: string | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

/** A skill file's bytes. */
export function fileBytes(file: SkillFile): Buffer {
  return file.encoding === "base64"
    ? Buffer.from(file.content, "base64")
    : Buffer.from(file.content, "utf8");
}

/**
 * A skill folder's hash, computed the same way by the sync scripts: one line
 * per file, "<sha256 of its bytes> <path>", sorted by path byte by byte, and
 * the SHA-256 of those lines. The marker file and ignored files are left out.
 */
export function treeHash(files: readonly SkillFile[]): string {
  const lines = files
    .filter((file) => !isIgnoredFile(file.path))
    .map((file) => ({
      path: Buffer.from(file.path, "utf8"),
      line: `${sha256(fileBytes(file))} ${file.path}\n`,
    }))
    .sort((a, b) => Buffer.compare(a.path, b.path))
    .map((entry) => entry.line)
    .join("");
  return sha256(lines);
}

/**
 * A managed block's hash. Carriage returns are dropped first, so an editor
 * that saves Windows line endings doesn't count as an edit.
 */
export function blockHash(text: string): string {
  return sha256(text.replace(/\r/g, ""));
}
