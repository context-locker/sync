// The sync manifest: one line per thing the sync script should hold, each
// with the hash of its content. The script compares hashes with what it last
// wrote, fetches only what changed, and sends the manifest's hash back next
// time, so an unchanged playbook costs one small request.
//
//   context-locker-sync 1
//   workspace <workspace id>
//   script <version>                                 the newest sync script, in the global manifest
//   block <sha256> <target>                          a managed block
//   skill <tree hash> <target> <item id> <version>   a skill folder
//   file <sha256> <target>                           a whole file, such as the notes folder's README
//   note <sha256> <target> <item id> <version>       a note's file in a project's notes folder
//   link <item id> <path>                            a project's link to a path in the repo, which
//                                                    the script checks is there; the path is the
//                                                    rest of the line, and may hold spaces
//   context <sha256>                                 printed at session start
//   hold <sha256> <target>                           a local edit waiting for approval: keep it
//
// Scripts skip lines they don't know, so later versions can add kinds: a
// script from before notes leaves the notes folder alone, and one from before
// links doesn't check them.
import { blockHash, sha256, treeHash } from "./hash.js";
import type { ItemRef, Output, SkillFile } from "./types.js";

export const MANIFEST_HEADER = "context-locker-sync 1";

/**
 * The newest version of the sync scripts, as their SCRIPT_VERSION says. The
 * global manifest names it, so an older script can say a newer one is out.
 */
export const SYNC_SCRIPT_VERSION = 5;

export type ManifestEntry =
  | { kind: "block"; hash: string; target: string }
  | { kind: "skill"; hash: string; target: string; item: ItemRef }
  | { kind: "file"; hash: string; target: string }
  | { kind: "note"; hash: string; target: string; item: ItemRef }
  | { kind: "link"; id: string; path: string }
  | { kind: "context"; hash: string }
  | { kind: "hold"; hash: string; target: string }
  | { kind: "script"; version: number };

/** A project's link to a path in its repo, such as docs/runbook.md, which the script checks. */
export interface RepoLink {
  id: string;
  path: string;
}

/** What a hash in the manifest stands for: a file's bytes, or a skill folder. */
export type Blob =
  { kind: "file"; bytes: Buffer } | { kind: "tree"; files: SkillFile[] };

export interface Hold {
  target: string;
  hash: string;
}

