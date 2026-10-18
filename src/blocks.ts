// Managed blocks: the part of a file Context Locker owns, between two marker
// lines. Nothing outside the markers is ever changed. The sync scripts find
// and splice blocks with the same rules as these functions.

export const BLOCK_START = "<!-- context-locker:start v1 -->";
export const BLOCK_END = "<!-- context-locker:end -->";

// A marker is a whole line. Later versions of the start marker still count,
// and trailing spaces or a carriage return are allowed.
const START_LINE = /^<!-- context-locker:start(?: v[0-9]+)? -->[ \t\r]*$/;
const END_LINE = /^<!-- context-locker:end -->[ \t\r]*$/;

export function isMarkerLine(line: string): boolean {
  return START_LINE.test(line) || END_LINE.test(line);
}

export type BlockPosition =
  | { found: true; start: number; end: number }
  | { found: false; broken: boolean };

/**
 * Where the block is, as indexes into the file's lines, both inclusive. A
 * file with no markers has no block. Markers that don't pair up exactly once
 * mean the block is broken, and the file must be left alone.
 */
export function findBlock(lines: readonly string[]): BlockPosition {
  const starts: number[] = [];
  const ends: number[] = [];
  lines.forEach((line, index) => {
    if (START_LINE.test(line)) starts.push(index);
    if (END_LINE.test(line)) ends.push(index);
  });

  if (starts.length === 0 && ends.length === 0) {
    return { found: false, broken: false };
  }
  const [start] = starts;
  const [end] = ends;
  if (
    starts.length === 1 &&
    ends.length === 1 &&
    start !== undefined &&
    end !== undefined &&
    start < end
  ) {
    return { found: true, start, end };
  }
  return { found: false, broken: true };
}

/** Splits text into lines, keeping each line's own ending out of it. */
function splitLines(text: string): string[] {
  if (text === "") return [];
  const lines = text.split("\n");
  // A final newline doesn't start another line
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** The block in a file, markers included and ending with a newline, or null. */
export function extractBlock(fileText: string): string | null {
  const lines = splitLines(fileText);
  const position = findBlock(lines);
  if (!position.found) return null;
  return `${lines.slice(position.start, position.end + 1).join("\n")}\n`;
}

export class BrokenBlockError extends Error {
  constructor() {
    super(
      "The Context Locker markers in this file don't pair up, so it was left as it is.",
    );
    this.name = "BrokenBlockError";
  }
}

const isBlank = (line: string | undefined) =>
  line !== undefined && line.trim() === "";

/**
 * Puts a block into a file's text: in place of the old block, or at the end
 * after a blank line. With block null, takes the block out, with one blank
 * line next to it. Everything outside the markers is kept byte for byte.
 */
export function spliceBlock(fileText: string, block: string | null): string {
  const lines = splitLines(fileText);
  const position = findBlock(lines);

  if (!position.found && position.broken) {
    throw new BrokenBlockError();
  }

  if (!position.found) {
    if (block === null) return fileText;
    if (fileText.trim() === "") return block;
    return `${fileText}${fileText.endsWith("\n") ? "\n" : "\n\n"}${block}`;
  }

  let { start, end } = position;
  if (block === null) {
    if (isBlank(lines[start - 1])) start -= 1;
    else if (isBlank(lines[end + 1])) end += 1;
  }

  // The lines before keep their newlines; the rest of the file is kept as it was
  const before = lines.slice(0, start);
  const after = lines.slice(end + 1);
  const head = before.length > 0 ? `${before.join("\n")}\n` : "";
  const tail =
    after.length > 0
      ? `${after.join("\n")}${fileText.endsWith("\n") ? "\n" : ""}`
      : "";
  return `${head}${block ?? ""}${tail}`;
}
