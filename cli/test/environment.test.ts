import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it, test } from "node:test";
import {
  CLOUD_SANDBOX_WARNING,
  COWORK_REFUSAL,
  claudeCloudOf,
  environmentOf,
} from "../src/environment.js";
import { parse } from "../src/cli.js";
import { placeFrom } from "../src/place.js";
import { FAILED, setup } from "../src/setup.js";

test("uses provider signals or an explicit environment, leaving ambiguous sessions unknown", () => {
  assert.equal(environmentOf({ CLAUDE_CODE_REMOTE: "true" }), "cloud");
  assert.equal(environmentOf({ CODESPACES: "true" }), "cloud");
  assert.equal(environmentOf({ CODESPACES: "true" }, "computer"), "computer");
  for (const env of [
    {},
    { HOSTNAME: "vm", OSTYPE: "linux" },
    { SSH_CONNECTION: "remote", CI: "true" },
    { CLAUDE_CODE_REMOTE: "false", CODESPACES: "false" },
  ]) {
    assert.equal(environmentOf(env), undefined);
  }
});

test("accepts only the two explicit locations", () => {
  const parsed = parse(["setup", "--app", "codex", "--environment", "cloud"]);
  assert.ok(!("problem" in parsed));
  assert.equal(parsed.environment, "cloud");
  assert.ok("problem" in parse(["setup", "--environment", "vm"]));
});

test("tells Claude in Cowork from other Claude cloud sessions, never a codespace (G1-260)", () => {
  assert.equal(
    claudeCloudOf({
      CLAUDE_CODE_REMOTE: "true",
      CLAUDE_CODE_ENTRYPOINT: "remote_cowork",
    }),
    "cowork",
  );
  assert.equal(
    claudeCloudOf({
      CLAUDE_CODE_REMOTE: "true",
      CLAUDE_CODE_ENTRYPOINT: "cli",
    }),
    "other",
  );
  assert.equal(claudeCloudOf({ CLAUDE_CODE_REMOTE: "true" }), "other");
  for (const env of [
    {},
    { CODESPACES: "true" },
    { CLAUDE_CODE_ENTRYPOINT: "remote_cowork" },
    { CLAUDE_CODE_REMOTE: "false", CLAUDE_CODE_ENTRYPOINT: "remote_cowork" },
  ]) {
    assert.equal(claudeCloudOf(env), null);
  }
});

describe("setup in a Claude cloud session (G1-260)", () => {
  const work = mkdtempSync(join(tmpdir(), "ctx-cli-cloud-"));
  after(() => rmSync(work, { recursive: true, force: true }));

  /** Setup with no network: any request fails the test */
  const run = async (
    env: Record<string, string>,
    environment?: "cloud" | "computer",
  ) => {
    const home = mkdtempSync(join(work, "home-"));
    const place = placeFrom({ HOME: home, ...env }, "linux");
    const said: string[] = [];
    let asked = false;
    const code = await setup({
      place,
      apps: ["claude-code"],
      environment,
      code: null,
      browser: false,
      wait: 0,
      out: (line) => said.push(line),
      fetch: async () => {
        asked = true;
        throw new Error("setup asked Context Locker for something");
      },
    }).catch(() => null);
    return {
      code,
      said,
      asked,
      saved: existsSync(join(place.clHome, "sync.sh")),
    };
  };
  const cowork = {
    CLAUDE_CODE_REMOTE: "true",
    CLAUDE_CODE_ENTRYPOINT: "remote_cowork",
  };

  it("stops in Cowork, before saving or asking for anything, unless told to go on", async () => {
    for (const environment of [undefined, "computer"] as const) {
      const stopped = await run(cowork, environment);
      assert.equal(stopped.code, FAILED);
      assert.ok(stopped.said.includes(COWORK_REFUSAL), stopped.said.join("\n"));
      assert.equal(stopped.saved, false);
      assert.equal(stopped.asked, false);
    }
    // --environment cloud connects it on purpose, so setup goes on
    const told = await run(cowork, "cloud");
    assert.ok(!told.said.includes(COWORK_REFUSAL));
    assert.ok(
      told.said.some((line) => line.startsWith("Setting up Claude Code")),
    );
    assert.equal(told.saved, true);
    assert.equal(told.asked, true);
  });

  it("warns in another Claude cloud session, and goes on", async () => {
    const warned = await run({ CLAUDE_CODE_REMOTE: "true" });
    assert.ok(warned.said.includes(CLOUD_SANDBOX_WARNING));
    assert.ok(
      warned.said.some((line) => line.startsWith("Setting up Claude Code")),
    );
    assert.equal(warned.saved, true);
    // A codespace, or a computer, sets up as before
    for (const env of [{ CODESPACES: "true" }, {}] as Record<
      string,
      string
    >[]) {
      const plain = await run(env);
      assert.ok(!plain.said.includes(CLOUD_SANDBOX_WARNING));
      assert.ok(!plain.said.includes(COWORK_REFUSAL));
    }
  });
});
