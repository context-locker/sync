import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  MANIFEST_HEADER,
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
  projectPreferences,
  skills,
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
    assert.ok(block?.kind === "block" && skill?.kind === "skill");

    assert.equal(
      manifest.text,
      [
        MANIFEST_HEADER,
        `workspace ${WORKSPACE_ID}`,
        `block ${blockHash(block.text)} {codex}/AGENTS.md`,
        `skill ${treeHash(skill.files)} {agents}/skills/code-review ${skill.item.id} 2`,
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
});
