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
  MANIFEST_HEADER,
  SYNC_SCRIPT_VERSION,
  blobArchive,
  buildManifest,
  compile,
  sha256,
  type Blob,
  type PreferenceInput,
  type RepoLink,
} from "../src/index.js";
import { preferences, projectPreferences } from "./fixtures.js";
import { computerName, computerPattern } from "./computer-name.js";
import { SCRIPT_PATH } from "./script-path.js";

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
  "Context Locker: a newer version of its sync script is out. When it suits the person, offer to set Context Locker up again for them: once they say yes, download the newest steps with `curl -fsSL https://context.locker/setup/SKILL.md` and follow them. The one installed keeps working until then.";

interface FakeProject {
  id: string;
  name: string;
  remote?: string;
  links?: RepoLink[];
  /** The project's own preferences, which make its block */
  preferences?: PreferenceInput[];
  /** Answers its manifest with this status instead */
  fail?: number;
}

/** A fake Context Locker that knows some projects, their remotes and pointers to paths in their repos */
class FakeLocker {
  projects = new Map<string, FakeProject>();
  /** The newest script the global manifest names */
  script = SYNC_SCRIPT_VERSION;
  /** Whether the global manifest carries the app's own blocks too */
  globalBlocks = false;
  /** Every request, as "METHOD /path?query" */
  requests: string[] = [];
  roomAware = false;
  rooms: Array<{ path: string; room: string | undefined }> = [];
  /** The room each request said the app's global file leaves (G1-309) */
  globalRooms: Array<{ path: string; room: string | undefined }> = [];
  /** What each kind of request sent, in order */
  sent: Record<string, string[]> = {
    find: [],
    record: [],
    map: [],
    done: [],
    repo: [],
  };
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

