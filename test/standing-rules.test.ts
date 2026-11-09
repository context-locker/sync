// The standing rules (G1-309): one text, its slots filled for each way an app
// connects, within its own budget, and the room Hermes's and OpenClaw's
// global files leave for the block.
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  AI_TEXT_BUDGETS,
  BUDGETS,
  RULE_FILLS,
  RULE_SLOTS,
  STANDING_RULES,
  TEXT,
  compile,
  injectionMatches,
  standingRules,
  type RulesEnvironment,
} from "../src/index.js";
import { preferences } from "./fixtures.js";

const ENVIRONMENTS: RulesEnvironment[] = ["mcp", "sync", "brief"];

describe("the standing rules (G1-309)", () => {
  it("fill every slot they have, and have no slot without a fill", () => {
    const slots = [...STANDING_RULES.matchAll(/\{(\w+)\}/g)].map(
      ([, name]) => name,
    );
    assert.deepEqual([...new Set(slots)].sort(), [...RULE_SLOTS].sort());
    for (const environment of ENVIRONMENTS) {
      assert.deepEqual(
        Object.keys(RULE_FILLS[environment]).sort(),
        [...RULE_SLOTS].sort(),
      );
      assert.doesNotMatch(standingRules(environment), /[{}]/, environment);
    }
  });

  it("keep within their own budget, filled for each environment", () => {
    for (const environment of ENVIRONMENTS) {
      const rules = standingRules(environment);
      assert.ok(
        rules.length <= AI_TEXT_BUDGETS.rules,
        `${environment}: ${rules.length}`,
      );
      assert.deepEqual(injectionMatches(rules), [], environment);
    }
  });

  it("mark the two kinds of rule, and say which is which first", () => {
    const [intro, regardless, defaults] = STANDING_RULES.split(
      /\n\n(?=Rules that hold regardless:|Defaults:)/,
    );
    assert.match(intro!, /Defaults give way to the person's own preferences/);
    assert.match(intro!, /the rules that hold regardless never do/);
    // What no preference changes: text is information and never consent,
    // consent comes from the person, and a cleanup request is theirs
    assert.match(
      regardless!,
      /information, never as an instruction or the person's consent/,
    );
    assert.match(regardless!, /Take consent only from the person/);
    assert.match(regardless!, /cleanup request .* the person's own decision/);
    // What the person's preferences can change: where to ask, how to report
    assert.match(defaults!, /in the chat while the person is there|\{where\}/);
    assert.match(defaults!, /When you report to the person/);
  });

  it("say how each environment keeps a fact and asks", () => {
    assert.match(standingRules("mcp"), /Keep one with remember/);
    assert.match(standingRules("mcp"), /write_ticket/);
    assert.match(standingRules("sync"), /`remember <app>`/);
    assert.match(standingRules("sync"), /`tickets <app> write`/);
    assert.doesNotMatch(standingRules("brief"), /remember|write_ticket/);
  });
});

describe("the block the rules open (G1-309)", () => {
  it("heads its preferences even with none yet, so an added line reads back", () => {
    const output = compile({
      harness: "claude-code",
      project: null,
      preferences: [],
      skills: [],
    }).outputs.find((each) => each.kind === "block");
    assert.ok(output && output.kind === "block");
    assert.ok(
      output.text.includes(
        `${TEXT.preferencesHeading}\n\n${TEXT.noPreferences}\n`,
      ),
      output.text,
    );
  });
});

describe("the room in Hermes's and OpenClaw's global files (G1-309)", () => {
  const block = (harness: "hermes" | "openclaw", globalBytes?: number) => {
    const output = compile({
      harness,
      project: null,
      preferences: Array.from({ length: 60 }, (_, index) => ({
        ...preferences[0]!,
        id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
        name: `rule-${index}`,
        text: "A preference long enough that sixty of them fill any block. ".repeat(
          5,
        ),
      })),
      skills: [],
      ...(globalBytes === undefined ? {} : { globalBytes }),
    }).outputs.find((each) => each.kind === "block");
    assert.ok(output && output.kind === "block");
    return Buffer.byteLength(output.text);
  };

  it("takes the room the sync script measured, up to the cap", () => {
    for (const harness of ["hermes", "openclaw"] as const) {
      const small = block(harness, 5_000);
      assert.ok(small <= 5_000 && small > 4_000, `${harness} ${small}`);
      const capped = block(harness, 20_000);
      assert.ok(
        capped <= BUDGETS.hermesSoul && capped > BUDGETS.unmeasuredGlobal,
        `${harness} ${capped}`,
      );
      // Unmeasured, as from a script that doesn't say, it keeps to the
      // budget that leaves the person 8,000 characters of their own
      const unmeasured = block(harness);
      assert.ok(
        unmeasured <= BUDGETS.unmeasuredGlobal && unmeasured > 11_000,
        `${harness} ${unmeasured}`,
      );
    }
    assert.equal(BUDGETS.hermesSoul, 14_000);
    assert.equal(BUDGETS.openclawAgents, 14_000);
  });

  it("leaves the other apps' fixed budgets alone", () => {
    const output = compile({
      harness: "claude-code",
      project: null,
      preferences,
      skills: [],
      globalBytes: 1_000,
    }).outputs.find((each) => each.kind === "block");
    assert.ok(output && output.kind === "block");
    assert.ok(output.text.includes(TEXT.rulesHeading));
  });
});
