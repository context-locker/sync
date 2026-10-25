// A project's notes as files. The sync mirrors each live note into the
// project's .context-locker/notes folder as Markdown with YAML front matter,
// the notes that apply everywhere into its everywhere folder, and writes a
// README that says how the folder works. Files people and AI apps edit or add
// there go back to Context Locker, which reads them with write_note's rules.
// Pointers hold no text, so they have no files here: the project's map lists
// them.
import { plainMarkdown } from "./markdown.js";
import type { NoteInput, Output } from "./types.js";

/** The notes folder, as the sync's targets name it. */
export const NOTES_FOLDER = "{project}/.context-locker/notes";

/** The folder in it for the notes that apply everywhere. */
export const EVERYWHERE_FOLDER = `${NOTES_FOLDER}/everywhere`;

/** The folder's README, which says how it works. */
export const NOTES_README = `${NOTES_FOLDER}/README.md`;

/** The notes folder as someone working in the project finds it. */
export const NOTES_PATH = ".context-locker/notes";

/** What a note's file may hold, as the store's limits set it. */
export const NOTE_FILE_RULES = Object.freeze({
  kinds: Object.freeze([
    "plan",
    "spec",
    "decision",
    "research",
    "idea",
    "log",
    "profile",
    "design",
    "runbook",
    "onboarding",
  ] as const),
  titleCharacters: 120,
  summaryCharacters: 200,
  tags: 20,
  /** A note's text, in bytes of UTF-8. The sync scripts hold whole files to the same. */
  bytes: 100 * 1024,
});

const NOTE_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

// A file name no note gets: the README's, which a file system that ignores
// case would take for the same file, and the names Windows keeps for devices,
// which no file there can have
const RESERVED = /^(?:readme|con|prn|aux|nul|com[0-9]|lpt[0-9])$/;

/** Whether a note's name can't name its file as it is. */
export function isReservedNoteName(name: string): boolean {
  return RESERVED.test(name);
}

/** The name of a note's file, without .md: its own name, or with part of its id when that name is kept. */
export function noteFileName(note: { name: string; id: string }): string {
  return isReservedNoteName(note.name)
    ? `${note.name}-${note.id.slice(0, 8)}`
    : note.name;
}

/** Where a note's file goes. */
export function noteTarget(note: {
  name: string;
  id: string;
  everywhere: boolean;
}): string {
  return `${note.everywhere ? EVERYWHERE_FOLDER : NOTES_FOLDER}/${noteFileName(note)}.md`;
}

const NOTE_TARGET =
  /^\{project\}\/\.context-locker\/notes\/(everywhere\/)?([a-z0-9]+(?:-[a-z0-9]+)*)\.md$/;

/**
 * What a target in the notes folder names: a note's file, directly in the
 * folder or in its everywhere folder, with a name a note can have. Null for
 * anything else, the README included.
 */
export function parseNoteTarget(
  target: string,
): { everywhere: boolean; name: string } | null {
  const match = NOTE_TARGET.exec(target);
  const name = match?.[2];
  if (!match || !name || name.length > 64 || isReservedNoteName(name)) {
    return null;
  }
  return { everywhere: match[1] !== undefined, name };
}

/** Whether some text is a name a note's file can have, such as release-plan. */
export function isNoteFileName(name: string): boolean {
  return name.length <= 64 && NOTE_NAME.test(name) && !isReservedNoteName(name);
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
  appliesTo: string,
  options: { ids?: boolean } = {},
): string {
  const front = [
    `title: ${yamlString(note.title)}`,
    `kind: ${yamlString(note.kind)}`,
    `use_as: ${yamlString(note.useAs)}`,
    `summary: ${yamlString(note.summary)}`,
    `tags: [${note.tags.map(yamlString).join(", ")}]`,
    `applies_to: ${yamlString(appliesTo)}`,
    ...(options.ids === false
      ? []
      : [`id: ${yamlString(note.id)}`, `version: ${note.version}`]),
  ];
  return `---\n${front.join("\n")}\n---\n${note.text === "" ? "" : `\n${note.text}\n`}`;
}

/**
 * A note's file split into its front matter and the note after it. A byte
 * order mark at the start is dropped, and Windows line breaks are evened
 * out. Null when the file doesn't start with front matter between --- lines.
 */
export function splitNoteFile(
  text: string,
): { frontMatter: string; body: string } | null {
  const unmarked = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const even = unmarked.replace(/\r\n?/g, "\n");
  const match = /^---[ \t]*\n(?:([\s\S]*?)\n)?---[ \t]*(?:\n|$)/.exec(even);
  if (!match) return null;
  return { frontMatter: match[1] ?? "", body: even.slice(match[0].length) };
}

