// How big a playbook is whole, against the room agents give it (CLK-415): a
// project as an agent reads it at the start of a session, its team's
// preferences first, against 8,000, and the person's All projects as the
// global file holds it, against the smallest room their apps give it.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { describe, it } from "node:test";

import {
  BUDGETS,
  DEVICE_APPS,
  allProjectsSize,
  compile,
  projectSize,
  teamPreferencesSize,
  type PreferenceInput,
} from "../src/index.js";

const preference = (
  name: string,
  text: string,
  team = false,
): PreferenceInput => ({
  id: randomUUID(),
  version: 1,
  name,
  text,
  ...(team ? { team: true } : {}),
});

const NO_MAP = { startHere: [], docsHome: null };

/** Preferences of about the length given, each a rule and an example */
const preferences = (count: number, length = 400) =>
  Array.from({ length: count }, (_, index) =>
    preference(
      `rule-${index + 1}`,
      `Follow rule ${index + 1} in every session. ${"For example, this is how it reads. ".repeat(Math.ceil(length / 35)).trim()}`,
    ),
  );

describe("a playbook's size whole (CLK-415)", () => {
  it("measures a project as its session start reads it whole, against 8,000", () => {
    const small = projectSize({ name: "Website" }, preferences(3), NO_MAP);
    assert.equal(small.room, BUDGETS.context);
    assert.equal(small.room, 8_000);
    assert.ok(small.used > 1_000 && small.used < 2_000, `${small.used}`);
    // What a project's sync prints for it, while it fits, is that size
    const synced = compile({
      harness: "claude-code",
      project: { id: randomUUID(), name: "Website", layer: "personal" },
      preferences: preferences(3),
      skills: [],
    }).outputs.find((output) => output.kind === "context");
    assert.ok(synced && "text" in synced);
    assert.ok(Math.abs(Buffer.byteLength(synced.text) - small.used) < 200);

    const large = projectSize({ name: "Website" }, preferences(30), NO_MAP);
    assert.ok(large.used > large.room, `${large.used}`);
  });

  it("counts a team's preferences in each of its projects", () => {
    const own = preferences(3);
    const alone = projectSize({ name: "Website" }, own, NO_MAP);
    const teamed = projectSize(
      { name: "Website", team: "Acme" },
      [...preferences(4).map((each) => ({ ...each, team: true })), ...own],
      NO_MAP,
    );
    assert.ok(teamed.used > alone.used + 4 * 300, `${teamed.used}`);
    assert.equal(teamed.room, 8_000);
    // What the team's adds is one figure, whatever the project, for its
    // own tab and each project's alike
    const theirs = preferences(4).map((each) => ({ ...each, team: true }));
    const share = teamPreferencesSize("Acme", theirs);
    assert.ok(share > 4 * 300 && share < teamed.used, String(share));
    assert.equal(teamPreferencesSize("Acme", []), 0);
  });

  it("measures All projects against the smallest room the person's apps give it, or not at all", () => {
    const list = preferences(10);
    assert.equal(allProjectsSize(list, undefined, []), null);
    // Only apps that sync files count, not a chat app's connector
    assert.equal(allProjectsSize(list, undefined, ["claude", "mcp"]), null);
    const claude = allProjectsSize(list, undefined, ["claude-code"]);
    assert.equal(claude?.room, DEVICE_APPS["claude-code"].budget);
    const both = allProjectsSize(list, undefined, ["claude-code", "hermes"]);
    assert.equal(both?.room, DEVICE_APPS.hermes.budget);
    assert.equal(both?.used, claude?.used);
    // The standing rules come first, whatever the person's preferences
    assert.ok((claude?.used ?? 0) > 4_000 + 10 * 300, `${claude?.used}`);
  });
});
