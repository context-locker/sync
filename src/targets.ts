import { OPENCLAW_AGENTS_MD, TARGETS } from "./compile.js";
import { NOTES_FOLDER, NOTES_README, parseNoteTarget } from "./notes.js";
import type { CompiledHarness } from "./types.js";

/** Skill names, as the Agent Skills format and the store require. */
export const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

/** Every file and skills folder an app's sync may write. The sync scripts hold the same list. */
export function allowedTargets(harness: CompiledHarness): {
  blocks: string[];
  skillRoots: string[];
  /** A project's notes folder, for an app that works in project folders */
  notesFolder: string | null;
} {
  const targets = TARGETS[harness];
  const blocks = [targets.global];
  if (harness === "openclaw") blocks.push(OPENCLAW_AGENTS_MD);
  if (targets.projectBlock) blocks.push(targets.projectBlock);
  const skillRoots = [targets.skills];
  if (targets.projectSkills) skillRoots.push(targets.projectSkills);
  return {
    blocks,
    skillRoots,
    notesFolder: targets.projectBlock ? NOTES_FOLDER : null,
  };
}

export type ParsedTarget =
  | { kind: "block"; target: string }
  | { kind: "skill"; target: string; name: string }
  | { kind: "note"; target: string; name: string; everywhere: boolean }
  | { kind: "file"; target: string };

/** What a target names, if the app's sync may write it. */
export function parseTarget(
  harness: CompiledHarness,
  target: string,
): ParsedTarget | null {
  const { blocks, skillRoots, notesFolder } = allowedTargets(harness);
  if (blocks.includes(target)) return { kind: "block", target };
  if (notesFolder) {
    if (target === NOTES_README) return { kind: "file", target };
    const note = parseNoteTarget(target);
    if (note) return { kind: "note", target, ...note };
  }
  const slash = target.lastIndexOf("/");
  const root = target.slice(0, slash);
  const name = target.slice(slash + 1);
  if (
    slash > 0 &&
    skillRoots.includes(root) &&
    name.length <= 64 &&
    SKILL_NAME.test(name)
  ) {
    return { kind: "skill", target, name };
  }
  return null;
}

/** Whether a target sits in a project's folder rather than the app's own. */
export function isProjectTarget(target: string): boolean {
  return target.startsWith("{project}/");
}
