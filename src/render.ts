// The words compiled into every AI app's files. Agents read these, so they
// stay short and plain, and none of them may look like prompt injection.
import { BLOCK_END, BLOCK_START } from "./blocks.js";
import { plainMarkdown } from "./markdown.js";
import { NOTES_PATH, noteFileName } from "./notes.js";
import { oneAppPlace } from "./one-app-places.js";
import { injectionMatches } from "./threats.js";
import type {
  DocsHome,
  DocsLocation,
  ItemRef,
  PreferenceInput,
  StartHereInput,
  WorkPlace,
} from "./types.js";

export { plainMarkdown };

/** The most Start here entries a project's block or session-start output lists. */
export const START_HERE_MOST = 10;

/**
 * Said in a playbook's block when its owner allows personal details in it
 * (G1-246): what apps may keep there. Nothing scans for personal details.
 */
const PERSONAL_DETAILS =
  "This project allows personal details: keep what the person shares about themselves here, health and finances included, and what they share about the people in their life for the help they ask for, noting that they shared it. Don't go looking for more.";

/**
 * How an app asks the user (G1-277): the ask protocol, in at most 120
 * words, so an app that never read the plan asks the same way. Said beside
 * the board rules in get_context and playbook_map, the setup steps and the
 * sync script's tickets help; the standing rules say it in two sentences.
 */
export const ASK_PROTOCOL =
  "Assume first: if a reasonable assumption settles an uncertainty, the result wouldn't change much and no preference says to ask, decide, do the work and record it with write_ticket's assumed. One decision per ask, one open ask per task: split compound uncertainties, asking first what unblocks most. Do the reading and attach the evidence; the user decides, never researches. Choices are outcomes, one recommended with why; for a yes or their own step, use kind approval or your_action. Finished work and news go on the task, never in an ask; nothing they must act on goes in a comment. Answer Something else with the work or a revised ask. After the same answer three times, suggest it as a preference.";

/**
 * What an app does with an answer the user gives in a chat (G1-300): it
 * logs it on what it's about, so decisions can be traced in one place. The
 * rule of 6 Nov 2026 that an approval asked in a chat stays in the chat now
 * reads: answered in the chat, logged on the platform. Said after the ask
 * protocol beside the board rules in get_context and playbook_map, and in
 * the sync script's tickets help.
 */
export const LOG_DECISIONS =
  "In a chat, ask the user there, not in the inbox, and log their answer with remember, kind decision: your question and their words, on the task, entry or playbook it's about, or on this connection for setup, the doctor or an import. Log only what concerns Context Locker, never the rest of the chat. It never waits, and they can correct it.";

