// The harness compilers. Each AI app reads instructions and skills from its
// own places, with its own limits; these turn one playbook into the files each
// app needs, and the sync script writes them.
import { DEVICE_APPS, byApp, type DeviceApp } from "./device-apps.js";
import {
  IMPORT_SKILL_NAME,
  LEGACY_IMPORT_SKILL_NAME,
  importSkill,
} from "./import-skill.js";
import { notesFolderOutputs } from "./notes.js";
import {
  renderBlock,
  renderContext,
  TEXT,
  type MapPlan,
  type RenderedBlock,
} from "./render.js";
import type {
  CompileInput,
  Compiled,
  CompiledHarness,
  DocsHome,
  DocsLocation,
  NoteInput,
  Output,
  PreferenceInput,
  ProjectLayer,
  SkillInput,
  StartHereInput,
  WorkPlace,
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
  /** Hermes's SOUL.md, from its entry in DEVICE_APPS */
  hermesSoul: DEVICE_APPS.hermes.budget,
  /**
   * OpenClaw's workspace AGENTS.md, which holds its whole block, leaving
   * USER.md to the person (G1-299), from its entry in DEVICE_APPS
   */
  openclawAgents: DEVICE_APPS.openclaw.budget,
  /** Session-start output. Claude Code previews hook output over 10,000 characters. */
  context: 8_000,
  /**
   * The most a project's Start here entries take of its block or
   * session-start output, heading included: room for 10 of a usual length,
   * so the project's preferences keep most of the room.
   */
  startHere: 3_000,
});

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

/**
 * Whether an app's project sync mirrors the project's notes into its notes
 * folder. Every app that works in project folders gets it, in a repo linked
 * to the workspace and in a folder linked on one computer, as the folder is
 * kept out of git and the repo's own files stay as they are. Hermes syncs a
 * project only in a linked repo, and OpenClaw works in no project folders.
 */
export function notesSynced(
  harness: CompiledHarness,
  layer: ProjectLayer,
): boolean {
  if (TARGETS[harness].projectBlock === null) return false;
  return !(harness === "hermes" && layer === "personal");
}

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

function capNotes(rendered: RenderedBlock, where: string): string[] {
  const notes: string[] = [];
  if (rendered.overflow.length > 0) {
    notes.push(
      `${plural(rendered.overflow.length, "preference didn't", "preferences didn't")} fit in ${where}: ${rendered.overflow.map((p) => p.name).join(", ")}.`,
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
  const ours = (skill: SkillInput) =>
    skill.name === IMPORT_SKILL_NAME || skill.name === LEGACY_IMPORT_SKILL_NAME;
  return {
    skills: [
      ...skillList.filter((skill) => !ours(skill)),
      importSkill(harness),
    ].sort(byName),
    notes: skillList
      .filter(ours)
      .map(
        (skill) =>
          `Your skill ${skill.name} has the name of Context Locker's own Import skill, so it was left out of ${NAMES[harness]}'s files.`,
      ),
  };
}

function compileGlobal(
  harness: CompiledHarness,
  preferences: PreferenceInput[],
  personal: SkillInput[],
  docsLocations?: DocsLocation[],
  /** This connection's own preferences, from its memory (G1-299) */
  memory: PreferenceInput[] = [],
): Compiled {
  const targets = TARGETS[harness];
  const map = docsLocations?.length
    ? { startHere: [], docsHome: null, docsLocations, startHereBudget: 0 }
    : undefined;
  const { skills: skillList, notes: skillNotes } = globalSkills(
    harness,
    personal,
  );

  const budget = DEVICE_APPS[harness].budget;
  const rendered = renderBlock({
    title: TEXT.globalTitle,
    intro: `${TEXT.globalIntro}\n\n${TEXT.plainWords}\n\n${TEXT.askProtocol}\n\n${TEXT.logDecisions}`,
    preferences,
    memory,
    empty: TEXT.noPreferences,
    budget,
    map,
    footer: TEXT.endOfTask,
  });
  return {
    outputs: [
      block(targets.global, rendered),
      ...skills(targets.skills, skillList),
    ],
    notes: [...capNotes(rendered, targets.global), ...skillNotes],
  };
}

/** A project's notes folder, and a sentence for any note that couldn't have a file of its own. */
function notesFolder(
  project: NonNullable<CompileInput["project"]>,
  folder: { notes: NoteInput[]; tags: string[] },
): Compiled {
  const { outputs, leftOut } = notesFolderOutputs({
    projectName: project.name,
    notes: folder.notes,
    tags: folder.tags,
  });
  return {
    outputs,
    notes:
      leftOut.length > 0
        ? [
            `${plural(leftOut.length, "note was", "notes were")} left out of ${project.name}'s notes folder, as another note's file has the same name: ${leftOut.map((note) => note.title).join(", ")}.`,
          ]
        : [],
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
  folder: { notes: NoteInput[]; tags: string[] },
  agentsMdBytes?: number,
): Compiled {
  const targets = TARGETS[harness];
  const outputs: Output[] = [];
  const notes: string[] = [];
  const mapPlan: MapPlan = {
    ...map,
    startHereBudget: BUDGETS.startHere,
    notesFolder: notesSynced(harness, project.layer),
  };
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
    // own: the session start carries the preferences, and only the notes
    // folder, which git leaves out, is written. Hermes runs its sync from a
    // daily job, so there's no session start to print at.
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
      );
      outputs.push({
        kind: "context",
        text: rendered.text,
        items: rendered.items,
      });
      notes.push(...capNotes(rendered, "the session-start output"));
    }
    if (skillList.length > 0) {
      notes.push(
        `${project.name}'s own skills load only in repos linked with a .contextlocker.json: ${skillList.map((s) => s.name).join(", ")}.`,
      );
    }
    const mirrored = notesFolder(project, folder);
    return {
      outputs: [...outputs, ...mirrored.outputs],
      notes: [...notes, ...mirrored.notes],
    };
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
  const mirrored = notesFolder(project, folder);
  return {
    outputs: [...outputs, ...mirrored.outputs],
    notes: [...notes, ...mirrored.notes],
  };
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
        { notes: [...(input.notes ?? [])], tags: [...(input.tags ?? [])] },
        input.agentsMdBytes,
      )
    : compileGlobal(
        input.harness,
        preferences,
        skillList,
        input.docsLocations,
        [...(input.memory ?? [])],
      );
}
