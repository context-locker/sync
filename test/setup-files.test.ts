// context.locker/setup/<version>/ serves the copies of the setup steps and
// the sync scripts in setup/<version>/. A published version never changes,
// the newest one matches the scripts here, and every version names the
// hashes of its own files.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { SYNC_SCRIPT_RELEASE, SYNC_SCRIPT_VERSION } from "../src/index.js";

const SITE = fileURLToPath(new URL("../", import.meta.url));
const SCRIPTS = fileURLToPath(new URL("../scripts/", import.meta.url));

const sha256 = (path: string) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");

const versions = readdirSync(`${SITE}setup`)
  .filter((name) => /^v\d+$/.test(name))
  .sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));

describe("the published setup files", () => {
  it("include at least one version", () => {
    assert.ok(versions.length > 0);
  });

  it("match the scripts here in the newest version", () => {
    const newest = `${SITE}setup/${versions.at(-1)}/`;
    for (const script of ["sync.sh", "sync.ps1"]) {
      assert.equal(
        sha256(`${newest}${script}`),
        sha256(`${SCRIPTS}${script}`),
        `${script} changed: publish it as a new setup version, and leave the old ones as they are`,
      );
    }
  });

  for (const version of versions) {
    it(`name the hashes of their own scripts in ${version}`, () => {
      const dir = `${SITE}setup/${version}/`;
      const skill = readFileSync(`${dir}SKILL.md`, "utf8");
      assert.match(
        skill,
        /^---\nname: context-locker-setup\ndescription: .+\n---\n/,
      );
      assert.ok(
        skill.includes(`This is version ${version.slice(1)} of these steps,`),
        "the steps say which version they are",
      );
      assert.ok(
        skill.includes(`https://context.locker/setup/${version}/sync.sh`),
      );
      assert.ok(
        skill.includes(`\`${sha256(`${dir}sync.sh`)}\``),
        "sync.sh's hash",
      );
      assert.ok(
        skill.includes(`\`${sha256(`${dir}sync.ps1`)}\``),
        "sync.ps1's hash",
      );
      assert.doesNotMatch(skill, /%%[A-Z_0-9]+%%/);
    });
  }

  it("hold the newest scripts where the update command takes them from (G1-112)", () => {
    const release = SYNC_SCRIPT_RELEASE;
    assert.equal(release.version, SYNC_SCRIPT_VERSION);
    const dir = `${SITE}setup/v${release.setup}/`;
    assert.ok(
      versions.includes(`v${release.setup}`),
      `setup v${release.setup} is published`,
    );
    for (const [shell, script] of [
      ["sh", "sync.sh"],
      ["powershell", "sync.ps1"],
    ] as const) {
      assert.equal(
        sha256(`${dir}${script}`),
        release.sha256[shell],
        `SYNC_SCRIPT_RELEASE names ${script}'s SHA-256 in setup v${release.setup}`,
      );
      assert.equal(
        sha256(`${dir}${script}`),
        sha256(`${SCRIPTS}${script}`),
        `setup v${release.setup} holds the newest ${script}`,
      );
    }
    // Only a script with the update command can take it, and the newest
    // script has nothing to take
    assert.ok(release.updatesFrom >= 20, "update came in with script 20");
    assert.ok(release.updatesFrom <= release.version);
  });
});
