// The harness compilers. Each AI app reads instructions and skills from its
// own places, with its own limits; these turn one playbook into the files each
// app needs, and the sync script writes them.
import { DEVICE_APPS, byApp, type DeviceApp } from "./device-apps.js";
import { GUIDE_SKILL_NAME, guideSkill } from "./guide.js";
import {
  IMPORT_SKILL_NAME,
  LEGACY_IMPORT_SKILL_NAME,
  importSkill,
} from "./import-skill.js";
import { standingRules } from "./standing-rules.js";
import {
  preferenceLine,
  renderBlock,
  renderContext,
  TEXT,
  type BlockPlan,
  type MapPlan,
  type RenderedBlock,
} from "./render.js";
import type {
  CompileInput,
  Compiled,
  CompiledHarness,
  DocsHome,
  DocsLocation,
  Output,
  PreferenceInput,
  SkillInput,
  StartHereInput,
  WorkPlace,
  FileRoom,
} from "./types.js";

/** Most bytes each compiled block may take, markers included. */
export const BUDGETS = Object.freeze({
  /** Claude Code's global block, from its entry in DEVICE_APPS */
  claudeRules: DEVICE_APPS["claude-code"].budget,
  /** Codex's global AGENTS.md, from its entry in DEVICE_APPS */
  codexGlobal: DEVICE_APPS.codex.budget,
  /**
   * A repo's AGENTS.md is read by several apps. Codex stops reading project
   * files after 32 KiB in all, so the block takes well under half of that.
   */
  sharedAgentsMd: 12_000,
  /**
   * The most Hermes's SOUL.md takes, from its entry in DEVICE_APPS. The
   * sync script says how much room Hermes's trim leaves after the file's own
   * text, and the block takes the smaller (G1-309).
   */
  hermesSoul: DEVICE_APPS.hermes.budget,
  /**
   * The most OpenClaw's workspace AGENTS.md takes, which holds its whole
   * block, leaving USER.md to the person (G1-299), from its entry in
   * DEVICE_APPS. The sync script says how much room OpenClaw's trim leaves
   * after the file's own text, and the block takes the smaller (G1-309).
   */
  openclawAgents: DEVICE_APPS.openclaw.budget,
  /**
   * Hermes's SOUL.md and OpenClaw's AGENTS.md when the sync script didn't
   * say how much room they have, which leaves the person 8,000 characters
   * of their own under the apps' 20,000-character trim
   */
  unmeasuredGlobal: 12_000,
  /** Session-start output. Claude Code previews hook output over 10,000 characters. */
  context: 8_000,
  /**
   * The most a project's Start here entries take of its block or
   * session-start output, heading included: room for 10 of a usual length,
   * so the project's preferences keep most of the room.
   */
  startHere: 3_000,
});

/**
 * The apps whose global file holds the person's own text beside the block
 * and is trimmed whole past 20,000 characters, so the sync script measures
 * the room it leaves (G1-309)
 */
export const ROOM_MEASURED: ReadonlySet<string> = new Set<CompiledHarness>([
  "hermes",
  "openclaw",
]);

/** Where each app's compiled files go, from its entry in DEVICE_APPS. Roots in braces are resolved by the sync script. */
export const TARGETS: Readonly<Record<CompiledHarness, DeviceApp["targets"]>> =
  byApp((app) => app.targets);

/** OpenClaw's workspace AGENTS.md, which holds its whole block (G1-299) */
export const OPENCLAW_AGENTS_MD = "{openclaw}/AGENTS.md";

/**
 * Where OpenClaw's block began until G1-299. Nothing is written there now,
 * and the sync takes the old block out, but an edit made to it before then
 * still reads back.
 */
export const OPENCLAW_USER_MD = "{openclaw}/USER.md";

const NAMES = byApp((app) => app.name);

function block(target: string, rendered: RenderedBlock): Output {
  return { kind: "block", target, text: rendered.text, items: rendered.items };
}

function skills(root: string, list: SkillInput[]): Output[] {
  return list.map((skill) => ({
    kind: "skill",
    target: `${root}/${skill.name}`,
    files: skill.files,
    ...(skill.fileIndex ? { fileIndex: skill.fileIndex } : {}),
    item: { id: skill.id, version: skill.version },
  }));
}

function plural(count: number, one: string, many: string): string {
  return count === 1 ? `1 ${one}` : `${count} ${many}`;
}

