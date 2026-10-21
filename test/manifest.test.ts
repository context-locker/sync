import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  GATHER_SKILL_ID,
  GATHER_SKILL_VERSION,
  MANIFEST_HEADER,
  SYNC_SCRIPT_VERSION,
  blockHash,
  buildManifest,
  compile,
  parseManifest,
  parseTarget,
  sha256,
  treeHash,
} from "../src/index.js";
import {
  WORKSPACE_ID,
  preferences,
  project,
  projectNotes,
  projectPreferences,
  skills,
  tagList,
} from "./fixtures.js";

const outputs = compile({
  harness: "codex",
  project: null,
  preferences,
  skills,
}).outputs;

describe("the sync manifest", () => {
  it("lists blocks, skills and holds with their hashes, in a fixed order", () => {
    const hold = {
      target: "{agents}/skills/code-review",
      hash: "a".repeat(64),
    };
    const manifest = buildManifest({
      workspaceId: WORKSPACE_ID,
      outputs,
      holds: [hold],
    });
    const block = outputs[0];
    const skill = outputs[1];
    const gather = outputs[2];
    assert.ok(
      block?.kind === "block" &&
        skill?.kind === "skill" &&
        gather?.kind === "skill",
    );

    // Context Locker's own Gather skill goes with the person's
    assert.equal(
      manifest.text,
      [
        MANIFEST_HEADER,
        `workspace ${WORKSPACE_ID}`,
        `block ${blockHash(block.text)} {codex}/AGENTS.md`,
        `skill ${treeHash(skill.files)} {agents}/skills/code-review ${skill.item.id} 2`,
        `skill ${treeHash(gather.files)} {agents}/skills/context-locker-gather ${GATHER_SKILL_ID} ${GATHER_SKILL_VERSION}`,
        `hold ${"a".repeat(64)} {agents}/skills/code-review`,
        "",
      ].join("\n"),
    );
    assert.equal(manifest.etag, sha256(manifest.text));
    assert.deepEqual(manifest.blobs.get(blockHash(block.text)), {
      kind: "file",
      bytes: Buffer.from(block.text),
    });
    assert.deepEqual(manifest.blobs.get(treeHash(skill.files)), {
      kind: "tree",
      files: skill.files,
    });
  });

  it("gives the same text and ETag for the same playbook", () => {
    const a = buildManifest({ workspaceId: WORKSPACE_ID, outputs, holds: [] });
    const b = buildManifest({
      workspaceId: WORKSPACE_ID,
      outputs: [...outputs].reverse(),
      holds: [],
    });
    assert.equal(a.text, b.text);
    assert.equal(a.etag, b.etag);
  });

  it("carries session-start text as a context line", () => {
    const personal = compile({
      harness: "claude-code",
      project: { ...project, layer: "personal" },
      preferences: projectPreferences,
      skills: [],
    }).outputs;
    const manifest = buildManifest({
      workspaceId: WORKSPACE_ID,
      outputs: personal,
      holds: [],
    });
    const context = personal[0];
    assert.ok(context?.kind === "context");
    assert.match(
      manifest.text,
      new RegExp(`^context ${sha256(context.text)}$`, "m"),
    );
  });

  it("lists a project's notes folder: its README as a file, and each note with its id and version", () => {
    const folder = compile({
      harness: "codex",
      project: { ...project, layer: "repo" },
      preferences: projectPreferences,
      skills: [],
      notes: projectNotes,
      tags: tagList,
    }).outputs;
    const manifest = buildManifest({
      workspaceId: WORKSPACE_ID,
      outputs: folder,
      holds: [],
    });
    const lines = manifest.text.split("\n");
    const readme = folder.find((output) => output.kind === "file");
    const plan = folder.find(
      (output) =>
        output.kind === "note" &&
        output.target === "{project}/.context-locker/notes/release-plan.md",
    );
    assert.ok(readme?.kind === "file" && plan?.kind === "note");
    assert.deepEqual(lines.slice(2, 4), [
      `block ${blockHash((folder[0] as { text: string }).text)} {project}/AGENTS.md`,
      `file ${sha256(readme.text)} {project}/.context-locker/notes/README.md`,
    ]);
    assert.ok(
      lines.includes(
        `note ${sha256(plan.text)} {project}/.context-locker/notes/release-plan.md d1111111-1111-4111-8111-111111111111 3`,
      ),
    );
    // Each one's hash is the file's, byte for byte, as the scripts hash it
    assert.deepEqual(manifest.blobs.get(sha256(plan.text)), {
      kind: "file",
      bytes: Buffer.from(plan.text),
    });
    assert.deepEqual(parseManifest(manifest.text).entries, manifest.entries);
  });

  it("reads back, skipping lines it doesn't know", () => {
    const manifest = buildManifest({
      workspaceId: WORKSPACE_ID,
      outputs,
      holds: [],
    });
    const parsed = parseManifest(`${manifest.text}later-kind something new\n`);
    assert.equal(parsed.workspaceId, WORKSPACE_ID);
    assert.deepEqual(parsed.entries, manifest.entries);
  });

  it("refuses targets that could reach outside their root", () => {
    for (const target of [
      "{codex}/../AGENTS.md",
      "{codex}/./AGENTS.md",
      "/etc/passwd",
      "{codex}/with space.md",
      "{codex}",
    ]) {
      assert.throws(
        () =>
          buildManifest({
            workspaceId: WORKSPACE_ID,
            outputs: [{ kind: "block", target, text: "x\n", items: [] }],
            holds: [],
          }),
        /usable target/,
        target,
      );
    }
  });

  it("names the newest sync script, and a project's links to paths in its repo", () => {
    const runbook = "a1111111-1111-4111-8111-111111111111";
    const guide = "b2222222-2222-4222-8222-222222222222";
    const manifest = buildManifest({
      workspaceId: WORKSPACE_ID,
      outputs,
      holds: [],
      script: SYNC_SCRIPT_VERSION,
      links: [
        { id: runbook, path: "docs/run book.md" },
        { id: guide, path: "AGENTS.md" },
      ],
    });
    const lines = manifest.text.split("\n");
    assert.equal(lines[2], `script ${SYNC_SCRIPT_VERSION}`);
    // By path, after the files, each path the rest of its line
    assert.deepEqual(
      lines.filter((line) => line.startsWith("link ")),
      [`link ${guide} AGENTS.md`, `link ${runbook} docs/run book.md`],
    );
    assert.deepEqual(parseManifest(manifest.text).entries, manifest.entries);
    assert.deepEqual(
      parseManifest(manifest.text).entries.filter(
        (entry) => entry.kind === "link",
      ),
      [
        { kind: "link", id: guide, path: "AGENTS.md" },
        { kind: "link", id: runbook, path: "docs/run book.md" },
      ],
    );

    for (const path of [
      "",
      "/etc/passwd",
      "~/notes.md",
      "docs/../../secrets",
      "docs/a\nblock x {codex}/AGENTS.md",
      "docs\\runbook.md",
      " docs/runbook.md",
    ]) {
      assert.throws(
        () =>
          buildManifest({
            workspaceId: WORKSPACE_ID,
            outputs: [],
            holds: [],
            links: [{ id: guide, path }],
          }),
        /usable path/,
        JSON.stringify(path),
      );
    }
  });

  it("names the version the scripts here say they are", () => {
    const scripts = new URL("../scripts/", import.meta.url);
    assert.match(
      readFileSync(new URL("sync.sh", scripts), "utf8"),
      new RegExp(`^SCRIPT_VERSION=${SYNC_SCRIPT_VERSION}$`, "m"),
    );
    assert.match(
      readFileSync(new URL("sync.ps1", scripts), "utf8"),
      new RegExp(`^\\$ScriptVersion = ${SYNC_SCRIPT_VERSION}$`, "m"),
    );
  });
});

