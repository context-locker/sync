// The sync scripts' update command (G1-112). It takes the newest script from
// where setup publishes it, only when Context Locker says this one can, and
// only when it matches the SHA-256 Context Locker gives for it, keeping the
// old one beside it and changing nothing else. The session start and the
// doctor name it. These run the real scripts against a fake Context Locker
// that also plays the website.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
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
/** The setup version the fake website publishes the next script in */
const SETUP = 999;

const sha256 = (data: Buffer | string) =>
  createHash("sha256").update(data).digest("hex");

/** The script here, saying it's another version, as a later release would be */
function scriptAs(name: string, version: number, extra = ""): Buffer {
  const text = readFileSync(join(SCRIPTS, name), "utf8");
  const [from, to] =
    name === "sync.sh"
      ? [
          `\nSCRIPT_VERSION=${SYNC_SCRIPT_VERSION}\n`,
          `\nSCRIPT_VERSION=${version}\n`,
        ]
      : [
          `\n$ScriptVersion = ${SYNC_SCRIPT_VERSION}\n`,
          `\n$ScriptVersion = ${version}\n`,
        ];
  assert.ok(text.includes(from), `${name} says it's ${SYNC_SCRIPT_VERSION}`);
  return Buffer.from(text.replace(from, to) + extra, "utf8");
}

interface Answer {
  status: number;
  body: Buffer | string;
}

/** A fake Context Locker, which also serves setup's files as the website does */
class Fake {
  /** What GET /v1/sync/script answers */
  script: Answer = { status: 200, body: `script ${SYNC_SCRIPT_VERSION}\n` };
  /** What the website serves, by path */
  site = new Map<string, Answer>();
  /** The global manifest */
  manifest = buildManifest({
    workspaceId: WORKSPACE,
    outputs: [],
    holds: [],
    script: SYNC_SCRIPT_VERSION,
  }).text;
  /** Each request, with whether it carried the connection's token */
  requests: Array<{ route: string; token: boolean }> = [];
}

