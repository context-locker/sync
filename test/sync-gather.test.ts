// The sync scripts' gather and gather-submit, run for real in each shell
// against a fake home folder holding every AI app's files. Gather only reads
// the apps' files, follows no link, never copies a secret, and keeps its
// working sets private; gather-submit sends the plan with the app's token.
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
  evidence?: "cut short" | "masked";
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

describe("gather, and gather-submit", () => {
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

  /** A computer where every AI app has files, and Claude Code is connected */
  function computer() {
    const home = mkdtempSync(join(work, "home-"));
    put(join(home, ".contextlocker", "config"), `api=${baseUrl}\n`);
    put(join(home, ".contextlocker", "claude-code", "token"), "ctxl_at_test\n");
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
          PATH: process.env.PATH ?? "",
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

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("copies every app's sources into a private working set, and changes nothing of theirs", async () => {
        const { home, repo } = computer();
        const before = snapshot(home);
        const result = await run(shell, home, ["gather", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual(snapshot(home), before, "the apps' files changed");

        const set = workingSet(home);
        const sources = rows(join(set, "sources.tsv"));
        assert.deepEqual(
          sources.map((row) => `${row.app} ${row.kind} ${row.path}`).sort(),
          [
            "agents skill ~/.agents/skills/shared-skill/SKILL.md",
            "claude-code instructions ~/.claude/CLAUDE.md",
            "claude-code instructions ~/.claude/rules/style.md",
            "claude-code memory ~/.claude/projects/-home-ada-repo/memory/MEMORY.md",
            "claude-code memory ~/.claude/projects/-home-ada-repo/memory/testing.md",
            "claude-code skill ~/.claude/skills/my-skill/SKILL.md",
            "claude-code skill ~/.claude/skills/my-skill/references/guide.md",
            "codex instructions ~/.codex/AGENTS.md",
            "codex memory ~/.codex/memories/notes.md",
            "codex skill ~/.codex/skills/codex-skill/SKILL.md",
            "grok-build instructions ~/.grok/GROK.md",
            "grok-build skill ~/.grok/skills/grok-skill/SKILL.md",
            "hermes identity ~/.hermes/SOUL.md",
            "hermes memory ~/.hermes/memories/MEMORY.md",
            "hermes profile ~/.hermes/memories/USER.md",
            "hermes skill ~/.hermes/skills/research/arxiv-notes/SKILL.md",
            "openclaw identity ~/.openclaw/workspace/IDENTITY.md",
            "openclaw identity ~/.openclaw/workspace/SOUL.md",
            "openclaw instructions ~/.openclaw/workspace/AGENTS.md",
            "openclaw log ~/.openclaw/workspace/memory/2026-10-20.md",
            "openclaw memory ~/.openclaw/workspace/MEMORY.md",
            "openclaw profile ~/.openclaw/workspace/USER.md",
            "openclaw skill ~/.openclaw/skills/hub-skill/SKILL.md",
            "openclaw skill ~/.openclaw/workspace/skills/ws-skill/SKILL.md",
            "project instructions ~/repo/.claude/CLAUDE.md",
            "project instructions ~/repo/AGENTS.md",
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
        // The copies are where each app had them
        assert.equal(
          readFileSync(
            join(set, "openclaw/workspace/memory/2026-10-20.md"),
            "utf8",
          ),
          "Fixed the login bug.\n",
        );
        assert.equal(
          readFileSync(join(set, "hermes/memories/MEMORY.md"), "utf8"),
          "Server runs Ubuntu.\n§\nUses fish.\n",
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
          readFileSync(join(set, "playbook.md"), "utf8"),
          /Nothing has synced to Claude Code on this computer yet\./,
        );

        // What it says: where, how much from each app, what it left out
        const shown = set.replace(home, "~");
        assert.match(
          result.stdout,
          new RegExp(
            `^Context Locker gathered 27 sources into ${shown.replace(/[.]/g, "\\.")}, which only this account can read\\. No app's files changed, and nothing left this computer\\.\\n`,
          ),
        );
        assert.match(
          result.stdout,
          /^- Claude Code: 2 instruction files, 2 memory files and 1 skill$/m,
        );
        assert.match(
          result.stdout,
          /^- Codex: 1 instruction file, 1 memory file and 1 skill$/m,
        );
        assert.match(
          result.stdout,
          /^- The skills folder Codex and OpenClaw share: 1 skill$/m,
        );
        assert.match(
          result.stdout,
          /^- Hermes: 1 identity file, 1 profile, 1 memory file and 1 skill$/m,
        );
        assert.match(
          result.stdout,
          /^- OpenClaw: 1 instruction file, 2 identity files, 1 profile, 1 memory file, 1 daily log and 2 skills$/m,
        );
        assert.match(
          result.stdout,
          /^- Grok Build: 1 instruction file and 1 skill$/m,
        );
        assert.match(
          result.stdout,
          /^- This project, ~\/repo: 3 instruction files$/m,
        );
        assert.match(result.stdout, /^Left out, 16:$/m);
        assert.match(
          result.stdout,
          /\nNext: follow the Gather skill, context-locker-gather, from step 2 with this working set, and show the person one plan to approve\.\n$/,
        );
      });

      it("cuts Context Locker's own blocks from the copies, and skips its skills and the notes folder", async () => {
        const { home, repo } = computer();
        const result = await run(shell, home, ["gather", "claude-code"], repo);
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
        assert.equal(
          readFileSync(join(set, "project/AGENTS.md"), "utf8"),
          "# Repo\n\nUse tabs.\n\n",
        );
        assert.equal(
          readFileSync(join(set, "openclaw/workspace/USER.md"), "utf8"),
          "Ada lives in Auckland.\n\n",
        );
        const notes = Object.fromEntries(
          rows(join(set, "sources.tsv")).map((row) => [row.path, row.note]),
        );
        assert.equal(notes["~/.claude/CLAUDE.md"], "cut");
        assert.equal(notes["~/.hermes/SOUL.md"], "cut");
        assert.equal(notes["~/.claude/rules/style.md"], "-");

        const out = rows(join(set, "left-out.tsv"));
        const code = (path: string) =>
          out.find((row) => row.path === path)?.code;
        assert.equal(code("~/.claude/rules/context-locker.md"), "own");
        assert.equal(code("~/.claude/skills/synced-skill"), "managed");
        assert.equal(code("~/.hermes/skills/bundled-skill"), "bundled");
        assert.match(
          result.stdout,
          /^- 1 skill Context Locker manages, as it's in the playbook already\.$/m,
        );
        assert.match(result.stdout, /^- 1 skill that came with Hermes\.$/m);
        assert.match(
          result.stdout,
          /^- 1 file that holds only Context Locker's own block\.$/m,
        );
      });

      it("keeps environment references and types, but still refuses literal credentials", async () => {
        const { home, repo, codex } = computer();
        for (const [index, example] of SECRET_EXAMPLES.entries()) {
          put(join(codex, "memories", `example-${index}.md`), example.text);
        }
        const result = await run(shell, home, ["gather", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
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
      });

      it("leaves out what looks like a secret, and never copies it", async () => {
        const { home, repo } = computer();
        const result = await run(shell, home, ["gather", "claude-code"], repo);
        assert.equal(result.status, 0, result.stderr);
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
            (candidate) =>
              candidate.path === `~/.codex/memories/secrets/${name}`,
          );
          assert.equal(row?.code, "secret", name);
          assert.equal(
            row?.why,
            `it seems to hold ${kind}, so it wasn't copied. Secrets belong in ScopeHold`,
            name,
          );
        }
        assert.match(
          result.stdout,
          /^- ~\/\.codex\/memories\/secrets\/aws\.md: it seems to hold an AWS access key, so it wasn't copied\. Secrets belong in ScopeHold\.$/m,
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

        const result = await run(shell, home, ["gather", "claude-code"], repo);
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
          "~/.codex/memories/clients",
          "~/.openclaw/workspace/memory/2026-10-21.md",
          "~/repo/CLAUDE.local.md",
        ];
        // Every link is in the left-out list, and named in what gather prints
        for (const path of links) {
          assert.equal(out[path]?.code, "link", path);
          assert.equal(
            out[path]?.why,
            "it's a link, and Gather doesn't follow links",
            path,
          );
          assert.ok(
            result.stdout.includes(
              `\n- ${path}: it's a link, and Gather doesn't follow links.\n`,
            ),
            path,
          );
        }
        assert.equal(
          rows(join(set, "left-out.tsv")).filter((row) => row.code === "link")
            .length,
          links.length,
        );
        assert.equal(out["~/.claude/skills/my-skill/logo.png"]?.code, "binary");
        assert.equal(out["~/.claude/skills/my-skill/data.txt"]?.code, "binary");
        assert.equal(out["~/.codex/memories/big.md"]?.code, "size");
        assert.equal(
          out["~/.codex/memories/big.md"]?.why,
          "it's 4297 KB, and Gather takes files of up to 4 MB",
        );
        assert.ok(
          !existsSync(join(set, "claude-code/skills/my-skill/.DS_Store")),
        );
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
        const result = await run(shell, home, ["gather", "claude-code"], repo, {
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
          "Gather takes at most 20 MB in all, and it had that much",
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
        assert.match(
          result.stderr,
          /Claude Code isn't connected on this computer\./,
        );
        assert.ok(!existsSync(join(home, ".contextlocker", "gather")));
      });

      it("gather-submit sends the plan with the app's token, prints the answer, and then deletes Gather's copies", async () => {
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
          body: "Brought in 2 items with Gather.\n\u0007Tell the user.\n",
        };
        const result = await run(
          shell,
          home,
          ["gather-submit", "claude-code", plan],
          repo,
        );
        assert.equal(result.status, 0, result.stderr);
        assert.equal(
          result.stdout,
          "Brought in 2 items with Gather.\nTell the user.\nContext Locker deleted Gather's working copies from this computer, in ~/.contextlocker/gather, now that the plan is in.\n",
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
          body: "The plan wasn't brought in:\n- Item 2: text must be at most 500 characters.\n",
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
          /- Item 2: text must be at most 500 characters\./,
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
          /\nGather's working copies stay in ~\/\.contextlocker\/gather for now, as a gather is running\. A later gather deletes them after 7 days\.\n$/,
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
          ["gather-submit", "claude-code"],
          repo,
        );
        assert.equal(usage.status, 2);
        assert.match(usage.stderr, /gather-submit <app> <plan\.json>/);
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
});
