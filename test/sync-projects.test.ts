// The sync scripts and projects: finding a clone's project by its git
// remote, checking a project's links to paths in its repo, the map command,
// daily syncs of the projects linked on a computer, and the line that says
// a newer script is out. These run the real scripts against a fake API.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
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
  MANIFEST_HEADER,
  SYNC_SCRIPT_VERSION,
  blobArchive,
  buildManifest,
  compile,
  sha256,
  type Blob,
  type RepoLink,
} from "../src/index.js";

const SCRIPT = fileURLToPath(new URL("../scripts/sync.sh", import.meta.url));
const PS_SCRIPT = fileURLToPath(
  new URL("../scripts/sync.ps1", import.meta.url),
);
const WORKSPACE = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);
const HAVE_GIT = spawnSync("sh", ["-c", "command -v git"]).status === 0;
const NEWER_LINE =
  "Context Locker: a newer version of its sync script is out. When it suits the user, offer to set Context Locker up again from https://context.locker/setup. The one installed keeps working until then.";

interface FakeProject {
  id: string;
  name: string;
  remote?: string;
  links?: RepoLink[];
  /** Answers its manifest with this status instead */
  fail?: number;
}

/** A fake Context Locker that knows some projects, their remotes and pointers to paths in their repos */
class FakeLocker {
  projects = new Map<string, FakeProject>();
  /** The newest script the global manifest names */
  script = SYNC_SCRIPT_VERSION;
  /** Every request, as "METHOD /path?query" */
  requests: string[] = [];
  /** What each kind of request sent, in order */
  sent: Record<string, string[]> = { find: [], record: [], map: [], done: [] };
  blobs = new Map<string, Blob>();

  add(project: Omit<FakeProject, "id"> & { id?: string }): FakeProject {
    const full = { id: randomUUID(), ...project };
    this.projects.set(full.id, full);
    return full;
  }

