// What a session start says when the sync can't get Context Locker's answer
// (G1-258). What a sync writes to stderr never reaches the app, so the line
// goes where the app reads it: why, since when its files are as they are, and
// what to offer the person, who says yes before the app does it. A newer
// script named by an answer that didn't come this time says when it came.
// These run the real scripts against a fake Context Locker.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

import { SYNC_SCRIPT_VERSION, buildManifest } from "../src/index.js";

const SCRIPTS = fileURLToPath(new URL("../scripts/", import.meta.url));
const WORKSPACE = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);
const NEXT = SYNC_SCRIPT_VERSION + 1;
/** When the last sync that worked happened, as the lock says it */
const LAST = "2026-10-26T09:05:00Z";
const SETUP_STEPS =
  "download the newest steps with `curl -fsSL https://context.locker/setup/SKILL.md` and follow them";
const CONNECT = `Offer to connect it again: once the person says yes, ${SETUP_STEPS}, and give them the link and code the setup command prints.`;

interface Answer {
  status: number;
  body: string;
}

/** A fake Context Locker */
class Fake {
  /** What GET /v1/sync answers, unless it's the manifest */
  sync: Answer | null = null;
  /** The global manifest */
  manifest = buildManifest({
    workspaceId: WORKSPACE,
    outputs: [],
    holds: [],
    script: NEXT,
    update: { hash: "c".repeat(64), setup: 999 },
  }).text;
  /** What every other route answers */
  other: Answer | null = null;
  requests: string[] = [];
}