  manifest(
    url: URL,
    harness: string,
    room?: string,
  ): { status: number; text: string } {
    const id = url.searchParams.get("project");
    if (!id && this.globalBlocks) {
      const manifest = buildManifest({
        workspaceId: WORKSPACE,
        outputs: compile({
          harness: harness as "claude-code",
          project: null,
          preferences,
          skills: [],
        }).outputs,
        holds: [],
        script: this.script,
      });
      for (const [hash, blob] of manifest.blobs) this.blobs.set(hash, blob);
      return { status: 200, text: manifest.text };
    }
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
        ...(this.roomAware && room !== undefined
          ? { agentsMdBytes: Number(room) }
          : {}),
        preferences: project.preferences ?? [],
        skills: [],
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
        const room = request.headers["context-locker-agents-md-bytes"] as
          string | undefined;
        fake.rooms.push({ path: `${url.pathname}${url.search}`, room });
        fake.globalRooms.push({
          path: `${url.pathname}${url.search}`,
          room: request.headers["context-locker-global-bytes"] as
            string | undefined,
        });
        if (route === "GET /v1/sync") {
          const { status, text } = fake.manifest(url, harness, room);
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
        } else if (route === "POST /v1/sync/repo") {
          // Whether a folder is the project's repo, by its remote (CLK-420)
          fake.sent.repo?.push(`${url.searchParams.get("project")} ${body}`);
          const project = fake.projects.get(
            url.searchParams.get("project") ?? "",
          );
          if (!project) return json(404, { error: "not_found" });
          json(200, {
            repo: Boolean(
              project.remote &&
              body &&
              FakeLocker.normal(project.remote) === FakeLocker.normal(body),
            ),
            git_remote: project.remote
              ? FakeLocker.normal(project.remote)
              : null,
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

  const git = (dir: string, ...args: string[]) =>
    spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  /** Commits these paths in the folder, or all it holds, as Nova */
  const commit = (dir: string, ...paths: string[]) => {
    git(dir, "add", ...(paths.length > 0 ? ["--", ...paths] : ["-A"]));
    git(
      dir,
      "-c",
      "user.name=Nova",
      "-c",
      "user.email=nova@example.com",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "Docs",
    );
  };
  /**
   * Makes the folder's last commit origin's default branch, main, as a clone
   * that just fetched it has it (CLK-420)
   */
  const fetched = (dir: string) => {
    git(dir, "update-ref", "refs/remotes/origin/main", "HEAD");
    git(
      dir,
      "symbolic-ref",
      "refs/remotes/origin/HEAD",
      "refs/remotes/origin/main",
    );
  };
  /** A report's lines about links */
  const linkLines = (report: string | undefined) =>
    (report ?? "")
      .split("\n")
      .filter((line) => /^(repo-links|repo-remote|missing) /.test(line));

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
          PATH: SCRIPT_PATH,
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

  /** Text of exactly this many bytes, in lines of plain letters, ending with a newline */
  const filler = (bytes: number) =>
    `${"a".repeat(99)}\n`.repeat(Math.floor(bytes / 100)) +
    (bytes % 100 ? `${"b".repeat((bytes % 100) - 1)}\n` : "");
  const grouped = (n: number) => n.toLocaleString("en-GB");
  const lines = (text: string) => text.split(/\r?\n/);

  for (const shell of SHELLS) {
    describe(
      `in ${shell}`,
      { skip: !HAVE_GIT && "git isn't installed" },
      () => {
        it("says how much room Hermes's SOUL.md and OpenClaw's AGENTS.md leave for the block (G1-309)", async () => {
          const block =
            "<!-- context-locker:start v1 -->\n## Context Locker\n<!-- context-locker:end -->\n";
          for (const [harness, file] of [
            ["hermes", ".hermes/SOUL.md"],
            ["openclaw", ".openclaw/workspace/AGENTS.md"],
          ] as const) {
            const machine = computer([harness]);
            const path = join(machine.home, file);
            mkdirSync(join(path, ".."), { recursive: true });
            const said = async () => {
              fake.globalRooms = [];
              const result = await run(shell, machine, { harness });
              assert.equal(result.status, 0, result.stderr);
              const global = fake.globalRooms.filter(
                (each) => each.path === "/v1/sync",
              );
              assert.ok(global.length > 0, harness);
              return [...new Set(global.map((each) => each.room))];
            };
            // The person's 9,500 characters, and the line write_block adds
            // before a new block: 20,000 less 9,501, in thousands
            writeFileSync(path, filler(9_500));
            assert.deepEqual(await said(), ["10000"], harness);
            // Text after the block counts too
            writeFileSync(path, `${filler(9_500)}\n${block}${filler(2_000)}`);
            assert.deepEqual(await said(), ["8000"], harness);
            // A file over the trim leaves nothing, never less than nothing
            writeFileSync(path, filler(21_000));
            assert.deepEqual(
              await said(),
              // Hermes keeps the last 4,000 characters of a longer file,
              // where a new block goes
              [harness === "hermes" ? "4000" : "0"],
              harness,
            );
          }
          // Apps whose global file has no trim say nothing
          const machine = computer(["claude-code"]);
          fake.globalRooms = [];
          const result = await run(shell, machine, {});
          assert.equal(result.status, 0, result.stderr);
          assert.ok(
            fake.globalRooms.every((each) => each.room === undefined),
            JSON.stringify(fake.globalRooms),
          );
        });

        it("fits the same shared block for Codex and Hermes without false edits (G1-218)", async () => {
          const machine = computer(["codex", "hermes"]);
          fake.roomAware = true;
          const project = fake.add({
            name: "Shared room",
            preferences: Array.from({ length: 30 }, (_, i) => ({
              id: randomUUID(),
              version: 1,
              name: `rule-${i}`,
              text: "Keep the documented approach. ".repeat(15),
            })),
          });
          const dir = repo(machine.home, "shared");
          linkFile(dir, project.id);
          const file = join(dir, "AGENTS.md");
          const original = filler(26000);
          writeFileSync(file, original);
          let first = "";
          for (const harness of ["codex", "hermes", "codex", "hermes"]) {
            const result = await run(shell, machine, { cwd: dir, harness });
            assert.equal(result.status, 0, result.stderr);
            const text = readFileSync(file, "utf8");
            assert.ok(text.startsWith(original + "\n"));
            const block = text.slice(original.length + 1);
            assert.ok(Buffer.byteLength(block) <= 4000);
            // Every preference keeps its name, shortened where there's no room (G1-336)
            assert.match(block, /shortened here, /);
            if (first) assert.equal(text, first);
            first = text;
          }
          const projectRequests = fake.rooms.filter(
            (r) =>
              r.path.includes(`project=${project.id}`) &&
              /^\/v1\/sync(?:\?|\/blobs|\/edits)/.test(r.path),
          );
          assert.ok(
            projectRequests.some((r) => r.path.startsWith("/v1/sync/blobs")),
          );
          assert.ok(
            projectRequests.every((r) => r.room === "4000"),
            JSON.stringify(projectRequests),
          );
          assert.ok(
            !fake.requests.some((r) => r.startsWith("POST /v1/sync/edits")),
          );
          assert.ok(
            fake.rooms
              .filter((r) => r.path === "/v1/sync")
              .every((r) => r.room === undefined),
          );

          // A longer preamble exhausts Codex's room. No cut-off block is
          // written and the session text says the guidance was not loaded.
          writeFileSync(file, filler(34000) + first.slice(original.length));
          const none = await run(shell, machine, {
            cwd: dir,
            harness: "codex",
          });
          assert.equal(none.status, 0, none.stderr);
          assert.ok(
            !readFileSync(file, "utf8").includes("context-locker:start"),
          );
          assert.ok(readFileSync(file, "utf8").startsWith(filler(34000)));
          assert.match(none.stdout, /block is not loaded/);
          const offlineCopy = readFileSync(
            join(
              machine.home,
              ".contextlocker/codex/projects",
              `${project.id}.context`,
            ),
            "utf8",
          );
          assert.match(offlineCopy, /`context <app>`/);
        });

        it("uses ancestor bytes, UTF-8, custom limits and round-down steps for both apps", async () => {
          const machine = computer(["codex", "hermes"]);
          fake.roomAware = true;
          const project = fake.add({
            name: "Nested",
            preferences: projectPreferences,
          });
          const top = repo(machine.home, "nested");
          const dir = join(top, "part");
          mkdirSync(dir);
          linkFile(dir, project.id);
          writeFileSync(join(top, "AGENTS.override.md"), filler(5000));
          writeFileSync(join(top, "AGENTS.md"), filler(20000)); // overridden
          mkdirSync(join(machine.home, ".codex"));
          mkdirSync(join(machine.home, ".hermes"));
          writeFileSync(
            join(machine.home, ".codex/config.toml"),
            "project_doc_max_bytes = 12_000\n",
          );
          writeFileSync(
            join(machine.home, ".hermes/config.yaml"),
            "context_file_max_chars: 6000\n",
          );
          const original = "文".repeat(1500) + "\n"; // 4,501 bytes, 1,501 characters
          writeFileSync(join(dir, "AGENTS.md"), original);
          for (const harness of ["codex", "hermes"]) {
            const result = await run(shell, machine, { cwd: dir, harness });
            assert.equal(result.status, 0, result.stderr);
            const text = readFileSync(join(dir, "AGENTS.md"), "utf8");
            assert.ok(text.startsWith(original));
            assert.ok(Buffer.byteLength(text) + 5002 <= 12000);
          }
          const requests = fake.rooms.filter(
            (r) =>
              r.path.includes(`project=${project.id}`) &&
              r.path.startsWith("/v1/sync?"),
          );
          assert.ok(
            requests.every((r) => r.room === "2000"),
            JSON.stringify(requests),
          );
        });

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
          const outside = await run(shell, machine, { cwd: plain });
          assert.equal(outside.status, 0, outside.stderr);
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

          // --project wins over the file, and, on the person's word for a
          // project with no repository, records the remote on it (CLK-423)
          fake.requests = [];
          const flagged = await run(shell, machine, {
            cwd: sub,
            args: [
              shell === "pwsh" ? "-Project" : "--project",
              byFlag.id,
              shell === "pwsh" ? "-LinkFolder" : "--link-folder",
            ],
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

          // Then the link, to a checkout of the project's repository
          rmSync(join(clone, ".contextlocker.json"));
          byLink.remote = "github.com/acme/docs";
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
          delete byLink.remote;
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

        it("checks the project's links in the default branch the checkout last fetched, says which are missing in one line, and reports them with its remote (CLK-420)", async () => {
          const machine = computer();
          const ids = Array.from({ length: 7 }, () => randomUUID());
          const at = (index: number) => ids[index] as string;
          const docs = fake.add({
            name: "Docs site",
            links: [
              { id: at(0), path: "docs/runbook.md" },
              { id: at(1), path: "docs/missing.md" },
              { id: at(2), path: "docs/feature.md" },
              { id: at(3), path: "docs/gone-here.md" },
              { id: at(4), path: "design/first draft.md" },
              { id: at(5), path: "docs/inside.md" },
              { id: at(6), path: "shared/notes.md" },
            ],
          });
          const clone = repo(
            machine.home,
            "docs",
            "git@github.com:acme/docs.git",
          );
          linkFile(clone, docs.id);
          mkdirSync(join(clone, "docs"));
          mkdirSync(join(clone, "design"));
          writeFileSync(join(clone, "docs", "runbook.md"), "Run it.\n");
          writeFileSync(join(clone, "docs", "gone-here.md"), "Here.\n");
          writeFileSync(join(clone, "design", "first draft.md"), "Draft.\n");
          // A link in the repo to a file in it counts, as GitHub lists it; a
          // path through a folder that's a link doesn't
          symlinkSync("runbook.md", join(clone, "docs", "inside.md"));
          mkdirSync(join(machine.home, "elsewhere"));
          writeFileSync(
            join(machine.home, "elsewhere", "notes.md"),
            "Elsewhere.\n",
          );
          symlinkSync(join(machine.home, "elsewhere"), join(clone, "shared"));
          commit(clone);
          fetched(clone);
          // A feature branch's file doesn't count, and one gone from the
          // disk but on the default branch is still there
          git(clone, "checkout", "-q", "-b", "feature");
          writeFileSync(join(clone, "docs", "feature.md"), "Feature.\n");
          commit(clone, "docs/feature.md");
          rmSync(join(clone, "docs", "gone-here.md"));

          const first = await run(shell, machine, { cwd: clone });
          assert.equal(first.status, 0, first.stderr);
          assert.equal(
            first.stderr,
            `Context Locker: 3 of this project's links lead to paths that aren't on origin/main, the default branch ${clone} last fetched: docs/feature.md, docs/missing.md, shared/notes.md. If they moved, change their addresses in Context Locker.\n`,
          );
          // In the manifest's order, by path, with the folder's remote for
          // Context Locker to check, without its user name
          assert.deepEqual(linkLines(fake.sent.done?.at(-1)), [
            "repo-links 7",
            "repo-remote github.com:acme/docs.git",
            `missing ${at(2)}`,
            `missing ${at(1)}`,
            `missing ${at(6)}`,
          ]);

          // Nothing changed, so nothing more is reported
          const reports = fake.sent.done?.length ?? 0;
          const second = await run(shell, machine, { cwd: clone });
          assert.equal(second.status, 0);
          assert.equal(fake.sent.done?.length, reports);

          // Files the default branch gets are reported, even with the same
          // manifest
          writeFileSync(join(clone, "docs", "missing.md"), "Back.\n");
          commit(clone, "docs/missing.md");
          fetched(clone);
          const third = await run(shell, machine, { cwd: clone });
          assert.match(
            third.stderr,
            /1 of this project's links leads to a path that isn't on origin\/main, the default branch .* last fetched: shared\/notes\.md\. If it moved, change the link's address in Context Locker\./,
          );
          assert.equal(fake.sent.done?.length, reports + 1);
          assert.deepEqual(linkLines(fake.sent.done?.at(-1)), [
            "repo-links 7",
            "repo-remote github.com:acme/docs.git",
            `missing ${at(6)}`,
          ]);

          // With no default branch to look in, it checks none, and reports
          // that it found nothing, so what it found before goes; the folder's
          // remote still goes with it (CLK-423)
          git(clone, "symbolic-ref", "-d", "refs/remotes/origin/HEAD");
          const fourth = await run(shell, machine, { cwd: clone });
          assert.equal(fourth.status, 0, fourth.stderr);
          assert.equal(fourth.stderr, "");
          assert.equal(fake.sent.done?.length, reports + 2);
          assert.deepEqual(linkLines(fake.sent.done?.at(-1)), [
            "repo-remote github.com:acme/docs.git",
          ]);
          // And nothing outside the repo changed
          assert.equal(
            readFileSync(join(machine.home, "elsewhere", "notes.md"), "utf8"),
            "Elsewhere.\n",
          );
        });

        it("links a folder to a project only when it's a checkout of the project's repository, and a sync anywhere else checks none of its links and clears what it found (CLK-420)", async () => {
          const machine = computer();
          const id = randomUUID();
          const docs = fake.add({
            name: "Docs site",
            remote: "github.com/acme/docs",
            links: [{ id, path: "docs/missing.md" }],
          });
          const flag = shell === "pwsh" ? "-Project" : "--project";

          // A clone of the project's repository checks them and reports them
          const clone = repo(
            machine.home,
            "docs",
            "git@github.com:acme/docs.git",
          );
          writeFileSync(join(clone, "README.md"), "Docs.\n");
          commit(clone);
          fetched(clone);
          const right = await run(shell, machine, {
            cwd: clone,
            args: [flag, docs.id],
          });
          assert.equal(right.status, 0, right.stderr);
          assert.match(
            right.stderr,
            /1 of this project's links leads to a path that isn't on origin\/main, the default branch .* last fetched: docs\/missing\.md\./,
          );
          assert.equal(linked(machine.home), `${docs.id} ${clone}\n`);
          assert.deepEqual(linkLines(fake.sent.done?.at(-1)), [
            "repo-links 1",
            "repo-remote github.com:acme/docs.git",
            `missing ${id}`,
          ]);
          // The remote goes without its user name, as every remote does
          assert.ok(
            fake.sent.repo?.includes(`${docs.id} github.com:acme/docs.git`),
            JSON.stringify(fake.sent.repo),
          );

          // A folder of another repo isn't linked, gets none of the
          // project's files, and hears how to read the project for one call
          const other = repo(
            machine.home,
            "other",
            "https://github.com/acme/other.git",
          );
          fake.requests = [];
          const wrong = await run(shell, machine, {
            cwd: other,
            args: [flag, docs.id],
          });
          assert.equal(wrong.status, 0, wrong.stderr);
          assert.match(
            wrong.stderr,
            new RegExp(
              `^Context Locker: didn't link ${other.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} to the project: it isn't a checkout of github\\.com/acme/docs, the project's repository\\. Run ${flag} in a checkout of it, or read the project for one call instead with \`.+ context claude-code ${flag} ${docs.id}\`\\.$`,
              "m",
            ),
          );
          assert.equal(linked(machine.home), `${docs.id} ${clone}\n`);
          assert.deepEqual(projectSyncs(), []);
          assert.equal(existsSync(join(other, ".context-locker")), false);
          assert.equal(existsSync(join(other, "CLAUDE.md")), false);

          // Nor is a folder with no repo at all
          const plain = join(machine.home, "plain");
          mkdirSync(plain);
          const bare = await run(shell, machine, {
            cwd: plain,
            args: [flag, docs.id],
          });
          assert.match(
            bare.stderr,
            /didn't link .* to the project: it isn't a checkout of github\.com\/acme\/docs/,
          );
          // And when Context Locker can't say, nothing is linked either
          const unknown = await run(shell, machine, {
            cwd: plain,
            args: [flag, randomUUID()],
          });
          assert.match(
            unknown.stderr,
            /didn't link .* to the project, as Context Locker couldn't say whether it's a checkout of the project's repository\./,
          );
          assert.equal(linked(machine.home), `${docs.id} ${clone}\n`);

          // A folder an older script linked is unlinked at the next sync,
          // gets none of the project's files and sends nothing, so what this
          // agent found in the clone stands (CLK-423)
          writeFileSync(
            join(machine.home, ".contextlocker", "projects"),
            `${docs.id} ${clone}\n${docs.id} ${other}\n`,
          );
          const reports = fake.sent.done?.length ?? 0;
          fake.requests = [];
          const before = await run(shell, machine, { cwd: other });
          assert.equal(before.status, 0, before.stderr);
          assert.match(
            before.stderr,
            new RegExp(
              `^Context Locker: unlinked ${other.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} from its project, as it isn't a checkout of github\\.com/acme/docs, the project's repository, so it gets none of the project's files\\. Read the project with \`.+ context claude-code ${flag} ${docs.id}\`\\.$`,
              "m",
            ),
          );
          assert.equal(linked(machine.home), `${docs.id} ${clone}\n`);
          assert.deepEqual(projectSyncs(), []);
          assert.equal(fake.sent.done?.length, reports);
          assert.equal(existsSync(join(other, "CLAUDE.md")), false);
        });

        it("links a folder to a project with no repository only on the person's word, which records the folder's remote, and sends the folder's remote with every project report (CLK-423)", async () => {
          const machine = computer();
          const site = fake.add({ name: "Site" });
          const flag = shell === "pwsh" ? "-Project" : "--project";
          const linkFlag = shell === "pwsh" ? "-LinkFolder" : "--link-folder";
          const clone = repo(
            machine.home,
            "site",
            "https://github.com/acme/site.git",
          );

          // Named alone, the project is read for one call: nothing is linked
          // and nothing written
          const named = await run(shell, machine, {
            cwd: clone,
            args: [flag, site.id],
          });
          assert.equal(named.status, 0, named.stderr);
          assert.match(
            named.stderr,
            new RegExp(
              `^Context Locker: didn't link ${clone.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} to the project, which has no repository, so no folder gets its files\\. Read it with \`.+ context claude-code ${flag} ${site.id}\`\\. To link this folder, which records its git remote as the project's repository, run ${flag} with ${linkFlag}, only on the person's word\\.$`,
              "m",
            ),
          );
          assert.equal(linked(machine.home), "");
          assert.deepEqual(projectSyncs(), []);
          assert.equal(existsSync(join(clone, "CLAUDE.md")), false);

          // A repo with no remote can't be linked, as it has none to record
          const local = repo(machine.home, "local");
          const bare = await run(shell, machine, {
            cwd: local,
            args: [flag, site.id, linkFlag],
          });
          assert.match(
            bare.stderr,
            /didn't link .* to the project: it's a repo with no git remote, which would become the project's repository\. Read the project with `.+ context claude-code/,
          );
          assert.equal(linked(machine.home), "");

          // On the person's word, the checkout is linked, synced and its
          // remote recorded on the project
          const linkedNow = await run(shell, machine, {
            cwd: clone,
            args: [flag, site.id, linkFlag],
          });
          assert.equal(linkedNow.status, 0, linkedNow.stderr);
          assert.equal(linked(machine.home), `${site.id} ${clone}\n`);
          assert.ok(
            fake.sent.record?.includes(
              `${site.id} https://github.com/acme/site.git`,
            ),
            JSON.stringify(fake.sent.record),
          );
          // With no links to check, the report still carries the remote
          assert.deepEqual(linkLines(fake.sent.done?.at(-1)), [
            "repo-remote https://github.com/acme/site.git",
          ]);
        });

        it("links a folder outside any repo to a project for this computer only, on the person's word, writing nothing into it while a session there gets the project at its start (CLK-423)", async () => {
          const machine = computer();
          const project = fake.add({
            name: "Scratch",
            remote: "github.com/acme/scratch",
            preferences: projectPreferences,
            links: [{ id: randomUUID(), path: "docs/plan.md" }],
          });
          const flag = shell === "pwsh" ? "-Project" : "--project";
          const linkFlag = shell === "pwsh" ? "-LinkFolder" : "--link-folder";
          const esc = (text: string) =>
            text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const plain = join(machine.home, "scratch");
          mkdirSync(plain);

          // Named alone, nothing is linked, and the line offers the plain link
          const named = await run(shell, machine, {
            cwd: plain,
            args: [flag, project.id],
          });
          assert.equal(named.status, 0, named.stderr);
          assert.match(
            named.stderr,
            new RegExp(
              `didn't link ${esc(plain)} to the project: it isn't a checkout of github\\.com/acme/scratch, the project's repository\\. Read the project for one call instead with \`.+ context claude-code ${flag} ${project.id}\`, or link this folder for this computer only, writing nothing into it, with ${flag} and ${linkFlag}, only on the person's word\\.$`,
              "m",
            ),
          );
          assert.equal(linked(machine.home), "");

          // On the person's word it's a plain link, kept apart from a
          // checkout's, and the project comes at the session's start
          fake.requests = [];
          const linkedNow = await run(shell, machine, {
            cwd: plain,
            args: [flag, project.id, linkFlag],
          });
          assert.equal(linkedNow.status, 0, linkedNow.stderr);
          assert.match(
            linkedNow.stderr,
            /linked .* to the project for this computer only: the sync writes nothing into it and checks none of its links, and a session started there gets the project at its start\./,
          );
          assert.equal(linked(machine.home), `plain ${project.id} ${plain}\n`);
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${project.id}&layer=personal`,
          ]);
          assert.deepEqual(readdirSync(plain), []);
          assert.match(
            linkedNow.stdout,
            /Context Locker preferences for Scratch/,
          );

          // A session started there, or in a folder in it, gets the project
          // at its start, checks no links, and the link stays
          const sub = join(plain, "drafts");
          mkdirSync(sub);
          fake.requests = [];
          const later = await run(shell, machine, { cwd: sub });
          assert.equal(later.status, 0, later.stderr);
          assert.equal(later.stderr, "");
          assert.match(later.stdout, /Context Locker preferences for Scratch/);
          assert.deepEqual(projectSyncs(), [
            `GET /v1/sync?project=${project.id}&layer=personal`,
          ]);
          assert.ok(
            !fake.requests.some((request) =>
              request.startsWith("POST /v1/sync/repo"),
            ),
            JSON.stringify(fake.requests),
          );
          assert.deepEqual(readdirSync(plain), ["drafts"]);
          assert.deepEqual(readdirSync(sub), []);
          assert.equal(linked(machine.home), `plain ${project.id} ${plain}\n`);

          // A checkout of another repo is never linked that way
          const other = repo(
            machine.home,
            "other",
            "https://github.com/acme/other.git",
          );
          const refused = await run(shell, machine, {
            cwd: other,
            args: [flag, project.id, linkFlag],
          });
          assert.match(
            refused.stderr,
            /didn't link .* to the project: it isn't a checkout of github\.com\/acme\/scratch, the project's repository\. Run .* in a checkout of it/,
          );
          assert.equal(linked(machine.home), `plain ${project.id} ${plain}\n`);
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
          assert.ok(
            none.stderr.includes(
              `isn't in a project known on ${computerName(shell)}.`,
            ),
            none.stderr,
          );
          assert.equal(linked(machine.home), before);
        });

        it("syncs the projects linked on this computer in a daily run, quietly, as far as each app works in projects", async () => {
          const machine = computer(["codex", "hermes", "openclaw"]);
          // Each linked folder is a checkout of its project's repository
          const one = fake.add({ name: "One", remote: "github.com/acme/one" });
          const two = fake.add({ name: "Two", remote: "github.com/acme/two" });
          const inRepo = fake.add({ name: "In a repo" });
          const first = repo(
            machine.home,
            "one",
            "https://github.com/acme/one.git",
          );
          const second = repo(
            machine.home,
            "two",
            "https://github.com/acme/two.git",
          );
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
            new RegExp(
              `1 folder linked on ${computerPattern(shell)} isn't there any more, so its project wasn't synced\\.`,
            ),
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
            /^WARN  A newer version of the sync script is out\. When it suits the person, offer to set Context Locker up again for them: once they say yes, download the newest steps with `curl -fsSL https:\/\/context\.locker\/setup\/SKILL\.md` and follow them\. This one keeps working until then\.$/m,
          );
          // Nothing was saved over the script or anywhere else
          assert.equal(
            existsSync(join(machine.home, ".contextlocker", "sync.sh")),
            false,
          );
        });

        it("says when Codex doesn't read all of its block in a repo's AGENTS.md, at session start and in the doctor (G1-212)", async () => {
          const machine = computer(["codex"]);
          const project = fake.add({
            name: "Docs site",
            preferences: projectPreferences,
          });
          const dir = repo(machine.home, "docs");
          linkFile(dir, project.id);
          const path = join(dir, "AGENTS.md");
          const codex = (mode?: string) =>
            run(shell, machine, { cwd: dir, harness: "codex", mode });
          const told = `Context Locker: Codex doesn't read all of Context Locker's block in ${path}. Read the block there in full before you start.`;

          const first = await codex();
          assert.equal(first.status, 0, first.stderr);
          assert.equal(first.stderr, "");
          const block = readFileSync(path, "utf8");
          const size = Buffer.byteLength(block);

          // At Codex's 32 KiB it reads the whole file, and nothing's said
          writeFileSync(path, `${filler(32_768 - 1 - size)}\n${block}`);
          const at = await codex();
          assert.equal(at.status, 0, at.stderr);
          assert.equal(lines(at.stdout).includes(told), false, at.stdout);
          assert.doesNotMatch((await codex("doctor")).stdout, /Codex reads/);

          // One byte over, the session and the doctor say so
          writeFileSync(path, `${filler(32_768 - size)}\n${block}`);
          const over = await codex();
          assert.equal(over.status, 0, over.stderr);
          assert.ok(lines(over.stdout).includes(told), over.stdout);
          const doctor = await codex("doctor");
          assert.ok(
            lines(doctor.stdout).includes(
              `WARN  Codex reads the first 32,768 bytes of a repo's AGENTS.md files, so it misses the last 1 byte of Context Locker's block in ${path}. Shortening the text outside the block lets Codex read all of it.`,
            ),
            doctor.stdout,
          );

          // A block the sync adds after a long file is said as it's written
          writeFileSync(path, filler(40_000));
          const added = await codex();
          assert.equal(added.status, 0, added.stderr);
          assert.ok(
            lines(added.stderr).includes(
              `Context Locker: Codex reads the first 32,768 bytes of a repo's AGENTS.md files, so it stops before Context Locker's block in ${path}. Shortening the text outside the block lets Codex read all of it.`,
            ),
            added.stderr,
          );
          assert.ok(readFileSync(path, "utf8").endsWith(block));

          // AGENTS.override.md comes first, so Codex never sees the block
          writeFileSync(path, block);
          writeFileSync(join(dir, "AGENTS.override.md"), "# Mine\n");
          const shadowed = await codex();
          assert.ok(lines(shadowed.stdout).includes(told), shadowed.stdout);
          assert.ok(
            lines((await codex("doctor")).stdout).includes(
              `WARN  Codex reads ${join(dir, "AGENTS.override.md")} instead of ${path}, so it never sees Context Locker's block there.`,
            ),
          );
        });

        it("counts the AGENTS.md files Codex reads in the folders above the project's (G1-212)", async () => {
          const machine = computer(["codex"]);
          const project = fake.add({
            name: "App",
            preferences: projectPreferences,
          });
          const top = repo(machine.home, "mono");
          const app = join(top, "app");
          mkdirSync(app);
          linkFile(app, project.id);
          writeFileSync(join(top, "AGENTS.md"), filler(32_700));

          const synced = await run(shell, machine, {
            cwd: app,
            harness: "codex",
          });
          assert.equal(synced.status, 0, synced.stderr);
          const path = join(app, "AGENTS.md");
          const size = Buffer.byteLength(readFileSync(path, "utf8"));
          assert.ok(
            lines(synced.stderr).includes(
              `Context Locker: Codex reads 32,768 bytes of a repo's AGENTS.md files, and the ones in the folders above ${app} use 32,700 of them, so it misses the last ${grouped(size - 68)} bytes of Context Locker's block in ${path}. Shortening the text outside the block lets Codex read all of it.`,
            ),
            synced.stderr,
          );
        });

        it("says when Hermes reads another file, or cuts the middle of its block (G1-212)", async () => {
          const machine = computer(["hermes"]);
          const project = fake.add({
            name: "Docs site",
            preferences: projectPreferences,
          });
          const dir = repo(machine.home, "docs");
          linkFile(dir, project.id);
          const path = join(dir, "AGENTS.md");
          const hermes = (mode?: string) =>
            run(shell, machine, { cwd: dir, harness: "hermes", mode });

          assert.equal((await hermes()).status, 0);
          const block = readFileSync(path, "utf8");
          // The block in the middle of a long file, where Hermes cuts
          writeFileSync(path, `${filler(15_000)}\n${block}\n${filler(10_000)}`);
          const doctor = await hermes("doctor");
          assert.ok(
            lines(doctor.stdout).includes(
              `WARN  Unless its model has a large context window, Hermes keeps the first 14,000 and last 4,000 characters of a file over 20,000, so it misses ${grouped([...block].length)} characters of Context Locker's block in ${path}. Shortening the text outside the block lets Hermes read all of it.`,
            ),
            doctor.stdout,
          );

          // A .hermes.md anywhere up to the repo's top comes first
          writeFileSync(join(dir, ".hermes.md"), "# Mine\n");
          assert.ok(
            lines((await hermes("doctor")).stdout).includes(
              `WARN  Hermes reads ${join(dir, ".hermes.md")} instead of ${path}, so it never sees Context Locker's block there.`,
            ),
          );
        });

        it("says when OpenClaw's AGENTS.md is longer than it reads (G1-212, G1-299)", async () => {
          const machine = computer(["openclaw"]);
          fake.globalBlocks = true;
          const workspace = join(machine.home, ".openclaw", "workspace");
          mkdirSync(workspace, { recursive: true });
          // Its whole block is in AGENTS.md now, which OpenClaw reads up to 20,000 characters of
          const agents = join(workspace, "AGENTS.md");
          writeFileSync(agents, filler(21_000));

          const synced = await run(shell, machine, { harness: "openclaw" });
          assert.equal(synced.status, 0, synced.stderr);
          const said = `OpenClaw reads up to 20,000 characters of ${agents}, which has ${grouped([...readFileSync(agents, "utf8")].length)}, so it can miss part of Context Locker's block. Shortening the text outside the block lets OpenClaw read all of it.`;
          assert.ok(
            lines(synced.stderr).includes(`Context Locker: ${said}`),
            synced.stderr,
          );
          assert.ok(
            lines(
              (
                await run(shell, machine, {
                  harness: "openclaw",
                  mode: "doctor",
                })
              ).stdout,
            ).includes(`WARN  ${said}`),
          );
        });
      },
    );
  }
});