  /** The remote as the API keeps it, roughly: host/owner/repo */
  static normal(sent: string): string {
    return sent
      .replace(/^[a-z+]+:\/\//, "")
      .replace(/^[^@/]*@/, "")
      .replace(/^([^/:]+):(?!\d)/, "$1/")
      .replace(/\.git$/, "")
      .toLowerCase();
  }

  manifest(url: URL, harness: string): { status: number; text: string } {
    const id = url.searchParams.get("project");
    if (!id) {
      return {
        status: 200,
        text: `${MANIFEST_HEADER}\nworkspace ${WORKSPACE}\nscript ${this.script}\n`,
      };
    }
    const project = this.projects.get(id);
    if (!project) return { status: 404, text: '{"error":"not_found"}' };
    if (project.fail) return { status: project.fail, text: '{"error":"x"}' };
    const layer =
      url.searchParams.get("layer") === "repo" ? "repo" : "personal";
    const manifest = buildManifest({
      workspaceId: WORKSPACE,
      outputs: compile({
        harness: harness as "claude-code",
        project: { id, name: project.name, layer },
        preferences: [],
        skills: [],
        notes: [],
        tags: [],
      }).outputs,
      holds: [],
      links: project.links ?? [],
    });
    for (const [hash, blob] of manifest.blobs) this.blobs.set(hash, blob);
    return { status: 200, text: manifest.text };
  }
}

describe("a project in the sync", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new FakeLocker();
  const work = mkdtempSync(join(tmpdir(), "ctx-projects-"));

  before(async () => {
    server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        fake.requests.push(`${request.method} ${url.pathname}${url.search}`);
        const body = Buffer.concat(chunks).toString("utf8");
        const harness =
          String(request.headers["user-agent"]).match(/\((\S+);/)?.[1] ??
          "claude-code";
        const send = (status: number, type: string, data: Buffer | string) => {
          response.writeHead(status, { "content-type": type });
          response.end(data);
        };
        const json = (status: number, value: unknown) =>
          send(status, "application/json", JSON.stringify(value));
        const route = `${request.method} ${url.pathname}`;
        if (route === "GET /v1/sync") {
          const { status, text } = fake.manifest(url, harness);
          const etag = `"${sha256(text)}"`;
          if (status === 200 && request.headers["if-none-match"] === etag) {
            response.writeHead(304, { etag });
            response.end();
            return;
          }
          response.writeHead(status, {
            "content-type": status === 200 ? "text/plain" : "application/json",
            ...(status === 200 ? { etag } : {}),
          });
          response.end(text);
        } else if (route === "POST /v1/sync/blobs") {
          const blobs: Array<[string, Blob]> = [];
          for (const hash of body.split("\n").filter(Boolean)) {
            const blob = fake.blobs.get(hash);
            if (!blob) return json(409, { error: "changed" });
            blobs.push([hash, blob]);
          }
          send(200, "application/x-tar", blobArchive(blobs, 0));
        } else if (route === "POST /v1/sync/remote") {
          fake.sent.find?.push(body);
          const project = [...fake.projects.values()].find(
            (candidate) =>
              candidate.remote &&
              FakeLocker.normal(candidate.remote) === FakeLocker.normal(body),
          );
          if (!project) return json(404, { error: "not_found" });
          json(200, {
            project: { id: project.id, name: project.name },
            git_remote: FakeLocker.normal(project.remote as string),
          });
        } else if (route === "PUT /v1/sync/remote") {
          fake.sent.record?.push(`${url.searchParams.get("project")} ${body}`);
          json(200, { status: "recorded" });
        } else if (route === "POST /v1/sync/map") {
          fake.sent.map?.push(body);
          const project = fake.projects.get(
            url.searchParams.get("project") ?? "",
          );
          if (!project) return json(404, { error: "not_found" });
          send(
            200,
            "text/plain; charset=utf-8",
            `Map of ${project.name}, for ${body || "the whole project"}.\n\u001b[31mNo colours.\tTabs stay.\n`,
          );
        } else if (route === "POST /v1/sync/done") {
          fake.sent.done?.push(body);
          json(200, { status: "recorded" });
        } else if (route === "GET /v1/agent") {
          json(200, {
            agent: { name: harness, machine_name: "Test" },
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

  /** A computer with these apps connected */
  function computer(apps: string[] = ["claude-code"]) {
    fake = new FakeLocker();
    const home = mkdtempSync(join(work, "home-"));
    mkdirSync(join(home, ".contextlocker"));
    writeFileSync(join(home, ".contextlocker", "config"), `api=${baseUrl}\n`);
    for (const app of apps) {
      mkdirSync(join(home, ".contextlocker", app), { recursive: true });
      writeFileSync(
        join(home, ".contextlocker", app, "token"),
        "ctxl_at_test\n",
      );
    }
    return { home };
  }

  /** A git repo in the home folder, with an origin remote when one's given */
  function repo(home: string, name: string, origin?: string) {
    const dir = join(home, name);
    mkdirSync(dir, { recursive: true });
    spawnSync("git", ["init", "-q", dir]);
    if (origin)
      spawnSync("git", ["-C", dir, "remote", "add", "origin", origin]);
    return dir;
  }

  const linkFile = (dir: string, project: string) =>
    writeFileSync(
      join(dir, ".contextlocker.json"),
      JSON.stringify({ workspace: WORKSPACE, project }),
    );

  const linked = (home: string) => {
    const file = join(home, ".contextlocker", "projects");
    return existsSync(file) ? readFileSync(file, "utf8") : "";
  };

  function run(
    shell: string,
    machine: { home: string },
    options: {
      cwd?: string;
      args?: string[];
      harness?: string;
      mode?: string;
    } = {},
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const harness = options.harness ?? "claude-code";
    const start = options.mode ? [options.mode, harness] : [harness];
    const args =
      shell === "pwsh"
        ? [
            "-NoProfile",
            "-NonInteractive",
            "-File",
            PS_SCRIPT,
            ...start,
            ...(options.args ?? []),
          ]
        : [SCRIPT, ...start, ...(options.args ?? [])];
    return new Promise((resolve, reject) => {
      const child = spawn(shell, args, {
        cwd: options.cwd ?? machine.home,
        env: {
          PATH: process.env.PATH ?? "",
          HOME: machine.home,
          POWERSHELL_TELEMETRY_OPTOUT: "1",
          GIT_CONFIG_NOSYSTEM: "1",
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

  const projectSyncs = () =>
    fake.requests.filter((request) =>
      /^GET \/v1\/sync\?project=/.test(request),
    );

  for (const shell of SHELLS) {
    describe(
      `in ${shell}`,
      { skip: !HAVE_GIT && "git isn't installed" },
      () => {
        it("links a clone to its project by its git remote, syncs it and says so in one line", async () => {
          const machine = computer();
          const docs = fake.add({
            name: "Docs site",
            remote: "github.com/acme/docs",
          });
          const clone = repo(
            machine.home,
            "docs",
            "https://nova:ghp_secret@github.com/acme/docs.git?x=1#top",
          );

          const first = await run(shell, machine, { cwd: clone });
          assert.equal(first.status, 0, first.stderr);
          assert.equal(
            first.stderr,
            `Context Locker: linked ${clone} to Docs site by its git remote, github.com/acme/docs.\n`,
          );
          // Only the remote went, with no user name, password, query or fragment
          assert.deepEqual(fake.sent.find, [
            "https://github.com/acme/docs.git",
          ]);
          assert.equal(linked(machine.home), `${docs.id} ${clone}\n`);
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${docs.id}&layer=personal`,
          ]);

          // From then on the link finds it, with nothing more to say
          const again = await run(shell, machine, { cwd: join(clone) });
          assert.equal(again.status, 0, again.stderr);
          assert.equal(again.stderr, "");
          assert.equal(fake.sent.find?.length, 1);
          assert.equal(projectSyncs().length, 2);
        });

        it("never sends a path on this computer as a remote", async () => {
          const machine = computer();
          fake.add({ name: "Docs site", remote: "github.com/acme/docs" });
          for (const [name, origin] of [
            ["local", join(machine.home, "upstream.git")],
            ["file", `file://${join(machine.home, "upstream.git")}`],
            ["relative", "../upstream.git"],
            ["none", undefined],
          ] as const) {
            const clone = repo(machine.home, name, origin);
            const result = await run(shell, machine, { cwd: clone });
            assert.equal(result.status, 0, result.stderr);
            assert.equal(result.stderr, "", name);
          }
          // Outside a git work tree too
          const plain = join(machine.home, "plain");
          mkdirSync(plain);
          assert.equal((await run(shell, machine, { cwd: plain })).status, 0);
          assert.deepEqual(fake.sent.find, []);
          assert.deepEqual(projectSyncs(), []);
          assert.equal(linked(machine.home), "");
          // An scp-like remote goes without its user name
          const ssh = repo(
            machine.home,
            "ssh",
            "git@github.com:acme/other.git",
          );
          await run(shell, machine, { cwd: ssh });
          assert.deepEqual(fake.sent.find, ["github.com:acme/other.git"]);
        });

        it("takes --project first, then .contextlocker.json, then a linked folder, then the remote", async () => {
          const machine = computer();
          const byFile = fake.add({ name: "By file" });
          const byFlag = fake.add({ name: "By flag" });
          const byLink = fake.add({ name: "By link" });
          const byRemote = fake.add({
            name: "By remote",
            remote: "github.com/acme/docs",
          });
          const clone = repo(
            machine.home,
            "docs",
            "https://nova:ghp_secret@github.com/acme/docs.git",
          );
          linkFile(clone, byFile.id);
          const sub = join(clone, "src");
          mkdirSync(sub);

          await run(shell, machine, { cwd: sub });
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${byFile.id}&layer=repo`,
          ]);

          // --project wins over the file, and records the remote on its project
          fake.requests = [];
          const flagged = await run(shell, machine, {
            cwd: sub,
            args: [shell === "pwsh" ? "-Project" : "--project", byFlag.id],
          });
          assert.equal(flagged.status, 0, flagged.stderr);
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${byFlag.id}&layer=personal`,
          ]);
          assert.deepEqual(fake.sent.record, [
            `${byFlag.id} https://github.com/acme/docs.git`,
          ]);
          assert.equal(linked(machine.home), `${byFlag.id} ${clone}\n`);

          // Without the flag, the file comes before the folder's link
          fake.requests = [];
          await run(shell, machine, { cwd: sub });
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${byFile.id}&layer=repo`,
          ]);

          // Then the link
          rmSync(join(clone, ".contextlocker.json"));
          writeFileSync(
            join(machine.home, ".contextlocker", "projects"),
            `${byLink.id} ${clone}\n`,
          );
          fake.requests = [];
          await run(shell, machine, { cwd: sub });
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${byLink.id}&layer=personal`,
          ]);

          // And last the remote, which links the folder
          rmSync(join(machine.home, ".contextlocker", "projects"));
          fake.requests = [];
          const found = await run(shell, machine, { cwd: sub });
          assert.match(
            found.stderr,
            /by its git remote, github\.com\/acme\/docs\.$/m,
          );
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${byRemote.id}&layer=personal`,
          ]);
          assert.equal(fake.sent.find?.length, 1);
        });

        it("checks the project's pointers to paths in its repo, says which are missing in one line, and reports them", async () => {
          const machine = computer();
          const ids = Array.from({ length: 6 }, () => randomUUID());
          const docs = fake.add({
            name: "Docs site",
            links: [
              { id: ids[0] as string, path: "docs/runbook.md" },
              { id: ids[1] as string, path: "docs/missing.md" },
              { id: ids[2] as string, path: "docs/outside.md" },
              { id: ids[3] as string, path: "docs/inside.md" },
              { id: ids[4] as string, path: "design/first draft.md" },
              { id: ids[5] as string, path: "shared/notes.md" },
            ],
          });
          const clone = repo(machine.home, "docs");
          linkFile(clone, docs.id);
          mkdirSync(join(clone, "docs"));
          mkdirSync(join(clone, "design"));
          writeFileSync(join(clone, "docs", "runbook.md"), "Run it.\n");
          writeFileSync(join(clone, "design", "first draft.md"), "Draft.\n");
          // A link to a file inside the repo counts; one out of it doesn't
          symlinkSync("runbook.md", join(clone, "docs", "inside.md"));
          writeFileSync(join(machine.home, "secret.md"), "Not the repo's.\n");
          symlinkSync(
            join(machine.home, "secret.md"),
            join(clone, "docs", "outside.md"),
          );
          // Nor does a folder that leads out of it
          mkdirSync(join(machine.home, "elsewhere"));
          writeFileSync(
            join(machine.home, "elsewhere", "notes.md"),
            "Elsewhere.\n",
          );
          symlinkSync(join(machine.home, "elsewhere"), join(clone, "shared"));

          const first = await run(shell, machine, { cwd: clone });
          assert.equal(first.status, 0, first.stderr);
          assert.equal(
            first.stderr,
            `Context Locker: 3 of this project's pointers point to paths that aren't in ${clone}: docs/missing.md, docs/outside.md, shared/notes.md. If they moved, change their addresses in Context Locker.\n`,
          );
          const report = fake.sent.done?.at(-1) ?? "";
          assert.match(report, /^links 6$/m);
          assert.deepEqual(
            report.split("\n").filter((line) => line.startsWith("missing ")),
            // In the manifest's order, by path
            [`missing ${ids[1]}`, `missing ${ids[2]}`, `missing ${ids[5]}`],
          );

          // Nothing changed, so nothing more is reported
          const reports = fake.sent.done?.length;
          const second = await run(shell, machine, { cwd: clone });
          assert.equal(second.status, 0);
          assert.equal(fake.sent.done?.length, reports);

          // A file that comes back is reported, even with the same manifest
          writeFileSync(join(clone, "docs", "missing.md"), "Back.\n");
          const third = await run(shell, machine, { cwd: clone });
          assert.match(
            third.stderr,
            /2 of this project's pointers point to paths that aren't in .*: docs\/outside\.md, shared\/notes\.md\./,
          );
          assert.equal(fake.sent.done?.length, (reports ?? 0) + 1);
          assert.deepEqual(
            (fake.sent.done?.at(-1) ?? "")
              .split("\n")
              .filter((line) => /^(links|missing) /.test(line)),
            ["links 6", `missing ${ids[2]}`, `missing ${ids[5]}`],
          );
          // And nothing in the repo changed
          assert.equal(
            readFileSync(join(machine.home, "secret.md"), "utf8"),
            "Not the repo's.\n",
          );
        });

        it("prints the project's map for the folder it runs in, or every entry with --all", async () => {
          const machine = computer();
          const docs = fake.add({ name: "Docs site" });
          const clone = repo(machine.home, "docs");
          linkFile(clone, docs.id);
          // The workspace comes from the last global sync
          assert.equal((await run(shell, machine, { cwd: clone })).status, 0);
          const billing = join(clone, "src", "billing");
          mkdirSync(billing, { recursive: true });
          const before = linked(machine.home);

          const here = await run(shell, machine, { cwd: billing, mode: "map" });
          assert.equal(here.status, 0, here.stderr);
          assert.equal(
            here.stdout,
            "Map of Docs site, for src/billing.\n[31mNo colours.\tTabs stay.\n",
          );
          const all = await run(shell, machine, {
            cwd: billing,
            mode: "map",
            args: [shell === "pwsh" ? "-All" : "--all"],
          });
          assert.equal(all.status, 0, all.stderr);
          assert.match(
            all.stdout,
            /^Map of Docs site, for the whole project\.$/m,
          );
          assert.deepEqual(fake.sent.map, ["src/billing", ""]);
          assert.ok(
            fake.requests.includes(
              `POST /v1/sync/map?project=${docs.id}&layer=repo`,
            ),
          );

          // Outside a project there's no map, and nothing is linked
          const elsewhere = join(machine.home, "elsewhere");
          mkdirSync(elsewhere);
          const none = await run(shell, machine, {
            cwd: elsewhere,
            mode: "map",
          });
          assert.equal(none.status, 1);
          assert.match(none.stderr, /isn't in a project this computer knows/);
          assert.equal(linked(machine.home), before);
        });

        it("syncs the projects linked on this computer in a daily run, quietly, as far as each app works in projects", async () => {
          const machine = computer(["codex", "hermes", "openclaw"]);
          const one = fake.add({ name: "One" });
          const two = fake.add({ name: "Two" });
          const inRepo = fake.add({ name: "In a repo" });
          const first = repo(machine.home, "one");
          const second = repo(machine.home, "two");
          const third = repo(machine.home, "three");
          linkFile(third, inRepo.id);
          writeFileSync(
            join(machine.home, ".contextlocker", "projects"),
            [
              `${one.id} ${first}`,
              `${two.id} ${second}`,
              `${inRepo.id} ${third}`,
              `${randomUUID()} ${join(machine.home, "gone")}`,
              "",
            ].join("\n"),
          );

          // Codex works in every linked folder
          const codex = await run(shell, machine, {
            harness: "codex",
            args: [shell === "pwsh" ? "-Daily" : "--daily"],
          });
          assert.equal(codex.status, 0, codex.stdout);
          assert.equal(codex.stdout, "");
          assert.equal(codex.stderr, "");
          assert.deepEqual(
            projectSyncs().sort(),
            [
              `GET /v1/sync?project=${inRepo.id}&layer=repo`,
              `GET /v1/sync?project=${one.id}&layer=personal`,
              `GET /v1/sync?project=${two.id}&layer=personal`,
            ].sort(),
          );

          // Hermes only in repos linked with a .contextlocker.json, OpenClaw in none
          fake.requests = [];
          const hermes = await run(shell, machine, {
            harness: "hermes",
            args: [shell === "pwsh" ? "-Daily" : "--daily"],
          });
          assert.equal(hermes.status, 0, hermes.stdout);
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${inRepo.id}&layer=repo`,
          ]);
          fake.requests = [];
          const openclaw = await run(shell, machine, {
            harness: "openclaw",
            args: [shell === "pwsh" ? "-Daily" : "--daily"],
          });
          assert.equal(openclaw.status, 0, openclaw.stdout);
          assert.deepEqual(projectSyncs(), []);

          // A project that fails makes the run fail, and then it says it all
          (fake.projects.get(two.id) as FakeProject).fail = 500;
          const failed = await run(shell, machine, {
            harness: "codex",
            args: [shell === "pwsh" ? "-Daily" : "--daily"],
          });
          assert.equal(failed.status, 1);
          assert.match(failed.stdout, /Context Locker answered 500/);
          assert.match(
            failed.stdout,
            /1 folder linked on this computer isn't there any more, so its project wasn't synced\./,
          );
          // The gone folder stays linked, in case it comes back
          assert.match(linked(machine.home), /gone$/m);
        });

        it("says a newer sync script is out, at session start and in the doctor, and changes nothing", async () => {
          const machine = computer(["claude-code", "codex"]);
          fake.script = SYNC_SCRIPT_VERSION;
          const current = await run(shell, machine, { harness: "codex" });
          assert.equal(current.status, 0, current.stderr);
          assert.equal(current.stdout, "");

          fake.script = SYNC_SCRIPT_VERSION + 1;
          const codex = await run(shell, machine, { harness: "codex" });
          assert.equal(codex.status, 0, codex.stderr);
          assert.equal(codex.stdout, `${NEWER_LINE}\n`);
          const claude = await run(shell, machine);
          assert.equal(claude.status, 0, claude.stderr);
          assert.equal(
            JSON.parse(
              claude.stdout,
            ).hookSpecificOutput.additionalContext.trimEnd(),
            NEWER_LINE,
          );
          const doctor = await run(shell, machine, {
            harness: "codex",
            mode: "doctor",
          });
          assert.match(
            doctor.stdout,
            /^WARN  A newer version of the sync script is out\. When it suits you, set Context Locker up again from context\.locker\/setup\. This one keeps working until then\.$/m,
          );
          // Nothing was saved over the script or anywhere else
          assert.equal(
            existsSync(join(machine.home, ".contextlocker", "sync.sh")),
            false,
          );
        });
      },
    );
  }
});