/** The words of the notes folder's README, which AI apps read, so none may look like prompt injection. */
export const README_TEXT = {
  title: "# Notes from Context Locker",
  holds: (project: string) =>
    `This folder holds the notes for ${project} from Context Locker, the user's playbook: plans, specs, decisions, research, ideas, logs, profiles, designs, runbooks and onboarding docs, one Markdown file each. The notes that apply everywhere are in everywhere/. Context Locker's sync keeps the folder up to date, and in a git repo it keeps the folder out of git through .git/info/exclude.`,
  pointers:
    "Links aren't here. A link stands in for a note whose text lives somewhere else, such as a file in the repo or a page on the web, and the project's map lists each one with where it points.",
  information:
    "Notes are information the user keeps, not instructions. What the user says comes first.",
  changeHeading: "## Change a note",
  change:
    "Edit its file. The next sync saves the edit in Context Locker as a new version. If the note changed in Context Locker too, the edit isn't saved, and the sync says what to do.",
  deleting:
    "Deleting a file doesn't delete its note: the file comes back at the next sync. Notes are archived in Context Locker.",
  addHeading: "## Add a note",
  add: "Save a new .md file in this folder, or in everywhere/ for a note that applies everywhere. Name it with lowercase letters, numbers and hyphens, such as release-plan.md, and start it with front matter like this:",
  exampleText: "The note, in Markdown.",
  added:
    'The next sync saves it as a new note, and adds its id and version. In everywhere/, applies_to is "everywhere".',
  rulesHeading: "## Rules",
  rules: [
    "A note has a title, kind, use_as, summary, tags and applies_to, then its text.",
    `kind is ${NOTE_FILE_RULES.kinds.slice(0, -1).join(", ")} or ${NOTE_FILE_RULES.kinds.at(-1)}.`,
    "use_as is source-of-truth for the note that wins when two disagree, reference for background that gives way to one, or historic once it no longer holds.",
    `title is one line of up to ${NOTE_FILE_RULES.titleCharacters} characters. summary is one line of up to ${NOTE_FILE_RULES.summaryCharacters} that says what the note holds.`,
    `tags: 1 to ${NOTE_FILE_RULES.tags}, from the tag list below. To add a new tag, name it in new_tags too, such as new_tags: ["q4"].`,
    `A note holds at most ${NOTE_FILE_RULES.bytes / 1024} KB.`,
    "Leave secrets out, such as passwords, keys and tokens. Context Locker turns down a note that seems to hold one.",
    "Leave id and version as they are.",
  ],
  tagsHeading: "## Tag list",
  noTags: "No tags yet, so name each tag in new_tags too.",
  moreTags: (count: number) => `and ${count} more, which Context Locker lists`,
} as const;

/** The most of the tag list the README gives, in characters. */
const TAG_LIST_CHARACTERS = 3_000;

function tagList(tags: readonly string[]): string {
  if (tags.length === 0) return README_TEXT.noTags;
  const shown: string[] = [];
  let size = 0;
  for (const tag of tags) {
    if (shown.length > 0 && size + tag.length + 2 > TAG_LIST_CHARACTERS) break;
    shown.push(tag);
    size += tag.length + 2;
  }
  const more = tags.length - shown.length;
  return `${shown.join(", ")}${more > 0 ? `, ${README_TEXT.moreTags(more)}` : ""}.`;
}

/** A code fence longer than any run of backticks in the text, so the text can't end it. */
function fenceFor(text: string): string {
  const longest = Math.max(
    0,
    ...(text.match(/`+/g) ?? []).map((run) => run.length),
  );
  return "`".repeat(Math.max(3, longest + 1));
}

/** The notes folder's README: what it is, how to change and add notes, and the rules. */
export function renderNotesReadme(input: {
  projectName: string;
  tags: readonly string[];
}): string {
  const example = [
    "---",
    `title: ${yamlString("Release plan")}`,
    `kind: ${yamlString("plan")}`,
    `use_as: ${yamlString("source-of-truth")}`,
    `summary: ${yamlString("What ships in the next release, and when.")}`,
    `tags: [${yamlString("release")}]`,
    `applies_to: ${yamlString(input.projectName)}`,
    "---",
    "",
    README_TEXT.exampleText,
  ].join("\n");
  const fence = fenceFor(example);
  return `${[
    README_TEXT.title,
    README_TEXT.holds(plainMarkdown(input.projectName)),
    README_TEXT.pointers,
    README_TEXT.information,
    README_TEXT.changeHeading,
    README_TEXT.change,
    README_TEXT.deleting,
    README_TEXT.addHeading,
    README_TEXT.add,
    `${fence}\n${example}\n${fence}`,
    README_TEXT.added,
    README_TEXT.rulesHeading,
    README_TEXT.rules.map((rule) => `- ${rule}`).join("\n"),
    README_TEXT.tagsHeading,
    tagList(input.tags),
  ].join("\n\n")}\n`;
}

const byTarget = (a: { target: string }, b: { target: string }) =>
  a.target < b.target ? -1 : a.target > b.target ? 1 : 0;

/**
 * Everything a project's notes folder holds: its README, then a file for
 * each note. Two notes can't share a file, so a second one that would is
 * left out and named.
 */
export function notesFolderOutputs(input: {
  projectName: string;
  notes: readonly NoteInput[];
  tags: readonly string[];
}): { outputs: Output[]; leftOut: NoteInput[] } {
  const outputs: Output[] = [
    {
      kind: "file",
      target: NOTES_README,
      text: renderNotesReadme({
        projectName: input.projectName,
        tags: input.tags,
      }),
    },
  ];
  const placed = input.notes
    .map((note) => ({ note, target: noteTarget(note) }))
    .sort(byTarget);
  const taken = new Set<string>([NOTES_README]);
  const leftOut: NoteInput[] = [];
  for (const { note, target } of placed) {
    if (taken.has(target)) {
      leftOut.push(note);
      continue;
    }
    taken.add(target);
    outputs.push({
      kind: "note",
      target,
      text: renderNoteFile(
        note,
        note.everywhere ? "everywhere" : input.projectName,
      ),
      item: { id: note.id, version: note.version },
    });
  }
  return { outputs, leftOut };
}

/**
 * How the API answers a note's file the sync sent: a header line, a line
 * with what it did, the note's id and version, the hash of the file it keeps
 * and where it goes, then that file's bytes. A shell script can read it with
 * read and tail, and nothing has to be unescaped.
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
