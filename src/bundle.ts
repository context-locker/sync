// How the sync script sends an edited skill folder: a header line, then for
// each file a line with its size and path, its bytes and a newline. A shell
// script can write this with printf, wc and cat, and nothing has to escape.
//
//   context-locker-bundle 1
//   file <bytes> <path>
//   <the file's bytes>
import type { SkillFile } from "./types.js";

export const BUNDLE_HEADER = "context-locker-bundle 1";

export class BundleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BundleError";
  }
}

const NEWLINE = 0x0a;
const FILE_LINE = /^file (0|[1-9][0-9]{0,9}) (.+)$/;

function readLine(data: Buffer, from: number): { line: string; next: number } {
  const end = data.indexOf(NEWLINE, from);
  if (end === -1 || end - from > 1024) {
    throw new BundleError("The skill bundle is cut short or malformed.");
  }
  return { line: data.subarray(from, end).toString("utf8"), next: end + 1 };
}

const utf8 = new TextDecoder("utf-8", { fatal: true });

function asSkillFile(path: string, bytes: Buffer): SkillFile {
  if (!bytes.includes(0)) {
    try {
      return { path, content: utf8.decode(bytes), encoding: "utf8" };
    } catch {
      // Not text, so it travels as base64
    }
  }
  return { path, content: bytes.toString("base64"), encoding: "base64" };
}

export function parseBundle(
  data: Buffer,
  limits: { files: number; bytes: number },
): SkillFile[] {
  let { line, next } = readLine(data, 0);
  if (line !== BUNDLE_HEADER) {
    throw new BundleError("That isn't a Context Locker skill bundle.");
  }

  const files: SkillFile[] = [];
  let total = 0;
  while (next < data.length) {
    ({ line, next } = readLine(data, next));
    const match = FILE_LINE.exec(line);
    if (!match) throw new BundleError("The skill bundle is malformed.");
    const size = Number(match[1]);
    const path = match[2] as string;
    total += size;
    if (files.length >= limits.files) {
      throw new BundleError(
        `A skill can have at most ${limits.files.toLocaleString("en-GB")} files.`,
      );
    }
    if (total > limits.bytes) {
      const most =
        limits.bytes >= 1024 * 1024
          ? `${Math.floor(limits.bytes / (1024 * 1024))} MB`
          : `${Math.floor(limits.bytes / 1024)} KB`;
      throw new BundleError(`A skill can hold at most ${most}.`);
    }
    if (next + size + 1 > data.length || data[next + size] !== NEWLINE) {
      throw new BundleError("The skill bundle is cut short or malformed.");
    }
    files.push(asSkillFile(path, data.subarray(next, next + size)));
    next += size + 1;
  }
  return files;
}

/** Writes a bundle, as the sync scripts do. */
export function writeBundle(
  files: ReadonlyArray<{ path: string; bytes: Buffer }>,
): Buffer {
  const chunks: Buffer[] = [Buffer.from(`${BUNDLE_HEADER}\n`)];
  for (const file of files) {
    chunks.push(
      Buffer.from(`file ${file.bytes.length} ${file.path}\n`, "utf8"),
      file.bytes,
      Buffer.from("\n"),
    );
  }
  return Buffer.concat(chunks);
}
