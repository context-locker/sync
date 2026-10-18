import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";

import {
  BundleError,
  MANAGED_MARKER,
  blobArchive,
  isIgnoredFile,
  parseBundle,
  sha256,
  treeHash,
  writeBundle,
  type SkillFile,
} from "../src/index.js";

const work = mkdtempSync(join(tmpdir(), "ctx-archives-"));
after(() => rmSync(work, { recursive: true, force: true }));

const skill: SkillFile[] = [
  { path: "SKILL.md", content: "---\nname: demo\n---\nHi\n", encoding: "utf8" },
  {
    path: "scripts/run.sh",
    content: "#!/bin/sh\necho hi\n",
    encoding: "utf8",
  },
  {
    path: "assets/pixel.bin",
    content: Buffer.from([0, 1, 2, 255]).toString("base64"),
    encoding: "base64",
  },
];

describe("a skill folder's tree hash", () => {
  it("hashes sorted lines of file hashes and paths", () => {
    // Byte order puts capitals first
    const lines = [
      `${sha256("---\nname: demo\n---\nHi\n")} SKILL.md\n`,
      `${sha256(Buffer.from([0, 1, 2, 255]))} assets/pixel.bin\n`,
      `${sha256("#!/bin/sh\necho hi\n")} scripts/run.sh\n`,
    ].join("");
    assert.equal(treeHash(skill), sha256(lines));
  });

  it("doesn't depend on file order or the marker file", () => {
    const reordered = [...skill].reverse();
    reordered.push({ path: MANAGED_MARKER, content: "x", encoding: "utf8" });
    assert.equal(treeHash(reordered), treeHash(skill));
  });

  it("leaves out folder settings and editor backup, lock and swap files", () => {
    const junk: SkillFile[] = [
      ".DS_Store",
      "references/.DS_Store",
      "Thumbs.db",
      "desktop.ini",
      "4913",
      "SKILL.md~",
      ".#SKILL.md",
      ".SKILL.md.swp",
      "references/.notes.md.swo",
    ].map((path) => ({ path, content: "junk", encoding: "utf8" as const }));
    assert.equal(treeHash([...skill, ...junk]), treeHash(skill));
    for (const path of [".ctx-managed", "SKILL.md~", ".x.swp"]) {
      assert.equal(isIgnoredFile(path), true, path);
    }
    for (const path of [
      "references/.ctx-managed",
      "notes.swp",
      "..swp",
      "a.md",
    ]) {
      assert.equal(isIgnoredFile(path), false, path);
    }
  });

  it("sorts by bytes, so a shorter path comes before a longer one it starts", () => {
    const files: SkillFile[] = [
      { path: "a.b", content: "1", encoding: "utf8" },
      { path: "a", content: "2", encoding: "utf8" },
      { path: "B", content: "3", encoding: "utf8" },
    ];
    const lines = [
      `${sha256("3")} B\n`,
      `${sha256("2")} a\n`,
      `${sha256("1")} a.b\n`,
    ].join("");
    assert.equal(treeHash(files), sha256(lines));
  });
});

describe("the blob archive", () => {
  it("unpacks with tar into files and folders named by hash", () => {
    const hash = treeHash(skill);
    const block = Buffer.from("<!-- block -->\n");
    const archive = blobArchive(
      [
        [sha256(block), { kind: "file", bytes: block }],
        [hash, { kind: "tree", files: skill }],
      ],
      1_760_000_000,
    );
    const dir = mkdtempSync(join(work, "tar-"));
    execFileSync("tar", ["-xmof", "-", "-C", dir], { input: archive });

    assert.deepEqual(readFileSync(join(dir, sha256(block))), block);
    assert.equal(
      readFileSync(join(dir, hash, "SKILL.md"), "utf8"),
      "---\nname: demo\n---\nHi\n",
    );
    assert.deepEqual(
      readFileSync(join(dir, hash, "assets/pixel.bin")),
      Buffer.from([0, 1, 2, 255]),
    );
    assert.equal(
      statSync(join(dir, hash, "scripts/run.sh")).mode & 0o111,
      0o111,
    );
    assert.equal(statSync(join(dir, hash, "SKILL.md")).mode & 0o111, 0);
    assert.deepEqual(readdirSync(join(dir, hash)).sort(), [
      "SKILL.md",
      "assets",
      "scripts",
    ]);
  });

  it("carries paths longer than 100 bytes in a pax header", () => {
    const deep = `${"d".repeat(60)}/${"e".repeat(60)}/${"f".repeat(60)}.md`;
    const files: SkillFile[] = [
      { path: deep, content: "deep", encoding: "utf8" },
    ];
    const hash = treeHash(files);
    const dir = mkdtempSync(join(work, "pax-"));
    execFileSync("tar", ["-xmof", "-", "-C", dir], {
      input: blobArchive([[hash, { kind: "tree", files }]], 0),
    });
    assert.equal(readFileSync(join(dir, hash, deep), "utf8"), "deep");
  });
});

describe("the skill bundle", () => {
  const limits = { files: 100, bytes: 512 * 1024 };

  it("reads back what the scripts write, with binary files as base64", () => {
    const bundle = writeBundle([
      { path: "SKILL.md", bytes: Buffer.from("text\n") },
      { path: "empty.txt", bytes: Buffer.alloc(0) },
      { path: "x.bin", bytes: Buffer.from([0, 10, 255]) },
    ]);
    assert.deepEqual(parseBundle(bundle, limits), [
      { path: "SKILL.md", content: "text\n", encoding: "utf8" },
      { path: "empty.txt", content: "", encoding: "utf8" },
      {
        path: "x.bin",
        content: Buffer.from([0, 10, 255]).toString("base64"),
        encoding: "base64",
      },
    ]);
  });

  it("refuses bundles that are malformed, cut short or too big", () => {
    const good = writeBundle([{ path: "SKILL.md", bytes: Buffer.from("abc") }]);
    assert.throws(
      () => parseBundle(Buffer.from("hello\n"), limits),
      BundleError,
    );
    assert.throws(
      () => parseBundle(good.subarray(0, good.length - 2), limits),
      BundleError,
    );
    assert.throws(
      () =>
        parseBundle(Buffer.from("context-locker-bundle 1\nfile x a\n"), limits),
      BundleError,
    );
    assert.throws(
      () => parseBundle(good, { files: 100, bytes: 2 }),
      /at most 0 KB/,
    );
    assert.throws(
      () =>
        parseBundle(
          writeBundle([
            { path: "a", bytes: Buffer.from("1") },
            { path: "b", bytes: Buffer.from("2") },
          ]),
          { files: 1, bytes: 100 },
        ),
      /at most 1 files/,
    );
  });
});
