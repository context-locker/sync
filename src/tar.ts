// A small tar writer, for sending blobs to the sync script in one response.
// The script unpacks it with the tar that ships with macOS, Linux and
// Windows 10 and later. Paths longer than the ustar header holds get a pax
// header, which GNU tar and bsdtar both read.
import { fileBytes } from "./hash.js";
import type { Blob } from "./manifest.js";

export interface TarEntry {
  path: string;
  /** Null for a directory. */
  bytes: Buffer | null;
  mode?: number;
}

const BLOCK = 512;

function octal(value: number, length: number): string {
  // Digits, then a NUL, filling the field
  return `${value.toString(8).padStart(length - 1, "0")}\0`;
}

function header(
  name: string,
  size: number,
  mode: number,
  type: string,
  mtime: number,
): Buffer {
  const buffer = Buffer.alloc(BLOCK, 0);
  buffer.write(name, 0, 100, "utf8");
  buffer.write(octal(mode, 8), 100, 8, "ascii");
  buffer.write(octal(0, 8), 108, 8, "ascii");
  buffer.write(octal(0, 8), 116, 8, "ascii");
  buffer.write(octal(size, 12), 124, 12, "ascii");
  buffer.write(octal(mtime, 12), 136, 12, "ascii");
  buffer.write("        ", 148, 8, "ascii");
  buffer.write(type, 156, 1, "ascii");
  buffer.write("ustar\0", 257, 6, "ascii");
  buffer.write("00", 263, 2, "ascii");
  let sum = 0;
  for (const byte of buffer) sum += byte;
  buffer.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, 8, "ascii");
  return buffer;
}

function padded(bytes: Buffer): Buffer {
  const rest = bytes.length % BLOCK;
  return rest === 0
    ? bytes
    : Buffer.concat([bytes, Buffer.alloc(BLOCK - rest, 0)]);
}

/** A pax record: its own length in decimal, a space, key=value and a newline. */
function paxRecord(key: string, value: string): string {
  const body = ` ${key}=${value}\n`;
  const bodyLength = Buffer.byteLength(body, "utf8");
  // The length counts its own digits, so settle on a length whose digits fit
  let length = bodyLength;
  for (;;) {
    const next = bodyLength + String(length).length;
    if (next === length) break;
    length = next;
  }
  return `${length}${body}`;
}

export function writeTar(entries: readonly TarEntry[], mtime: number): Buffer {
  const chunks: Buffer[] = [];
  for (const entry of entries) {
    const isDir = entry.bytes === null;
    const name =
      isDir && !entry.path.endsWith("/") ? `${entry.path}/` : entry.path;
    const bytes = entry.bytes ?? Buffer.alloc(0);
    const mode = entry.mode ?? (isDir ? 0o755 : 0o644);

    if (Buffer.byteLength(name, "utf8") > 100) {
      const pax = Buffer.from(paxRecord("path", name), "utf8");
      chunks.push(
        header("PaxHeader", pax.length, 0o644, "x", mtime),
        padded(pax),
      );
    }
    chunks.push(
      header(name.slice(0, 100), bytes.length, mode, isDir ? "5" : "0", mtime),
    );
    if (bytes.length > 0) chunks.push(padded(bytes));
  }
  // Two empty blocks end the archive
  chunks.push(Buffer.alloc(BLOCK * 2, 0));
  return Buffer.concat(chunks);
}

/**
 * The blobs the script asked for, as one archive. A file blob is a file named
 * by its hash; a skill blob is a folder named by its hash. Files that start
 * with #! are made executable.
 */
export function blobArchive(
  blobs: ReadonlyArray<readonly [string, Blob]>,
  mtime: number,
): Buffer {
  const entries: TarEntry[] = [];
  for (const [hash, blob] of blobs) {
    if (blob.kind === "file") {
      entries.push({ path: hash, bytes: blob.bytes });
      continue;
    }
    entries.push({ path: hash, bytes: null });
    const folders = new Set<string>();
    const files = [...blob.files].sort((a, b) =>
      a.path < b.path ? -1 : a.path > b.path ? 1 : 0,
    );
    for (const file of files) {
      const parts = file.path.split("/");
      for (let depth = 1; depth < parts.length; depth += 1) {
        const folder = parts.slice(0, depth).join("/");
        if (!folders.has(folder)) {
          folders.add(folder);
          entries.push({ path: `${hash}/${folder}`, bytes: null });
        }
      }
      const bytes = fileBytes(file);
      const executable = bytes.subarray(0, 2).toString("latin1") === "#!";
      entries.push({
        path: `${hash}/${file.path}`,
        bytes,
        mode: executable ? 0o755 : 0o644,
      });
    }
  }
  return writeTar(entries, mtime);
}
