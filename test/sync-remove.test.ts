// A Claude cloud session never gets a device connection by mistake (G1-260):
// the sync scripts' signin stops in Claude in Cowork unless told to connect
// the sandbox on purpose, and says where it runs; the doctor offers to take
// Context Locker off a computer whose connection was revoked, never to set it
// up again; and remove takes off what the sync wrote, its hook and the
// install, once the person says yes, keeping what changed and the backups.
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
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);
const BLOCK = "{claude}/rules/context-locker.md";
const COWORK = {
  CLAUDE_CODE_REMOTE: "true",
  CLAUDE_CODE_ENTRYPOINT: "remote_cowork",
};

/** A fake Context Locker: the global manifest, sign-in and the connection */
class Fake {
  built = buildManifest({
    workspaceId: WORKSPACE,
    outputs: [
      {
        kind: "block",
        target: BLOCK,
        // As the compilers write a block, between its markers
        text: "<!-- context-locker:start v1 -->\n## Context Locker\n\n- dates-with-year: Give dates with the year.\n<!-- context-locker:end -->\n",
        items: [],
      },
    ],
    holds: [],
    script: SYNC_SCRIPT_VERSION,
  });
  manifest = this.built.text;
  /** How GET /v1/agent answers */
  agent: "live" | "revoked" = "live";
  /** Each request, with its body */
  requests: Array<{ route: string; body: string }> = [];
}

