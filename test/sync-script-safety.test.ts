// The sync script must not trust the manifest: it writes only the files its
// app may write, checks every hash, and refuses archives with anything but
// plain files and folders. These run it against a fake API.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

import {
  BLOCK_END,
  BLOCK_START,
  MANIFEST_HEADER,
  blockHash,
  writeTar,
} from "../src/index.js";

const SCRIPT = fileURLToPath(new URL("../scripts/sync.sh", import.meta.url));
const WORKSPACE = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) => spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0,
);
const PS_SCRIPT = fileURLToPath(
  new URL("../scripts/sync.ps1", import.meta.url),
);

interface Fake {
  manifest: string;
  /** Sent for a project's sync, when set. */
  projectManifest?: string;
  archive: Buffer;
  requests: string[];
}

describe("the sync script's checks", () => {
  let server: Server;
  let baseUrl: string;
  const fake: Fake = { manifest: "", archive: Buffer.alloc(0), requests: [] };
  const work = mkdtempSync(join(tmpdir(), "ctx-safety-"));

  before(async () => {
    server = createServer((request, response) => {
      fake.requests.push(`${request.method} ${request.url}`);
      request.resume();
      request.on("end", () => {
        if (request.url?.startsWith("/v1/sync/blobs")) {
          response.writeHead(200, { "content-type": "application/x-tar" });
          response.end(fake.archive);
        } else if (request.url?.startsWith("/v1/sync/done")) {
          response.writeHead(200, { "content-type": "application/json" });
          response.end('{"status":"recorded"}');
        } else {
          response.writeHead(200, { "content-type": "text/plain" });
          response.end(
            request.url?.includes("project=") && fake.projectManifest
              ? fake.projectManifest
              : fake.manifest,
          );
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

  function home(harness: string) {
    const dir = mkdtempSync(join(work, `${harness}-`));
    mkdirSync(join(dir, ".contextlocker", harness), { recursive: true });
    writeFileSync(join(dir, ".contextlocker", "config"), `api=${baseUrl}\n`);
    writeFileSync(
      join(dir, ".contextlocker", harness, "token"),
      "ctxl_at_test\n",
    );
    return dir;
  }

  function run(shell: string, dir: string, harness: string, cwd = dir) {
    return new Promise<{ status: number | null; stderr: string }>((resolve) => {
      const args =
        shell === "pwsh"
          ? ["-NoProfile", "-NonInteractive", "-File", PS_SCRIPT, harness]
          : [SCRIPT, harness];
      const child = spawn(shell, args, {
        cwd,
        env: {
          PATH: process.env.PATH ?? "",
          HOME: dir,
          POWERSHELL_TELEMETRY_OPTOUT: "1",
        },
        stdio: ["ignore", "ignore", "pipe"],
      });
      let stderr = "";
      child.stderr
        .setEncoding("utf8")
        .on("data", (chunk: string) => (stderr += chunk));
      child.on("close", (status) => resolve({ status, stderr }));
    });
  }

  /** Every file under a folder, leaving out the script's own state. */
  function files(dir: string, prefix = ""): string[] {
    return readdirSync(join(dir, prefix), { withFileTypes: true }).flatMap(
      (entry) => {
        const path = prefix ? `${prefix}/${entry.name}` : entry.name;
        // The script's own state, and PowerShell's cache
        if (path === ".contextlocker" || path === ".cache") return [];
        return entry.isDirectory() ? files(dir, path) : [path];
      },
    );
  }

  const block = `${BLOCK_START}\n## Context Locker\n${BLOCK_END}\n`;

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("writes only the files its app may write", async () => {
        const hash = blockHash(block);
        fake.manifest = [
          MANIFEST_HEADER,
          `workspace ${WORKSPACE}`,
          `block ${hash} {claude}/rules/context-locker.md`,
          `block ${hash} {codex}/../escaped.md`,
          `block ${hash} {project}/AGENTS.md`,
          `block ${hash} {nowhere}/AGENTS.md`,
          `skill ${hash} {agents}/skills/../../outside 1 1`,
          `skill ${hash} {agents}/skills/a/b 1 1`,
          `skill ${hash} {agents}/skills/Bad_Name 1 1`,
          `block ${hash} {codex}/AGENTS.md`,
          "",
        ].join("\n");
        fake.archive = writeTar([{ path: hash, bytes: Buffer.from(block) }], 0);
        const dir = home("codex");

        const result = await run(shell, dir, "codex");
        assert.equal(result.status, 0);
        assert.deepEqual(files(dir), [".codex/AGENTS.md"]);
        assert.equal(
          (result.stderr.match(/isn't a file codex's sync may write/g) ?? [])
            .length,
          7,
        );
      });

      it("keeps each sync to its own files, and follows no links in a project", async () => {
        const hash = blockHash(block);
        const projectId = "55555555-5555-4555-8555-555555555555";
        fake.manifest = [
          MANIFEST_HEADER,
          `workspace ${WORKSPACE}`,
          `block ${hash} {claude}/rules/context-locker.md`,
          `block ${hash} {project}/.claude/rules/context-locker.md`,
          "",
        ].join("\n");
        fake.projectManifest = [
          MANIFEST_HEADER,
          `workspace ${WORKSPACE}`,
          `block ${hash} {claude}/rules/other.md`,
          `block ${hash} {project}/.claude/rules/context-locker.md`,
          "",
        ].join("\n");
        fake.archive = writeTar([{ path: hash, bytes: Buffer.from(block) }], 0);
        const dir = home("claude-code");
        const elsewhere = join(dir, "elsewhere");
        mkdirSync(elsewhere);
        const repo = join(dir, "repo");
        mkdirSync(repo);
        writeFileSync(
          join(repo, ".contextlocker.json"),
          JSON.stringify({ workspace: WORKSPACE, project: projectId }),
        );
        symlinkSync(elsewhere, join(repo, ".claude"));

        const result = await run(shell, dir, "claude-code", repo);
        fake.projectManifest = undefined;
        assert.equal(result.status, 0);
        // The link itself is listed; nothing went through it
        assert.deepEqual(files(dir), [
          ".claude/rules/context-locker.md",
          "repo/.claude",
          "repo/.contextlocker.json",
        ]);
        assert.deepEqual(readdirSync(elsewhere), []);
        assert.match(result.stderr, /links in a project aren't followed/);
        assert.equal(
          (
            result.stderr.match(/isn't a file claude-code's sync may write/g) ??
            []
          ).length,
          2,
        );
      });

      it("refuses an archive with anything but files and folders", async () => {
        const hash = blockHash(block);
        fake.manifest = `${MANIFEST_HEADER}\nworkspace ${WORKSPACE}\nblock ${hash} {codex}/AGENTS.md\n`;
        // A symlink entry, hand-made: type 2 points somewhere else entirely
        const archive = writeTar(
          [{ path: hash, bytes: Buffer.from(block) }],
          0,
        );
        const header = Buffer.from(archive.subarray(0, 512));
        header.fill(0, 0, 100);
        header.write("link", 0, "ascii");
        header.write("2", 156, "ascii");
        header.write("/etc/passwd", 157, "ascii");
        header.fill(0x30, 124, 135);
        header.write(" ".repeat(8), 148, "ascii");
        let sum = 0;
        for (const byte of header) sum += byte;
        header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, 8, "ascii");
        fake.archive = Buffer.concat([header, archive]);
        const dir = home("codex");

        const result = await run(shell, dir, "codex");
        assert.equal(result.status, 0);
        assert.match(result.stderr, /couldn't fetch the latest files/);
        assert.deepEqual(files(dir), []);
      });

      it("writes nothing whose content doesn't match its hash", async () => {
        const hash = blockHash(block);
        fake.manifest = `${MANIFEST_HEADER}\nworkspace ${WORKSPACE}\nblock ${hash} {codex}/AGENTS.md\n`;
        fake.archive = writeTar(
          [
            {
              path: hash,
              bytes: Buffer.from(block.replace("Context", "Other")),
            },
          ],
          0,
        );
        const dir = home("codex");
        fake.requests.length = 0;
        const result = await run(shell, dir, "codex");
        assert.equal(result.status, 0);
        assert.equal(existsSync(join(dir, ".codex", "AGENTS.md")), false);
        // Not applied, so not reported as applied
        assert.deepEqual(
          fake.requests.map((request) => request.split("?")[0]),
          ["GET /v1/sync", "POST /v1/sync/blobs"],
        );
      });

      it("asks for an update when the manifest is a newer version", async () => {
        fake.manifest = `context-locker-sync 2\nworkspace ${WORKSPACE}\n`;
        const dir = home("codex");
        const result = await run(shell, dir, "codex");
        assert.equal(result.status, 0);
        assert.match(result.stderr, /out of date/);
      });
    });
  }
});