/** How the room of a project's session-start output is named (G1-336) */
const SESSION_START = "the session-start output";

/** What a rendered file had no room for (G1-336), or nothing when it holds every preference whole */
function roomOf(
  rendered: RenderedBlock,
  target: string,
  noRoom = rendered.text === "" || rendered.text.includes(TEXT.tightBlock),
): FileRoom[] {
  const shortened = rendered.shortened.length + rendered.overflow.length;
  return shortened > 0 || noRoom ? [{ target, shortened, noRoom }] : [];
}

function capNotes(rendered: RenderedBlock, where: string): string[] {
  const notes: string[] = [];
  if (rendered.overflow.length > 0) {
    notes.push(
      `${plural(rendered.overflow.length, "preference didn't", "preferences didn't")} fit in ${where}: ${rendered.overflow.map((p) => p.name).join(", ")}.`,
    );
  }
  // A file with no room for all of them whole shows some shortened (G1-336)
  if (rendered.shortened.length > 0) {
    notes.push(
      `${plural(rendered.shortened.length, "preference is", "preferences are")} shortened in ${where}, as it has no room for all of them whole: ${rendered.shortened.map((p) => p.name).join(", ")}.`,
    );
  }
  if (rendered.leftOut.length > 0) {
    notes.push(
      `${plural(rendered.leftOut.length, "preference was", "preferences were")} left out of ${where} for wording some apps refuse: ${rendered.leftOut.map((p) => p.name).join(", ")}.`,
    );
  }
  const { map } = rendered;
  if (map.overflow.length > 0) {
    notes.push(
      `${plural(map.overflow.length, "Start here entry didn't", "Start here entries didn't")} fit in ${where}: ${map.overflow.map((entry) => entry.title).join(", ")}.`,
    );
  }
  if (map.leftOut.length > 0) {
    notes.push(
      `${plural(map.leftOut.length, "Start here entry was", "Start here entries were")} left out of ${where} for wording or an address some apps refuse: ${map.leftOut.map((entry) => entry.title).join(", ")}.`,
    );
  }
  if (map.docsHomeLeftOut) {
    notes.push(
      `The docs home's place was left out of ${where} for wording or an address some apps refuse: ${map.docsHomeLeftOut}.`,
    );
  }
  return notes;
}

const byName = (a: { name: string }, b: { name: string }) =>
  a.name < b.name ? -1 : a.name > b.name ? 1 : 0;

/**
 * The global sync's skills: the person's own, and Context Locker's Import
 * skill, which every app gets. A skill of the person's with the Import
 * skill's name, or the name it had before G1-206, is left out, and named.
 */
function globalSkills(
  harness: CompiledHarness,
  skillList: SkillInput[],
): { skills: SkillInput[]; notes: string[] } {
  // Context Locker's own skills: Import, and the guide (G1-309)
  const ours = (skill: SkillInput) =>
    skill.name === IMPORT_SKILL_NAME ||
    skill.name === LEGACY_IMPORT_SKILL_NAME ||
    skill.name === GUIDE_SKILL_NAME;
  return {
    skills: [
      ...skillList.filter((skill) => !ours(skill)),
      importSkill(harness),
      guideSkill(harness),
    ].sort(byName),
    notes: skillList
      .filter(ours)
      .map(
        (skill) =>
          `Your skill ${skill.name} has the name of one of Context Locker's own skills, so it was left out of ${NAMES[harness]}'s files.`,
      ),
  };
}

/** The map a global block carries: the documentation locations, when recorded */
function globalMap(docsLocations?: DocsLocation[]): MapPlan | undefined {
  return docsLocations?.length
    ? { startHere: [], docsHome: null, docsLocations, startHereBudget: 0 }
    : undefined;
}

/**
 * The global block: the standing rules, then the person's preferences,
 * always under their headings, so reading an edit back knows where the
 * rules end (G1-309), then this connection's own (G1-299)
 */
function globalPlan(
  preferences: PreferenceInput[],
  budget: number,
  docsLocations?: DocsLocation[],
  memory: PreferenceInput[] = [],
): BlockPlan {
  return {
    title: TEXT.globalTitle,
    intro: `${TEXT.globalIntro}\n\n${TEXT.rulesHeading}\n\n${standingRules("sync")}`,
    headed: true,
    preferences,
    memory,
    empty: TEXT.noPreferences,
    budget,
    map: globalMap(docsLocations),
  };
}

