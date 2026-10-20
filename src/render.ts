// The words compiled into every AI app's files. Agents read these, so they
// stay short and plain, and none of them may look like prompt injection.
import { BLOCK_END, BLOCK_START } from "./blocks.js";
import { injectionMatches } from "./threats.js";
import type { ItemRef, PreferenceInput } from "./types.js";

export const TEXT = {
  globalTitle: "## Context Locker",
  globalIntro:
    "Your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  /** The intro of OpenClaw's second file, for preferences that didn't fit in USER.md. */
  moreIntro:
    "More of your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  noPreferences: "No preferences saved yet.",
  /** Headings, used only when some preferences are in About */
  aboutUser: "### About the user",
  aboutProject: "### About this project",
  preferencesHeading: "### Preferences",
  projectTitle: (name: string) => `## Context Locker: ${name}`,
  projectIntro:
    "Preferences for this project, kept in sync by Context Locker. Where one has the same name as a general preference, it replaces that one here. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  personalIntro: (name: string) =>
    `Context Locker preferences for ${name}. Where one has the same name as a general preference, it replaces that one here. To change one, ask your user to edit it in Context Locker.`,
  endOfTask:
    "When you finish a task, ask yourself: did a preference or skill mislead you or force a workaround? If so, fix its line here or the skill's files, and say why in your reply. The next sync saves the fix in Context Locker, unless it needs approval first.",
  /** The same question, in a file that doesn't hold all the preference lines. */
  endOfTaskIn: (where: string) =>
    `When you finish a task, ask yourself: did a preference or skill mislead you or force a workaround? If so, fix its line in ${where}, or the skill's files, and say why in your reply. The next sync saves the fix in Context Locker, unless it needs approval first.`,
  overflow: (count: number, where: string | null) =>
    count === 1
      ? `1 more preference didn't fit in this file. ${where ? `It's in ${where}.` : "It's in Context Locker."}`
      : `${count} more preferences didn't fit in this file. ${where ? `They're in ${where}.` : "They're in Context Locker."}`,
  leftOut: (count: number) =>
    count === 1
      ? "1 preference was left out of this file because some AI apps refuse to load files with wording like it. It's in Context Locker."
      : `${count} preferences were left out of this file because some AI apps refuse to load files with wording like theirs. They're in Context Locker.`,
} as const;

/**
 * Intros the compilers wrote before. A file edited from an older copy of its
 * block can still hold one, and reading the edit skips it like today's.
 */
export const OLD_INTROS: readonly string[] = [
  "Your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync sends your edit for review.",
  "Preferences for this project, kept in sync by Context Locker. Where one has the same name as a general preference, it replaces that one here. To change one, edit its line here. The next sync sends your edit for review.",
  "More of your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync sends your edit for review.",
];

/**
 * A preference as one list item. Any further lines are indented under the
 * first, so the item reads as one and an edit to it can be read back.
 */
export function preferenceLine(preference: PreferenceInput): string {
  return `- ${preference.name}: ${preference.text.replace(/\n/g, "\n  ")}`;
}

/** About first, then the rest, each in the order given. */
function aboutFirst(preferences: PreferenceInput[]): PreferenceInput[] {
  return [
    ...preferences.filter((preference) => preference.about),
    ...preferences.filter((preference) => !preference.about),
  ];
}

/**
 * The preference lines, under About and Preferences headings when some are
 * in About, and as a plain list when none are, as before About existed.
 */
function preferenceSections(
  preferences: PreferenceInput[],
  aboutHeading: string,
): string[] {
  const about = preferences.filter((preference) => preference.about);
  const rest = preferences.filter((preference) => !preference.about);
  if (about.length === 0) {
    return rest.length > 0 ? [rest.map(preferenceLine).join("\n")] : [];
  }
  return [
    `${aboutHeading}\n\n${about.map(preferenceLine).join("\n")}`,
    ...(rest.length > 0
      ? [`${TEXT.preferencesHeading}\n\n${rest.map(preferenceLine).join("\n")}`]
      : []),
  ];
}

