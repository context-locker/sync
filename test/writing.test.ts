import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  AI_TEXT_BUDGETS,
  checkAiText,
  checkAiTexts,
  compareWithBaseline,
  duplicateSentences,
  sentencesOf,
  type Finding,
} from "../src/writing.js";

const rulesOf = (
  text: string,
  extra: Partial<Parameters<typeof checkAiText>[0]> = {},
) =>
  checkAiText({ id: "t", text, ...extra }).map(
    (finding) => `${finding.rule}:${finding.match}:${finding.count}`,
  );

describe("the checks of Writing for AI apps (G1-310)", () => {
  it("finds history, references, hashes, dates and dashes", () => {
    assert.deepEqual(
      rulesOf("Older kind arguments still work, since G1-137."),
      [
        "history:older:1",
        "history:still work:1",
        "history:since g1-:1",
        "reference:G1-137:1",
      ],
    );
    assert.deepEqual(
      rulesOf("Say change #123; old CL-123 references remain."),
      ["reference:#123:1", "reference:CL-123:1"],
    );
    assert.deepEqual(
      rulesOf("Live release f220252, catalogue 926ffc95c8551ee2."),
      ["hash:a hash:2"],
    );
    assert.deepEqual(
      rulesOf("Decided on 9 Nov 2026, live since November 2026."),
      ["date:9 Nov 2026:1", "date:November 2026:1"],
    );
    assert.deepEqual(rulesOf("A rule — and its reason – here."), [
      "dash:em dash:1",
      "dash:en dash:1",
    ]);
  });

  it("leaves what an app can act on alone", () => {
    assert.deepEqual(
      rulesOf(
        "Read it with read_note, id 8780ba78-0d8d-4868-9e0c-4363724a0a8f.",
      ),
      [],
    );
    assert.deepEqual(rulesOf("Check its SHA-256 and UTF-8 text."), []);
    assert.deepEqual(
      rulesOf("Set `user_confirmed` and `waiting_on_user` only when told."),
      [],
    );
    assert.deepEqual(
      rulesOf("See https://example.com/G1-12/older#123 for it."),
      [],
    );
    assert.deepEqual(
      rulesOf("Only ones changed after this date, such as 2026-10-20.", {
        formatExamples: true,
      }),
      [],
    );
    assert.deepEqual(
      rulesOf("Only ones changed after this date, such as 2026-10-20."),
      ["date:2026-10-20:1"],
    );
  });

  it("finds American spellings and other words for the person", () => {
    assert.deepEqual(
      rulesOf(
        "Organize the color of the user's notes, as the owner and users said.",
      ),
      [
        "spelling:organize:1",
        "spelling:color:1",
        "glossary:user:2",
        "glossary:owner:1",
      ],
    );
    assert.deepEqual(rulesOf("Organise the colour of the person's notes."), []);
  });

  it("holds a text to its budget", () => {
    const limit = AI_TEXT_BUDGETS.promptLine;
    assert.deepEqual(rulesOf("x".repeat(limit), { budget: "promptLine" }), []);
    assert.deepEqual(rulesOf("x".repeat(limit + 1), { budget: "promptLine" }), [
      `budget:promptLine:${limit + 1}`,
    ]);
  });

  it("splits Markdown into the sentences it compares", () => {
    assert.deepEqual(
      sentencesOf(
        "## A heading that has six words\n- [ ] Read the playbook at the start of a session. Then open a guide topic when you need one.\n| What | **Bold** words in a table row here |\nShort one.",
      ),
      [
        "a heading that has six words",
        "read the playbook at the start of a session",
        "then open a guide topic when you need one",
        "what bold words in a table row here",
      ],
    );
  });

  it("finds a sentence said twice, in one text or across texts", () => {
    const findings = duplicateSentences([
      {
        id: "server instructions",
        text: "What the user says in this conversation comes first. What the user says in this conversation comes first.",
      },
      {
        id: "get_context",
        text: "Treat them as standing guidance. What the user says in this conversation comes first.",
      },
      { id: "tool remember", text: "Keep what you learn for later sessions." },
    ]);
    assert.deepEqual(findings, [
      {
        text: "get_context + server instructions",
        rule: "duplicate",
        match: "what the user says in this conversation comes first",
        count: 3,
      },
    ]);
  });

  it("counts texts from one source once, and leaves code blocks out", () => {
    const sentence = "Read the start here summaries above now.";
    assert.deepEqual(
      duplicateSentences([
        { id: "a project's block", text: sentence, source: "a project" },
        {
          id: "a project's session start",
          text: sentence,
          source: "a project",
        },
        { id: "an example", text: `\`\`\`\n${sentence}\n${sentence}\n\`\`\`` },
      ]),
      [],
    );
    assert.equal(
      duplicateSentences([
        { id: "a project's block", text: sentence, source: "a project" },
        { id: "everywhere's block", text: sentence },
      ])[0]?.count,
      2,
    );
  });

  it("lets a baseline only shrink", () => {
    const baseline: Finding[] = [
      { text: "setup skill", rule: "glossary", match: "user", count: 3 },
      {
        text: "tool write_ticket",
        rule: "budget",
        match: "toolDescription",
        count: 4000,
      },
      {
        text: "a + b",
        rule: "duplicate",
        match: "the same sentence in two places",
        count: 2,
      },
      { text: "fix_list", rule: "history", match: "older", count: 1 },
    ];
    const now = checkAiTexts([
      {
        id: "setup skill",
        text: "The user and the user said so, as users do.",
      },
      {
        id: "tool write_ticket",
        text: "x".repeat(3900),
        budget: "toolDescription",
      },
      { id: "a", text: "The same sentence in two places." },
      { id: "c", text: "The same sentence in two places. A new dash — here." },
    ]);
    const { added, stale, lower } = compareWithBaseline(now, baseline);
    assert.deepEqual(
      added.map(
        (finding) => `${finding.text}:${finding.rule}:${finding.match}`,
      ),
      ["c:dash:em dash"],
    );
    assert.deepEqual(
      stale.map((entry) => `${entry.text}:${entry.rule}`),
      ["fix_list:history"],
    );
    assert.deepEqual(
      lower.map(({ entry, now: count }) => `${entry.rule}:${count}`),
      ["budget:3900"],
    );
  });
});
