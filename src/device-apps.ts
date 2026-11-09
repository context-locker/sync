// Each AI app that syncs files on a computer, as data (G1-299, decided by
// Alan on 8 Nov 2026): its name, where its files go and the file it loads
// in every session, how much its block may take there, where it keeps its
// own memory, and the events its hooks run on. Adding a persistent agent
// that syncs files is an entry here: TARGETS, each block's budget,
// MEMORY_PLACES and the hook events come from it. The sync scripts keep
// marked copies of what they need, which tests keep equal. How an app
// connects in the first place, its route, is in KNOWN_APPS in
// packages/shared, which this package can't import.
import type { CompiledHarness } from "./types.js";

export interface MemoryPlace {
  /**
   * A file, or a folder whose files count, under the app's own folder; a *
   * stands for any one folder, such as each of Claude Code's projects
   */
  path: string;
  /** For a folder: how deep its files go, 1 for only its own */
  depth?: number;
  /** For a file that holds Context Locker's block too: its note holds the rest */
  outsideBlock?: true;
}

export interface DeviceApp {
  name: string;
  /** Where its files go; roots in braces are resolved by the sync script */
  targets: {
    /** The file it loads in every session, which holds Context Locker's block */
    global: string;
    skills: string;
    projectBlock: string | null;
    projectSkills: string | null;
  };
  /** The most bytes its global block may take, markers included */
  budget: number;
  /** Where it keeps its own memory, which syncs with its connection's (G1-299) */
  memory: readonly MemoryPlace[];
  /** The events its session hook runs on */
  hooks: readonly string[];
  /** The event its per-prompt hook runs on, where it has one (G1-271) */
  promptHook?: string;
}

export const DEVICE_APPS: Readonly<Record<CompiledHarness, DeviceApp>> =
  Object.freeze({
    "claude-code": {
      name: "Claude Code",
      targets: {
        global: "{claude}/rules/context-locker.md",
        skills: "{claude}/skills",
        projectBlock: "{project}/.claude/rules/context-locker.md",
        projectSkills: "{project}/.claude/skills",
      },
      // Claude Code loads rule files whole; this keeps 100 one-line
      // preferences with room to spare
      budget: 40_000,
      memory: [{ path: "{claude}/projects/*/memory", depth: 3 }],
      hooks: ["startup", "resume", "clear", "compact"],
      promptHook: "UserPromptSubmit",
    },
    codex: {
      name: "Codex",
      targets: {
        global: "{codex}/AGENTS.md",
        skills: "{agents}/skills",
        projectBlock: "{project}/AGENTS.md",
        projectSkills: "{project}/.agents/skills",
      },
      // Codex loads the global AGENTS.md whole and re-reads it every turn
      budget: 40_000,
      memory: [{ path: "{codex}/memories", depth: 3 }],
      hooks: ["startup", "resume", "clear", "compact"],
      promptHook: "UserPromptSubmit",
    },
    hermes: {
      name: "Hermes",
      targets: {
        // Its persona: the only file Hermes loads in every session, wherever
        // it runs, which keeps the Everywhere block too
        global: "{hermes}/SOUL.md",
        skills: "{hermes}/skills",
        projectBlock: "{project}/AGENTS.md",
        projectSkills: null,
      },
      // Hermes trims SOUL.md past 20,000 characters, persona included, so
      // the block takes this or the room the sync script measures after the
      // file's own text, whichever is smaller (G1-309)
      budget: 14_000,
      memory: [
        { path: "{hermes}/SOUL.md", outsideBlock: true },
        { path: "{hermes}/USER.md" },
        { path: "{hermes}/MEMORY.md" },
        { path: "{hermes}/memories", depth: 1 },
      ],
      hooks: ["on_session_start", "post_compaction"],
      promptHook: "pre_llm_call",
    },
    openclaw: {
      name: "OpenClaw",
      targets: {
        // Its workspace's AGENTS.md, which OpenClaw loads at every session
        // start, with the room USER.md hasn't; USER.md stays the person's
        global: "{openclaw}/AGENTS.md",
        skills: "{agents}/skills",
        projectBlock: null,
        projectSkills: null,
      },
      // OpenClaw trims bootstrap files past 20,000 characters, so the block
      // takes this or the room the sync script measures after the file's
      // own text, whichever is smaller (G1-309)
      budget: 14_000,
      // Its daily logs, in memory/, stay out, as raw logs
      memory: [
        { path: "{openclaw}/AGENTS.md", outsideBlock: true },
        { path: "{openclaw}/SOUL.md" },
        { path: "{openclaw}/IDENTITY.md" },
        { path: "{openclaw}/USER.md" },
        { path: "{openclaw}/MEMORY.md" },
      ],
      hooks: [
        "gateway:startup",
        "command:new",
        "command:reset",
        "session:compact:before",
      ],
    },
  });

/** One thing every device app has, by app, such as its targets */
export function byApp<T>(
  pick: (app: DeviceApp) => T,
): Readonly<Record<CompiledHarness, T>> {
  return Object.freeze(
    Object.fromEntries(
      Object.entries(DEVICE_APPS).map(([id, app]) => [id, pick(app)]),
    ) as Record<CompiledHarness, T>,
  );
}