describe("targets an app may write", () => {
  it("allow the app's own files and skill folders", () => {
    assert.deepEqual(parseTarget("codex", "{codex}/AGENTS.md"), {
      kind: "block",
      target: "{codex}/AGENTS.md",
    });
    assert.deepEqual(
      parseTarget("claude-code", "{project}/.claude/skills/docs-style"),
      {
        kind: "skill",
        target: "{project}/.claude/skills/docs-style",
        name: "docs-style",
      },
    );
  });

  it("refuse other apps' files and bad skill names", () => {
    assert.equal(
      parseTarget("codex", "{claude}/rules/context-locker.md"),
      null,
    );
    assert.equal(parseTarget("claude-code", "{codex}/AGENTS.md"), null);
    assert.equal(parseTarget("codex", "{agents}/skills/Bad_Name"), null);
    assert.equal(parseTarget("codex", "{agents}/skills/a/b"), null);
    assert.equal(parseTarget("openclaw", "{project}/AGENTS.md"), null);
  });

  it("allow a project's notes folder to apps that work in project folders", () => {
    assert.deepEqual(
      parseTarget("hermes", "{project}/.context-locker/notes/README.md"),
      { kind: "file", target: "{project}/.context-locker/notes/README.md" },
    );
    assert.deepEqual(
      parseTarget(
        "claude-code",
        "{project}/.context-locker/notes/everywhere/writing-voice.md",
      ),
      {
        kind: "note",
        target: "{project}/.context-locker/notes/everywhere/writing-voice.md",
        name: "writing-voice",
        everywhere: true,
      },
    );
    assert.equal(
      parseTarget("codex", "{project}/.context-locker/notes/con.md"),
      null,
    );
    assert.equal(
      parseTarget(
        "codex",
        "{project}/.context-locker/notes/everywhere/README.md",
      ),
      null,
    );
  });
});