describe("a session start when the sync can't get Context Locker's answer", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new Fake();
  const work = mkdtempSync(join(tmpdir(), "ctx-broken-"));

  before(async () => {
    server = createServer((request, response) => {
      request.resume();
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        const route = `${request.method} ${url.pathname}`;
        fake.requests.push(route);
        const send = (answer: Answer) => {
          response.writeHead(answer.status, {
            "content-type": answer.body.startsWith("{")
              ? "application/json"
              : "text/plain",
          });
          response.end(answer.body);
        };
        if (route === "GET /v1/sync") {
          if (fake.sync) return send(fake.sync);
          response.writeHead(200, { "content-type": "text/plain" });
          response.end(fake.manifest);
        } else if (fake.other) {
          send(fake.other);
        } else if (route === "POST /v1/sync/done") {
          send({ status: 200, body: '{"status":"recorded"}' });
        } else {
          send({ status: 404, body: '{"error":"not_found"}' });
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
  const runLine = (shell: string) =>
    shell === "pwsh"
      ? "pwsh -NoProfile -File ~/.contextlocker/sync.ps1"
      : "sh ~/.contextlocker/sync.sh";
  const yes = (shell: string) => (shell === "pwsh" ? "-Yes" : "--yes");

  /** A computer with the app connected, and this script where setup puts it */
  function computer(shell: string, harness: string) {
    fake = new Fake();
    const home = mkdtempSync(join(work, "home-"));
    const clHome = join(home, ".contextlocker");
    mkdirSync(join(clHome, harness), { recursive: true });
    writeFileSync(join(clHome, "config"), `api=${baseUrl}\nsite=${baseUrl}\n`);
    writeFileSync(join(clHome, harness, "token"), "ctxl_at_test\n", {
      mode: 0o600,
    });
    const installed = join(clHome, scriptName(shell));
    copyFileSync(join(SCRIPTS, scriptName(shell)), installed);
    return { home, clHome, installed, harness };
  }

  function run(
    shell: string,
    machine: { home: string; installed: string },
    words: string[],
    env: Record<string, string> = {},
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
        cwd: machine.home,
        env: {
          PATH: process.env.PATH ?? "",
          HOME: machine.home,
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
      const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
      child.on("error", reject);
      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ status, stdout, stderr });
      });
    });
  }

  /** Syncs once while all is well, and dates that sync as LAST */
  async function syncedOnce(
    shell: string,
    machine: {
      home: string;
      installed: string;
      clHome: string;
      harness: string;
    },
  ) {
    const first = await run(shell, machine, [machine.harness]);
    assert.equal(first.status, 0, first.stdout + first.stderr);
    const lock = join(machine.clHome, machine.harness, "global.lock");
    const text = readFileSync(lock, "utf8");
    assert.match(text, /^synced /m);
    writeFileSync(lock, text.replace(/^synced .*$/m, `synced ${LAST}`));
  }

  /** What Claude Code reads from the hook, which PowerShell ends with a newline */
  const additional = (stdout: string): string =>
    JSON.parse(stdout).hookSpecificOutput.additionalContext.trimEnd();

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("offers to take Context Locker off when the connection was revoked in Context Locker", async () => {
        const machine = computer(shell, "claude-code");
        await syncedOnce(shell, machine);
        fake.sync = { status: 401, body: '{"error":"connection_revoked"}' };

        const session = await run(shell, machine, ["claude-code"]);
        assert.equal(session.status, 0, session.stderr);
        // Only the line about the connection: the newer script the last
        // answer named comes with setting up again, or not at all
        assert.equal(
          additional(session.stdout),
          `Context Locker: this computer's connection for Claude Code was revoked in Context Locker, so nothing syncs here any more, and Claude Code's files are as they were on 26 Oct 2026. Offer to take Context Locker off this computer: run \`${runLine(shell)} remove claude-code\`, which says what it would take out and changes nothing, and only once the person says yes, run it again with \`${yes(shell)}\`.`,
        );
        assert.match(session.stderr, /was revoked in Context Locker/);
      });

      it("offers to connect again when the connection has expired, or its token is missing or damaged", async () => {
        const machine = computer(shell, "codex");
        await syncedOnce(shell, machine);
        fake.sync = { status: 401, body: '{"error":"agent_token_invalid"}' };

        const expired = await run(shell, machine, ["codex"]);
        assert.equal(expired.status, 0, expired.stderr);
        assert.equal(
          expired.stdout,
          `Context Locker: this computer's connection for Codex was revoked or has expired, so Codex's files are as they were on 26 Oct 2026. ${CONNECT}\n`,
        );

        // Without a token, it never asks Context Locker
        const token = join(machine.clHome, "codex", "token");
        rmSync(token);
        fake.requests = [];
        const unset = await run(shell, machine, ["codex"]);
        assert.equal(unset.status, 0, unset.stderr);
        assert.equal(
          unset.stdout,
          `Context Locker: Codex isn't connected on this computer, so Codex's files are as they were on 26 Oct 2026. ${CONNECT}\n`,
        );
        assert.match(unset.stderr, /isn't connected on this computer/);
        assert.deepEqual(fake.requests, []);

        writeFileSync(token, "ctxl_at_not!a!token\n", { mode: 0o600 });
        const damaged = await run(shell, machine, ["codex"]);
        assert.equal(
          damaged.stdout,
          `Context Locker: the saved token for Codex is damaged, so Codex's files are as they were on 26 Oct 2026. ${CONNECT}\n`,
        );

        // A daily job and the doctor don't print it
        const daily = await run(shell, machine, ["codex", "--daily"]);
        assert.equal(daily.status, 1);
        assert.doesNotMatch(daily.stdout, /Offer to connect it again/);
      });

      it("says so as the hook's JSON for Claude Code, and when nothing has synced yet", async () => {
        const machine = computer(shell, "claude-code");
        rmSync(join(machine.clHome, "claude-code", "token"));
        const session = await run(shell, machine, ["claude-code"]);
        assert.equal(session.status, 0, session.stderr);
        assert.equal(
          additional(session.stdout),
          `Context Locker: Claude Code isn't connected on this computer, so nothing has synced here yet. ${CONNECT}`,
        );
        assert.equal(
          JSON.parse(session.stdout).hookSpecificOutput.hookEventName,
          "SessionStart",
        );
      });

      it("says when Context Locker can't be reached, and when the newer script it named was named", async () => {
        const machine = computer(shell, "codex");
        await syncedOnce(shell, machine);

        const offline = await run(shell, machine, ["codex"], {
          CONTEXT_LOCKER_API: "http://127.0.0.1:9",
        });
        assert.equal(offline.status, 0, offline.stderr);
        assert.equal(
          offline.stdout,
          `Context Locker: can't reach Context Locker, so Codex's files are as they were on 26 Oct 2026. The next sync tries again. If it keeps happening, offer to look into it with \`${runLine(shell)} doctor codex\`.\n` +
            "\n" +
            `Context Locker: as of the last sync, on 26 Oct 2026, version ${NEXT} of its sync script is out. When it suits the user, offer to update it, and once they say yes, run \`${runLine(shell)} update codex\`. That changes only the script, and the one installed keeps working until then.\n`,
        );
        assert.match(offline.stderr, /can't reach Context Locker/);

        fake.sync = { status: 503, body: '{"error":"unavailable"}' };
        const down = await run(shell, machine, ["codex"]);
        assert.equal(down.status, 0, down.stderr);
        assert.ok(
          down.stdout.startsWith(
            `Context Locker: Context Locker answered 503, so Codex's files are as they were on 26 Oct 2026. The next sync tries again.`,
          ),
          down.stdout,
        );

        // Once it answers, the line goes, and the newer script reads as live
        fake.sync = null;
        const back = await run(shell, machine, ["codex"]);
        assert.equal(
          back.stdout,
          `Context Locker: version ${NEXT} of its sync script is out. When it suits the user, offer to update it, and once they say yes, run \`${runLine(shell)} update codex\`. That changes only the script, and the one installed keeps working until then.\n`,
        );
      });

      it("names the newest script from this answer when auto sync off leaves the lock as it was", async () => {
        const machine = computer(shell, "codex");
        fake.manifest = buildManifest({
          workspaceId: WORKSPACE,
          outputs: [],
          holds: [],
          script: SYNC_SCRIPT_VERSION,
        }).text;
        await syncedOnce(shell, machine);
        const lock = join(machine.clHome, "codex", "global.lock");
        const before = readFileSync(lock, "utf8");

        // Changes wait, so the lock stays, while the answer names a newer one
        fake.manifest =
          buildManifest({
            workspaceId: WORKSPACE,
            outputs: [],
            holds: [],
            script: NEXT,
            autoSync: false,
          }).text + `block ${"d".repeat(64)} {codex}/AGENTS.md\n`;
        const waiting = await run(shell, machine, ["codex"]);
        assert.equal(waiting.status, 0, waiting.stderr);
        assert.equal(readFileSync(lock, "utf8"), before);
        assert.ok(
          waiting.stdout.startsWith(
            "Context Locker: a newer version of its sync script is out. When it suits the user, offer to set Context Locker up again for them: once they say yes, download the newest steps with `curl -fsSL https://context.locker/setup/SKILL.md` and follow them. The one installed keeps working until then.\n",
          ),
          waiting.stdout,
        );
      });

      it("offers what fits when a command finds the connection gone", async () => {
        const machine = computer(shell, "codex");
        fake.other = { status: 401, body: '{"error":"connection_revoked"}' };
        const revoked = await run(shell, machine, ["fix", "codex"]);
        assert.equal(revoked.status, 1);
        assert.ok(
          revoked.stderr.includes(
            `Context Locker: this computer's connection for Codex was revoked in Context Locker, so nothing syncs here any more. Offer to take Context Locker off this computer: run \`${runLine(shell)} remove codex\``,
          ),
          revoked.stderr,
        );

        fake.other = { status: 401, body: '{"error":"agent_token_invalid"}' };
        const expired = await run(shell, machine, ["fix", "codex"]);
        assert.equal(expired.status, 1);
        assert.ok(
          expired.stderr.includes(
            `Context Locker: this computer's connection for Codex was revoked or has expired. ${CONNECT}`,
          ),
          expired.stderr,
        );

        fake.other = { status: 401, body: '{"error":"connection_revoked"}' };
        const update = await run(shell, machine, ["update", "codex"]);
        assert.equal(update.status, 1);
        assert.match(
          update.stderr,
          /was revoked in Context Locker, so the sync script stays as it is, and nothing syncs here any more\. Offer to take Context Locker off this computer/,
        );
      });
    });
  }
});
