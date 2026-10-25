// The words compiled into every AI app's files. Agents read these, so they
// stay short and plain, and none of them may look like prompt injection.
import { BLOCK_END, BLOCK_START } from "./blocks.js";
import { plainMarkdown } from "./markdown.js";
import { NOTES_PATH, noteFileName } from "./notes.js";
import { injectionMatches } from "./threats.js";
import type {
  DocsHome,
  ItemRef,
  PreferenceInput,
  StartHereInput,
} from "./types.js";

export { plainMarkdown };

/** The most Start here entries a project's block or session-start output lists. */
export const START_HERE_MOST = 10;

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
  /** A project's map: the notes and pointers a new agent opens first */
  startHereHeading: "### Start here",
  /**
   * After the Start here entries: what to do with them, and where the rest of
   * the map is. An app that only reads its files may not have the tool
   */
  onboarding:
    "Start each session with a three-line startup brief for the user: the project, the sources you'll use, and your first step. These come from the project's map in Context Locker. When the task needs more of it, call Context Locker's project_map tool if you have it.",
  /** After a note that has no file here, which an app with the tools can open */
  readNote: "Read it with read_note, if you have it.",
  startHereOverflow: (count: number) =>
    count === 1
      ? "1 more Start here entry didn't fit here. It's in Context Locker."
      : `${count} more Start here entries didn't fit here. They're in Context Locker.`,
  startHereLeftOut: (count: number) =>
    count === 1
      ? "1 Start here entry was left out here because some AI apps refuse to load files with wording like it. It's in Context Locker."
      : `${count} Start here entries were left out here because some AI apps refuse to load files with wording like theirs. They're in Context Locker.`,
  /**
   * Where a project's lasting docs go, once a docs home is recorded. With
   * none, a file says nothing: an app that only reads its files couldn't
   * record the answer, so it would ask the user every session
   */
  docsHomeHeading: "### Docs home",
  docsHomePlace: (place: string) =>
    `Keep lasting docs in ${place}, this project's docs home, and add a link for each new one with write_note, if you have it.`,
  docsHomeNotes:
    "Keep lasting docs in Context Locker Notes, this project's docs home.",
  /**
   * After docsHomeNotes in a project's files, where the sync mirrors its
   * notes: how an app that only reads its files saves a lasting doc
   */
  notesFolder:
    "Save each as a Markdown file in .context-locker/notes, with the front matter its README shows; the next sync saves it.",
  /** When the docs home's place has wording or an address some apps refuse */
  docsHomeLeftOut:
    "Keep lasting docs in this project's docs home, and add a link for each new one with write_note, if you have it. The place is left out here because some AI apps refuse to load files with wording like it. It's in Context Locker.",
} as const;

const SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*:/;
const WEB_ADDRESS = /^https?:\/\/[^/?#\s]+\S*$/i;
const UP_A_FOLDER = /(?:^|\/)\.\.(?:[/?#]|$)/;

/**
 * Where a link goes, as a Markdown link's destination: an http or https
 * address, or a path in the repo that stays inside it. Spaces and brackets
 * are percent-encoded so the destination reads as one. Anything else, such
 * as another scheme or an absolute path, is null.
 */
export function linkDestination(url: string): string | null {
  if (url.length === 0 || url.length > 2048 || /[\p{Cc}<>\\]/u.test(url)) {
    return null;
  }
  const web = WEB_ADDRESS.test(url);
  const inRepo =
    !web &&
    !SCHEME.test(url) &&
    !url.startsWith("/") &&
    !url.startsWith("~") &&
    !UP_A_FOLDER.test(url);
  if (!web && !inRepo) return null;
  return url.replace(
    /[ ()]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

/** A summary that ends a sentence, so another can follow it. */
function sentence(text: string): string {
  const said = plainMarkdown(text);
  return said === "" || /[.!?]$/.test(said) ? said : `${said}.`;
}

/**
 * A Start here entry as a block lists it. A pointer is its title linked to
 * its address; a note is its title linked to its file in the notes folder,
 * when the app mirrors it, and otherwise its title with a word on how to read
 * it. Then its kind and its summary. Null for a pointer whose address a block
 * can't link to. With ids, each line ends with the entry's id, for an app
 * that can open it by its id.
 */
export function startHereLine(
  entry: StartHereInput,
  options: { notesFolder?: boolean; ids?: boolean } = {},
): string | null {
  const title = plainMarkdown(entry.title);
  const facts = `(${plainMarkdown(entry.kind)})`;
  const id = options.ids ? ` Id: ${entry.id}.` : "";
  if (entry.address !== null) {
    const destination = linkDestination(entry.address);
    if (destination === null) return null;
    return `- [${title}](${destination}) ${facts}: ${plainMarkdown(entry.summary)}${id}`;
  }
  if (options.notesFolder) {
    const file = `${NOTES_PATH}/${noteFileName(entry)}.md`;
    return `- [${title}](${file}) ${facts}: ${plainMarkdown(entry.summary)}${id}`;
  }
  return `- ${title} ${facts}: ${sentence(entry.summary)} ${TEXT.readNote}${id}`;
}

/**
 * The docs-home rule for a project: where to keep lasting docs, or null when
 * no docs home is recorded. A place a block can't link to, or whose wording
 * looks like prompt injection, is left out and the rule says so.
 */
export function docsHomeRule(home: DocsHome): {
  rule: string | null;
  leftOut: string | null;
} {
  if (home === null) {
    return { rule: null, leftOut: null };
  }
  if (home.kind === "notes") {
    return { rule: TEXT.docsHomeNotes, leftOut: null };
  }
  const destination = linkDestination(home.place);
  const rule =
    destination === null
      ? null
      : TEXT.docsHomePlace(`[${plainMarkdown(home.place)}](${destination})`);
  if (rule === null || injectionMatches(rule).length > 0) {
    return { rule: TEXT.docsHomeLeftOut, leftOut: home.place };
  }
  return { rule, leftOut: null };
}

/** A project's Start here entries and docs home, to compile into its block. */
export interface MapPlan {
  startHere: StartHereInput[];
  docsHome: DocsHome;
  /** Most bytes the Start here section may take, so preferences keep most of the room */
  startHereBudget: number;
  /** Whether the sync mirrors the project's notes into its notes folder for this app */
  notesFolder?: boolean;
}

/** What the map adds to a block, built before the preferences are fitted. */
interface RenderedMap {
  /** The Start here section and the onboarding line, or nothing */
  startHere: string[];
  /** The docs-home rule, or nothing when none is recorded */
  docsHome: string[];
  items: ItemRef[];
  map: RenderedBlock["map"];
}

const NO_MAP: RenderedMap = {
  startHere: [],
  docsHome: [],
  items: [],
  map: { overflow: [], leftOut: [], docsHomeLeftOut: null },
};

/**
 * The map's parts of a block. Every Start here line goes through the same
 * filter that keeps wording like prompt injection out of a shared AGENTS.md,
 * as an AI app may have written it. Entries that fit go in order, up to 10,
 * until the section's budget runs out; the rest are counted in a line.
 */
function renderMap(map: MapPlan | undefined): RenderedMap {
  if (!map) return NO_MAP;
  const listed = map.startHere.slice(0, START_HERE_MOST);
  const extra = map.startHere.slice(START_HERE_MOST);
  const lines = new Map(
    listed.map((entry) => [
      entry,
      startHereLine(entry, { notesFolder: map.notesFolder === true }),
    ]),
  );
  const leftOut = listed.filter((entry) => {
    const line = lines.get(entry);
    return !line || injectionMatches(line).length > 0;
  });
  const candidates = listed.filter((entry) => !leftOut.includes(entry));

  const section = (kept: StartHereInput[], overflowCount: number) => {
    const notes = [
      ...(overflowCount > 0 ? [TEXT.startHereOverflow(overflowCount)] : []),
      ...(leftOut.length > 0 ? [TEXT.startHereLeftOut(leftOut.length)] : []),
    ];
    return [
      TEXT.startHereHeading,
      ...(kept.length > 0
        ? [kept.map((entry) => lines.get(entry) ?? "").join("\n")]
        : []),
      ...(notes.length > 0 ? [notes.join("\n")] : []),
    ].join("\n\n");
  };

  const kept: StartHereInput[] = [];
  for (const [index, entry] of candidates.entries()) {
    const remaining = candidates.length - index - 1 + extra.length;
    if (bytes(section([...kept, entry], remaining)) > map.startHereBudget) {
      break;
    }
    kept.push(entry);
  }
  const overflow = [...candidates.slice(kept.length), ...extra];
  const home = docsHomeRule(map.docsHome);
  // With Notes as the docs home, an app that only reads its files saves a
  // lasting doc as a file in the notes folder, when the sync mirrors one
  const rule =
    home.rule !== null && map.docsHome?.kind === "notes" && map.notesFolder
      ? `${home.rule} ${TEXT.notesFolder}`
      : home.rule;
  return {
    startHere:
      map.startHere.length > 0
        ? [section(kept, overflow.length), TEXT.onboarding]
        : [],
    docsHome: rule === null ? [] : [`${TEXT.docsHomeHeading}\n\n${rule}`],
    items: kept.map(({ id, version }) => ({ id, version })),
    map: { overflow, leftOut, docsHomeLeftOut: home.leftOut },
  };
}

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
 * in About or a section comes before them, and as a plain list otherwise, as
 * before About existed.
 */
function preferenceSections(
  preferences: PreferenceInput[],
  aboutHeading: string,
  headed = false,
): string[] {
  const about = preferences.filter((preference) => preference.about);
  const rest = preferences.filter((preference) => !preference.about);
  if (about.length === 0 && !headed) {
    return rest.length > 0 ? [rest.map(preferenceLine).join("\n")] : [];
  }
  return [
    ...(about.length > 0
      ? [`${aboutHeading}\n\n${about.map(preferenceLine).join("\n")}`]
      : []),
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
  /** A project's map, whose Start here entries and docs home join its block */
  map?: MapPlan;
}

export interface RenderedBlock {
  text: string;
  items: ItemRef[];
  /** Preferences that didn't fit, in order. */
  overflow: PreferenceInput[];
  leftOut: PreferenceInput[];
  /** Start here entries that didn't fit or were left out, and a docs-home place left out */
  map: {
    overflow: StartHereInput[];
    leftOut: StartHereInput[];
    docsHomeLeftOut: string | null;
  };
}

const bytes = (text: string) => Buffer.byteLength(text, "utf8");

function assemble(
  plan: BlockPlan,
  kept: PreferenceInput[],
  overflowCount: number,
  leftOutCount: number,
  map: RenderedMap,
): string {
  const sections: string[] = [
    `${plan.title}\n\n${plan.intro}`,
    ...map.startHere,
  ];
  if (kept.length > 0) {
    sections.push(
      ...preferenceSections(
        kept,
        plan.aboutHeading ?? TEXT.aboutUser,
        map.startHere.length > 0,
      ),
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
  sections.push(...map.docsHome);
  if (plan.footer) sections.push(plan.footer);
  return `${BLOCK_START}\n${sections.join("\n\n")}\n${BLOCK_END}\n`;
}

/**
 * Builds a managed block within its byte budget. A project's Start here
 * entries and docs home go in first, then preferences in order, About first,
 * until the next one wouldn't fit; the rest are counted in a line that says
 * where they are, so nothing is cut without saying so.
 */
export function renderBlock(plan: BlockPlan): RenderedBlock {
  const map = renderMap(plan.map);
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
      map,
    );
    if (bytes(trial) > plan.budget) break;
    kept.push(preference);
  }

  const overflow = candidates.slice(kept.length);
  const text = assemble(plan, kept, overflow.length, leftOut.length, map);
  return {
    text,
    items: [...map.items, ...kept.map(({ id, version }) => ({ id, version }))],
    overflow,
    leftOut,
    map: map.map,
  };
}

/** The text a session-start hook prints for a project the repo isn't linked to. */
export function renderContext(
  projectName: string,
  preferences: PreferenceInput[],
  budget: number,
  plan?: MapPlan,
): RenderedBlock {
  const map = renderMap(plan);
  const kept: PreferenceInput[] = [];
  const intro = TEXT.personalIntro(projectName);
  const ordered = aboutFirst(preferences);
  const headed = map.startHere.length > 0;
  const mapped = headed || map.docsHome.length > 0;
  // Sections under headings get a blank line between them; a plain list
  // with nothing else stays as compact as it always was
  const build = (list: PreferenceInput[], overflowCount: number) => {
    const spaced = mapped || list.some((preference) => preference.about);
    return (
      [
        intro,
        ...map.startHere,
        ...(list.length > 0
          ? preferenceSections(list, TEXT.aboutProject, headed)
          : mapped && overflowCount === 0
            ? [TEXT.noPreferences]
            : []),
        ...(overflowCount > 0 ? [TEXT.overflow(overflowCount, null)] : []),
        ...map.docsHome,
      ].join(spaced ? "\n\n" : "\n") + "\n"
    );
  };

  for (const [index, preference] of ordered.entries()) {
    const remaining = ordered.length - index - 1;
    if (bytes(build([...kept, preference], remaining)) > budget) break;
    kept.push(preference);
  }
  const overflow = ordered.slice(kept.length);
  return {
    text: build(kept, overflow.length),
    items: [...map.items, ...kept.map(({ id, version }) => ({ id, version }))],
    overflow,
    leftOut: [],
    map: map.map,
  };
}
