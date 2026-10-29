/** The AI apps that get compiled files. Others reach Context Locker over MCP. */
export const COMPILED_HARNESSES = [
  "claude-code",
  "codex",
  "hermes",
  "openclaw",
] as const;

export type CompiledHarness = (typeof COMPILED_HARNESSES)[number];

export function isCompiledHarness(value: string): value is CompiledHarness {
  return (COMPILED_HARNESSES as readonly string[]).includes(value);
}

/** One file in a skill folder, as the store keeps it. */
export interface SkillFile {
  path: string;
  content: string;
  encoding: "utf8" | "base64";
}

/** An item and the version of it that was compiled. */
export interface ItemRef {
  id: string;
  version: number;
}

export interface PreferenceInput extends ItemRef {
  name: string;
  /** One or more lines, with no empty ones */
  text: string;
  /** In About: a fact about the person or their work, which goes first */
  about?: boolean;
}

export interface SkillInput extends ItemRef {
  name: string;
  files: SkillFile[];
}

/**
 * One of a project's Start here entries, the few a new agent opens first: a
 * note, or a pointer to the one file or page that holds the content. Its
 * title and summary may come from an AI app.
 */
export interface StartHereInput extends ItemRef {
  title: string;
  /** What it is, such as runbook or code */
  kind: string;
  /** What it holds, in one line */
  summary: string;
  /**
   * A pointer's address: an http or https address, or a path in the repo.
   * Null for a note, which holds its own text
   */
  address: string | null;
  /** A note's name, which its file in the notes folder is named after */
  name: string;
}

/**
 * A note as a project's notes folder holds it: a Markdown document and its
 * front matter, in a file named after the note. Pointers hold no text, so
 * they have no files.
 */
export interface NoteInput extends ItemRef {
  /** The note's name, such as release-plan, which its file is named after */
  name: string;
  title: string;
  /** plan, spec, decision, research, idea, log, profile, design, runbook or onboarding */
  kind: string;
  /** How AI apps should use it: source-of-truth, reference or historic */
  useAs: string;
  /** What it holds, in one line */
  summary: string;
  tags: string[];
  /** The note, in Markdown */
  text: string;
  /** Whether it applies everywhere, rather than to the project being synced */
  everywhere: boolean;
  /**
   * For one that applies to more than one project: their names, its own
   * first, which its file lists in each project's notes folder (G1-68)
   */
  appliesTo?: readonly string[];
}

/**
 * Where a project's lasting docs go: Context Locker Notes, a place such as a
 * folder in the repo or a web address, or null when the owner hasn't said yet.
 */
export type DocsHome =
  { kind: "notes" } | { kind: "place"; place: string } | null;

/**
 * Where a project's compiled files go. "repo": into the repo's own files,
 * because the repo is linked to this workspace with a .contextlocker.json.
 * "personal": nowhere in the repo; the session-start output carries them.
 */
export type ProjectLayer = "repo" | "personal";

/** A recorded location is a map, never a grant of access or a mirrored copy. */
export interface DocsLocation {
  id: string;
  name: string;
  kind: "notes" | "place";
  place: string | null;
  purpose: string;
  is_default: boolean;
}

export interface CompileInput {
  harness: CompiledHarness;
  /** Null for the global sync, which carries everything that applies everywhere. */
  project: { id: string; name: string; layer: ProjectLayer } | null;
  /**
   * The preferences for this sync only: the ones that apply everywhere for the
   * global sync, or the project's own versions for a project sync. In order.
   */
  preferences: PreferenceInput[];
  /** The skills for this sync, scoped the same way. */
  skills: SkillInput[];
  /**
   * For a project sync: its Start here entries, notes and pointers, in the
   * order they're listed. A block lists 10 at most.
   */
  startHere?: StartHereInput[];
  /** For a project sync: its docs home. Left out, none is recorded. */
  docsHome?: DocsHome;
  docsLocations?: DocsLocation[];
  /**
   * For a project sync: its live notes and the ones that apply everywhere,
   * historic ones too, which its notes folder mirrors. Pointers are left out.
   */
  notes?: NoteInput[];
  /** For a project sync: the workspace's tag list, which the notes folder's README gives. */
  tags?: string[];
}

/**
 * What a compiler asks the sync script to write. Targets start with a root in
 * braces, such as {claude} or {project}, which the script resolves on the
 * computer it runs on.
 */
export type Output =
  | {
      kind: "block";
      /** A file holding a managed block between Context Locker's markers. */
      target: string;
      /** The whole block, markers included, ending with a newline. */
      text: string;
      items: ItemRef[];
    }
  | {
      kind: "skill";
      /** The skill's folder. */
      target: string;
      files: SkillFile[];
      item: ItemRef;
    }
  | {
      kind: "context";
      /** Printed at the start of each session instead of written to a file. */
      text: string;
      items: ItemRef[];
    }
  | {
      kind: "note";
      /** A note's file in a project's notes folder. */
      target: string;
      /** The whole file: its front matter, then the note. */
      text: string;
      item: ItemRef;
    }
  | {
      kind: "file";
      /** A whole file Context Locker writes, such as the notes folder's README. */
      target: string;
      text: string;
    };

export interface Compiled {
  outputs: Output[];
  /** Plain sentences about anything a cap or a rule left out. */
  notes: string[];
}
