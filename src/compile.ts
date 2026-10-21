// The harness compilers. Each AI app reads instructions and skills from its
// own places, with its own limits; these turn one playbook into the files each
// app needs, and the sync script writes them.
import { GATHER_SKILL_NAME, gatherSkill } from "./gather.js";
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
  LinkInput,
  NoteInput,
  Output,
  PreferenceInput,
  ProjectLayer,
  SkillInput,
} from "./types.js";

/** Most bytes each compiled block may take, markers included. */
export const BUDGETS = Object.freeze({
  /** Claude Code loads rule files whole; this keeps 100 one-line preferences with room to spare. */
  claudeRules: 40_000,
  /** Codex loads the global AGENTS.md whole and re-reads it every turn. */
  codexGlobal: 40_000,
  /**
   * A repo's AGENTS.md is read by several apps. Codex stops reading project
   * files after 32 KiB in all, so the block takes well under half of that.
   */
  sharedAgentsMd: 12_000,
  /** Hermes trims SOUL.md past 20,000 characters. */
  hermesSoul: 12_000,
  /** OpenClaw loads at most 4,000 characters of USER.md; the rest is the person's. */
  openclawUser: 2_400,
  /** OpenClaw trims bootstrap files past 20,000 characters. */
  openclawAgents: 12_000,
  /** Session-start output. Claude Code previews hook output over 10,000 characters. */
  context: 8_000,
  /**
   * The most a project's Start here links take of its block or session-start
   * output, heading included: room for 10 links of a usual length, so the
   * project's preferences keep most of the room.
   */
  startHere: 3_000,
});

/** Where each app's compiled files go. Roots in braces are resolved by the sync script. */
export const TARGETS = Object.freeze({
  "claude-code": {
    global: "{claude}/rules/context-locker.md",
    skills: "{claude}/skills",
    projectBlock: "{project}/.claude/rules/context-locker.md",
    projectSkills: "{project}/.claude/skills",
  },
  codex: {
    global: "{codex}/AGENTS.md",
    skills: "{agents}/skills",
    projectBlock: "{project}/AGENTS.md",
    projectSkills: "{project}/.agents/skills",
  },
  hermes: {
    global: "{hermes}/SOUL.md",
    skills: "{hermes}/skills",
    projectBlock: "{project}/AGENTS.md",
    projectSkills: null,
  },
  openclaw: {
    global: "{openclaw}/USER.md",
    skills: "{agents}/skills",
    projectBlock: null,
    projectSkills: null,
  },
} satisfies Record<
  CompiledHarness,
  {
    global: string;
    skills: string;
    projectBlock: string | null;
    projectSkills: string | null;
  }
>);

/** OpenClaw's second file: preferences that don't fit in USER.md, and the end-of-task question. */
export const OPENCLAW_AGENTS_MD = "{openclaw}/AGENTS.md";

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

const OPENCLAW_OVERFLOW = "AGENTS.md, under Context Locker";

const NAMES: Record<CompiledHarness, string> = {
  "claude-code": "Claude Code",
  codex: "Codex",
  hermes: "Hermes",
  openclaw: "OpenClaw",
};

function block(target: string, rendered: RenderedBlock): Output {
  return { kind: "block", target, text: rendered.text, items: rendered.items };
}

