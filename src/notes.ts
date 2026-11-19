// A note as a Markdown file with YAML front matter, as an export and
// notes-move-out write it, and the answer the API gives for an app's own
// memory file. Computers keep no copies of notes: an agent reads them from
// Context Locker with the sync script's notes commands (CLK-423).
import type { NoteInput } from "./types.js";

/** What a note's file may hold, as the store's limits set it. */
export const NOTE_FILE_RULES = Object.freeze({
  /**
   * A note's text, in bytes of UTF-8 (G1-17). The sync scripts hold an
   * app's own memory files to the same.
   */
  bytes: 512 * 1024,
});

// A file name no note gets: the README's, which a file system that ignores
// case would take for the same file, and the names Windows keeps for devices,
// which no file there can have
const RESERVED = /^(?:readme|con|prn|aux|nul|com[0-9]|lpt[0-9])$/;

/** The name of a note's file, without .md: its own name, or with part of its id when that name is kept. */
export function noteFileName(note: { name: string; id: string }): string {
  return RESERVED.test(note.name)
    ? `${note.name}-${note.id.slice(0, 8)}`
    : note.name;
}

// Characters a person can't see or that break a line, which a quoted string
// spells out as escapes so the front matter shows them
const SPELLED_OUT = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Cs}]/gu;

/**
 * Text as a double-quoted YAML string. JSON's strings are YAML's, so quotes,
 * backslashes and colons can't break the front matter, and any character
 * people can't see is written as an escape.
 */
export function yamlString(value: string): string {
  return JSON.stringify(value).replace(SPELLED_OUT, (character) => {
    const point = character.codePointAt(0) ?? 0;
    return point > 0xffff
      ? `\\U${point.toString(16).padStart(8, "0")}`
      : `\\u${point.toString(16).padStart(4, "0")}`;
  });
}

/**
 * A note's file: front matter with every string double-quoted, then a blank
 * line and the note. The fields come in a fixed order, so the same note
 * always makes the same file. Without ids, the file leaves out the note's id
 * and version, as a note moved out of Context Locker into a repo is the
 * repo's own file from then on.
 */
export function renderNoteFile(
  note: NoteInput,
  /** everywhere, its project's name, or every project's when there are several */
  appliesTo: string | readonly string[],
  options: { ids?: boolean } = {},
): string {
  const front = [
    `title: ${yamlString(note.title)}`,
    `type: ${yamlString(note.kind)}`,
    `use_as: ${yamlString(note.useAs)}`,
    `summary: ${yamlString(note.summary)}`,
    `tags: [${note.tags.map(yamlString).join(", ")}]`,
    typeof appliesTo === "string" || appliesTo.length === 1
      ? `applies_to: ${yamlString(typeof appliesTo === "string" ? appliesTo : (appliesTo[0] ?? ""))}`
      : `applies_to: [${appliesTo.map(yamlString).join(", ")}]`,
    // Only a note that copies a document says where from (CLK-442)
    ...(note.cameFrom ? [`came_from: ${yamlString(note.cameFrom)}`] : []),
    ...(options.ids === false
      ? []
      : [`id: ${yamlString(note.id)}`, `version: ${note.version}`]),
  ];
  return `---\n${front.join("\n")}\n---\n${note.text === "" ? "" : `\n${note.text}\n`}`;
}

/**
 * How the API answers an app's own memory file the sync sent (G1-299): a
 * header line, a line with what it did, the note's id and version, the hash
 * of the file it keeps and where it goes, then that file's bytes. A shell
 * script can read it with read and tail, and nothing has to be unescaped.
 *
 *   context-locker-note 1
 *   saved <note id> <version> <sha256> <target>
 *   <the file>
 *
 * "saved" is a new version or a new note; "same" means the file held nothing
 * new, and the file is the note as it stands.
 */
export const NOTE_REPLY_HEADER = "context-locker-note 1";

export interface NoteReply {
  status: "saved" | "same";
  id: string;
  version: number;
  hash: string;
  target: string;
  file: Buffer;
}

export function writeNoteReply(
  reply: Omit<NoteReply, "file"> & { file: string },
): Buffer {
  return Buffer.concat([
    Buffer.from(
      `${NOTE_REPLY_HEADER}\n${reply.status} ${reply.id} ${reply.version} ${reply.hash} ${reply.target}\n`,
      "utf8",
    ),
    Buffer.from(reply.file, "utf8"),
  ]);
}

const REPLY_LINE =
  /^(saved|same) ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ([1-9][0-9]{0,9}) ([0-9a-f]{64}) (\S+)$/;

/** Reads a reply {@link writeNoteReply} made, as the scripts do, or null. */
export function parseNoteReply(data: Buffer): NoteReply | null {
  const first = data.indexOf(0x0a);
  const second = first === -1 ? -1 : data.indexOf(0x0a, first + 1);
  if (second === -1) return null;
  if (data.subarray(0, first).toString("utf8") !== NOTE_REPLY_HEADER) {
    return null;
  }
  const match = REPLY_LINE.exec(
    data.subarray(first + 1, second).toString("utf8"),
  );
  if (!match) return null;
  return {
    status: match[1] as "saved" | "same",
    id: match[2] as string,
    version: Number(match[3]),
    hash: match[4] as string,
    target: match[5] as string,
    file: data.subarray(second + 1),
  };
}