function compileGlobal(
  harness: CompiledHarness,
  preferences: PreferenceInput[],
  personal: SkillInput[],
  docsLocations?: DocsLocation[],
  /** This connection's own preferences, from its memory (G1-299) */
  memory: PreferenceInput[] = [],
  /** The room the sync script measured in the app's global file (G1-309) */
  globalBytes?: number,
): Compiled {
  const targets = TARGETS[harness];
  const { skills: skillList, notes: skillNotes } = globalSkills(
    harness,
    personal,
  );

  const budget = ROOM_MEASURED.has(harness)
    ? Math.min(
        DEVICE_APPS[harness].budget,
        globalBytes ?? BUDGETS.unmeasuredGlobal,
      )
    : DEVICE_APPS[harness].budget;
  const rendered = renderBlock(
    globalPlan(preferences, budget, docsLocations, memory),
  );
  return {
    outputs: [
      block(targets.global, rendered),
      ...skills(targets.skills, skillList),
    ],
    notes: [...capNotes(rendered, targets.global), ...skillNotes],
    room: roomOf(rendered, targets.global),
  };
}

function compileProject(
  harness: CompiledHarness,
  project: NonNullable<CompileInput["project"]>,
  preferences: PreferenceInput[],
  skillList: SkillInput[],
  map: {
    startHere: StartHereInput[];
    docsHome: DocsHome;
    docsLocations?: DocsLocation[];
    workPlaces?: WorkPlace[];
  },
  agentsMdBytes?: number,
): Compiled {
  const targets = TARGETS[harness];
  const outputs: Output[] = [];
  const notes: string[] = [];
  const room: FileRoom[] = [];
  const mapPlan: MapPlan = { ...map, startHereBudget: BUDGETS.startHere };
  // A project with preferences, Start here entries or a docs home gets its
  // block, which says where lasting docs go once a docs home is recorded
  const compiled =
    preferences.length > 0 ||
    map.startHere.length > 0 ||
    map.docsHome !== null ||
    (map.docsLocations?.length ?? 0) > 0 ||
    (map.workPlaces?.length ?? 0) > 0;

  if (!targets.projectBlock) {
    return {
      outputs,
      notes: [
        `${NAMES[harness]} doesn't work in project folders, so ${project.name}'s preferences reach it through MCP only.`,
      ],
    };
  }

  if (project.layer === "personal") {
    // None of the repo's own files change in a repo this workspace doesn't
    // own: the session start carries the preferences. Hermes runs its sync
    // from a daily job, so there's no session start to print at.
    if (harness === "hermes") {
      if (
        preferences.length > 0 ||
        skillList.length > 0 ||
        map.startHere.length > 0
      ) {
        notes.push(
          `Hermes gets ${project.name}'s preferences only in repos linked with a .contextlocker.json.`,
        );
      }
      return { outputs, notes };
    }
    if (compiled) {
      const rendered = renderContext(
        project.name,
        preferences,
        BUDGETS.context,
        mapPlan,
        project.personal === true,
        project.team,
      );
      outputs.push({
        kind: "context",
        text: rendered.text,
        items: rendered.items,
      });
      notes.push(...capNotes(rendered, "the session-start output"));
      room.push(...roomOf(rendered, SESSION_START, false));
    }
    if (skillList.length > 0) {
      notes.push(
        `${project.name}'s own skills load only in repos linked with a .contextlocker.json: ${skillList.map((s) => s.name).join(", ")}.`,
      );
    }
    return { outputs, notes, room };
  }

  if (compiled) {
    // A repo's AGENTS.md is shared by every app that reads it, so its block is
    // compiled the same way for all of them, to the strictest rules
    const shared = targets.projectBlock === "{project}/AGENTS.md";
    const rendered = renderBlock({
      title: TEXT.projectTitle(project.name),
      // A playbook whose owner allows personal details says so (G1-246)
      intro: project.personal
        ? `${TEXT.projectIntro} ${TEXT.personalDetails}`
        : TEXT.projectIntro,
      aboutHeading: TEXT.aboutProject,
      // A team's project lists the team's preferences first (G1-329)
      team: project.team,
      preferences,
      empty: TEXT.noPreferences,
      budget: shared
        ? Math.max(
            0,
            Math.min(
              BUDGETS.sharedAgentsMd,
              agentsMdBytes ?? BUDGETS.sharedAgentsMd,
            ),
          )
        : BUDGETS.claudeRules,
      shared,
      map: mapPlan,
    });
    if (rendered.text) outputs.push(block(targets.projectBlock, rendered));
    else {
      // No complete block fits. Keep the warning outside the exhausted file,
      // in the session-start output, including on unchanged/offline runs.
      outputs.push({
        kind: "context",
        text: `${project.name}: ${TEXT.noRoom}\n`,
        items: [],
      });
      notes.push(TEXT.noRoom);
    }
    notes.push(...capNotes(rendered, targets.projectBlock));
    room.push(...roomOf(rendered, targets.projectBlock));
  }

  if (skillList.length > 0) {
    if (targets.projectSkills) {
      outputs.push(...skills(targets.projectSkills, skillList));
    } else {
      notes.push(
        `Context Locker doesn't write project skills for ${NAMES[harness]} yet, so these stay out: ${skillList.map((s) => s.name).join(", ")}.`,
      );
    }
  }
  return { outputs, notes, room };
}

