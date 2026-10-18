import type { PreferenceInput, SkillInput } from "../src/index.js";

export const WORKSPACE_ID = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";

export const preferences: PreferenceInput[] = [
  {
    id: "11111111-1111-4111-8111-111111111111",
    name: "dates-with-year",
    version: 1,
    text: "Write dates with the year, such as 17 Oct 2026.",
  },
  {
    id: "22222222-2222-4222-8222-222222222222",
    name: "no-dashes",
    version: 2,
    text: "Don't use em or en dashes.",
  },
  {
    id: "33333333-3333-4333-8333-333333333333",
    name: "short-sentences",
    version: 3,
    text: "Use short sentences in prose.",
  },
];

export const skills: SkillInput[] = [
  {
    id: "44444444-4444-4444-8444-444444444444",
    name: "code-review",
    version: 2,
    files: [
      {
        path: "SKILL.md",
        content:
          "---\nname: code-review\ndescription: Review a change before it merges. Use when asked to review a diff or a pull request.\n---\n\n# Code review\n\nRead the diff, then the tests.\n",
        encoding: "utf8",
      },
      {
        path: "references/checklist.md",
        content: "- Tests cover the change\n- Names are plain\n",
        encoding: "utf8",
      },
    ],
  },
];

export const project = {
  id: "55555555-5555-4555-8555-555555555555",
  name: "Docs site",
};

export const projectPreferences: PreferenceInput[] = [
  {
    id: "66666666-6666-4666-8666-666666666666",
    name: "short-sentences",
    version: 1,
    text: "Steps in the docs may use longer sentences when they need to.",
  },
];

export const projectSkills: SkillInput[] = [
  {
    id: "77777777-7777-4777-8777-777777777777",
    name: "docs-style",
    version: 1,
    files: [
      {
        path: "SKILL.md",
        content:
          "---\nname: docs-style\ndescription: House style for the docs site. Use when writing or editing docs pages.\n---\n\nKeep pages short.\n",
        encoding: "utf8",
      },
    ],
  },
];

/** Numbered preferences of a given length, for testing caps. */
export function manyPreferences(
  count: number,
  length: number,
): PreferenceInput[] {
  return Array.from({ length: count }, (_, index) => {
    const name = `rule-${String(index + 1).padStart(3, "0")}`;
    const text = `Rule ${index + 1}: ${"keep it plain ".repeat(40)}`
      .slice(0, length)
      .trim();
    return {
      id: `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
      name,
      version: 1,
      text,
    };
  });
}
