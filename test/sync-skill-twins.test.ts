// A skill Context Locker syncs and the app also gets elsewhere (G1-221):
// listed once when the copies match, as Context Locker's copy is left out on
// that computer until they differ or the other goes, and named once, with
// where to turn the other off, when they don't. The other copy is only read.
// These run the real scripts against a fake Context Locker.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

import {
  SYNC_SCRIPT_VERSION,
  blobArchive,
  buildManifest,
} from "../src/index.js";

const SCRIPTS = fileURLToPath(new URL("../scripts/", import.meta.url));
const WORKSPACE = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";
const SKILL_ID = "7d1c2b3a-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const PROJECT_ID = "3b9a1c2d-4e5f-4a6b-9c8d-7e6f5a4b3c2d";
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);

/** The skill as Context Locker keeps it, with its description in quotes */
const SKILL_MD =
  '---\nname: motion\ndescription: "Animate interfaces well."\n---\n\nUse transforms.\n';
/** The same skill as another source keeps it, unquoted */
const SKILL_MD_PLAIN =
  "---\nname: motion\ndescription: Animate interfaces well.\n---\n\nUse transforms.\n";
const NOTES = "Prefer opacity and transform.\n";

/** A fake Context Locker serving one skill, motion, for Claude Code */
class Fake {
  built = buildManifest({
    workspaceId: WORKSPACE,
    outputs: [
      {
        kind: "skill",
        target: "{claude}/skills/motion",
        files: [
          { path: "SKILL.md", content: SKILL_MD, encoding: "utf8" },
          { path: "references/notes.md", content: NOTES, encoding: "utf8" },
        ],
        item: { id: SKILL_ID, version: 1 },
      },
    ],
    holds: [],
    script: SYNC_SCRIPT_VERSION,
  });
  /** A playbook's own skill, motion, which its project gets in .claude/skills */
  project = buildManifest({
    workspaceId: WORKSPACE,
    outputs: [
      {
        kind: "skill",
        target: "{project}/.claude/skills/motion",
        files: [
          { path: "SKILL.md", content: SKILL_MD, encoding: "utf8" },
          { path: "references/notes.md", content: NOTES, encoding: "utf8" },
        ],
        item: { id: SKILL_ID, version: 1 },
      },
    ],
    holds: [],
  });
  requests: string[] = [];
}

