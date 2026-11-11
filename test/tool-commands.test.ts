// Each MCP tool's twin in the sync script (G1-335): every command the table
// names is in both scripts' help, so an agent on device sync can run it. The
// API's tests check that every tool is in the table.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  TOOL_COMMANDS,
  commandLine,
  toolCommand,
} from "../src/tool-commands.js";

const help = (name: string, prefix: string) =>
  readFileSync(new URL(`../scripts/${name}`, import.meta.url), "utf8")
    .split("\n")
    .filter((line) => line.startsWith(prefix));

/** sync.ps1 spells sync.sh's --done as -Done */
const powershellFlag = (word: string) =>
  word.startsWith("--") ? `-${word[2]!.toUpperCase()}${word.slice(3)}` : word;

describe("each MCP tool's command in the sync scripts (G1-335)", () => {
  for (const [name, prefix, flag] of [
    ["sync.sh", "sh sync.sh ", (word: string) => word],
    ["sync.ps1", "sync.ps1 ", powershellFlag],
  ] as const) {
    it(`names every command in ${name}'s help`, () => {
      const lines = help(name, prefix);
      for (const [tool, twin] of Object.entries(TOOL_COMMANDS)) {
        if (!("command" in twin)) continue;
        const [first, ...rest] = twin.command.split(" ");
        const its = lines.filter((line) =>
          line.startsWith(`${prefix}${first} <app>`),
        );
        assert.ok(its.length > 0, `${tool}: no ${first} in ${name}'s help`);
        for (const word of rest.join(" ").split("|").filter(Boolean))
          assert.ok(
            its.some((line) => line.split(/[\s|]/).includes(flag(word))),
            `${tool}: ${first} has no ${word} in ${name}'s help`,
          );
      }
    });
  }

  it("puts the app after a command's first word", () => {
    assert.equal(commandLine("notes write", "codex"), "notes codex write");
    assert.equal(commandLine("context", "<app>"), "context <app>");
    assert.equal(toolCommand("read_note", "hermes"), "notes hermes read");
    assert.equal(toolCommand("get_skill", "codex"), null);
    assert.equal(toolCommand("toString", "codex"), null);
  });

  it("says why a tool has none", () => {
    for (const [tool, twin] of Object.entries(TOOL_COMMANDS))
      if ("none" in twin) assert.match(twin.none, /^The .{20,}\.$/, tool);
  });
});
