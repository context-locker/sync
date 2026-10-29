import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";

import { appList, namesOf, selectApp } from "../src/apps.js";
import { main, parse } from "../src/cli.js";
import { apiOf, placeFrom, shown } from "../src/place.js";

const work = mkdtempSync(join(tmpdir(), "ctx-cli-unit-"));
after(() => rmSync(work, { recursive: true, force: true }));

describe("the command line", () => {
  it("reads setup's options", () => {
    assert.deepEqual(parse(["setup"]), {
      command: "setup",
      apps: [],
      code: null,
      browser: true,
      wait: null,
    });
    const code = `ctxl_ic_${"a".repeat(43)}`;
    assert.deepEqual(
      parse([
        "setup",
        "--app",
        "codex",
        "--app",
        "codex",
        "--code",
        code,
        "--no-browser",
        "--wait",
        "30",
      ]),
      {
        command: "setup",
        apps: ["codex"],
        code,
        browser: false,
        wait: 30,
      },
    );
  });

  it("says what's wrong with a command it can't run", () => {
    const problem = (args: string[]) => {
      const parsed = parse(args);
      assert.ok("problem" in parsed, args.join(" "));
      return parsed.problem;
    };
    assert.match(problem(["install"]), /There's no command install/);
    assert.equal(
      problem(["setup", "--app", "cursor"]),
      "--app takes the app's name: claude-code, codex, hermes or openclaw.",
    );
    assert.match(problem(["setup", "--app"]), /--app takes/);
    assert.match(
      problem(["setup", "--app", "codex", "--app", "hermes"]),
      /one app at a time/,
    );
    assert.match(
      problem(["setup", "--code", "123456"]),
      /starts with ctxl_ic_/,
    );
    assert.match(problem(["setup", "--wait", "soon"]), /up to 900/);
    assert.match(problem(["setup", "--wait", "901"]), /up to 900/);
    assert.match(problem(["setup", "--force"]), /no option --force/);
  });

  it("shows help and the version", async () => {
    const lines: string[] = [];
    assert.equal(await main([], (line) => lines.push(line)), 0);
    assert.match(lines.join("\n"), /npx context-locker setup \[options\]/);
    assert.match(lines.join("\n"), /claude-code, codex, hermes or openclaw/);
    lines.length = 0;
    assert.equal(await main(["--version"], (line) => lines.push(line)), 0);
    assert.match(lines[0] ?? "", /^\d+\.\d+\.\d+$/);
    lines.length = 0;
    assert.equal(
      await main(["setup", "--nope"], (line) => lines.push(line)),
      2,
    );
  });
});

describe("finding the apps", () => {
  it("names apps as people read them", () => {
    assert.equal(namesOf(["codex"]), "Codex");
    assert.equal(namesOf(["claude-code", "codex"]), "Claude Code and Codex");
    assert.equal(
      namesOf(["claude-code", "codex", "hermes"]),
      "Claude Code, Codex and Hermes",
    );
    assert.equal(appList(), "claude-code, codex, hermes or openclaw");
  });

  it("finds Context Locker's folder and API as the sync scripts do", () => {
    const home = mkdtempSync(join(work, "home-"));
    const place = placeFrom({ HOME: home }, "linux");
    assert.equal(place.clHome, join(home, ".contextlocker"));
    assert.equal(place.usualHome, true);
    assert.equal(apiOf(place), "https://api.context.locker");
    mkdirSync(place.clHome);
    writeFileSync(join(place.clHome, "config"), "api=http://localhost:4000/\n");
    assert.equal(apiOf(place), "http://localhost:4000");
    assert.equal(
      apiOf(
        placeFrom(
          { HOME: home, CONTEXT_LOCKER_API: "https://x.test" },
          "linux",
        ),
      ),
      "https://x.test",
    );
    const elsewhere = placeFrom(
      { HOME: home, CONTEXT_LOCKER_HOME: join(work, "locker") },
      "linux",
    );
    assert.equal(elsewhere.usualHome, false);
    assert.equal(
      shown(place, join(home, ".claude", "settings.json")),
      "~/.claude/settings.json",
    );
    assert.equal(shown(place, "/etc/hosts"), "/etc/hosts");
  });
});

describe("selecting just the invoking app", () => {
  it("uses one session marker, never configuration folders or PATH", () => {
    assert.deepEqual(selectApp([], { CLAUDECODE: "1" }), {
      app: "claude-code",
    });
    assert.deepEqual(selectApp([], { CODEX_THREAD_ID: "thread" }), {
      app: "codex",
    });
    assert.deepEqual(selectApp([], { HERMES_SESSION_ID: "session" }), {
      app: "hermes",
    });
    assert.ok(
      "problem" in
        selectApp([], {
          CODEX_HOME: "/installed",
          HERMES_HOME: "/installed",
          CLAUDE_CONFIG_DIR: "/installed",
          PATH: "/apps",
        }),
    );
    assert.ok(
      "problem" in selectApp([], { CLAUDECODE: "0", CODEX_THREAD_ID: " " }),
    );
  });
  it("requires one explicit choice when absent or ambiguous", () => {
    assert.ok("problem" in selectApp([], {}));
    assert.ok(
      "problem" in
        selectApp([], { CLAUDECODE: "1", CODEX_THREAD_ID: "thread" }),
    );
    assert.deepEqual(selectApp(["openclaw"], {}), { app: "openclaw" });
    assert.deepEqual(
      selectApp(["hermes"], { CLAUDECODE: "1", HERMES_SESSION_ID: "session" }),
      { app: "hermes" },
    );
    assert.ok("problem" in selectApp(["codex", "hermes"], {}));
  });
});
