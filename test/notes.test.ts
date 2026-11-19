import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import {
  COMPILED_HARNESSES,
  compile,
  injectionMatches,
  noteFileName,
  parseNoteReply,
  parseTarget,
  renderNoteFile,
  sha256,
  writeNoteReply,
  yamlString,
} from "../src/index.js";
import { project, projectNotes, projectPreferences } from "./fixtures.js";

const GOLDEN = join(dirname(fileURLToPath(import.meta.url)), "golden");

function golden(name: string, actual: string) {
  const file = join(GOLDEN, `${name}.txt`);
  if (process.env.UPDATE_GOLDEN === "1" || !existsSync(file)) {
    writeFileSync(file, actual);
  }
  assert.equal(actual, readFileSync(file, "utf8"), `${name} changed`);
}

describe("a note's file, as an export and notes-move-out write it", () => {
  const [plan, decision, voice, reserved] = projectNotes as [
    (typeof projectNotes)[0],
    (typeof projectNotes)[0],
    (typeof projectNotes)[0],
    (typeof projectNotes)[0],
  ];

  it("renders each note as front matter, then the note", () => {
    golden(
      "notes-files",
      [
        [plan, "Docs site"],
        [decision, "Docs site"],
        [voice, "everywhere"],
        [reserved, ["Docs site", "App"]],
      ]
        .map(
          ([note, appliesTo]) =>
            `== ${noteFileName(note as typeof plan)}.md\n${renderNoteFile(note as typeof plan, appliesTo as string | string[])}`,
        )
        .join("\n"),
    );
    // Moved out of Context Locker, a note's file is the repo's own, with no
    // id or version
    assert.doesNotMatch(
      renderNoteFile(plan, "Docs site", { ids: false }),
      /^(id|version):/m,
    );
  });

  it("says where a note that copies a document came from (CLK-442)", () => {
    const copied = renderNoteFile(
      { ...plan, cameFrom: "https://www.notion.so/acme/Release-plan" },
      "Docs site",
    );
    assert.match(
      copied,
      /^applies_to: "Docs site"\ncame_from: "https:\/\/www\.notion\.so\/acme\/Release-plan"\nid: /m,
    );
    // One that copies nothing has no line for it
    assert.doesNotMatch(
      renderNoteFile({ ...plan, cameFrom: null }, "Docs site"),
      /came_from/,
    );
  });

  it("quotes every string, so colons, quotes and backslashes can't break it", () => {
    assert.equal(yamlString('a: "b" \\ c'), '"a: \\"b\\" \\\\ c"');
    assert.equal(yamlString("tab\there\nline"), '"tab\\there\\nline"');
    // Characters people can't see are spelled out
    assert.equal(yamlString("zero\u200bwidth"), '"zero\\u200bwidth"');
    assert.equal(yamlString("tag\u{e0041}"), '"tag\\U000e0041"');
    assert.equal(yamlString("line\u2028break"), '"line\\u2028break"');
    assert.equal(yamlString("Café ✨"), '"Café ✨"');
    const text = renderNoteFile(decision, "Docs site");
    assert.match(
      text,
      /^title: "Hosting: \\"Vercel\\" over Netlify"$/m,
      "the title stays one quoted string",
    );
  });

  it("is named after its note, with part of its id when Windows keeps the name", () => {
    assert.equal(noteFileName(plan), "release-plan");
    assert.equal(noteFileName(reserved), "con-d4444444");
    assert.equal(
      noteFileName({ name: "readme", id: plan.id }),
      "readme-d1111111",
    );
  });

  it("never looks like prompt injection", () => {
    for (const note of projectNotes) {
      assert.deepEqual(injectionMatches(renderNoteFile(note, "Docs site")), []);
    }
  });
});

describe("a project's sync", () => {
  it("writes no notes, as a computer keeps no copies of them (CLK-423)", () => {
    for (const harness of COMPILED_HARNESSES) {
      for (const layer of ["repo", "personal"] as const) {
        for (const output of compile({
          harness,
          project: { ...project, layer },
          preferences: projectPreferences,
          skills: [],
        }).outputs) {
          assert.ok(
            !("target" in output) || !output.target.includes(".context-locker"),
            `${harness} ${layer}`,
          );
        }
        // Nor may an app's sync write one
        for (const target of [
          "{project}/.context-locker/notes/release-plan.md",
          "{project}/.context-locker/notes/README.md",
        ]) {
          assert.equal(parseTarget(harness, target), null, target);
        }
      }
    }
  });
});

describe("the answer to an app's own memory file", () => {
  it("reads back as the scripts read it", () => {
    const file = renderNoteFile(
      projectNotes[0] as (typeof projectNotes)[0],
      "Docs site",
    );
    const reply = writeNoteReply({
      status: "saved",
      id: "d1111111-1111-4111-8111-111111111111",
      version: 4,
      hash: sha256(file),
      target: "{claude}/projects/x/memory/MEMORY.md",
      file,
    });
    const parsed = parseNoteReply(reply);
    assert.ok(parsed);
    assert.equal(parsed.status, "saved");
    assert.equal(parsed.version, 4);
    assert.equal(parsed.file.toString("utf8"), file);
    assert.equal(
      parseNoteReply(Buffer.from("context-locker-note 2\nsaved x\n")),
      null,
    );
    assert.equal(
      parseNoteReply(Buffer.from("context-locker-note 1\nsaved\n")),
      null,
    );
  });
});
