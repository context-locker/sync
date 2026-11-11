// The sync scripts' import and import-submit, called gather and
// gather-submit before, run for real in each shell against a fake home folder
// holding every AI app's files. An import reads only its own app's files
// (G1-206), follows no link, never copies a secret, and keeps its working
// sets private; import-submit sends the plan with the app's token.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

import { BLOCK_END, BLOCK_START } from "../src/index.js";
import { computerName, computerPattern } from "./computer-name.js";
import { SCRIPT_PATH } from "./script-path.js";

const SCRIPT = fileURLToPath(new URL("../scripts/sync.sh", import.meta.url));
const PS_SCRIPT = fileURLToPath(
  new URL("../scripts/sync.ps1", import.meta.url),
);
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);

const sha256 = (data: Buffer | string) =>
  createHash("sha256").update(data).digest("hex");

const UPLOAD_ID = "0b5f6c2e-4a7d-4e8b-9f10-2c3d4e5f6a7b";

const block = (text: string) => `${BLOCK_START}\n${text}\n${BLOCK_END}\n`;

// Secrets of each kind the API refuses, which gather must never copy
const SECRETS: Record<string, string> = {
  "github.md":
    "Push with ghp_abcdefghijklmnopqrstuvwxyzABCDEF0123 when asked.\n",
  "aws.md": "The key is AKIAIOSFODNN7EXAMPLE for the bucket.\n",
  "pem.md":
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA0Z3VS5JJcds3\n-----END RSA PRIVATE KEY-----\n",
  "openai.md":
    "Use sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD in tests.\n",
  "password.md": "Database password: hunter2hunter2\n",
  "next-line.md": "api_key:\n    zyxwvutsrqponm\n",
  "address.md": "Connect to postgres://admin:s3cretpass@db.example.com/app\n",
  "context-locker.md": "token ctxl_at_0123456789abcdefghijKLMNOP\n",
};
const KINDS: Record<string, string> = {
  "github.md": "a GitHub token",
  "aws.md": "an AWS access key",
  "pem.md": "a private key",
  "openai.md": "an OpenAI API key",
  "password.md": "a password or key",
  "next-line.md": "a password or key",
  "address.md": "a password in an address",
  "context-locker.md": "a Context Locker token",
};
// What a secret file holds that must never reach the working set
const SECRET_VALUES = [
  "ghp_abcdefghijklmnopqrstuvwxyzABCDEF0123",
  "AKIAIOSFODNN7EXAMPLE",
  "MIIEpAIBAAKCAQEA0Z3VS5JJcds3",
  "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD",
  "hunter2hunter2",
  "zyxwvutsrqponm",
  "s3cretpass",
  "ctxl_at_0123456789abcdefghijKLMNOP",
];

const SECRET_EXAMPLES = JSON.parse(
  readFileSync(new URL("./secret-examples.json", import.meta.url), "utf8"),
) as Array<{
  name: string;
  text: string;
  kind: string | null;
  evidence?: "cut short" | "masked" | "short provider key";
}>;

/** Writes a file, making its folders */
function put(path: string, content: string | Buffer) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}

interface Seen {
  method: string;
  path: string;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}

