import assert from "node:assert/strict";
import { test } from "node:test";
import { environmentOf } from "../src/environment.js";
import { parse } from "../src/cli.js";

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
