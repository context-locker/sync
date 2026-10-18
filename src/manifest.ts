// The sync manifest: one line per thing the sync script should hold, each
// with the hash of its content. The script compares hashes with what it last
// wrote, fetches only what changed, and sends the manifest's hash back next
// time, so an unchanged playbook costs one small request.
//
//   context-locker-sync 1
//   workspace <workspace id>
//   block <sha256> <target>                          a managed block
//   skill <tree hash> <target> <item id> <version>   a skill folder
//   context <sha256>                                 printed at session start
//   hold <sha256> <target>                           a local edit waiting for review: keep it
//
// Scripts skip lines they don't know, so later versions can add kinds.
import { blockHash, sha256, treeHash } from "./hash.js";
import type { ItemRef, Output, SkillFile } from "./types.js";

export const MANIFEST_HEADER = "context-locker-sync 1";

export type ManifestEntry =
  | { kind: "block"; hash: string; target: string }
  | { kind: "skill"; hash: string; target: string; item: ItemRef }
  | { kind: "context"; hash: string }
  | { kind: "hold"; hash: string; target: string };

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

export function buildManifest(input: {
  workspaceId: string;
  outputs: readonly Output[];
  holds: readonly Hold[];
}): Manifest {
  if (!UUID.test(input.workspaceId)) {
    throw new Error("The workspace id must be a UUID");
  }

  const blobs = new Map<string, Blob>();
  const blocks: ManifestEntry[] = [];
  const skills: ManifestEntry[] = [];
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

  const entries = [
    ...(blocks as Array<ManifestEntry & { target: string }>).sort(byTarget),
    ...(skills as Array<ManifestEntry & { target: string }>).sort(byTarget),
    ...contexts,
    ...holds,
  ];

  const lines = [MANIFEST_HEADER, `workspace ${input.workspaceId}`];
  for (const entry of entries) {
    switch (entry.kind) {
      case "block":
        lines.push(`block ${entry.hash} ${entry.target}`);
        break;
      case "skill":
        lines.push(
          `skill ${entry.hash} ${entry.target} ${entry.item.id} ${entry.item.version}`,
        );
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
    } else if (kind === "skill" && hash && target && id && version) {
      entries.push({
        kind,
        hash,
        target,
        item: { id, version: Number(version) },
      });
    } else if (kind === "context" && hash) entries.push({ kind, hash });
    else if (kind === "hold" && hash && target) {
      entries.push({ kind, hash, target });
    }
  }
  return { workspaceId, entries };
}