describe("the sync scripts' update command", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new Fake();
  const work = mkdtempSync(join(tmpdir(), "ctx-update-"));

  before(async () => {
    server = createServer((request, response) => {
      request.resume();
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        const route = `${request.method} ${url.pathname}`;
        fake.requests.push({
          route,
          token: request.headers.authorization !== undefined,
        });
        const send = (answer: Answer, type = "text/plain") => {
          response.writeHead(answer.status, { "content-type": type });
          response.end(answer.body);
        };
        const site = fake.site.get(url.pathname);
        if (request.method === "GET" && site) send(site, "text/x-sh");
        else if (route === "GET /v1/sync/script") send(fake.script);
        else if (route === "GET /v1/sync") {
          const etag = `"${sha256(fake.manifest)}"`;
          if (request.headers["if-none-match"] === etag) {
            response.writeHead(304, { etag });
            response.end();
            return;
          }
          response.writeHead(200, { "content-type": "text/plain", etag });
          response.end(fake.manifest);
        } else if (route === "POST /v1/sync/done") {
          send(
            { status: 200, body: '{"status":"recorded"}' },
            "application/json",
          );
        } else if (route === "GET /v1/agent") {
          send(
            {
              status: 200,
              body: JSON.stringify({
                agent: { name: "codex", machine_name: "Test" },
                workspace: { name: "Personal" },
              }),
            },
            "application/json",
          );
        } else {
          send(
            { status: 404, body: '{"error":"not_found"}' },
            "application/json",
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

  const scriptName = (shell: string) =>
    shell === "pwsh" ? "sync.ps1" : "sync.sh";
  const runLine = (shell: string) =>
    shell === "pwsh"
      ? "pwsh -NoProfile -File ~/.contextlocker/sync.ps1"
      : "sh ~/.contextlocker/sync.sh";
  const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  /**
   * A computer with Codex connected, and this script saved where setup puts
   * it, owner-only, with the website at Context Locker's own address
   */
  function computer(shell: string) {
    fake = new Fake();
    const home = mkdtempSync(join(work, "home-"));
    const clHome = join(home, ".contextlocker");
    mkdirSync(join(clHome, "codex"), { recursive: true });
    writeFileSync(join(clHome, "config"), `api=${baseUrl}\nsite=${baseUrl}\n`);
    writeFileSync(join(clHome, "codex", "token"), "ctxl_at_test\n", {
      mode: 0o600,
    });
    const installed = join(clHome, scriptName(shell));
    copyFileSync(join(SCRIPTS, scriptName(shell)), installed);
    // As setup saves it
    spawnSync("chmod", ["600", installed]);
    return { home, clHome, installed };
  }

  /** Publishes a script on the fake website, and has Context Locker name it */
  function publish(shell: string, bytes: Buffer, hash = sha256(bytes)) {
    fake.site.set(`/setup/v${SETUP}/${scriptName(shell)}`, {
      status: 200,
      body: bytes,
    });
    fake.script = {
      status: 200,
      body: `script ${NEXT}\nupdate ${hash} ${SETUP}\n`,
    };
  }

  /** Runs a script, the one setup saved unless another is named, as an app would */
  function run(
    shell: string,
    machine: { home: string; installed: string },
    words: string[],
    script = machine.installed,
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const args =
      shell === "pwsh"
        ? ["-NoProfile", "-NonInteractive", "-File", script, ...words]
        : [script, ...words];
    return new Promise((resolve, reject) => {
      const child = spawn(shell, args, {
        cwd: machine.home,
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

  /** Every file in a folder, with what it holds, but the scripts and their copies */
  function snapshot(folder: string): Record<string, string> {
    const files: Record<string, string> = {};
    const walk = (dir: string, prefix: string) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        const rel = `${prefix}${name}`;
        if (/^sync\.(sh|ps1)(\.previous)?$/.test(rel)) continue;
        if (statSync(path).isDirectory()) walk(path, `${rel}/`);
        else files[rel] = readFileSync(path, "utf8");
      }
    };
    walk(folder, "");
    return files;
  }

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("says at session start and in the doctor how to update, when Context Locker says this script can", async () => {
        const machine = computer(shell);
        fake.manifest = buildManifest({
          workspaceId: WORKSPACE,
          outputs: [],
          holds: [],
          script: NEXT,
          update: { hash: "c".repeat(64), setup: SETUP },
        }).text;
        const synced = await run(shell, machine, ["codex"]);
        assert.equal(synced.status, 0, synced.stdout + synced.stderr);
        assert.ok(
          synced.stdout.includes(
            `Context Locker: version ${NEXT} of its sync script is out. When it suits the user, offer to update it, and once they say yes, run \`${runLine(shell)} update codex\`. That changes only the script, and the one installed keeps working until then.\n`,
          ),
          synced.stdout,
        );
        const doctor = await run(shell, machine, ["doctor", "codex"]);
        assert.match(
          doctor.stdout,
          new RegExp(
            `^WARN {2}${escape(`Version ${NEXT} of the sync script is out, and updating to it changes only the script. When it suits you, run: ${runLine(shell)} update codex`)}$`,
            "m",
          ),
        );

        // When the newest needs more than the script, setting up again
        fake.manifest = buildManifest({
          workspaceId: WORKSPACE,
          outputs: [],
          holds: [],
          script: NEXT,
        }).text;
        const again = await run(shell, machine, ["codex"]);
        assert.equal(again.status, 0, again.stdout + again.stderr);
        assert.ok(
          again.stdout.includes(
            "Context Locker: a newer version of its sync script is out. When it suits the user, offer to set Context Locker up again from https://context.locker/setup. The one installed keeps working until then.\n",
          ),
          again.stdout,
        );
        assert.doesNotMatch(again.stdout, / update codex/);
      });

      it("takes the newest script from setup's folder, keeps the old one beside it and changes nothing else", async () => {
        const machine = computer(shell);
        const old = readFileSync(machine.installed);
        const next = scriptAs(scriptName(shell), NEXT);
        publish(shell, next);
        const before = snapshot(machine.clHome);

        const updated = await run(shell, machine, ["update", "codex"]);
        assert.equal(updated.status, 0, updated.stdout + updated.stderr);
        assert.equal(
          updated.stdout,
          `Context Locker: the sync script is now version ${NEXT}, from ${baseUrl}/setup/v${SETUP}/${scriptName(shell)}. Version ${SYNC_SCRIPT_VERSION} is kept at ${machine.installed}.previous, and nothing else changed.\n`,
        );
        assert.equal(updated.stderr, "");
        assert.deepEqual(readFileSync(machine.installed), next);
        assert.deepEqual(readFileSync(`${machine.installed}.previous`), old);
        // Owner-only, as setup saves it
        assert.equal(statSync(machine.installed).mode & 0o777, 0o600);
        assert.deepEqual(snapshot(machine.clHome), before);
        // The website never gets the connection's token
        assert.deepEqual(
          fake.requests.map((request) => request.route),
          ["GET /v1/sync/script", `GET /setup/v${SETUP}/${scriptName(shell)}`],
        );
        assert.deepEqual(
          fake.requests.map((request) => request.token),
          [true, false],
        );

        // The new one is the newest, so there's nothing more to take
        const again = await run(shell, machine, ["update", "codex"]);
        assert.equal(again.status, 0, again.stdout + again.stderr);
        assert.equal(
          again.stdout,
          `Context Locker: the sync script is up to date, at version ${NEXT}.\n`,
        );
        assert.deepEqual(readFileSync(`${machine.installed}.previous`), old);
      });

      it("won't take a script that doesn't match, isn't the version named or doesn't read as a script", async () => {
        const name = scriptName(shell);
        const next = scriptAs(name, NEXT);
        const broken = scriptAs(
          name,
          NEXT,
          shell === "pwsh" ? "\nfunction Broken {\n" : "\nif then\n",
        );
        const cases: Array<{
          why: string;
          set: () => void;
          says: RegExp;
        }> = [
          {
            why: "a different file",
            set: () => publish(shell, next, sha256("something else")),
            says: /doesn't match the SHA-256 Context Locker gives for version \d+, so it wasn't used, and the script stays as it is\./,
          },
          {
            why: "another version",
            set: () => publish(shell, scriptAs(name, NEXT + 1)),
            says: /isn't version \d+, so it wasn't used, and the script stays as it is\./,
          },
          {
            why: "not a script",
            set: () => publish(shell, broken),
            says:
              shell === "pwsh"
                ? /doesn't read as a PowerShell script here, so it wasn't used/
                : /doesn't read as a shell script here, so it wasn't used/,
          },
          {
            why: "not there",
            set: () => {
              publish(shell, next);
              fake.site.set(`/setup/v${SETUP}/${name}`, {
                status: 404,
                body: "Not found",
              });
            },
            says: /answered 404, so the sync script stays as it is\. Try again later\./,
          },
          {
            why: "nothing to take in place",
            set: () => {
              fake.script = { status: 200, body: `script ${NEXT}\n` };
            },
            says: /version \d+ of the sync script needs more than the script, such as a new hook, so update can't take it\. Set Context Locker up again from https:\/\/context\.locker\/setup\./,
          },
          {
            why: "a connection that's gone",
            set: () => {
              fake.script = {
                status: 401,
                body: '{"error":"invalid_token"}',
              };
            },
            says: /connection for Codex was revoked or has expired, so the sync script stays as it is\./,
          },
        ];
        for (const each of cases) {
          const machine = computer(shell);
          const old = readFileSync(machine.installed);
          each.set();
          const refused = await run(shell, machine, ["update", "codex"]);
          assert.equal(refused.status, 1, `${each.why}: ${refused.stdout}`);
          assert.match(refused.stderr, each.says, each.why);
          assert.equal(refused.stdout, "", each.why);
          assert.deepEqual(readFileSync(machine.installed), old, each.why);
          assert.ok(!existsSync(`${machine.installed}.previous`), each.why);
          // Nothing of the download is left behind
          assert.deepEqual(
            readdirSync(machine.clHome)
              .filter((entry) => entry.startsWith("tmp."))
              .sort(),
            [],
            each.why,
          );
        }
      });

      it("leaves a script it isn't running, and one that's a link, as they are", async () => {
        const name = scriptName(shell);
        // The saved script is another version than the one running
        const other = computer(shell);
        writeFileSync(other.installed, scriptAs(name, NEXT));
        publish(shell, scriptAs(name, NEXT + 1));
        const mismatch = await run(
          shell,
          other,
          ["update", "codex"],
          join(SCRIPTS, name),
        );
        assert.equal(mismatch.status, 1);
        assert.ok(
          mismatch.stderr.includes(
            `Context Locker: the sync script at ${other.installed} is version ${NEXT}, and this one is version ${SYNC_SCRIPT_VERSION}. Run the one there: ${runLine(shell)} update codex`,
          ),
          mismatch.stderr,
        );
        // None of them asks Context Locker or the website anything
        assert.deepEqual(fake.requests, []);

        // A link, as a dotfiles setup might make
        const linked = computer(shell);
        const target = join(linked.home, "dotfiles-sync");
        copyFileSync(linked.installed, target);
        rmSync(linked.installed);
        symlinkSync(target, linked.installed);
        publish(shell, scriptAs(name, NEXT));
        const link = await run(shell, linked, ["update", "codex"], target);
        assert.equal(link.status, 1);
        assert.match(
          link.stderr,
          /is a link, so update leaves it as it is\. Set Context Locker up again from https:\/\/context\.locker\/setup instead\./,
        );
        assert.deepEqual(
          readFileSync(target),
          readFileSync(join(SCRIPTS, name)),
        );
        assert.deepEqual(fake.requests, []);

        // Nothing saved where setup puts it
        const missing = computer(shell);
        rmSync(missing.installed);
        const gone = await run(
          shell,
          missing,
          ["update", "codex"],
          join(SCRIPTS, name),
        );
        assert.equal(gone.status, 1);
        assert.match(gone.stderr, /so there's nothing to update/);
        assert.deepEqual(fake.requests, []);
      });
    });
  }
});