export interface BlockPlan {
  title: string;
  intro: string;
  preferences: PreferenceInput[];
  /** Shown when there are no preferences at all. */
  empty?: string;
  /** Most bytes the whole block may take, markers included. */
  budget: number;
  /** Where preferences that don't fit can be found, or null for Context Locker itself. */
  overflowTo?: string | null;
  /** Leave out preferences whose wording looks like prompt injection. */
  shared?: boolean;
  footer?: string;
  /** The heading over About, when some preferences are in it. About the user, unless set. */
  aboutHeading?: string;
}

export interface RenderedBlock {
  text: string;
  items: ItemRef[];
  /** Preferences that didn't fit, in order. */
  overflow: PreferenceInput[];
  leftOut: PreferenceInput[];
}

const bytes = (text: string) => Buffer.byteLength(text, "utf8");

function assemble(
  plan: BlockPlan,
  kept: PreferenceInput[],
  overflowCount: number,
  leftOutCount: number,
): string {
  const sections: string[] = [`${plan.title}\n\n${plan.intro}`];
  if (kept.length > 0) {
    sections.push(
      ...preferenceSections(kept, plan.aboutHeading ?? TEXT.aboutUser),
    );
  } else if (plan.empty && overflowCount === 0 && leftOutCount === 0) {
    sections.push(plan.empty);
  }
  const notes: string[] = [];
  if (overflowCount > 0) {
    notes.push(TEXT.overflow(overflowCount, plan.overflowTo ?? null));
  }
  if (leftOutCount > 0) notes.push(TEXT.leftOut(leftOutCount));
  if (notes.length > 0) sections.push(notes.join("\n"));
  if (plan.footer) sections.push(plan.footer);
  return `${BLOCK_START}\n${sections.join("\n\n")}\n${BLOCK_END}\n`;
}

/**
 * Builds a managed block within its byte budget. Preferences go in order,
 * About first, until the next one wouldn't fit; the rest are counted in a
 * line that says where they are, so nothing is cut without saying so.
 */
export function renderBlock(plan: BlockPlan): RenderedBlock {
  const leftOut = plan.shared
    ? plan.preferences.filter(
        (preference) => injectionMatches(preferenceLine(preference)).length > 0,
      )
    : [];
  const candidates = aboutFirst(
    plan.preferences.filter((preference) => !leftOut.includes(preference)),
  );

  const kept: PreferenceInput[] = [];
  for (const [index, preference] of candidates.entries()) {
    const remaining = candidates.length - index - 1;
    const trial = assemble(
      plan,
      [...kept, preference],
      remaining,
      leftOut.length,
    );
    if (bytes(trial) > plan.budget) break;
    kept.push(preference);
  }

  const overflow = candidates.slice(kept.length);
  const text = assemble(plan, kept, overflow.length, leftOut.length);
  return {
    text,
    items: kept.map(({ id, version }) => ({ id, version })),
    overflow,
    leftOut,
  };
}

/** The text a session-start hook prints for a project the repo isn't linked to. */
export function renderContext(
  projectName: string,
  preferences: PreferenceInput[],
  budget: number,
): RenderedBlock {
  const kept: PreferenceInput[] = [];
  const intro = TEXT.personalIntro(projectName);
  const ordered = aboutFirst(preferences);
  // Sections under headings get a blank line between them; a plain list
  // stays as compact as it always was
  const build = (list: PreferenceInput[], overflowCount: number) =>
    [
      intro,
      ...preferenceSections(list, TEXT.aboutProject),
      ...(overflowCount > 0 ? [TEXT.overflow(overflowCount, null)] : []),
    ].join(list.some((preference) => preference.about) ? "\n\n" : "\n") + "\n";

  for (const [index, preference] of ordered.entries()) {
    const remaining = ordered.length - index - 1;
    if (bytes(build([...kept, preference], remaining)) > budget) break;
    kept.push(preference);
  }
  const overflow = ordered.slice(kept.length);
  return {
    text: build(kept, overflow.length),
    items: kept.map(({ id, version }) => ({ id, version })),
    overflow,
    leftOut: [],
  };
}