/** What one AI app's files should hold for one sync: global, or one project. */
export function compile(input: CompileInput): Compiled {
  const preferences = [...input.preferences];
  const skillList = [...input.skills].sort(byName);
  return input.project
    ? compileProject(
        input.harness,
        input.project,
        preferences,
        skillList,
        {
          startHere: [...(input.startHere ?? [])],
          docsHome: input.docsHome ?? null,
          docsLocations: input.docsLocations,
          workPlaces: input.workPlaces,
        },
        input.agentsMdBytes,
      )
    : compileGlobal(
        input.harness,
        preferences,
        skillList,
        input.docsLocations,
        [...(input.memory ?? [])],
        input.globalBytes,
      );
}

/** How big a playbook is whole, against the room agents give it (CLK-415) */
export interface PlaybookSize {
  /** The characters it takes whole, its headings included */
  used: number;
  /** The most an agent reads whole */
  room: number;
}

const sizeOf = (text: string) => Buffer.byteLength(text, "utf8");

/**
 * A project whole, as an agent reads it at the start of a session, with its
 * team's preferences first in a team's project, against the room that output
 * gets: the smallest a project has anywhere, so a project that fits it fits
 * in every app's files (CLK-415)
 */
export function projectSize(
  project: { name: string; personal?: boolean; team?: string },
  preferences: PreferenceInput[],
  map: {
    startHere: StartHereInput[];
    docsHome: DocsHome;
    docsLocations?: DocsLocation[];
    workPlaces?: WorkPlace[];
  },
): PlaybookSize {
  const rendered = renderContext(
    project.name,
    preferences,
    Number.POSITIVE_INFINITY,
    { ...map, startHereBudget: BUDGETS.startHere },
    project.personal === true,
    project.team,
  );
  return { used: sizeOf(rendered.text), room: BUDGETS.context };
}

/**
 * What a Team context adds to each of its projects whole: its
 * heading, the line saying it's the team's and its preferences, the same
 * whatever the project, as it's read first in each (G1-329, CLK-415)
 */
export function teamPreferencesSize(
  team: string,
  preferences: PreferenceInput[],
): number {
  if (preferences.length === 0) return 0;
  return sizeOf(
    `${TEXT.teamHeading(team)}\n\n${TEXT.teamIntro}\n\n${preferences.map(preferenceLine).join("\n")}\n\n`,
  );
}

/**
 * The person's Personal context whole, as each app's global file holds it after
 * the standing rules, against the smallest room the apps they sync files to
 * give it, or null when they sync files to none (CLK-415)
 */
export function allProjectsSize(
  preferences: PreferenceInput[],
  docsLocations: DocsLocation[] | undefined,
  harnesses: readonly string[],
): PlaybookSize | null {
  const rooms = harnesses
    .filter((harness): harness is CompiledHarness =>
      Object.hasOwn(DEVICE_APPS, harness),
    )
    .map((harness) => DEVICE_APPS[harness].budget);
  if (rooms.length === 0) return null;
  const rendered = renderBlock(
    globalPlan(preferences, Number.POSITIVE_INFINITY, docsLocations),
  );
  return { used: sizeOf(rendered.text), room: Math.min(...rooms) };
}