function skills(root: string, list: SkillInput[]): Output[] {
  return list.map((skill) => ({
    kind: "skill",
    target: `${root}/${skill.name}`,
    files: skill.files,
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
  const { links } = rendered;
  if (links.overflow.length > 0) {
    notes.push(
      `${plural(links.overflow.length, "Start here link didn't", "Start here links didn't")} fit in ${where}: ${links.overflow.map((link) => link.title).join(", ")}.`,
    );
  }
  if (links.leftOut.length > 0) {
    notes.push(
      `${plural(links.leftOut.length, "Start here link was", "Start here links were")} left out of ${where} for wording or an address some apps refuse: ${links.leftOut.map((link) => link.title).join(", ")}.`,
    );
  }
  if (links.docsHomeLeftOut) {
    notes.push(
      `The docs home's link was left out of ${where} for wording or an address some apps refuse: ${links.docsHomeLeftOut.title}.`,
    );
  }
  return notes;
}

const byName = (a: { name: string }, b: { name: string }) =>
  a.name < b.name ? -1 : a.name > b.name ? 1 : 0;

/**
 * The global sync's skills: the person's own, and Context Locker's Gather
 * skill, which every app gets. A skill of the person's with the Gather
 * skill's name is left out, and named.
 */
function globalSkills(
  harness: CompiledHarness,
  skillList: SkillInput[],
): { skills: SkillInput[]; notes: string[] } {
  const clash = skillList.filter((skill) => skill.name === GATHER_SKILL_NAME);
  return {
    skills: [
      ...skillList.filter((skill) => skill.name !== GATHER_SKILL_NAME),
      gatherSkill(harness),
    ].sort(byName),
    notes:
      clash.length > 0
        ? [
            `Your skill ${GATHER_SKILL_NAME} has the name of Context Locker's own Gather skill, so it was left out of ${NAMES[harness]}'s files.`,
          ]
        : [],
  };
}

function compileGlobal(
  harness: CompiledHarness,
  preferences: PreferenceInput[],
  personal: SkillInput[],
): Compiled {
  const targets = TARGETS[harness];
  const { skills: skillList, notes: skillNotes } = globalSkills(
    harness,
    personal,
  );

  if (harness === "openclaw") {
    const user = renderBlock({
      title: TEXT.globalTitle,
      intro: TEXT.globalIntro,
      preferences,
      empty: TEXT.noPreferences,
      budget: BUDGETS.openclawUser,
      overflowTo: OPENCLAW_OVERFLOW,
    });
    const more = renderBlock({
      title: TEXT.globalTitle,
      intro:
        user.overflow.length > 0
          ? TEXT.moreIntro
          : "Context Locker keeps your preferences in USER.md.",
      preferences: user.overflow,
      budget: BUDGETS.openclawAgents,
      footer: TEXT.endOfTaskIn(
        user.overflow.length > 0 ? "USER.md or this file" : "USER.md",
      ),
    });
    return {
      outputs: [
        block(targets.global, user),
        block(OPENCLAW_AGENTS_MD, more),
        ...skills(targets.skills, skillList),
      ],
      notes: [...capNotes(more, "OpenClaw's AGENTS.md"), ...skillNotes],
    };
  }

  const budget =
    harness === "claude-code"
      ? BUDGETS.claudeRules
      : harness === "codex"
        ? BUDGETS.codexGlobal
        : BUDGETS.hermesSoul;
  const rendered = renderBlock({
    title: TEXT.globalTitle,
    intro: TEXT.globalIntro,
    preferences,
    empty: TEXT.noPreferences,
    budget,
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
  map: { startHere: LinkInput[]; docsHome: DocsHome },
  folder: { notes: NoteInput[]; tags: string[] },
): Compiled {
  const targets = TARGETS[harness];
  const outputs: Output[] = [];
  const notes: string[] = [];
  const mapPlan: MapPlan = {
    ...map,
    startHereBudget: BUDGETS.startHere,
    notesFolder: notesSynced(harness, project.layer),
  };
  // A project with preferences, Start here links or a docs home gets its
  // block, which says where lasting docs go once a docs home is recorded
  const compiled =
    preferences.length > 0 || map.startHere.length > 0 || map.docsHome !== null;

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
      intro: TEXT.projectIntro,
      aboutHeading: TEXT.aboutProject,
      preferences,
      empty: TEXT.noPreferences,
      budget: shared ? BUDGETS.sharedAgentsMd : BUDGETS.claudeRules,
      shared,
      map: mapPlan,
    });
    outputs.push(block(targets.projectBlock, rendered));
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
        },
        { notes: [...(input.notes ?? [])], tags: [...(input.tags ?? [])] },
      )
    : compileGlobal(input.harness, preferences, skillList);
}