describe("a skill the app also gets elsewhere (G1-221)", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new Fake();
  const work = mkdtempSync(join(tmpdir(), "ctx-twins-"));

  before(async () => {
    server = createServer((request, response) => {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk: string) => (body += chunk));
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        const route = `${request.method} ${url.pathname}`;
        fake.requests.push(route);
        const json = (status: number, value: unknown) => {
          response.writeHead(status, { "content-type": "application/json" });
          response.end(JSON.stringify(value));
        };
        if (route === "GET /v1/sync") {
          response.writeHead(200, { "content-type": "text/plain" });
          response.end(
            url.searchParams.get("project") === PROJECT_ID
              ? fake.project.text
              : fake.built.text,
          );
        } else if (route === "POST /v1/sync/blobs") {
          const hashes = body.split("\n").filter(Boolean);
          const blobs = hashes.map((hash) => [
            hash,
            fake.built.blobs.get(hash) ?? fake.project.blobs.get(hash),
          ]);
          if (blobs.some(([, blob]) => !blob))
            return json(409, { error: "changed" });
          response.writeHead(200, { "content-type": "application/x-tar" });
          response.end(blobArchive(blobs as never, 0));
        } else if (route === "POST /v1/sync/done") {
          json(200, { status: "recorded" });
        } else if (route === "GET /v1/agent") {
          json(200, {
            agent: { name: "Claude Code", machine_name: "Test" },
            workspace: { name: "Personal" },
          });
        } else {
          json(404, { error: "not_found" });
        }
      });
    });
    await new Promise<void>((resolve) =>
      server.listen(0, "127.0.0.1", resolve),
    );
    baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(work, { recursive: true, force: true });
  });

  const scriptName = (shell: string) =>
    shell === "pwsh" ? "sync.ps1" : "sync.sh";

  /** A computer with Claude Code connected, and this script where setup puts it */
  function computer(shell: string) {
    fake = new Fake();
    const home = mkdtempSync(join(work, "home-"));
    const clHome = join(home, ".contextlocker");
    mkdirSync(join(clHome, "claude-code"), { recursive: true });
    writeFileSync(join(clHome, "config"), `api=${baseUrl}\n`);
    writeFileSync(join(clHome, "claude-code", "token"), "ctxl_at_test\n", {
      mode: 0o600,
    });
    const installed = join(clHome, scriptName(shell));
    copyFileSync(join(SCRIPTS, scriptName(shell)), installed);
    return { home, clHome, installed };
  }

  function run(
    shell: string,
    machine: { home: string; installed: string },
    words: string[] = ["claude-code"],
    cwd = machine.home,
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const args =
      shell === "pwsh"
        ? [
            "-NoProfile",
            "-NonInteractive",
            "-File",
            machine.installed,
            ...words,
          ]
        : [machine.installed, ...words];
    return new Promise((resolve, reject) => {
      const child = spawn(shell, args, {
        cwd,
        env: {
          PATH: process.env.PATH ?? "",
          HOME: machine.home,
          POWERSHELL_TELEMETRY_OPTOUT: "1",
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      child.stdout
        .setEncoding("utf8")
        .on("data", (chunk: string) => (stdout += chunk));
      child.stderr
        .setEncoding("utf8")
        .on("data", (chunk: string) => (stderr += chunk));
      const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
      child.on("error", reject);
      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ status, stdout, stderr });
      });
    });
  }

  /** What Claude Code reads at the start of a session */
  const said = (stdout: string): string =>
    stdout.trim()
      ? (JSON.parse(stdout).hookSpecificOutput.additionalContext ?? "")
      : "";

  /** A plugin installed in Claude Code with this skill */
  function plugin(home: string, skillMd: string) {
    const root = join(
      home,
      ".claude",
      "plugins",
      "cache",
      "acme",
      "design",
      "1",
    );
    mkdirSync(join(root, "skills", "motion", "references"), {
      recursive: true,
    });
    writeFileSync(join(root, "skills", "motion", "SKILL.md"), skillMd);
    writeFileSync(
      join(root, "skills", "motion", "references", "notes.md"),
      NOTES,
    );
    writeFileSync(
      join(home, ".claude", "plugins", "installed_plugins.json"),
      JSON.stringify(
        {
          version: 2,
          plugins: {
            "design@acme": [{ scope: "user", installPath: root, version: "1" }],
          },
        },
        null,
        1,
      ),
    );
    return join(root, "skills", "motion");
  }

  /** Every file in a folder, with what it holds */
  function snapshot(folder: string): Record<string, string> {
    const files: Record<string, string> = {};
    const walk = (dir: string, prefix: string) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name);
        if (entry.isDirectory()) walk(path, `${prefix}${entry.name}/`);
        else files[`${prefix}${entry.name}`] = readFileSync(path, "utf8");
      }
    };
    walk(folder, "");
    return files;
  }

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("leaves its copy out while a plugin has the same skill, however it quotes it, and writes it again once they differ", async () => {
        const machine = computer(shell);
        const mine = join(machine.home, ".claude", "skills", "motion");
        const lock = join(machine.clHome, "claude-code", "global.lock");
        const theirs = plugin(machine.home, SKILL_MD_PLAIN);
        const before = snapshot(theirs);

        // The first sync writes it, as the bytes differ in their quotes
        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        assert.ok(existsSync(join(mine, "SKILL.md")));

        // The next finds the same skill, and takes its own copy out
        const second = await run(shell, machine);
        assert.equal(second.status, 0, second.stderr);
        assert.ok(!existsSync(mine), "Context Locker's copy is left out");
        assert.match(
          said(second.stdout),
          /Context Locker: left Context Locker's copy of the skill motion out, as the plugin design@acme has the same skill, so sessions list it once\./,
        );
        assert.match(
          readFileSync(lock, "utf8"),
          /^twin [0-9a-f]{64} \{claude\}\/skills\/motion [0-9a-f]{64}$/m,
        );
        // Kept in the backups, as anything the sync takes out is
        assert.ok(
          readdirSync(join(machine.clHome, "backups"), {
            recursive: true,
          }).some((path) => String(path).endsWith("SKILL.md")),
        );

        // And stays out, without saying it again
        const third = await run(shell, machine);
        assert.equal(third.status, 0, third.stderr);
        assert.ok(!existsSync(mine));
        assert.doesNotMatch(said(third.stdout), /skill motion/);

        const doctor = await run(shell, machine, ["doctor", "claude-code"]);
        assert.match(
          doctor.stdout,
          /^PASS {2}Context Locker's copy of the skill motion is left out here, as the plugin design@acme has the same skill, so sessions list it once\.$/m,
        );

        // The plugin's copy changes: Context Locker's comes back, then the
        // session start says once that the skill is listed twice
        writeFileSync(
          join(theirs, "SKILL.md"),
          SKILL_MD_PLAIN.replace("transforms", "springs"),
        );
        const back = await run(shell, machine);
        assert.equal(back.status, 0, back.stderr);
        assert.ok(existsSync(join(mine, "SKILL.md")));
        const twice = await run(shell, machine);
        assert.match(
          said(twice.stdout),
          /Context Locker: the skill motion is listed twice, as the plugin design@acme has a copy too, which differs from Context Locker's\. Context Locker keeps its own copy up to date\. Tell the person once, in plain words, that to list it once they can turn the plugin off in Claude Code with \/plugin, if its other skills aren't needed\./,
        );
        const quiet = await run(shell, machine);
        assert.doesNotMatch(said(quiet.stdout), /listed twice/);
        assert.ok(existsSync(join(mine, "SKILL.md")));
        const warned = await run(shell, machine, ["doctor", "claude-code"]);
        assert.match(
          warned.stdout,
          /^WARN {2}The skill motion is listed twice, as the plugin design@acme has a copy too, which differs from Context Locker's\. To list it once, turn the plugin off in Claude Code with \/plugin, if its other skills aren't needed\.$/m,
        );

        // The other source's copy is only ever read
        assert.deepEqual(snapshot(theirs), {
          ...before,
          "SKILL.md": SKILL_MD_PLAIN.replace("transforms", "springs"),
        });
      });

      it("leaves its copy out at once when the Claude app has the same bytes, and writes it again once that goes", async () => {
        const machine = computer(shell);
        const mine = join(machine.home, ".claude", "skills", "motion");
        const app = join(
          machine.home,
          "Library",
          "Application Support",
          "Claude",
          "local-agent-mode-sessions",
          "skills-plugin",
          "a1",
          "b2",
          "skills",
          "motion",
        );
        mkdirSync(join(app, "references"), { recursive: true });
        writeFileSync(join(app, "SKILL.md"), SKILL_MD);
        writeFileSync(join(app, "references", "notes.md"), NOTES);

        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        assert.ok(!existsSync(mine), "never written, as the bytes match");
        const doctor = await run(shell, machine, ["doctor", "claude-code"]);
        assert.match(
          doctor.stdout,
          /^PASS {2}Context Locker's copy of the skill motion is left out here, as the Claude app, from the skills uploaded to claude\.ai has the same skill, so sessions list it once\. A Claude Code session outside the Claude app doesn't list it while it's left out\.$/m,
        );

        rmSync(app, { recursive: true });
        const gone = await run(shell, machine);
        assert.equal(gone.status, 0, gone.stderr);
        assert.equal(readFileSync(join(mine, "SKILL.md"), "utf8"), SKILL_MD);
      });

      it("leaves a project's copy out when the person's own copy that applies everywhere is the same", async () => {
        const machine = computer(shell);
        // Nothing applies everywhere, so only the playbook's own skill syncs
        fake.built = buildManifest({
          workspaceId: WORKSPACE,
          outputs: [],
          holds: [],
          script: SYNC_SCRIPT_VERSION,
        });
        // The person's own skill, which every project gets, as Claude Code
        // reads ~/.claude/skills in all of them
        const own = join(machine.home, ".claude", "skills", "motion");
        mkdirSync(join(own, "references"), { recursive: true });
        writeFileSync(join(own, "SKILL.md"), SKILL_MD);
        writeFileSync(join(own, "references", "notes.md"), NOTES);
        const before = snapshot(own);
        // A repo linked to the playbook, where its skills go
        const project = join(machine.home, "site");
        mkdirSync(project);
        writeFileSync(
          join(project, ".contextlocker.json"),
          JSON.stringify({ workspace: WORKSPACE, project: PROJECT_ID }),
        );
        const linked = await run(
          shell,
          machine,
          [
            "claude-code",
            shell === "pwsh" ? "-Project" : "--project",
            PROJECT_ID,
          ],
          project,
        );
        assert.equal(linked.status, 0, linked.stderr);
        // The playbook's copy stays out of the project, as the person's own
        // folder already gives it the same skill
        assert.ok(!existsSync(join(project, ".claude", "skills", "motion")));
        assert.match(
          readFileSync(
            join(
              machine.clHome,
              "claude-code",
              "projects",
              `${PROJECT_ID}.lock`,
            ),
            "utf8",
          ),
          /^twin [0-9a-f]{64} \{project\}\/\.claude\/skills\/motion [0-9a-f]{64}$/m,
        );
        assert.deepEqual(snapshot(own), before);
      });
    });
  }
});
