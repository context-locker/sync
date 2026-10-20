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
 * Where a project's compiled files go. "repo": into the repo's own files,
 * because the repo is linked to this workspace with a .contextlocker.json.
 * "personal": nowhere in the repo; the session-start output carries them.
 */
export type ProjectLayer = "repo" | "personal";

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
    };

export interface Compiled {
  outputs: Output[];
  /** Plain sentences about anything a cap or a rule left out. */
  notes: string[];
}
