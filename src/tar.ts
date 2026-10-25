// A small tar writer, for sending blobs to the sync script in one response,
// and for an export, which is written as a stream an entry at a time. The
// script unpacks it with the tar that ships with macOS, Linux and Windows 10
// and later. Paths longer than the ustar header holds get a pax header, which
// GNU tar and bsdtar both read.
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

/**
 * The header blocks for one entry: a pax header first when its path is
 * longer than the ustar header holds, then its own. For an archive written
 * as a stream, an entry is its header, then `size` bytes of data, then
 * {@link tarPadding} for that size.
 */
export function tarHeader(
  entry: {
    path: string;
    /** Bytes of data that follow; 0 for a directory */
    size: number;
    directory?: boolean;
    mode?: number;
  },
  mtime: number,
): Buffer {
  const isDir = entry.directory === true;
  const name =
    isDir && !entry.path.endsWith("/") ? `${entry.path}/` : entry.path;
  const mode = entry.mode ?? (isDir ? 0o755 : 0o644);
  const chunks: Buffer[] = [];
  if (Buffer.byteLength(name, "utf8") > 100) {
    const pax = Buffer.from(paxRecord("path", name), "utf8");
    chunks.push(
      header("PaxHeader", pax.length, 0o644, "x", mtime),
      padded(pax),
    );
  }
  // The ustar name field holds 100 bytes; the pax record holds the whole path
  chunks.push(
    header(
      name.slice(0, 100),
      isDir ? 0 : entry.size,
      mode,
      isDir ? "5" : "0",
      mtime,
    ),
  );
  return Buffer.concat(chunks);
}

/** The zero bytes that fill an entry's data out to the archive's next block. */
export function tarPadding(size: number): Buffer {
  const rest = size % BLOCK;
  return Buffer.alloc(rest === 0 ? 0 : BLOCK - rest, 0);
}

/** The two empty blocks that end an archive. */
export const TAR_END: Buffer = Buffer.alloc(BLOCK * 2, 0);

/** An archive's entries in pieces, each header then its data, then the end. */
function* tarParts(
  entries: Iterable<TarEntry>,
  mtime: number,
): Generator<Buffer> {
  for (const entry of entries) {
    const isDir = entry.bytes === null;
    const bytes = entry.bytes ?? Buffer.alloc(0);
    yield tarHeader(
      {
        path: entry.path,
        size: bytes.length,
        directory: isDir,
        ...(entry.mode === undefined ? {} : { mode: entry.mode }),
      },
      mtime,
    );
    if (bytes.length > 0) {
      yield bytes;
      const padding = tarPadding(bytes.length);
      if (padding.length > 0) yield padding;
    }
  }
  yield TAR_END;
}

export function writeTar(entries: readonly TarEntry[], mtime: number): Buffer {
  return Buffer.concat([...tarParts(entries, mtime)]);
}

/**
 * The entries of the blobs the script asked for. A file blob is a file named
 * by its hash; a skill blob is a folder named by its hash. Files that start
 * with #! are made executable.
 */
function* blobEntries(
  blobs: ReadonlyArray<readonly [string, Blob]>,
): Generator<TarEntry> {
  for (const [hash, blob] of blobs) {
    if (blob.kind === "file") {
      yield { path: hash, bytes: blob.bytes };
      continue;
    }
    yield { path: hash, bytes: null };
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
          yield { path: `${hash}/${folder}`, bytes: null };
        }
      }
      const bytes = fileBytes(file);
      const executable = bytes.subarray(0, 2).toString("latin1") === "#!";
      yield {
        path: `${hash}/${file.path}`,
        bytes,
        mode: executable ? 0o755 : 0o644,
      };
    }
  }
}

/** The blobs the script asked for, as one archive. */
export function blobArchive(
  blobs: ReadonlyArray<readonly [string, Blob]>,
  mtime: number,
): Buffer {
  return Buffer.concat([...tarParts(blobEntries(blobs), mtime)]);
}

/**
 * The same archive in pieces, so a big one can go out a piece at a time
 * rather than as one buffer: one response holds at most 4.5 MB unless it
 * streams.
 */
export function blobArchiveParts(
  blobs: ReadonlyArray<readonly [string, Blob]>,
  mtime: number,
): Generator<Buffer> {
  return tarParts(blobEntries(blobs), mtime);
}