export interface Manifest {
  text: string;
  /** The SHA-256 of the text, sent as the ETag. */
  etag: string;
  entries: ManifestEntry[];
  blobs: Map<string, Blob>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TARGET = /^\{[a-z-]+\}(?:\/[A-Za-z0-9._-]+)+$/;
const HASH = /^[0-9a-f]{64}$/;
// What a link's path never holds: control characters and line breaks, which
// would end its line, and backslashes and angle brackets, as links never do
const NOT_IN_PATHS = /[\p{Cc}\p{Zl}\p{Zp}\\<>]/u;

function checkTarget(target: string): string {
  if (
    !TARGET.test(target) ||
    target.split("/").some((part) => part === "." || part === "..")
  ) {
    throw new Error(`Not a usable target: ${target}`);
  }
  return target;
}

const byTarget = (a: { target: string }, b: { target: string }) =>
  a.target < b.target ? -1 : a.target > b.target ? 1 : 0;

/**
 * A path in the repo as a manifest line can hold it: inside the repo, with
 * nothing that would end the line, and no space at either end.
 */
function checkRepoPath(path: string): string {
  if (
    path === "" ||
    path.length > 2048 ||
    path !== path.trim() ||
    NOT_IN_PATHS.test(path) ||
    path.startsWith("/") ||
    path.startsWith("~") ||
    path.split("/").some((part) => part === "..")
  ) {
    throw new Error(`Not a usable path in the repo: ${JSON.stringify(path)}`);
  }
  return path;
}

export function buildManifest(input: {
  workspaceId: string;
  outputs: readonly Output[];
  holds: readonly Hold[];
  /** The newest sync script's version, for the global manifest */
  script?: number;
  /** A project's links to paths in its repo */
  links?: readonly RepoLink[];
}): Manifest {
  if (!UUID.test(input.workspaceId)) {
    throw new Error("The workspace id must be a UUID");
  }
  if (
    input.script !== undefined &&
    (!Number.isSafeInteger(input.script) || input.script < 1)
  ) {
    throw new Error("A script version is a whole number");
  }

  const blobs = new Map<string, Blob>();
  const blocks: ManifestEntry[] = [];
  const skills: ManifestEntry[] = [];
  const files: ManifestEntry[] = [];
  const notes: ManifestEntry[] = [];
  const contexts: ManifestEntry[] = [];

  for (const output of input.outputs) {
    if (output.kind === "block") {
      const hash = blockHash(output.text);
      blobs.set(hash, {
        kind: "file",
        bytes: Buffer.from(output.text, "utf8"),
      });
      blocks.push({ kind: "block", hash, target: checkTarget(output.target) });
    } else if (output.kind === "skill") {
      const hash = treeHash(output.files);
      blobs.set(hash, { kind: "tree", files: output.files });
      skills.push({
        kind: "skill",
        hash,
        target: checkTarget(output.target),
        item: output.item,
      });
    } else if (output.kind === "file" || output.kind === "note") {
      // A whole file, byte for byte, as the script hashes the file it finds
      const hash = sha256(output.text);
      blobs.set(hash, {
        kind: "file",
        bytes: Buffer.from(output.text, "utf8"),
      });
      const target = checkTarget(output.target);
      if (output.kind === "note") {
        notes.push({ kind: "note", hash, target, item: output.item });
      } else {
        files.push({ kind: "file", hash, target });
      }
    } else {
      const hash = sha256(output.text);
      blobs.set(hash, {
        kind: "file",
        bytes: Buffer.from(output.text, "utf8"),
      });
      contexts.push({ kind: "context", hash });
    }
  }

  const holds: ManifestEntry[] = [...input.holds]
    .map((hold) => {
      if (!HASH.test(hold.hash)) throw new Error("A hold needs a SHA-256");
      return {
        kind: "hold" as const,
        hash: hold.hash,
        target: checkTarget(hold.target),
      };
    })
    .sort(byTarget);

  const links = [...(input.links ?? [])]
    .map((link) => {
      if (!UUID.test(link.id)) throw new Error("A link's id must be a UUID");
      return {
        kind: "link" as const,
        id: link.id,
        path: checkRepoPath(link.path),
      };
    })
    .sort((a, b) =>
      a.path < b.path ? -1 : a.path > b.path ? 1 : a.id < b.id ? -1 : 1,
    );

  const entries = [
    ...(input.script !== undefined
      ? [{ kind: "script" as const, version: input.script }]
      : []),
    ...(blocks as Array<ManifestEntry & { target: string }>).sort(byTarget),
    ...(skills as Array<ManifestEntry & { target: string }>).sort(byTarget),
    ...(files as Array<ManifestEntry & { target: string }>).sort(byTarget),
    ...(notes as Array<ManifestEntry & { target: string }>).sort(byTarget),
    ...links,
    ...contexts,
    ...holds,
  ];

  const lines = [MANIFEST_HEADER, `workspace ${input.workspaceId}`];
  for (const entry of entries) {
    switch (entry.kind) {
      case "script":
        lines.push(`script ${entry.version}`);
        break;
      case "block":
        lines.push(`block ${entry.hash} ${entry.target}`);
        break;
      case "skill":
        lines.push(
          `skill ${entry.hash} ${entry.target} ${entry.item.id} ${entry.item.version}`,
        );
        break;
      case "file":
        lines.push(`file ${entry.hash} ${entry.target}`);
        break;
      case "note":
        lines.push(
          `note ${entry.hash} ${entry.target} ${entry.item.id} ${entry.item.version}`,
        );
        break;
      case "link":
        lines.push(`link ${entry.id} ${entry.path}`);
        break;
      case "context":
        lines.push(`context ${entry.hash}`);
        break;
      case "hold":
        lines.push(`hold ${entry.hash} ${entry.target}`);
        break;
    }
  }
  const text = `${lines.join("\n")}\n`;
  return { text, etag: sha256(text), entries, blobs };
}

/** Reads a manifest back, skipping kinds it doesn't know, as the scripts do. */
export function parseManifest(text: string): {
  workspaceId: string | null;
  entries: ManifestEntry[];
} {
  const [header, ...lines] = text.split("\n");
  if (header !== MANIFEST_HEADER) {
    throw new Error("Not a Context Locker sync manifest");
  }
  let workspaceId: string | null = null;
  const entries: ManifestEntry[] = [];
  for (const line of lines) {
    const fields = line.split(" ");
    const [kind, hash, target, id, version] = fields;
    if (kind === "workspace" && hash) workspaceId = hash;
    else if (kind === "block" && hash && target) {
      entries.push({ kind, hash, target });
    } else if (
      (kind === "skill" || kind === "note") &&
      hash &&
      target &&
      id &&
      version
    ) {
      entries.push({
        kind,
        hash,
        target,
        item: { id, version: Number(version) },
      });
    } else if (kind === "file" && hash && target) {
      entries.push({ kind, hash, target });
    } else if (kind === "link" && hash && target) {
      // The path is the rest of the line, spaces and all
      entries.push({
        kind,
        id: hash,
        path: line.slice(`link ${hash} `.length),
      });
    } else if (kind === "script" && hash && /^[0-9]{1,6}$/.test(hash)) {
      entries.push({ kind, version: Number(hash) });
    } else if (kind === "context" && hash) entries.push({ kind, hash });
    else if (kind === "hold" && hash && target) {
      entries.push({ kind, hash, target });
    }
  }
  return { workspaceId, entries };
}