describe("import, and import-submit", () => {
  let server: Server;
  let baseUrl: string;
  const seen: Seen[] = [];
  let answer: { status: number; type: string; body: string } = {
    status: 200,
    type: "text/plain; charset=utf-8",
    body: "Brought in 2 items with Gather.\n",
  };
  // When set, how Context Locker answers the start of an upload
  let uploadAnswer: { status: number; body: string } | null = null;
  const work = mkdtempSync(join(tmpdir(), "ctx-gather-"));

  before(async () => {
    server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        seen.push({
          method: request.method ?? "",
          path: request.url ?? "",
          headers: request.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        });
        // An upload starts with its id and takes each part, as the API does
        if (request.url === "/v1/uploads" && request.method === "POST") {
          if (uploadAnswer) {
            response.writeHead(uploadAnswer.status, {
              "content-type": "application/json",
            });
            response.end(uploadAnswer.body);
            return;
          }
          response.writeHead(201, { "content-type": "text/plain" });
          response.end(`${UPLOAD_ID}\n`);
          return;
        }
        if (request.url?.startsWith(`/v1/uploads/${UPLOAD_ID}/parts/`)) {
          response.writeHead(204);
          response.end();
          return;
        }
        response.writeHead(answer.status, { "content-type": answer.type });
        response.end(answer.body);
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

  /** A computer where every AI app has files and is connected */
  function computer() {
    const home = mkdtempSync(join(work, "home-"));
    put(join(home, ".contextlocker", "config"), `api=${baseUrl}\n`);
    for (const app of ["claude-code", "codex", "hermes", "openclaw"]) {
      put(join(home, ".contextlocker", app, "token"), "ctxl_at_test\n");
    }
    const outside = join(home, "outside");
    put(join(outside, "notes.md"), "OUTSIDE-THE-SOURCE-FOLDER\n");
    put(join(outside, "skill", "SKILL.md"), "OUTSIDE-SKILL\n");

    // Claude Code
    const claude = join(home, ".claude");
    put(
      join(claude, "CLAUDE.md"),
      `# Mine\n\nUse plain words.\n\n${block("## Context Locker\n\n- synced-pref: CLAUDE-BLOCK-TEXT")}`,
    );
    put(join(claude, "rules", "style.md"), "Keep functions short.\n");
    put(
      join(claude, "rules", "context-locker.md"),
      block("## Context Locker\n\n- rules-pref: RULES-BLOCK-TEXT"),
    );
    symlinkSync(join(outside, "notes.md"), join(claude, "rules", "linked.md"));
    put(
      join(claude, "skills", "my-skill", "SKILL.md"),
      "---\nname: my-skill\ndescription: Mine.\n---\n\nSteps.\n",
    );
    put(
      join(claude, "skills", "my-skill", "references", "guide.md"),
      "Guide.\n",
    );
    put(
      join(claude, "skills", "my-skill", "logo.png"),
      Buffer.from([137, 80, 78, 71, 0, 1, 2]),
    );
    put(join(claude, "skills", "my-skill", "data.txt"), Buffer.from("a\0b"));
    put(join(claude, "skills", "my-skill", ".DS_Store"), "x");
    put(join(claude, "skills", "my-skill", "empty.txt"), "");
    put(
      join(claude, "skills", "my-skill", "agents", "openai.yaml"),
      "name: Useful skill\n",
    );
    put(
      join(claude, "skills", "synced-skill", "SKILL.md"),
      "---\nname: synced-skill\ndescription: Synced.\n---\nMANAGED-SKILL-TEXT\n",
    );
    put(
      join(claude, "skills", "synced-skill", ".ctx-managed"),
      "Managed by Context Locker: skill x, version 1.\n",
    );
    symlinkSync(join(outside, "skill"), join(claude, "skills", "linked-skill"));
    put(
      join(claude, "projects", "-home-ada-repo", "memory", "MEMORY.md"),
      "- The repo deploys from main.\n",
    );
    put(
      join(claude, "projects", "-home-ada-repo", "memory", "testing.md"),
      "- Run the tests with npm test.\n",
    );
    put(
      join(claude, "projects", "-home-ada-repo", "0b6f1c2e.jsonl"),
      '{"TRANSCRIPT-LINE": true}\n',
    );

    // Codex, and the skills folder it shares with OpenClaw
    const codex = join(home, ".codex");
    put(
      join(codex, "AGENTS.md"),
      `Codex: answer briefly.\n\n${block("## Context Locker\n\n- codex-pref: CODEX-BLOCK-TEXT")}`,
    );
    put(join(codex, "memories", "notes.md"), "Ada prefers pnpm.\n");
    for (const [name, content] of Object.entries(SECRETS)) {
      put(join(codex, "memories", "secrets", name), content);
    }
    put(join(codex, "memories", "big.md"), "x".repeat(4_400_000));
    put(
      join(codex, "skills", ".system", "skill-creator", "SKILL.md"),
      "SYSTEM-SKILL\n",
    );
    put(
      join(codex, "skills", "codex-skill", "SKILL.md"),
      "---\nname: codex-skill\ndescription: C.\n---\n",
    );
    put(
      join(home, ".agents", "skills", "shared-skill", "SKILL.md"),
      "---\nname: shared-skill\ndescription: S.\n---\n",
    );

    // Hermes
    const hermes = join(home, ".hermes");
    put(
      join(hermes, "SOUL.md"),
      `You are Hermes, calm and exact.\n\n${block("## Context Locker\n\n- hermes-pref: HERMES-BLOCK-TEXT")}`,
    );
    put(
      join(hermes, "memories", "MEMORY.md"),
      "Server runs Ubuntu.\n§\nUses fish.\n",
    );
    put(join(hermes, "memories", "USER.md"), "Ada is a designer.\n");
    put(join(hermes, "memories", "MEMORY.md.bak.1760000000"), "OLD-BACKUP\n");
    put(join(hermes, "skills", ".bundled_manifest"), "bundled-skill:abc123\n");
    put(
      join(hermes, "skills", "bundled-skill", "SKILL.md"),
      "---\nname: bundled-skill\ndescription: B.\n---\nBUNDLED-TEXT\n",
    );
    put(
      join(hermes, "skills", "research", "arxiv-notes", "SKILL.md"),
      "---\nname: arxiv-notes\ndescription: A.\n---\n",
    );

    // OpenClaw
    const openclaw = join(home, ".openclaw");
    const workspace = join(openclaw, "workspace");
    put(join(workspace, "AGENTS.md"), "Reply in one message.\n");
    put(join(workspace, "SOUL.md"), "Molty, a lobster.\n");
    put(join(workspace, "IDENTITY.md"), "Name: Molty\n");
    put(
      join(workspace, "USER.md"),
      `Ada lives in Auckland.\n\n${block("## Context Locker\n\n- oc-pref: OPENCLAW-BLOCK-TEXT")}`,
    );
    put(join(workspace, "MEMORY.md"), "Ada's studio is Scrollport.\n");
    put(join(workspace, "memory", "2026-10-20.md"), "Fixed the login bug.\n");
    put(
      join(workspace, "skills", "ws-skill", "SKILL.md"),
      "---\nname: ws-skill\ndescription: W.\n---\n",
    );
    put(
      join(openclaw, "skills", "hub-skill", "SKILL.md"),
      "---\nname: hub-skill\ndescription: H.\n---\n",
    );

    // Grok Build
    put(join(home, ".grok", "GROK.md"), "Grok: cite sources.\n");
    put(
      join(home, ".grok", "skills", "grok-skill", "SKILL.md"),
      "---\nname: grok-skill\ndescription: G.\n---\n",
    );

    // The project the gather runs in, with its notes folder
    const repo = join(home, "repo");
    put(
      join(repo, "AGENTS.md"),
      `# Repo\n\nUse tabs.\n\n${block("## Context Locker: Repo\n\n- repo-pref: REPO-BLOCK-TEXT")}`,
    );
    put(join(repo, "CLAUDE.md"), "Read AGENTS.md.\n");
    put(join(repo, ".claude", "CLAUDE.md"), "Prefer small commits.\n");
    put(
      join(repo, ".context-locker", "notes", "plan.md"),
      "NOTES-FOLDER-TEXT\n",
    );
    return { home, repo, codex };
  }

  function run(
    shell: string,
    home: string,
    args: string[],
    cwd: string,
    env: Record<string, string> = {},
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const command =
      shell === "pwsh"
        ? ["-NoProfile", "-NonInteractive", "-File", PS_SCRIPT, ...args]
        : [SCRIPT, ...args];
    return new Promise((resolve, reject) => {
      const child = spawn(shell, command, {
        cwd,
        env: {
          PATH: SCRIPT_PATH,
          HOME: home,
          POWERSHELL_TELEMETRY_OPTOUT: "1",
          ...env,
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
      const timer = setTimeout(() => child.kill("SIGKILL"), 120_000);
      child.on("error", reject);
      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ status, stdout, stderr });
      });
    });
  }

  /**
   * Every file, link and folder under the home folder, apart from the
   * script's own state and PowerShell's caches, with what it holds and when
   * it changed, so a run that changed anything shows
   */
  function snapshot(home: string, prefix = ""): Record<string, string> {
    const found: Record<string, string> = {};
    for (const entry of readdirSync(join(home, prefix), {
      withFileTypes: true,
    })) {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (path === ".contextlocker" || path === ".cache" || path === ".local") {
        continue;
      }
      const full = join(home, path);
      const stat = lstatSync(full);
      if (entry.isSymbolicLink()) {
        found[path] = `link ${readlinkSync(full)}`;
      } else if (entry.isDirectory()) {
        found[path] = `folder ${stat.mode} ${stat.mtimeMs}`;
        Object.assign(found, snapshot(home, path));
      } else {
        found[path] =
          `file ${stat.mode} ${stat.mtimeMs} ${sha256(readFileSync(full))}`;
      }
    }
    return found;
  }

  /** The one working set a gather made */
  function workingSet(home: string): string {
    const root = join(home, ".contextlocker", "gather");
    const sets = readdirSync(root).filter((name) =>
      /^\d{8}T\d{6}Z$/.test(name),
    );
    assert.equal(sets.length, 1, sets.join(", "));
    return join(root, sets[0] as string);
  }

  function rows(file: string): Array<Record<string, string>> {
    const [header, ...lines] = readFileSync(file, "utf8")
      .split("\n")
      .filter((line) => line !== "");
    const names = (header ?? "").split("\t");
    return lines.map((line) =>
      Object.fromEntries(
        line.split("\t").map((value, at) => [names[at], value]),
      ),
    );
  }

  /** Every file in a folder and the folders in it, as paths from it */
  function filesIn(dir: string, prefix = ""): string[] {
    return readdirSync(join(dir, prefix), { withFileTypes: true })
      .flatMap((entry) => {
        const path = prefix ? `${prefix}/${entry.name}` : entry.name;
        return entry.isDirectory() ? filesIn(dir, path) : [path];
      })
      .sort();
  }

  /** Each secret example copied or left out as the API would take it */
  function assertExamples(home: string) {
    const set = workingSet(home);
    const sources = rows(join(set, "sources.tsv"));
    const out = rows(join(set, "left-out.tsv"));
    for (const [index, example] of SECRET_EXAMPLES.entries()) {
      const path = `~/.codex/memories/example-${index}.md`;
      // A value cut short or masked is copied, for Context Locker to
      // check when the plan comes in, with it hidden
      if (example.kind === null || example.evidence) {
        assert.ok(
          sources.some((row) => row.path === path),
          example.name,
        );
        assert.ok(!out.some((row) => row.path === path), example.name);
      } else {
        assert.ok(!sources.some((row) => row.path === path), example.name);
        assert.equal(
          out.find((row) => row.path === path)?.why,
          `it seems to hold ${example.kind}, so it wasn't copied. Secrets belong in ScopeHold`,
          example.name,
        );
      }
    }
  }

  /** Every secret file left out for what it holds, and none of it copied */
  function assertSecretsLeftOut(home: string) {
    const set = workingSet(home);
    const everything = filesIn(set)
      .map((path) => readFileSync(join(set, path), "utf8"))
      .join("\n");
    for (const value of SECRET_VALUES) {
      assert.ok(!everything.includes(value), value);
    }
    const out = rows(join(set, "left-out.tsv"));
    for (const [name, kind] of Object.entries(KINDS)) {
      const row = out.find(
        (candidate) => candidate.path === `~/.codex/memories/secrets/${name}`,
      );
      assert.equal(row?.code, "secret", name);
      assert.equal(
        row?.why,
        `it seems to hold ${kind}, so it wasn't copied. Secrets belong in ScopeHold`,
        name,
      );
    }
  }

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("copies only this app's own sources into a private working set, and changes nothing of theirs", async () => {
        const { home, repo } = computer();
        const before = snapshot(home);
        const result = await run(shell, home, ["import", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual(snapshot(home), before, "the apps' files changed");

        const set = workingSet(home);
        const sources = rows(join(set, "sources.tsv"));
        assert.deepEqual(
          sources.map((row) => `${row.app} ${row.kind} ${row.path}`).sort(),
          [
            "claude-code instructions ~/.claude/CLAUDE.md",
            "claude-code instructions ~/.claude/rules/style.md",
            "claude-code memory ~/.claude/projects/-home-ada-repo/memory/MEMORY.md",
            "claude-code memory ~/.claude/projects/-home-ada-repo/memory/testing.md",
            "claude-code skill ~/.claude/skills/my-skill/.DS_Store",
            "claude-code skill ~/.claude/skills/my-skill/SKILL.md",
            "claude-code skill ~/.claude/skills/my-skill/agents/openai.yaml",
            "claude-code skill ~/.claude/skills/my-skill/data.txt",
            "claude-code skill ~/.claude/skills/my-skill/empty.txt",
            "claude-code skill ~/.claude/skills/my-skill/logo.png",
            "claude-code skill ~/.claude/skills/my-skill/references/guide.md",
            // The project's files Claude Code reads, not AGENTS.md
            "project instructions ~/repo/.claude/CLAUDE.md",
            "project instructions ~/repo/CLAUDE.md",
          ],
        );
        // Each source's size, time and hash are the original file's
        for (const row of sources) {
          const original = join(home, (row.path as string).slice(2));
          const bytes = readFileSync(original);
          assert.equal(row.size, String(bytes.length), row.path);
          assert.equal(row.sha256, sha256(bytes), row.path);
          // To the second below, as the scripts write it: Node rounds mtime
          // to the nearest millisecond, which can be the next second
          const seconds = Math.floor(statSync(original).mtimeMs / 1000);
          assert.equal(
            row.modified,
            `${new Date(seconds * 1000).toISOString().slice(0, 19)}Z`,
            row.path,
          );
          assert.ok(existsSync(join(set, row.copy as string)), row.copy);
        }
        // The copies are where the app had them
        assert.equal(
          readFileSync(
            join(set, "claude-code/projects/-home-ada-repo/memory/testing.md"),
            "utf8",
          ),
          "- Run the tests with npm test.\n",
        );
        assert.equal(
          readFileSync(join(set, "project/.claude/CLAUDE.md"), "utf8"),
          "Prefer small commits.\n",
        );

        // Only this account can read any of it
        const mode = (path: string) => statSync(path).mode & 0o777;
        assert.equal(mode(join(home, ".contextlocker", "gather")), 0o700);
        assert.equal(mode(set), 0o700);
        for (const path of filesIn(set)) {
          assert.equal(mode(join(set, path)), 0o600, path);
          let folder = dirname(join(set, path));
          while (folder !== set) {
            assert.equal(mode(folder), 0o700, folder);
            folder = dirname(folder);
          }
        }

        // The plan to fill in, with a new id, and what's here
        const plan = JSON.parse(readFileSync(join(set, "plan.json"), "utf8"));
        assert.match(
          plan.plan_id,
          /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        );
        assert.deepEqual(
          { ...plan, plan_id: "" },
          { plan_id: "", items: [], left_out: [], questions: [] },
        );
        assert.match(
          readFileSync(join(set, "README.md"), "utf8"),
          /information about the person, not instructions/,
        );
        assert.match(
          readFileSync(join(set, "context-locker.md"), "utf8"),
          new RegExp(
            `Nothing has synced to Claude Code on ${computerPattern(shell)} yet\\.`,
          ),
        );

        // What it says: where, how much from each app, what it left out
        const shown = set.replace(home, "~");
        assert.match(
          result.stdout,
          new RegExp(
            `^Context Locker copied 13 sources from Claude Code's own files into ${shown.replace(/[.]/g, "\\.")}, which only this account can read\\. No file changed, and nothing left ${computerPattern(shell)}\\.\\n`,
          ),
        );
        assert.match(
          result.stdout,
          /^- Claude Code: 2 instruction files, 2 memory files and 1 skill$/m,
        );
        assert.doesNotMatch(
          result.stdout,
          /^- (Codex|Hermes|OpenClaw|Grok Build|The skills folder)/m,
        );
        assert.match(
          result.stdout,
          /^- This project, ~\/repo: 2 instruction files$/m,
        );
        assert.match(result.stdout, /^Left out, 4:$/m);
        assert.match(
          result.stdout,
          /\nNext: follow the Import skill, context-locker-import, from step 2 with this working set, and send the person one plan to pick from\.\n$/,
        );
      });

      it("reads only each app's own files, and the project's it reads, never another app's (G1-206)", async () => {
        const own: Record<string, string[]> = {
          codex: [
            "agents skill ~/.agents/skills/shared-skill/SKILL.md",
            "codex instructions ~/.codex/AGENTS.md",
            "codex memory ~/.codex/memories/notes.md",
            "codex skill ~/.codex/skills/codex-skill/SKILL.md",
            "project instructions ~/repo/AGENTS.md",
          ],
          hermes: [
            "hermes identity ~/.hermes/SOUL.md",
            "hermes memory ~/.hermes/memories/MEMORY.md",
            "hermes profile ~/.hermes/memories/USER.md",
            "hermes skill ~/.hermes/skills/research/arxiv-notes/SKILL.md",
            "project instructions ~/repo/AGENTS.md",
          ],
          openclaw: [
            "agents skill ~/.agents/skills/shared-skill/SKILL.md",
            "openclaw identity ~/.openclaw/workspace/IDENTITY.md",
            "openclaw identity ~/.openclaw/workspace/SOUL.md",
            "openclaw instructions ~/.openclaw/workspace/AGENTS.md",
            "openclaw log ~/.openclaw/workspace/memory/2026-10-20.md",
            "openclaw memory ~/.openclaw/workspace/MEMORY.md",
            "openclaw profile ~/.openclaw/workspace/USER.md",
            "openclaw skill ~/.openclaw/skills/hub-skill/SKILL.md",
            "openclaw skill ~/.openclaw/workspace/skills/ws-skill/SKILL.md",
          ],
        };
        const copies: Record<string, [string, string]> = {
          codex: ["codex/memories/notes.md", "Ada prefers pnpm.\n"],
          hermes: [
            "hermes/memories/MEMORY.md",
            "Server runs Ubuntu.\n§\nUses fish.\n",
          ],
          openclaw: [
            "openclaw/workspace/memory/2026-10-20.md",
            "Fixed the login bug.\n",
          ],
        };
        for (const [app, expected] of Object.entries(own)) {
          const { home, repo } = computer();
          // gather, its name before, still works
          const result = await run(
            shell,
            home,
            [app === "hermes" ? "gather" : "import", app],
            repo,
          );
          assert.equal(result.status, 0, result.stderr);
          const set = workingSet(home);
          assert.deepEqual(
            rows(join(set, "sources.tsv"))
              .map((row) => `${row.app} ${row.kind} ${row.path}`)
              .sort(),
            expected,
            app,
          );
          const [copy, text] = copies[app] as [string, string];
          assert.equal(readFileSync(join(set, copy), "utf8"), text, app);
          assert.doesNotMatch(result.stdout, /Grok Build|Claude Code:/, app);
        }

        // --apps, which picked other apps' files, is taken and left unused
        const { home, repo } = computer();
        const picked = await run(
          shell,
          home,
          ["import", "codex", "--apps", "claude-code,project"],
          repo,
        );
        assert.equal(picked.status, 0, picked.stderr);
        assert.match(
          picked.stdout,
          /^Import reads only Codex's own files now, so -{1,2}[Aa]pps was left unused\.$/m,
        );
        assert.deepEqual(
          [
            ...new Set(
              rows(join(workingSet(home), "sources.tsv")).map((row) => row.app),
            ),
          ].sort(),
          ["agents", "codex", "project"],
        );
        // It's for an import only
        const refused = await run(
          shell,
          home,
          ["doctor", "codex", "--apps", "codex"],
          repo,
        );
        assert.equal(refused.status, 2);
      });

      it("cuts Context Locker's own blocks from the copies, and skips its skills and the notes folder", async () => {
        const { home, repo } = computer();
        const result = await run(shell, home, ["import", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(
          result.stderr,
          "",
          "The exclusion summary must work in this shell's awk.",
        );
        const set = workingSet(home);
        const everything = filesIn(set)
          .map((path) => readFileSync(join(set, path), "utf8"))
          .join("\n");
        for (const text of [
          "context-locker:start",
          "context-locker:end",
          "BLOCK-TEXT",
          "MANAGED-SKILL-TEXT",
          "NOTES-FOLDER-TEXT",
          "SYSTEM-SKILL",
          "BUNDLED-TEXT",
          "TRANSCRIPT-LINE",
          "OLD-BACKUP",
        ]) {
          assert.ok(!everything.includes(text), text);
        }
        assert.equal(
          readFileSync(join(set, "claude-code/CLAUDE.md"), "utf8"),
          "# Mine\n\nUse plain words.\n\n",
        );
        const notes = Object.fromEntries(
          rows(join(set, "sources.tsv")).map((row) => [row.path, row.note]),
        );
        assert.equal(notes["~/.claude/CLAUDE.md"], "cut");
        assert.equal(notes["~/.claude/rules/style.md"], "-");

        const out = rows(join(set, "left-out.tsv"));
        const code = (path: string) =>
          out.find((row) => row.path === path)?.code;
        assert.equal(code("~/.claude/rules/context-locker.md"), "own");
        assert.equal(code("~/.claude/skills/synced-skill"), "managed");
        assert.match(
          result.stdout,
          /^- 1 skill Context Locker manages, as it's in Context Locker already\.$/m,
        );
        assert.match(
          result.stdout,
          /^- 1 file that holds only Context Locker's own block\.$/m,
        );

        // Each other app's blocks are cut from its own copies too
        for (const [app, copy, text] of [
          ["codex", "project/AGENTS.md", "# Repo\n\nUse tabs.\n\n"],
          [
            "openclaw",
            "openclaw/workspace/USER.md",
            "Ada lives in Auckland.\n\n",
          ],
          ["hermes", "hermes/SOUL.md", "You are Hermes, calm and exact.\n\n"],
        ] as const) {
          const machine = computer();
          const ran = await run(
            shell,
            machine.home,
            ["import", app],
            machine.repo,
          );
          assert.equal(ran.status, 0, ran.stderr);
          const own = workingSet(machine.home);
          assert.equal(readFileSync(join(own, copy), "utf8"), text, app);
          if (app === "hermes") {
            assert.equal(
              rows(join(own, "left-out.tsv")).find(
                (row) => row.path === "~/.hermes/skills/bundled-skill",
              )?.code,
              "bundled",
            );
            assert.match(ran.stdout, /^- 1 skill that came with Hermes\.$/m);
          }
        }
      });

      it("keeps environment references and types, but still refuses literal credentials", async () => {
        const { home, repo, codex } = computer();
        for (const [index, example] of SECRET_EXAMPLES.entries()) {
          put(join(codex, "memories", `example-${index}.md`), example.text);
        }
        const result = await run(shell, home, ["import", "codex"], repo);
        assert.equal(result.status, 0, result.stderr);
        assertExamples(home);
      });

      it("leaves out what looks like a secret, and never copies it, nor a file over 4 MB", async () => {
        const { home, repo } = computer();
        const result = await run(shell, home, ["import", "codex"], repo);
        assert.equal(result.status, 0, result.stderr);
        assertSecretsLeftOut(home);
        assert.match(
          result.stdout,
          /^- ~\/\.codex\/memories\/secrets\/aws\.md: it seems to hold an AWS access key, so it wasn't copied\. Secrets belong in ScopeHold\.$/m,
        );
        const out = Object.fromEntries(
          rows(join(workingSet(home), "left-out.tsv")).map((row) => [
            row.path,
            row,
          ]),
        );
        assert.equal(out["~/.codex/memories/big.md"]?.code, "size");
        assert.equal(
          out["~/.codex/memories/big.md"]?.why,
          "it's 4297 KB, and Import takes files of up to 4 MB",
        );
      });

      it("follows no link, and leaves out files that aren't text or are over 4 MB", async () => {
        const { home, repo } = computer();
        // Links of every sort: to folders, under any name, more than the
        // output names one by one, and a CLAUDE.md a dotfiles setup links
        const outside = join(home, "outside");
        const claude = join(home, ".claude");
        symlinkSync(outside, join(claude, "rules", "shared-rules"));
        for (let at = 0; at < 14; at += 1) {
          symlinkSync(
            join(outside, "notes.md"),
            join(claude, "rules", `team-${String(at).padStart(2, "0")}.md`),
          );
        }
        symlinkSync(outside, join(claude, "projects", "-home-ada-linked"));
        symlinkSync(outside, join(home, ".codex", "memories", "clients"));
        symlinkSync(
          join(outside, "notes.md"),
          join(home, ".openclaw", "workspace", "memory", "2026-10-21.md"),
        );
        rmSync(join(claude, "CLAUDE.md"));
        symlinkSync(join(outside, "notes.md"), join(claude, "CLAUDE.md"));
        symlinkSync(join(outside, "notes.md"), join(repo, "CLAUDE.local.md"));

        const result = await run(shell, home, ["import", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
        const set = workingSet(home);
        const everything = filesIn(set)
          .map((path) => readFileSync(join(set, path), "utf8"))
          .join("\n");
        assert.ok(!everything.includes("OUTSIDE"));
        const out = Object.fromEntries(
          rows(join(set, "left-out.tsv")).map((row) => [row.path, row]),
        );
        const links = [
          "~/.claude/CLAUDE.md",
          "~/.claude/rules/linked.md",
          "~/.claude/rules/shared-rules",
          ...Array.from(
            { length: 14 },
            (_, at) => `~/.claude/rules/team-${String(at).padStart(2, "0")}.md`,
          ),
          "~/.claude/skills/linked-skill",
          "~/.claude/projects/-home-ada-linked",
          "~/repo/CLAUDE.local.md",
        ];
        // Every link is in the left-out list, and named in what gather prints
        for (const path of links) {
          assert.equal(out[path]?.code, "link", path);
          assert.equal(
            out[path]?.why,
            "it's a link, and Import doesn't follow links",
            path,
          );
          assert.ok(
            result.stdout.includes(
              `\n- ${path}: it's a link, and Import doesn't follow links.\n`,
            ),
            path,
          );
        }
        assert.equal(
          rows(join(set, "left-out.tsv")).filter((row) => row.code === "link")
            .length,
          links.length,
        );
        for (const name of [
          "logo.png",
          "data.txt",
          ".DS_Store",
          "empty.txt",
          "agents/openai.yaml",
        ]) {
          assert.equal(out[`~/.claude/skills/my-skill/${name}`], undefined);
          assert.deepEqual(
            readFileSync(join(set, "claude-code/skills/my-skill", name)),
            readFileSync(join(home, ".claude/skills/my-skill", name)),
          );
        }
        assert.ok(
          existsSync(join(set, "claude-code/skills/my-skill/.DS_Store")),
        );
      });

      it("defers a whole package if a file is blocked, without changing its source or keeping a partial copy", async () => {
        for (const blocked of [
          "secret",
          "link",
          "size",
          "depth",
          "count",
          "package-size",
        ]) {
          const { home, repo, codex } = computer();
          const root = join(codex, "skills", "atomic-skill");
          put(
            join(root, "SKILL.md"),
            "---\nname: atomic-skill\ndescription: Test.\n---\nWhole package.\n",
          );
          put(join(root, "LICENSE"), "MIT\n");
          if (blocked === "secret")
            put(join(root, "z.txt"), SECRETS["password.md"]!);
          if (blocked === "link")
            symlinkSync(join(home, "outside", "notes.md"), join(root, "z.txt"));
          if (blocked === "size")
            put(join(root, "z.bin"), Buffer.alloc(4 * 1024 * 1024 + 1));
          if (blocked === "depth")
            put(join(root, "a/b/c/d/e/f/g/h/i.txt"), "too deep");
          if (blocked === "count")
            for (let i = 0; i < 1000; i++) put(join(root, `file-${i}.txt`), "");
          if (blocked === "package-size")
            for (let i = 0; i < 3; i++)
              put(join(root, `file-${i}.bin`), Buffer.alloc(4 * 1024 * 1024));
          const before = snapshot(home);
          const result = await run(shell, home, ["import", "codex"], repo);
          assert.equal(result.status, 0, result.stderr);
          assert.deepEqual(snapshot(home), before, blocked);
          const set = workingSet(home);
          assert.equal(
            existsSync(join(set, "codex/skills/atomic-skill")),
            false,
            blocked,
          );
          assert.ok(
            rows(join(set, "left-out.tsv")).some(
              (row) =>
                row.path === "~/.codex/skills/atomic-skill" &&
                row.code === "package",
            ),
            blocked,
          );
          assert.ok(
            rows(join(set, "sources.tsv")).every(
              (row) => !row.path?.includes("atomic-skill"),
            ),
            blocked,
          );
        }
      });

      it("stops copying once it holds what a plan can, here 20 MB", async () => {
        const { home, repo, codex } = computer();
        for (let at = 0; at < 22; at += 1) {
          put(
            join(
              codex,
              "memories",
              "bulk",
              `part-${String(at).padStart(2, "0")}.md`,
            ),
            `${"line of a long memory file\n".repeat(37_000)}`,
          );
        }
        // A plan holds 64 MB, and a smaller total keeps the test quick
        const result = await run(shell, home, ["import", "codex"], repo, {
          CONTEXT_LOCKER_GATHER_MOST: String(20 * 1024 * 1024),
        });
        assert.equal(result.status, 0, result.stderr);
        const set = workingSet(home);
        const copied = filesIn(set).reduce(
          (total, path) => total + statSync(join(set, path)).size,
          0,
        );
        assert.ok(copied <= 20 * 1024 * 1024 + 20_000, String(copied));
        const over = rows(join(set, "left-out.tsv")).filter(
          (row) => row.code === "total",
        );
        assert.ok(over.length >= 2, String(over.length));
        assert.equal(
          over[0]?.why,
          "Import takes at most 20 MB in all, and it had that much",
        );
      });

      it("keeps its newest 3 working sets, none older than 7 days, and deletes only its own", async () => {
        const { home, repo } = computer();
        const root = join(home, ".contextlocker", "gather");
        const ours = [
          "20261001T090000Z",
          "20261002T090000Z",
          "20261003T090000Z",
          "20261004T090000Z",
        ];
        for (const name of ours) {
          put(
            join(root, name, ".context-locker-gather"),
            "context-locker-gather 1\n",
          );
          put(join(root, name, "sources.tsv"), "app\n");
        }
        // Not Gather's: no mark, another mark, another name, and a link
        put(join(root, "20260901T090000Z", "keep.md"), "mine\n");
        put(
          join(root, "20260902T090000Z", ".context-locker-gather"),
          "something else\n",
        );
        put(join(root, "my-notes", "keep.md"), "mine\n");
        const elsewhere = join(home, "elsewhere-set");
        put(
          join(elsewhere, ".context-locker-gather"),
          "context-locker-gather 1\n",
        );
        symlinkSync(elsewhere, join(root, "20260903T090000Z"));
        // One of the newest 3 is 8 days old, by when its mark was written,
        // and so is a folder that isn't Gather's
        const old = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000);
        utimesSync(
          join(root, "20261004T090000Z", ".context-locker-gather"),
          old,
          old,
        );
        utimesSync(join(root, "20260901T090000Z", "keep.md"), old, old);

        const result = await run(shell, home, ["gather", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
        const left = readdirSync(root).sort();
        const made = left.filter(
          (name) =>
            /^\d{8}T\d{6}Z$/.test(name) &&
            !name.startsWith("2026090") &&
            !ours.includes(name),
        );
        assert.equal(made.length, 1);
        assert.deepEqual(
          left,
          // The newest 3 were the new one, 1004 and 1003, and 1004 is too old
          [
            "20260901T090000Z",
            "20260902T090000Z",
            "20260903T090000Z",
            "20261003T090000Z",
            made[0] as string,
            "my-notes",
          ].sort(),
        );
        assert.ok(existsSync(join(elsewhere, ".context-locker-gather")));
      });

      it("refuses to run when the app isn't connected", async () => {
        const { home, repo } = computer();
        rmSync(join(home, ".contextlocker", "claude-code", "token"));
        const result = await run(shell, home, ["gather", "claude-code"], repo);
        assert.equal(result.status, 1);
        assert.ok(
          result.stderr.includes(
            `Claude Code isn't connected on ${computerName(shell)}.`,
          ),
          result.stderr,
        );
        assert.ok(!existsSync(join(home, ".contextlocker", "gather")));
      });

      it("import-submit sends the plan with the app's token, prints the answer, and then deletes Import's copies", async () => {
        const { home, repo } = computer();
        // Two working sets of Gather's, and a folder that isn't one
        const root = join(home, ".contextlocker", "gather");
        for (const name of ["20261020T090000Z", "20261021T090000Z"]) {
          put(
            join(root, name, ".context-locker-gather"),
            "context-locker-gather 1\n",
          );
          put(join(root, name, "codex", "memories", "notes.md"), "A memory.\n");
        }
        put(join(root, "my-notes", "keep.md"), "mine\n");
        const plan = join(home, "plan.json");
        const body = JSON.stringify({
          plan_id: "0b6f1c2e-8a3b-4c5d-9e7f-0a1b2c3d4e5f",
          items: [],
          left_out: [],
          questions: [],
        });
        writeFileSync(plan, body);
        seen.length = 0;
        answer = {
          status: 200,
          type: "text/plain; charset=utf-8",
          body: "Brought in 2 items with Gather.\n\u0007Tell the person.\n",
        };
        const result = await run(
          shell,
          home,
          ["import-submit", "claude-code", plan],
          repo,
        );
        assert.equal(result.status, 0, result.stderr);
        assert.equal(
          result.stdout,
          `Brought in 2 items with Gather.\nTell the person.\nContext Locker deleted Import's working copies from ${computerName(shell)}, in ~/.contextlocker/gather, now that the plan is in.\n`,
        );
        assert.deepEqual(readdirSync(root), ["my-notes"]);
        assert.equal(seen.length, 1);
        const request = seen[0] as Seen;
        assert.equal(request.method, "POST");
        assert.equal(request.path, "/v1/gather");
        assert.equal(request.headers.authorization, "Bearer ctxl_at_test");
        assert.equal(request.headers["content-type"], "application/json");
        assert.equal(request.headers.accept, "text/plain");
        assert.equal(request.body, body);

        // A refusal names the problems, the run fails, and the copies stay
        put(
          join(root, "20261021T100000Z", ".context-locker-gather"),
          "context-locker-gather 1\n",
        );
        answer = {
          status: 400,
          type: "text/plain; charset=utf-8",
          body: "The plan wasn't brought in:\n- Item 2: text must be at most 800 characters.\n",
        };
        const refused = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(refused.status, 1);
        assert.equal(refused.stdout, "");
        assert.match(
          refused.stderr,
          /- Item 2: text must be at most 800 characters\./,
        );
        assert.ok(existsSync(join(root, "20261021T100000Z")));

        // While a gather runs, its copies stay, and the answer says so
        mkdirSync(join(home, ".contextlocker", "gather.lock"));
        answer = {
          status: 200,
          type: "text/plain; charset=utf-8",
          body: "This plan was already brought in.\n",
        };
        const busy = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(busy.status, 0, busy.stderr);
        assert.match(
          busy.stdout,
          /\nImport's working copies stay in ~\/\.contextlocker\/gather for now, as an import is running\. A later import deletes them after 7 days\.\n$/,
        );
        assert.ok(existsSync(join(root, "20261021T100000Z")));
        rmSync(join(home, ".contextlocker", "gather.lock"), {
          recursive: true,
        });

        // An answer from before the plan was read is JSON
        answer = {
          status: 401,
          type: "application/json",
          body: '{"error":"agent_token_invalid","message":"This token was revoked."}',
        };
        const revoked = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(revoked.status, 1);
        assert.match(revoked.stderr, /was revoked or has expired/);

        // Too big for one plan, and no plan at all, never reach Context
        // Locker. The big one is sparse, so it takes no time to write
        seen.length = 0;
        writeFileSync(plan, "");
        truncateSync(plan, 65 * 1024 * 1024);
        const big = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(big.status, 1);
        assert.match(
          big.stderr,
          /the plan is 65 MB, and one plan holds at most 64 MB\. Split it into two plans/,
        );
        const missing = await run(
          shell,
          home,
          ["gather-submit", "claude-code", join(home, "nope.json")],
          repo,
        );
        assert.equal(missing.status, 1);
        assert.match(missing.stderr, /there's no plan at/);
        assert.equal(seen.length, 0);

        const usage = await run(
          shell,
          home,
          ["import-submit", "claude-code"],
          repo,
        );
        assert.equal(usage.status, 2);
        assert.match(usage.stderr, /import-submit <app> <plan\.json>/);
      });

      it("counts what an Import read once its plan is in, so the doctor asks about it again only once it's new or changed (G1-115)", async () => {
        const { home, repo } = computer();
        const gathered = await run(
          shell,
          home,
          ["gather", "claude-code"],
          repo,
        );
        assert.equal(gathered.status, 0, gathered.stderr);
        const plan = join(workingSet(home), "plan.json");
        answer = {
          status: 200,
          type: "text/plain; charset=utf-8",
          body: "Brought in 2 items with Gather.\n",
        };
        const submitted = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(submitted.status, 0, submitted.stderr);

        const [header, ...lines] = readFileSync(
          join(home, ".contextlocker", "sources"),
          "utf8",
        )
          .split("\n")
          .filter(Boolean);
        assert.equal(header, "context-locker-sources 1");
        const day = new Date().toISOString().slice(0, 10);
        const read = new Map(
          lines.map((line) => {
            const [answer, when, sha, path = ""] = line.split("\t");
            return [path, `${answer} ${when} ${sha}`];
          }),
        );
        const memory = join(home, ".claude", "projects", "-home-ada-repo");
        assert.equal(
          read.get(join(memory, "memory", "MEMORY.md")),
          `import ${day} ${sha256("- The repo deploys from main.\n")}`,
        );
        // What's outside Context Locker's block, past blank lines
        assert.equal(
          read.get(join(home, ".claude", "CLAUDE.md")),
          `import ${day} ${sha256("# Mine\nUse plain words.\n")}`,
        );
        assert.equal(
          read.get(join(repo, "CLAUDE.md")),
          `import ${day} ${sha256("Read AGENTS.md.\n")}`,
        );
        // Not a skill, nor what it left out, such as a secret
        const paths = [...read.keys()];
        assert.ok(
          !paths.some((path) => path.includes("/skills/")),
          paths.join("\n"),
        );
        assert.ok(
          !read.has(join(home, ".codex", "memories", "secrets", "aws.md")),
        );
        assert.ok(!read.has(join(home, ".codex", "memories", "big.md")));

        // The doctor says so, until something in it is new
        const today = new Date();
        const months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(
          " ",
        );
        const shown = `${today.getUTCDate()} ${months[today.getUTCMonth()]} ${today.getUTCFullYear()}`;
        const doctor = await run(shell, home, ["doctor", "claude-code"], repo);
        assert.match(
          doctor.stdout,
          new RegExp(
            `^PASS {2}Claude Code's memory, in ~/\\.claude/projects/-home-ada-repo/memory, went into an Import on ${shown}, and nothing in them is new since\\.$`,
            "m",
          ),
        );
        assert.match(
          doctor.stdout,
          new RegExp(
            `^PASS {2}~/\\.claude/CLAUDE\\.md went into an Import on ${shown}, and hasn't changed since\\.$`,
            "m",
          ),
        );
        put(
          join(memory, "memory", "deploys.md"),
          "- Deploys wait for the checks.\n",
        );
        const later = await run(shell, home, ["doctor", "claude-code"], repo);
        assert.match(
          later.stdout,
          new RegExp(
            `^WARN {2}Claude Code's memory, in ~/\\.claude/projects/-home-ada-repo/memory, have 1 new or changed file since an Import read them on ${shown}, with 1 line outside Context Locker\\. Bring them into Context Locker with Import \\(.+ import claude-code\\), or keep them in Claude Code only \\(.+ keep claude-code ~/\\.claude/projects/-home-ada-repo/memory\\)\\.$`,
            "m",
          ),
        );
      });

      it("gather-submit sends a plan over 4 MB in parts, then names the upload", async () => {
        const { home, repo } = computer();
        const plan = join(home, "plan.json");
        const body = `{"plan_id":"big","pad":"${"x".repeat(9 * 1024 * 1024)}"}`;
        writeFileSync(plan, body);
        answer = {
          status: 200,
          type: "text/plain; charset=utf-8",
          body: "Brought in 1 item with Gather.\n",
        };
        seen.length = 0;
        const result = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /Brought in 1 item with Gather\./);
        const [start, ...rest] = seen;
        assert.equal(start?.method, "POST");
        assert.equal(start?.path, "/v1/uploads");
        assert.deepEqual(JSON.parse(start?.body ?? "{}"), {
          purpose: "gather",
          parts: 3,
          bytes: Buffer.byteLength(body),
          sha256: sha256(body),
        });
        const parts = rest.filter((request) => request.method === "PUT");
        assert.deepEqual(
          parts.map((request) => request.path),
          [1, 2, 3].map((part) => `/v1/uploads/${UPLOAD_ID}/parts/${part}`),
        );
        assert.equal(parts.map((request) => request.body).join(""), body);
        const sent = rest.at(-1);
        assert.equal(sent?.path, "/v1/gather");
        assert.equal(sent?.headers["context-locker-upload"], UPLOAD_ID);
        assert.equal(sent?.body, "");

        // What Context Locker says to an upload it refuses is the answer,
        // and the plan isn't sent
        try {
          for (const [status, body, said] of [
            [
              401,
              '{"error":"agent_token_invalid","message":"This token was revoked."}',
              /was revoked or has expired/,
            ],
            [
              413,
              '{"error":"too_large","message":"That\'s 70 MB, and a plan can be at most 64 MB. Nothing changed."}',
              /^Context Locker: That's 70 MB, and a plan can be at most 64 MB\. Nothing changed\.$/m,
            ],
          ] as const) {
            uploadAnswer = { status, body };
            seen.length = 0;
            const refused = await run(
              shell,
              home,
              ["gather-submit", "claude-code", plan],
              repo,
            );
            assert.equal(refused.status, 1);
            assert.match(refused.stderr, said);
            assert.deepEqual(
              seen.map((request) => request.path),
              ["/v1/uploads"],
            );
          }
        } finally {
          uploadAnswer = null;
        }
      });
    });
  }

  // mawk, the awk on Debian and Ubuntu, reads a brace count such as {6,} as
  // text in 1.3.4-20200120 and as exactly six in 20240123 (G1-147). So the
  // secret checks run again in dash with each other awk installed here, and
  // always with one that refuses a program holding a brace count
  if (SHELLS.includes("dash")) {
    describe("in dash, with other awks", () => {
      const installed = (name: string) =>
        spawnSync("sh", ["-c", `command -v ${name}`]).status === 0;
      const awk = spawnSync("sh", ["-c", "command -v awk"], {
        encoding: "utf8",
      }).stdout.trim();
      const AWKS: Record<string, string> = {
        "an awk that refuses brace counts": `for arg do
  if printf '%s' "$arg" | grep -Eq '\\{[0-9]+(,[0-9]*)?\\}'; then
    echo "awk: a brace count, which mawk reads wrongly" >&2
    exit 2
  fi
done
exec "${awk}" "$@"
`,
        ...(installed("mawk") ? { mawk: 'exec mawk "$@"\n' } : {}),
        ...(installed("busybox")
          ? { "BusyBox's awk": 'exec busybox awk "$@"\n' }
          : {}),
      };
      for (const [name, body] of Object.entries(AWKS)) {
        it(`leaves out every secret with ${name}`, async () => {
          const bin = mkdtempSync(join(work, "awk-"));
          writeFileSync(join(bin, "awk"), `#!/bin/sh\n${body}`, {
            mode: 0o755,
          });
          const { home, repo, codex } = computer();
          for (const [index, example] of SECRET_EXAMPLES.entries()) {
            put(join(codex, "memories", `example-${index}.md`), example.text);
          }
          const result = await run("dash", home, ["import", "codex"], repo, {
            PATH: `${bin}:${SCRIPT_PATH}`,
          });
          assert.equal(result.status, 0, result.stderr);
          assert.equal(result.stderr, "");
          assertExamples(home);
          assertSecretsLeftOut(home);
        });
      }
    });
  }
});
