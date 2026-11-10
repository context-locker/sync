// Context Locker's guide (G1-309): one topic to a file, filled for chat apps
// and for apps on device sync, each within its budget, in every app's skills
// folder. The website's copy, from guideForPeople, isn't part of this copy.
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  AI_TEXT_BUDGETS,
  COMPILED_HARNESSES,
  GUIDE_SKILL_ID,
  GUIDE_SKILL_NAME,
  compile,
  guideSkillFiles,
  guideTopics,
  injectionMatches,
  isReservedSkillName,
  standingRules,
  type GuideEnvironment,
} from "../src/index.js";

const ENVIRONMENTS: GuideEnvironment[] = ["mcp", "sync"];

describe("Context Locker's guide (G1-309)", () => {
  it("fills every slot, keeps each topic within its budget and reads as plain text", () => {
    for (const environment of ENVIRONMENTS) {
      for (const topic of guideTopics(environment)) {
        assert.doesNotMatch(topic.text, /\{\w+\}/, topic.file);
        assert.ok(
          topic.text.length <= AI_TEXT_BUDGETS.guideTopic,
          `${environment} ${topic.file}: ${topic.text.length}`,
        );
        assert.deepEqual(injectionMatches(topic.text), [], topic.file);
        assert.match(topic.text, /^# .+\n\nOpen this topic /, topic.file);
      }
    }
  });

  it("lists each topic in its index, in one line, and nothing else", () => {
    for (const environment of ENVIRONMENTS) {
      const files = guideSkillFiles(environment);
      const index = files.find((file) => file.path === "SKILL.md")!.content;
      assert.match(index, new RegExp(`^---\\nname: ${GUIDE_SKILL_NAME}\\n`));
      const topics = files.filter((file) => file.path !== "SKILL.md");
      assert.deepEqual(
        [...index.matchAll(/^- `(topics\/[\w-]+\.md)`: /gm)].map(
          ([, file]) => file,
        ),
        topics.map((file) => file.path),
      );
    }
    // Sync on a computer is for apps on device sync only
    assert.ok(
      guideTopics("sync").some((topic) => topic.file === "topics/sync.md"),
    );
    assert.ok(
      !guideTopics("mcp").some((topic) => topic.file === "topics/sync.md"),
    );
  });

  it("says each environment's own tools and commands", () => {
    const text = (environment: GuideEnvironment) =>
      guideTopics(environment)
        .map((topic) => topic.text)
        .join("\n");
    assert.match(text("mcp"), /write_ticket/);
    assert.match(text("mcp"), /with remember/);
    assert.doesNotMatch(text("mcp"), /tickets <app>|remember <app>/);
    assert.match(text("sync"), /`tickets <app> write`/);
    assert.match(text("sync"), /`remember <app>`/);
  });

  it("goes into every app's skills folder, beside the Import skill, and keeps its name", () => {
    for (const harness of COMPILED_HARNESSES) {
      const skills = compile({
        harness,
        project: null,
        preferences: [],
        skills: [{ id: "x", version: 1, name: GUIDE_SKILL_NAME, files: [] }],
      });
      const guide = skills.outputs.filter(
        (output) =>
          output.kind === "skill" &&
          output.target.endsWith(`/${GUIDE_SKILL_NAME}`),
      );
      assert.equal(guide.length, 1, harness);
      assert.equal(
        guide[0]!.kind === "skill" && guide[0]!.item.id,
        GUIDE_SKILL_ID,
      );
      assert.ok(
        skills.notes.some((note) =>
          note.includes("Context Locker's own skills"),
        ),
        harness,
      );
    }
    assert.ok(isReservedSkillName(GUIDE_SKILL_NAME));
    assert.ok(!isReservedSkillName("context-lockers"));
  });

  it("is named in the standing rules wherever an app reads them", () => {
    assert.match(
      standingRules("mcp"),
      /the skill context-locker, with get_skill/,
    );
    assert.match(
      standingRules("sync"),
      /the skill context-locker in your skills folder/,
    );
    assert.match(standingRules("brief"), /context\.locker\/docs/);
  });
});