export const TEXT = {
  personalDetails: PERSONAL_DETAILS,
  globalTitle: "## Context Locker",
  globalIntro:
    "Your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  /**
   * The heading over the standing rules, after the global block's intro
   * (G1-309). What follows it, up to the next heading, is Context Locker's
   * own, so an edit there is never read back
   */
  rulesHeading: "### Standing rules",
  /** The heading over this connection's own preferences, from its memory (G1-299) */
  memoryHeading: "### Your memory",
  /** The intro of OpenClaw's second file, for preferences that didn't fit in USER.md. */
  moreIntro:
    "More of your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  noPreferences: "No preferences saved yet.",
  /** Headings, used only when some preferences are in About */
  aboutUser: "### About the person",
  aboutProject: "### About this project",
  preferencesHeading: "### Preferences",
  projectTitle: (name: string) => `## Context Locker: ${name}`,
  projectIntro:
    "Preferences for this project, kept in sync by Context Locker and edited here as your own are. Where one has the same name as a general preference, it replaces that one here.",
  personalIntro: (name: string) =>
    `Context Locker preferences for ${name}. Where one has the same name as a general preference, it replaces that one here. These lines aren't in a file you can edit, so to change one, ask the person to edit it in Context Locker.`,
  overflow: (count: number, where: string | null) =>
    count === 1
      ? `1 more preference didn't fit in this file. ${where ? `It's in ${where}.` : "It's in Context Locker."}`
      : `${count} more preferences didn't fit in this file. ${where ? `They're in ${where}.` : "They're in Context Locker."}`,
  leftOut: (count: number) =>
    count === 1
      ? "1 preference was left out of this file because some agents refuse to load files with wording like it. It's in Context Locker."
      : `${count} preferences were left out of this file because some agents refuse to load files with wording like theirs. They're in Context Locker.`,
  /** A project's map: the notes and pointers whose summaries a new agent reads first */
  startHereHeading: "### Start here",
  /**
   * After the Start here entries: what to do with them, and where the rest of
   * the map is. An app that only reads its files may not have the tool
   */
  onboarding:
    "Start each session with a three-line startup brief for the person: the project, the sources you'll use, and your first step. These come from the project's map in Context Locker. Read the Start here summaries above now, and open an entry only when the work needs it. When the work needs more of the map, call Context Locker's project_map tool if you have it.",
  /** After a note that has no file here, which an app with the tools can open */
  readNote: "Read it with read_note, if you have it.",
  startHereOverflow: (count: number) =>
    count === 1
      ? "1 more Start here entry didn't fit here. It's in Context Locker."
      : `${count} more Start here entries didn't fit here. They're in Context Locker.`,
  startHereLeftOut: (count: number) =>
    count === 1
      ? "1 Start here entry was left out here because some agents refuse to load files with wording like it. It's in Context Locker."
      : `${count} Start here entries were left out here because some agents refuse to load files with wording like theirs. They're in Context Locker.`,
  /**
   * Where a project's lasting docs go, once a docs home is recorded. With
   * none, a file says nothing: an app that only reads its files couldn't
   * record the answer, so it would ask the user every session
   */
  docsHomeHeading: "### Docs home",
  docsLocationsHeading: "### Documentation locations",
  workPlacesHeading: "### Where work is tracked",
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
    "Keep lasting docs in this project's docs home, and add a link for each new one with write_note, if you have it. The place is left out here because some agents refuse to load files with wording like it. It's in Context Locker.",
  mapNeedsReading:
    "The documentation and work locations didn't fit here. Read them with Context Locker's project_map before choosing where to save docs or track work.",
  startHereNeedsReading:
    "Some Start here summaries didn't fit here. Read them with Context Locker's project_map before work, and open the full entries only when needed.",
  tightBlock:
    "The full project didn't fit in this file. Before work, call Context Locker's get_context for this project and read all Start here summaries. Preferences and documentation or work locations omitted here still apply. If you can't fetch them, tell the person what is missing before acting.",
  noRoom:
    "There is no room for a complete Context Locker block in AGENTS.md within the apps' reading limits. The block is not loaded. Before work, call get_context for this project and read all Start here summaries. If you can't fetch them, tell the person what is missing before acting. Text outside the block stays unchanged.",
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
 * What a line adds for an address only one app can open, such as "only
 * Claude can open it", so an app reading it knows the others can't (G1-157)
 */
export function oneAppOnly(address: string): string | null {
  const place = oneAppPlace(address);
  return place ? `only ${place.who} can open it` : null;
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
    const only = oneAppOnly(entry.address);
    return `- [${title}](${destination}) ${only ? `(${plainMarkdown(entry.kind)}, ${only})` : facts}: ${plainMarkdown(entry.summary)}${id}`;
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

/** Where new documents go, said once wherever a project's locations are (G1-321) */
export const DOCS_LOCATIONS_RULE =
  "Keep existing documents at their authoritative locations. For a new document, use a location clearly matching its purpose, otherwise the default. If more than one fits, neither a purpose match nor a default exists, or you cannot access the chosen location, ask before saving elsewhere. Recording a location grants no access and copies nothing. Keep anything another agent needs where every app can read it: a place only one app can open, such as a Claude artifact, a chat, a session's own files or a page on localhost, is fine as a view or a working copy, never as its only home.";

/** What a project with no documentation locations says */
export const NO_DOCS_LOCATIONS =
  "No documentation locations are recorded. Ask the person where to keep new lasting docs.";

/** Consistent routing for new docs, without moving existing records or granting access. */
export function docsLocationsRule(
  locations: DocsLocation[],
  budget = 3000,
): string {
  const rule = DOCS_LOCATIONS_RULE;
  const lines = locations.map((l) => {
    const destination = l.kind === "notes" ? "Context Locker Notes" : l.place!;
    const only = l.kind === "notes" ? null : oneAppOnly(l.place!);
    const line = `- ${plainMarkdown(l.name)}${l.is_default ? " (default)" : ""}: ${plainMarkdown(destination)}${only ? ` (${only})` : ""}${l.purpose ? `. For: ${plainMarkdown(l.purpose)}` : ""}`;
    return injectionMatches(line).length
      ? "- A location needs a human check in project Settings before use."
      : line;
  });
  if (!locations.length) lines.push(NO_DOCS_LOCATIONS);
  const full = [rule, ...lines].join("\n");
  if (Buffer.byteLength(full, "utf8") <= budget) return full;
  return `${rule}\nThe documentation map is too long for this startup file. Read all locations through Context Locker's project_map or get_context, or ask the person to open project Settings, before choosing where to save.`;
}

/**
 * Where a project's work is tracked, and the rule for choosing, as for docs:
 * existing tickets stay where they are, new ones go to the place matching
 * their purpose or the default, and a doubtful choice waits for the person
 * (G1-151). A place whose line reads like wording aimed at apps waits for
 * the person to check it in Context Locker instead.
 */
export function workPlacesRule(places: WorkPlace[], budget = 3000): string {
  const rule =
    "Keep existing tasks where they're tracked. For new work, use the place clearly matching its purpose, otherwise the default. If more than one fits, none fits and there's no default, or you can't reach the place, ask before choosing. Recording a place grants no access and copies nothing.";
  const lines = places.map((place) => {
    const where =
      place.kind === "board"
        ? "Context Locker's board"
        : plainMarkdown(place.address ?? "");
    const line = `- ${plainMarkdown(place.name)}${place.is_default ? " (default)" : ""}: ${where}${place.purpose ? `. For: ${plainMarkdown(place.purpose)}` : ""}`;
    return injectionMatches(line).length
      ? "- A place needs a human check in Context Locker before use."
      : line;
  });
  // The inbox holds decisions only, so news goes on the task (G1-284), and
  // finished work is its completion note, sent with the move to Done (G1-293)
  const online =
    "Read Context Locker's board online with list_tasks over MCP, or the sync script's tasks <app> list command. Change it through write_task or tasks <app> write <request.json>. Take only ready tasks, claim one before work, and never edit a board in synced files. Record news on the task as a comment, and finished work as its completion note with the move to Done, never as an ask: the person's inbox holds decisions only.";
  const full = [
    rule,
    ...lines,
    ...(places.some((place) => place.kind === "board") ? [online] : []),
  ].join("\n");
  if (Buffer.byteLength(full, "utf8") <= budget) return full;
  return `${rule}\nThe list of places is too long for this startup file. Read it through Context Locker's list_tasks, or ask the person, before choosing where new work goes.`;
}

/** A project's Start here entries and docs home, to compile into its block. */
export interface MapPlan {
  startHere: StartHereInput[];
  docsHome: DocsHome;
  docsLocations?: DocsLocation[];
  /** Where the project's work is tracked, when that's recorded */
  workPlaces?: WorkPlace[];
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
  const home =
    map.docsLocations === undefined
      ? docsHomeRule(map.docsHome)
      : { rule: docsLocationsRule(map.docsLocations), leftOut: null };
  // With Notes as the docs home, an app that only reads its files saves a
  // lasting doc as a file in the notes folder, when the sync mirrors one
  const rule =
    home.rule !== null &&
    (map.docsHome?.kind === "notes" ||
      map.docsLocations?.some((l) => l.kind === "notes")) &&
    map.notesFolder
      ? `${home.rule}${map.docsLocations === undefined ? " " : "\n"}${map.docsLocations === undefined ? TEXT.notesFolder : "When the chosen location is Context Locker Notes, save a Markdown file in .context-locker/notes with the front matter its README shows; the next sync saves it."}`
      : home.rule;
  return {
    startHere:
      map.startHere.length > 0
        ? [section(kept, overflow.length), TEXT.onboarding]
        : [],
    docsHome: [
      ...(rule === null
        ? []
        : [
            `${map.docsLocations === undefined ? TEXT.docsHomeHeading : TEXT.docsLocationsHeading}\n\n${rule}`,
          ]),
      ...(map.workPlaces?.length
        ? [`${TEXT.workPlacesHeading}\n\n${workPlacesRule(map.workPlaces)}`]
        : []),
    ],
    items: kept.map(({ id, version }) => ({ id, version })),
    map: { overflow, leftOut, docsHomeLeftOut: home.leftOut },
  };
}

/**
 * Intros the compilers wrote before. A file edited from an older copy of its
 * block can still hold one, and reading the edit skips it like today's.
 */
export const OLD_INTROS: readonly string[] = [
  "Preferences for this project, kept in sync by Context Locker. Where one has the same name as a general preference, it replaces that one here. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  "Your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync sends your edit for review.",
  "Preferences for this project, kept in sync by Context Locker. Where one has the same name as a general preference, it replaces that one here. To change one, edit its line here. The next sync sends your edit for review.",
  "More of your preferences, kept in sync by Context Locker. To change one, edit its line here. The next sync sends your edit for review.",
  // What the global block said after its intro until the standing rules
  // (G1-309): how to speak to the person, the ask protocol and what to do
  // with an answer given in a chat
  "When you tell the person what you did or found, say what is so and what they need to decide, in the present tense and in plain English, with the main points only. Leave task, change, version, requirement and section numbers out unless they ask or need one to act: keep them in the task or note, and give one link to the detail. Name things by what they are, such as the PRD, not by id.",
  ASK_PROTOCOL,
  LOG_DECISIONS,
  // What blocks said before the restructure's words (G1-321)
  "Preferences for this playbook, kept in sync by Context Locker. Where one has the same name as a general preference, it replaces that one here. To change one, edit its line here. The next sync saves your edit in Context Locker, unless it needs approval first.",
  "Start each session with a three-line startup brief for the user: the playbook, the sources you'll use, and your first step. These come from the playbook's map in Context Locker. Read the Start here summaries above now, and open an entry only when the task needs it. When the task needs more of the map, call Context Locker's playbook_map tool if you have it.",
  "The documentation and work locations didn't fit here. Read them with Context Locker's playbook_map before choosing where to save docs or track work.",
  "Some Start here summaries didn't fit here. Read them with Context Locker's playbook_map before work, and open the full entries only when needed.",
  "The full playbook didn't fit in this file. Before work, call Context Locker's get_context for this playbook and read all Start here summaries. Preferences and documentation or work locations omitted here still apply. If you can't fetch them, tell the user what is missing before acting.",
  "There is no room for a complete Context Locker block in AGENTS.md within the apps' reading limits. The block is not loaded. Before work, call get_context for this playbook and read all Start here summaries. If you can't fetch them, tell the user what is missing before acting. Text outside the block stays unchanged.",
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
  /** Always put the preferences under their headings, as after the standing rules (G1-309) */
  headed?: boolean;
  /**
   * This connection's own preferences, from its memory, under their own
   * heading after the person's, fitted after them (G1-299)
   */
  memory?: PreferenceInput[];
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
  /** This connection's own preferences that fit (G1-299) */
  keptMemory: PreferenceInput[] = [],
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
        plan.headed === true || map.startHere.length > 0,
      ),
    );
  } else {
    // A block that always heads its preferences heads them with none yet,
    // so a line the person adds there reads back as one (G1-309)
    const empty =
      plan.empty &&
      overflowCount === 0 &&
      leftOutCount === 0 &&
      keptMemory.length === 0;
    if (plan.headed) {
      sections.push(
        empty
          ? `${TEXT.preferencesHeading}\n\n${plan.empty}`
          : TEXT.preferencesHeading,
      );
    } else if (empty) sections.push(plan.empty!);
  }
  if (keptMemory.length > 0) {
    sections.push(
      `${TEXT.memoryHeading}\n\n${keptMemory.map(preferenceLine).join("\n")}`,
    );
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
  const fullMap = renderMap(plan.map);
  const leftOut = plan.shared
    ? plan.preferences.filter(
        (preference) => injectionMatches(preferenceLine(preference)).length > 0,
      )
    : [];
  const candidates = aboutFirst(
    plan.preferences.filter((preference) => !leftOut.includes(preference)),
  );
  // This connection's own come after the person's, fitted after them (G1-299)
  const memory = plan.memory ?? [];
  const all = [...candidates, ...memory];

  const fit = (map: RenderedMap): RenderedBlock => {
    const kept: PreferenceInput[] = [];
    const split = (list: PreferenceInput[]) => [
      list.filter((preference) => !memory.includes(preference)),
      list.filter((preference) => memory.includes(preference)),
    ];
    for (const [index, preference] of all.entries()) {
      const remaining = all.length - index - 1;
      const [own, mine] = split([...kept, preference]);
      if (
        bytes(assemble(plan, own!, remaining, leftOut.length, map, mine!)) >
        plan.budget
      )
        break;
      kept.push(preference);
    }
    const [own, mine] = split(kept);
    const overflow = candidates.filter(
      (preference) => !own!.includes(preference),
    );
    const memoryOverflow = memory.length - mine!.length;
    return {
      text: assemble(
        plan,
        own!,
        overflow.length + memoryOverflow,
        leftOut.length,
        map,
        mine!,
      ),
      items: [
        ...map.items,
        ...kept.map(({ id, version }) => ({ id, version })),
      ],
      overflow,
      leftOut,
      map: map.map,
    };
  };
  const full = fit(fullMap);
  if (bytes(full.text) <= plan.budget) return full;

  // The map and boilerplate must fit too. Keep whole summaries, never half
  // a rule or a location, and explicitly require reading what was omitted.
  if (plan.map) {
    for (
      let room = plan.map.startHereBudget;
      room >= 0;
      room = Math.max(-1, room - 250)
    ) {
      const map = renderMap({ ...plan.map, startHereBudget: room });
      if (map.docsHome.length) map.docsHome = [TEXT.mapNeedsReading];
      if (map.map.overflow.length && map.startHere.length)
        map.startHere[1] = TEXT.startHereNeedsReading;
      const fitted = fit(map);
      if (bytes(fitted.text) <= plan.budget) return fitted;
    }
  }
  // Even the ordinary intro may not fit. A complete bootstrap notice, or
  // no block at all, is safer than a truncated instruction.
  const compact = `${BLOCK_START}\n${plan.title}\n\n${TEXT.tightBlock}\n${BLOCK_END}\n`;
  return {
    text: bytes(compact) <= plan.budget ? compact : "",
    items: [],
    overflow: candidates,
    leftOut,
    map: {
      ...fullMap.map,
      overflow: (plan.map?.startHere ?? []).filter(
        (entry) => !fullMap.map.leftOut.includes(entry),
      ),
    },
  };
}

/** The text a session-start hook prints for a project the repo isn't linked to. */
export function renderContext(
  projectName: string,
  preferences: PreferenceInput[],
  budget: number,
  plan?: MapPlan,
  /** Whether its owner allows personal details in it (G1-246) */
  personal = false,
): RenderedBlock {
  const map = renderMap(plan);
  const kept: PreferenceInput[] = [];
  const intro = personal
    ? `${TEXT.personalIntro(projectName)} ${TEXT.personalDetails}`
    : TEXT.personalIntro(projectName);
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
