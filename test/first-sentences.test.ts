// Every preference reaches every agent (G1-336): a file with no room for all
// of them whole keeps each one's name and first sentence, as many whole as
// fit in the person's order, marks the rest shortened and says how to read
// them, and never cuts a sentence part way.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { describe, it } from "node:test";

import {
  BLOCK_END,
  BLOCK_START,
  FIRST_SENTENCE_MAX,
  TEXT,
  firstSentence,
  sentenceLength,
  type PreferenceInput,
} from "../src/index.js";
import { renderBlock, renderContext } from "../src/render.js";

const preference = (
  name: string,
  text: string,
  about = false,
): PreferenceInput => ({
  id: randomUUID(),
  version: 1,
  name,
  text,
  ...(about ? { about: true } : {}),
});

/** A playbook of preferences, each a rule and then a long example */
const playbook = (count: number) =>
  Array.from({ length: count }, (_, index) =>
    preference(
      `rule-${String(index + 1).padStart(2, "0")}`,
      `Follow rule ${index + 1} in every session. ${"For example, this is how it reads in practice. ".repeat(8).trim()}`,
      index < 2,
    ),
  );

const block = (preferences: PreferenceInput[], budget: number) =>
  renderBlock({
    title: "## Context Locker",
    intro: "Your preferences.",
    preferences,
    budget,
    headed: true,
  });

const bytes = (text: string) => Buffer.byteLength(text, "utf8");

describe("a preference's first sentence (G1-336)", () => {
  it("ends at a stop with a space or the line's end after it, or at a line break", () => {
    const cases: [string, string, string][] = [
      ["Use plain words. Say why.", "Use plain words.", " Say why."],
      [
        "Ship on Tuesdays?\nNot in December.",
        "Ship on Tuesdays?",
        "\nNot in December.",
      ],
      ["Never force-push!", "Never force-push!", ""],
      [
        "Read context.locker first. Then work.",
        "Read context.locker first.",
        " Then work.",
      ],
      [
        "See docs/releases.md before shipping",
        "See docs/releases.md before shipping",
        "",
      ],
      [
        "One line\nand another. Then more.",
        "One line",
        "\nand another. Then more.",
      ],
      ["Version 1.2 ships. Then 1.3.", "Version 1.2 ships.", " Then 1.3."],
    ];
    for (const [text, first, rest] of cases) {
      assert.deepEqual(firstSentence(text), { first, rest }, text);
      assert.equal(first + rest, text);
    }
  });

  it("counts characters as people do, with a limit of 200", () => {
    assert.equal(FIRST_SENTENCE_MAX, 200);
    assert.equal(sentenceLength("Café 👩🏽‍💻."), 7);
    assert.equal(sentenceLength("a".repeat(200)), 200);
  });
});

describe("a file too small for every preference whole (G1-336)", () => {
  it("changes nothing when everything fits", () => {
    const preferences = playbook(4);
    const rendered = block(preferences, 40_000);
    assert.deepEqual(rendered.shortened, []);
    assert.doesNotMatch(rendered.text, /\(shortened\)/);
    for (const each of preferences)
      assert.ok(rendered.text.includes(`- ${each.name}: ${each.text}`));
  });

  it("keeps every name and first sentence, as many whole as fit in order, and says how to read the rest", () => {
    const preferences = playbook(30);
    const budget = 9_000;
    const rendered = block(preferences, budget);
    assert.ok(bytes(rendered.text) <= budget);
    assert.ok(rendered.shortened.length > 0);
    assert.deepEqual(rendered.overflow, []);
    const lines = rendered.text.split("\n");
    let shortenedYet = false;
    for (const each of preferences) {
      const whole = lines.includes(`- ${each.name}: ${each.text}`);
      const short = lines.includes(
        `- ${each.name}: ${firstSentence(each.text).first} ${TEXT.shortenedMark}`,
      );
      assert.ok(whole !== short, each.name);
      // Whole ones first, in the person's order, About first
      if (short) shortenedYet = true;
      else
        assert.ok(!shortenedYet, `${each.name} is whole after a shortened one`);
    }
    assert.ok(
      rendered.text.includes(TEXT.shortened(rendered.shortened.length, 0)),
    );
    assert.match(
      rendered.text,
      /Read them whole with the sync script's `context <app>`/,
    );
    // Every one the file shows is among its items, to read edits back
    assert.equal(rendered.items.length, preferences.length);
  });

  it("keeps every name when even the first sentences don't fit, and never cuts a sentence", () => {
    const preferences = playbook(60);
    const budget = 3_000;
    const rendered = block(preferences, budget);
    assert.ok(bytes(rendered.text) <= budget, `${bytes(rendered.text)}`);
    assert.deepEqual(rendered.overflow, []);
    const shown = rendered.text
      .split("\n")
      .filter((line) => line.startsWith("- rule-"));
    assert.equal(shown.length, preferences.length);
    for (const [index, line] of shown.entries()) {
      const each = preferences[index]!;
      assert.ok(
        line === `- ${each.name}: ${TEXT.shortenedMark}` ||
          line ===
            `- ${each.name}: ${firstSentence(each.text).first} ${TEXT.shortenedMark}`,
        line,
      );
    }
    assert.ok(shown.some((line) => line.endsWith(`: ${TEXT.shortenedMark}`)));
    assert.match(
      rendered.text,
      /to their first sentence and \d+ to their name/,
    );
  });

  it("leaves a one-sentence preference whole and unmarked where others show their first sentence", () => {
    const short = preference("plain-words", "Use plain words.");
    const preferences = [...playbook(30), short];
    const rendered = block(preferences, 9_000);
    assert.ok(rendered.shortened.length > 0);
    assert.ok(rendered.text.includes("- plain-words: Use plain words.\n"));
    assert.ok(!rendered.shortened.includes(short));
  });

  it("does the same in session-start output", () => {
    const preferences = playbook(30);
    const budget = 8_000;
    const rendered = renderContext("Docs site", preferences, budget);
    assert.ok(bytes(rendered.text) <= budget);
    assert.ok(rendered.shortened.length > 0);
    assert.deepEqual(rendered.overflow, []);
    for (const each of preferences)
      assert.ok(rendered.text.includes(`- ${each.name}: `), each.name);
    assert.match(
      rendered.text,
      /shortened here, to their first sentence, marked \(shortened\)/,
    );
  });

  it("keeps whole blocks as they were, between their markers", () => {
    const rendered = block(playbook(30), 9_000);
    assert.ok(rendered.text.startsWith(`${BLOCK_START}\n`));
    assert.ok(rendered.text.endsWith(`${BLOCK_END}\n`));
  });
});