describe("signin in a Claude cloud session, the doctor and remove (G1-260)", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new Fake();
  const work = mkdtempSync(join(tmpdir(), "ctx-remove-"));

  before(async () => {
    server = createServer((request, response) => {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk: string) => (body += chunk));
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        const route = `${request.method} ${url.pathname}`;
        fake.requests.push({ route, body });
        const json = (status: number, value: unknown) => {
          response.writeHead(status, { "content-type": "application/json" });
          response.end(JSON.stringify(value));
        };
        if (route === "GET /v1/sync") {
          response.writeHead(200, {
            "content-type": "text/plain",
            etag: '"m1"',
          });
          response.end(fake.manifest);
        } else if (route === "POST /v1/sync/blobs") {
          const hashes = body.split("\n").filter(Boolean);
          const blobs = hashes.map((hash) => [
            hash,
            fake.built.blobs.get(hash),
          ]);
          if (blobs.some(([, blob]) => !blob))
            return json(409, { error: "changed" });
          response.writeHead(200, { "content-type": "application/x-tar" });
          response.end(blobArchive(blobs as never, 0));
        } else if (route === "POST /v1/sync/done") {
          json(200, { status: "recorded" });
        } else if (route === "GET /v1/agent") {
          if (fake.agent === "revoked") {
            json(401, {
              error: "connection_revoked",
              message: "This connection was revoked in Context Locker.",
            });
          } else {
            json(200, {
              agent: { name: "Claude Code", machine_name: "Test" },
              workspace: { name: "Personal" },
            });
          }
        } else if (route === "POST /oauth/device_authorization") {
          json(200, {
            device_code: "ctxl_dc_test",
            user_code: "ABCD-EFGH",
            verification_uri: "http://127.0.0.1/device",
            verification_uri_complete: "http://127.0.0.1/device?code=ABCD-EFGH",
            expires_in: 900,
            interval: 5,
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

  /** A computer with this script saved where setup puts it, and Claude Code connected */
  function computer(shell: string, connected = true) {
    fake = new Fake();
    const home = mkdtempSync(join(work, "home-"));
    const clHome = join(home, ".contextlocker");
    mkdirSync(join(clHome, "claude-code"), { recursive: true });
    writeFileSync(join(clHome, "config"), `api=${baseUrl}\nsite=${baseUrl}\n`);
    if (connected) {
      writeFileSync(join(clHome, "claude-code", "token"), "ctxl_at_test\n", {
        mode: 0o600,
      });
    }
    const installed = join(clHome, scriptName(shell));
    copyFileSync(join(SCRIPTS, scriptName(shell)), installed);
    spawnSync("chmod", ["600", installed]);
    return { home, clHome, installed };
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
      child.stdout.setEncoding("utf8").on("data", (c: string) => (stdout += c));
      child.stderr.setEncoding("utf8").on("data", (c: string) => (stderr += c));
      child.on("error", reject);
      child.on("close", (status) => resolve({ status, stdout, stderr }));
    });
  }

  const started = () =>
    fake.requests.filter((r) => r.route === "POST /oauth/device_authorization");

  for (const shell of SHELLS) {
    describe(shell, () => {
      it("stops signin in Cowork, unless told to connect the sandbox on purpose", async () => {
        const machine = computer(shell, false);
        const stopped = await run(
          shell,
          machine,
          ["signin", "claude-code"],
          COWORK,
        );
        assert.equal(stopped.status, 1, stopped.stdout + stopped.stderr);
        assert.match(
          stopped.stderr,
          /this is a Claude cloud session, such as Cowork or Claude on the web\. It gets Context Locker from your account's Claude connector, which covers every chat, so device sync isn't needed here\. To connect this sandbox on purpose, add -?-[eE]nvironment cloud\./,
        );
        assert.equal(started().length, 0);

        const told = await run(
          shell,
          machine,
          ["signin", "claude-code", "--environment", "cloud", "--wait", "0"],
          COWORK,
        );
        assert.equal(told.status, 3, told.stdout + told.stderr);
        assert.match(told.stdout, /ABCD-EFGH/);
        const [request] = started();
        assert.equal(JSON.parse(request?.body ?? "{}").environment, "cloud");
      });

      it("warns in another Claude cloud session, and says it runs in the cloud", async () => {
        const machine = computer(shell, false);
        const warned = await run(
          shell,
          machine,
          ["signin", "claude-code", "--wait", "0"],
          { CLAUDE_CODE_REMOTE: "true" },
        );
        assert.equal(warned.status, 3, warned.stdout + warned.stderr);
        assert.match(
          warned.stdout,
          /this is a Claude cloud session, whose sandbox may not last: a device connection made here ends with it\./,
        );
        assert.equal(
          JSON.parse(started()[0]?.body ?? "{}").environment,
          "cloud",
        );

        // On a computer it says nothing of where it runs
        const plain = computer(shell, false);
        await run(shell, plain, ["signin", "claude-code", "--wait", "0"]);
        assert.equal(
          JSON.parse(started()[0]?.body ?? "{}").environment,
          undefined,
        );
      });

      it("offers to take a revoked connection off the computer, never to set up again", async () => {
        const machine = computer(shell);
        fake.agent = "revoked";
        const doctor = await run(shell, machine, ["doctor", "claude-code"]);
        assert.match(
          doctor.stdout,
          /FAIL {2}This computer's connection for Claude Code was revoked in Context Locker, so nothing syncs here any more\. To take Context Locker off this computer, run .*remove claude-code to see what it takes out, and only once the person says yes, run it again with -?-[yY]es\./,
        );
        assert.doesNotMatch(doctor.stdout, /signin claude-code/);
      });

      it("takes Context Locker off the computer once the person says yes", async () => {
        const machine = computer(shell);
        const synced = await run(shell, machine, ["claude-code", "--now"]);
        assert.equal(synced.status, 0, synced.stdout + synced.stderr);
        const rules = join(
          machine.home,
          ".claude",
          "rules",
          "context-locker.md",
        );
        assert.ok(
          existsSync(rules),
          `the sync wrote its block: ${synced.stderr}`,
        );
        // The hook setup adds, beside one of the person's own
        const settings = join(machine.home, ".claude", "settings.json");
        writeFileSync(
          settings,
          `${JSON.stringify(
            {
              theme: "dark",
              hooks: {
                SessionStart: [
                  {
                    hooks: [
                      {
                        type: "command",
                        command: `sh ~/.contextlocker/${scriptName(shell)} claude-code --hook`,
                        timeout: 60,
                      },
                    ],
                  },
                  { hooks: [{ type: "command", command: "echo mine" }] },
                ],
              },
            },
            null,
            2,
          )}\n`,
        );

        // Without --yes it only says what it would take out
        const listed = await run(shell, machine, ["remove", "claude-code"]);
        assert.equal(listed.status, 0, listed.stdout + listed.stderr);
        assert.match(listed.stdout, /takes out:/);
        assert.match(listed.stdout, /context-locker\.md/);
        assert.match(listed.stdout, /session-start hook in .*settings\.json/);
        assert.match(listed.stdout, /The connection stays in Context Locker/);
        assert.ok(existsSync(rules));
        assert.ok(existsSync(machine.installed));

        const removed = await run(shell, machine, [
          "remove",
          "claude-code",
          "--yes",
        ]);
        assert.equal(removed.status, 0, removed.stdout + removed.stderr);
        assert.match(
          removed.stdout,
          /Context Locker is off this computer for Claude Code/,
        );
        assert.match(removed.stdout, /The connection stays in Context Locker/);
        assert.ok(!existsSync(rules), "the block's own file is gone");
        assert.ok(!existsSync(join(machine.clHome, "claude-code")));
        assert.ok(!existsSync(machine.installed));
        assert.ok(!existsSync(join(machine.clHome, "config")));
        // The person's own settings and hook stay; only Context Locker's goes
        const left = JSON.parse(readFileSync(settings, "utf8"));
        assert.equal(left.theme, "dark");
        assert.deepEqual(left.hooks.SessionStart, [
          { hooks: [{ type: "command", command: "echo mine" }] },
        ]);
        // The backups stay, with a copy of what was taken out
        assert.ok(readdirSync(join(machine.clHome, "backups")).length > 0);
        // No request went to Context Locker: the connection stays as it was
        assert.ok(
          !fake.requests.some(
            (r) => r.route.includes("revoke") || r.route.startsWith("DELETE"),
          ),
        );
      });

      it("keeps what changed since the sync wrote it", async () => {
        const machine = computer(shell);
        await run(shell, machine, ["claude-code", "--now"]);
        const rules = join(
          machine.home,
          ".claude",
          "rules",
          "context-locker.md",
        );
        writeFileSync(
          rules,
          readFileSync(rules, "utf8").replace(
            "dates-with-year",
            "dates-in-full",
          ),
        );
        const removed = await run(shell, machine, [
          "remove",
          "claude-code",
          "--yes",
        ]);
        assert.equal(removed.status, 0, removed.stdout + removed.stderr);
        assert.match(
          removed.stdout,
          /It left:\n- Context Locker's part of .*context-locker\.md, which changed since the sync wrote it/,
        );
        assert.ok(existsSync(rules));
      });
    });
  }
});
