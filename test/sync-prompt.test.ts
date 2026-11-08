// The per-prompt hook (G1-271): prompt prints one line while a session runs,
// when Context Locker says someone left the app something new, in the shape
// each app reads from a hook, and nothing otherwise. It asks at most once a
// minute, sends the app's own id for its session from the JSON the app hands
// its hook, and never stops a prompt: every way out is quiet, with exit 0.
// These run the real scripts against a fake Context Locker.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
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

import { SYNC_SCRIPT_VERSION } from "../src/index.js";

const SCRIPTS = fileURLToPath(new URL("../scripts/", import.meta.url));
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);
const LINE =
  "Context Locker: Alan left you 1 new request to act on. Read it once the step in hand is done: run `sh ~/.contextlocker/sync.sh fix claude-code` in the project and do as the list says.";
const SESSION = "3f2a9c1e-5b7d-4e8f-a0b1-c2d3e4f5a6b7";

/** A fake Context Locker, which answers the prompt route as it's told */
class Fake {
  status = 200;
  body = `${LINE}\n`;
  requests: { url: string; agent: string; auth: string }[] = [];
}

describe("the per-prompt hook (G1-271)", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new Fake();
  const work = mkdtempSync(join(tmpdir(), "ctx-prompt-"));

  before(async () => {
    server = createServer((request, response) => {
      request.resume();
      request.on("end", () => {
        fake.requests.push({
          url: `${request.method} ${request.url}`,
          agent: request.headers["user-agent"] ?? "",
          auth: request.headers.authorization ?? "",
        });
        if (!(request.url ?? "").startsWith("/v1/sync/prompt")) {
          response.writeHead(404, { "content-type": "application/json" });
          response.end('{"error":"not_found"}');
          return;
        }
        response.writeHead(fake.status, { "content-type": "text/plain" });
        response.end(fake.status === 204 ? undefined : fake.body);
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

  /** A computer with the app connected, and this script where setup puts it */
  function computer(
    shell: string,
    harness: string,
    options: { api?: string; token?: boolean } = {},
  ) {
    fake = new Fake();
    const home = mkdtempSync(join(work, "home-"));
    const clHome = join(home, ".contextlocker");
    mkdirSync(join(clHome, harness), { recursive: true });
    writeFileSync(
      join(clHome, "config"),
      `api=${options.api ?? baseUrl}\nsite=${baseUrl}\n`,
    );
    if (options.token !== false) {
      writeFileSync(join(clHome, harness, "token"), "ctxl_at_test\n", {
        mode: 0o600,
      });
    }
    const installed = join(clHome, scriptName(shell));
    copyFileSync(join(SCRIPTS, scriptName(shell)), installed);
    return { home, clHome, installed, harness };
  }

  /** A prompt's hook, with the JSON the app hands it on stdin */
  function prompt(
    shell: string,
    machine: { home: string; installed: string; harness: string },
    input = `{"session_id":"${SESSION}","hook_event_name":"UserPromptSubmit","prompt":"Carry on, please"}`,
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const words = ["prompt", machine.harness];
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
        },
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      child.stdout
        .setEncoding("utf8")
        .on("data", (chunk: string) => (stdout += chunk));
      child.stderr
        .setEncoding("utf8")
        .on("data", (chunk: string) => (stderr += chunk));
      // A hook that's asked nothing may end before it reads what it's handed
      child.stdin.on("error", () => {});
      child.stdin.end(input);
      const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
      child.on("error", reject);
      child.on("close", (status) => {
        clearTimeout(timer);
        resolve({ status, stdout, stderr });
      });
    });
  }

  /** Dates the last time the hook asked a minute and a second ago */
  const minuteAgo = (machine: { clHome: string; harness: string }) =>
    writeFileSync(
      join(machine.clHome, machine.harness, "prompt-asked"),
      `${Math.floor(Date.now() / 1000) - 61}\n`,
    );

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      const agent = `context-locker-sync/${SYNC_SCRIPT_VERSION} (claude-code; ${shell === "pwsh" ? "powershell" : "sh"})`;

      it("says the line to Claude Code as its hook's JSON, sending the session's id", async () => {
        const machine = computer(shell, "claude-code");
        const said = await prompt(shell, machine);
        assert.equal(said.status, 0, said.stderr);
        const output = JSON.parse(said.stdout).hookSpecificOutput;
        assert.equal(output.hookEventName, "UserPromptSubmit");
        assert.equal(output.additionalContext, LINE);
        assert.deepEqual(fake.requests, [
          {
            url: `GET /v1/sync/prompt?session=${SESSION}`,
            agent,
            auth: "Bearer ctxl_at_test",
          },
        ]);
      });

      it("says it to Codex as text, and to Hermes as JSON with context", async () => {
        const codex = computer(shell, "codex");
        const plain = await prompt(shell, codex);
        assert.equal(plain.status, 0, plain.stderr);
        assert.equal(plain.stdout.trimEnd(), LINE);

        const hermes = computer(shell, "hermes");
        const json = await prompt(
          shell,
          hermes,
          `{"hook_event_name":"pre_llm_call","session_id":"20261107_011500_ab12","cwd":"/tmp","extra":{"user_message":"hi, \\"session_id\\": \\"not this one\\""}}`,
        );
        assert.equal(json.status, 0, json.stderr);
        assert.deepEqual(JSON.parse(json.stdout), { context: LINE });
        assert.equal(
          fake.requests[0]?.url,
          "GET /v1/sync/prompt?session=20261107_011500_ab12",
        );
      });

      it("asks at most once a minute, keeping when it last asked", async () => {
        const machine = computer(shell, "claude-code");
        assert.notEqual((await prompt(shell, machine)).stdout, "");
        // Within the minute it asks nothing and says nothing
        const again = await prompt(shell, machine);
        assert.equal(again.status, 0, again.stderr);
        assert.equal(again.stdout, "");
        assert.equal(fake.requests.length, 1);
        // A minute on, it asks again
        minuteAgo(machine);
        assert.notEqual((await prompt(shell, machine)).stdout, "");
        assert.equal(fake.requests.length, 2);
      });

      it("says nothing, and lets the prompt go on, when nothing's new or Context Locker can't say", async () => {
        const machine = computer(shell, "claude-code");
        fake.status = 204;
        const quiet = await prompt(shell, machine);
        assert.deepEqual(
          { status: quiet.status, stdout: quiet.stdout },
          { status: 0, stdout: "" },
        );
        minuteAgo(machine);
        fake.status = 500;
        fake.body = '{"error":"internal"}';
        const broken = await prompt(shell, machine);
        assert.deepEqual(
          { status: broken.status, stdout: broken.stdout },
          { status: 0, stdout: "" },
        );

        // Nothing listening, and no session id to send
        const away = computer(shell, "codex", { api: "http://127.0.0.1:9" });
        const unreachable = await prompt(shell, away, "");
        assert.deepEqual(
          { status: unreachable.status, stdout: unreachable.stdout },
          { status: 0, stdout: "" },
        );
      });

      it("asks nothing for an app that isn't connected here", async () => {
        const machine = computer(shell, "claude-code", { token: false });
        const quiet = await prompt(shell, machine);
        assert.deepEqual(
          { status: quiet.status, stdout: quiet.stdout },
          { status: 0, stdout: "" },
        );
        assert.deepEqual(fake.requests, []);
        assert.equal(
          existsSync(join(machine.clHome, "claude-code", "prompt-asked")),
          false,
        );
        // Nor does it leave anything else of its own
        assert.equal(
          readFileSync(join(machine.clHome, "config"), "utf8"),
          `api=${baseUrl}\nsite=${baseUrl}\n`,
        );
      });
    });
  }
});
