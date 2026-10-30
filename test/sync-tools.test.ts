// The sync scripts' tools: the doctor's checks of the playbook's limits, the
// files Context Locker doesn't manage and what has drifted since the last
// sync; export; moving a project's notes out into its repo; and Tidy-up,
// with fix. These run
// the real scripts against a fake API, which can answer in ways the real one
// rarely does: a note that changes between the two steps of a move, an
// answer that never comes, or an archive that tries to write somewhere else.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
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
import { gzipSync } from "node:zlib";
import { after, before, describe, it } from "node:test";

import {
  SYNC_SCRIPT_VERSION,
  TAR_END,
  blobArchive,
  blockHash,
  buildManifest,
  compile,
  extractBlock,
  sha256,
  tarHeader,
  tarPadding,
  type Blob,
} from "../src/index.js";

const SCRIPTS = fileURLToPath(new URL("../scripts/", import.meta.url));
const WORKSPACE = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";
const PROJECT = "2b7c9d1e-3f4a-4b5c-8d6e-7f8091a2b3c4";
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);
const HAVE_GIT = spawnSync("sh", ["-c", "command -v git"]).status === 0;
const MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(" ");

/** A date as the scripts write one, such as 21 Oct 2026 */
const dayOf = (date: Date) =>
  `${date.getUTCDate()} ${MONTHS[date.getUTCMonth()]} ${date.getUTCFullYear()}`;

/** One entry of a tar archive, which may be anything a hostile one holds */
interface Entry {
  path: string;
  data?: Buffer | string;
  directory?: boolean;
  /** A symbolic link to this target, instead of a file */
  link?: string;
}

function tarOf(entries: Entry[]): Buffer {
  const chunks: Buffer[] = [];
  for (const entry of entries) {
    const data = Buffer.from(entry.data ?? "");
    const header = tarHeader(
      {
        path: entry.path,
        size: entry.directory || entry.link ? 0 : data.length,
        directory: entry.directory === true,
      },
      0,
    );
    if (entry.link) {
      // The same header, as a symbolic link
      const last = header.subarray(header.length - 512);
      last.write("2", 156, 1, "ascii");
      last.write(entry.link, 157, 100, "utf8");
      last.write("        ", 148, 8, "ascii");
      let sum = 0;
      for (const byte of last) sum += byte;
      last.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148, 8, "ascii");
    }
    chunks.push(header);
    if (!entry.directory && !entry.link) {
      chunks.push(data, tarPadding(data.length));
    }
  }
  chunks.push(TAR_END);
  return Buffer.concat(chunks);
}

/** An export as Context Locker sends one, or with whatever else is asked for */
function exportArchive(top: string, extra: Entry[] = []): Buffer {
  const counts = {
    preferences: 4,
    about: 2,
    skills: 1,
    notes: 3,
    pointers: 2,
    projects: 1,
    events: 21,
    versions: 12,
  };
  return gzipSync(
    tarOf([
      { path: top, directory: true },
      { path: `${top}/everywhere`, directory: true },
      { path: `${top}/everywhere/preferences.md`, data: "# Preferences\n" },
      { path: `${top}/history`, directory: true },
      { path: `${top}/history/events.jsonl`, data: '{"action":"x"}\n' },
      {
        path: `${top}/export.json`,
        data: `${JSON.stringify({ format: "context-locker-export 1", counts }, null, 2)}\n`,
      },
      { path: `${top}/README.md`, data: "# Context Locker export\n" },
      ...extra,
    ]),
  );
}

interface MoveNote {
  id: string;
  version: number;
  file: string;
  text: string;
}

/** A fake Context Locker for the doctor, export and notes-move-out */
class FakeLocker {
  requests: string[] = [];
  blobs = new Map<string, Blob>();
  manifest: string;
  caps = {
    status: 200,
    text: "context-locker-caps 1\nPASS  Preferences: 1 of 50 everywhere.\nPASS  Skills: 1 of 20.\n",
  };
  exported: { status: number; body: Buffer } = {
    status: 200,
    body: exportArchive(`Context Locker export ${dayOf(new Date())}`),
  };
  /** The project's notes, as GET /v1/sync/move-out sends them */
  notes: MoveNote[] = [];
  /** The archive GET /v1/sync/move-out sends, instead of one of the notes */
  moveArchive: Buffer | null = null;
  /** What POST /v1/sync/move-out was sent, and which files were in the folder then */
  posted: Array<{ body: string; files: string[] }> = [];
  /** The folder whose files each POST lists */
  watch = "";
  /** How GET /v1/sync/fixes answers */
  fixes = { status: 200, text: "Nothing needs fixing right now.\n" };
  /** How POST /v1/sync/fixes/<id> answers, and what it was sent */
  marked = {
    status: 200,
    text: "Done. The check no longer finds the problem, so it's gone from Tidy-up.\n",
  };
  marks: Array<{ id: string; body: string; type: string }> = [];
  /** How POST /v1/sync/move-out answers: a status and text, or "drop" */
  answer: (body: string) => { status: number; text: string } | "drop" = (
    body,
  ) => ({
    status: 200,
    text: [
      "context-locker-move-out 2",
      ...body
        .split("\n")
        .filter((line) => line.startsWith("note "))
        .map((line) => {
          const [, id, , file] = line.split(" ");
          return `moved ${id} ${file}`;
        }),
      `docs-home none ${/^folder (.*)$/m.exec(body)?.[1] ?? ""}`,
      "",
    ].join("\n"),
  });

  constructor() {
    const compiled = compile({
      harness: "codex",
      project: null,
      preferences: [
        {
          id: randomUUID(),
          version: 1,
          name: "plain-words",
          text: "Use plain words.",
        },
      ],
      skills: [
        {
          id: randomUUID(),
          version: 1,
          name: "code-review",
          files: [
            {
              path: "SKILL.md",
              content:
                "---\nname: code-review\ndescription: Reviews code.\n---\n\nRead the tests first.\n",
              encoding: "utf8",
            },
          ],
        },
      ],
    });
    const manifest = buildManifest({
      workspaceId: WORKSPACE,
      outputs: compiled.outputs,
      holds: [],
      script: SYNC_SCRIPT_VERSION,
    });
    for (const [hash, blob] of manifest.blobs) this.blobs.set(hash, blob);
    this.manifest = manifest.text;
  }

  moveOutTar(): Buffer {
    if (this.moveArchive) return this.moveArchive;
    const index = ["context-locker-move-out 2", `project ${PROJECT} Docs site`];
    const entries: Entry[] = [];
    for (const note of this.notes) {
      const hash = sha256(note.text);
      entries.push({ path: hash, data: note.text });
      index.push(`note ${note.id} ${note.version} ${hash} ${note.file}`);
    }
    entries.push({ path: "index", data: `${index.join("\n")}\n` });
    return tarOf(entries);
  }
}

describe("the sync scripts' tools", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new FakeLocker();
  const work = mkdtempSync(join(tmpdir(), "ctx-tools-"));

  before(async () => {
    server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        fake.requests.push(`${request.method} ${url.pathname}${url.search}`);
        const body = Buffer.concat(chunks).toString("utf8");
        const send = (status: number, type: string, data: Buffer | string) => {
          response.writeHead(status, { "content-type": type });
          response.end(data);
        };
        const json = (status: number, value: unknown) =>
          send(status, "application/json", JSON.stringify(value));
        const route = `${request.method} ${url.pathname}`;
        if (route === "GET /v1/sync") {
          const etag = `"${sha256(fake.manifest)}"`;
          if (request.headers["if-none-match"] === etag) {
            response.writeHead(304, { etag });
            response.end();
            return;
          }
          response.writeHead(200, { "content-type": "text/plain", etag });
          response.end(fake.manifest);
        } else if (route === "POST /v1/sync/blobs") {
          const blobs: Array<[string, Blob]> = [];
          for (const hash of body.split("\n").filter(Boolean)) {
            const blob = fake.blobs.get(hash);
            if (!blob) return json(409, { error: "changed" });
            blobs.push([hash, blob]);
          }
          send(200, "application/x-tar", blobArchive(blobs, 0));
        } else if (route === "POST /v1/sync/done") {
          json(200, { status: "recorded" });
        } else if (route === "GET /v1/agent") {
          json(200, {
            agent: { name: "codex", machine_name: "Test" },
            workspace: { name: "Personal" },
          });
        } else if (route === "GET /v1/sync/caps") {
          send(fake.caps.status, "text/plain", fake.caps.text);
        } else if (route === "GET /v1/export") {
          send(
            fake.exported.status,
            fake.exported.status === 200
              ? "application/gzip"
              : "application/json",
            fake.exported.body,
          );
        } else if (route === "GET /v1/sync/fixes") {
          send(
            fake.fixes.status,
            fake.fixes.status === 200 ? "text/plain" : "application/json",
            fake.fixes.text,
          );
        } else if (
          request.method === "POST" &&
          url.pathname.startsWith("/v1/sync/fixes/")
        ) {
          fake.marks.push({
            id: url.pathname.slice("/v1/sync/fixes/".length),
            body,
            type: String(request.headers["content-type"] ?? ""),
          });
          send(
            fake.marked.status,
            fake.marked.status === 200 ? "text/plain" : "application/json",
            fake.marked.text,
          );
        } else if (route === "GET /v1/sync/move-out") {
          send(200, "application/x-tar", fake.moveOutTar());
        } else if (route === "POST /v1/sync/move-out") {
          fake.posted.push({
            body,
            files:
              fake.watch && existsSync(fake.watch)
                ? readdirSync(fake.watch).sort()
                : [],
          });
          const answer = fake.answer(body);
          if (answer === "drop") {
            request.socket.destroy();
            return;
          }
          send(
            answer.status,
            answer.status === 200 ? "text/plain" : "application/json",
            answer.text,
          );
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

  /** A computer with Codex connected, and the script saved where setup puts it */
  function computer(shell: string) {
    fake = new FakeLocker();
    const home = mkdtempSync(join(work, "home-"));
    mkdirSync(join(home, ".contextlocker", "codex"), { recursive: true });
    writeFileSync(join(home, ".contextlocker", "config"), `api=${baseUrl}\n`);
    writeFileSync(
      join(home, ".contextlocker", "codex", "token"),
      "ctxl_at_test\n",
      {
        mode: 0o600,
      },
    );
    const script = shell === "pwsh" ? "sync.ps1" : "sync.sh";
    copyFileSync(join(SCRIPTS, script), join(home, ".contextlocker", script));
    return { home };
  }

  const run = (
    shell: string,
    machine: { home: string },
    options: {
      mode?: string;
      args?: string[];
      cwd?: string;
      /** For PowerShell: words to call the script with, as -Command takes them */
      command?: string;
    } = {},
  ): Promise<{ status: number | null; stdout: string; stderr: string }> => {
    const start = options.mode ? [options.mode, "codex"] : ["codex"];
    const spelled = (options.args ?? []).map((arg) =>
      shell === "pwsh"
        ? ((
            {
              "--to": "-To",
              "--done": "-Done",
              "--skip": "-Skip",
              "--reason": "-Reason",
            } as Record<string, string>
          )[arg] ?? arg)
        : arg,
    );
    const args = options.command
      ? [
          "-NoProfile",
          "-NonInteractive",
          "-Command",
          `& '${join(SCRIPTS, "sync.ps1")}' ${options.command}; exit $LASTEXITCODE`,
        ]
      : shell === "pwsh"
        ? [
            "-NoProfile",
            "-NonInteractive",
            "-File",
            join(SCRIPTS, "sync.ps1"),
            ...start,
            ...spelled,
          ]
        : [join(SCRIPTS, "sync.sh"), ...start, ...spelled];
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
  };

  const read = (path: string) => readFileSync(path, "utf8");
  const runLine = (shell: string) =>
    shell === "pwsh"
      ? "pwsh -NoProfile -File ~/.contextlocker/sync.ps1"
      : "sh ~/.contextlocker/sync.sh";
  const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  /** The hook Codex runs at session start, as setup adds it */
  function addHook(home: string, shell: string) {
    writeFileSync(
      join(home, ".codex", "hooks.json"),
      JSON.stringify(
        {
          hooks: {
            SessionStart: [
              {
                hooks: [
                  { type: "command", command: `${runLine(shell)} codex` },
                ],
              },
            ],
          },
        },
        null,
        2,
      ),
    );
  }

  /** A repo linked to the project, on a computer whose last sync knows the workspace */
  function project(home: string) {
    const lock = join(home, ".contextlocker", "codex", "global.lock");
    if (!existsSync(lock)) {
      writeFileSync(
        lock,
        `context-locker-lock 1\nentry workspace ${WORKSPACE}\n`,
      );
    }
    const repo = join(home, "repo");
    mkdirSync(repo, { recursive: true });
    writeFileSync(
      join(repo, ".contextlocker.json"),
      JSON.stringify({ workspace: WORKSPACE, project: PROJECT }),
    );
    return repo;
  }

  const note = (file: string, version = 1): MoveNote => ({
    id: randomUUID(),
    version,
    file,
    text: `---\ntitle: "${file}"\nkind: "plan"\nuse_as: "source-of-truth"\nsummary: "About ${file}."\ntags: ["release"]\napplies_to: "Docs site"\n---\n\nThe note ${file}.\n`,
  });

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("prints Tidy-up with fix, for the project, and marks an item done or skipped", async () => {
        const machine = computer(shell);
        const id = randomUUID();
        fake.fixes.text = `1 thing needs looking after in the user's playbook.\n1. A problem.\x1b[31m Its evidence.\n   Id: ${id}\n`;
        const listed = await run(shell, machine, { mode: "fix" });
        assert.equal(listed.status, 0, listed.stderr);
        // Control characters never show
        assert.equal(
          listed.stdout,
          `1 thing needs looking after in the user's playbook.\n1. A problem.[31m Its evidence.\n   Id: ${id}\n`,
        );
        assert.ok(
          fake.requests.includes("GET /v1/sync/fixes"),
          fake.requests.join("\n"),
        );

        // In a project, it asks for the project's items, unless --all
        const repo = project(machine.home);
        await run(shell, machine, { mode: "fix", cwd: repo });
        assert.ok(
          fake.requests.includes(`GET /v1/sync/fixes?project=${PROJECT}`),
          fake.requests.join("\n"),
        );
        fake.requests = [];
        await run(shell, machine, { mode: "fix", cwd: repo, args: ["--all"] });
        assert.deepEqual(
          fake.requests.filter((line) => line.includes("/fixes")),
          ["GET /v1/sync/fixes"],
        );

        const done = await run(shell, machine, {
          mode: "fix",
          args: ["--done", id],
        });
        assert.equal(done.status, 0, done.stderr);
        assert.equal(
          done.stdout,
          "Done. The check no longer finds the problem, so it's gone from Tidy-up.\n",
        );
        fake.marked.text =
          "Skipped. It stays in Tidy-up for the user, with your reason.\n";
        const skipped = await run(shell, machine, {
          mode: "fix",
          args: ["--skip", id, "--reason", "It still holds, says the user."],
        });
        assert.equal(skipped.status, 0, skipped.stderr);
        assert.deepEqual(
          fake.marks.map(({ id: marked, body }) => [marked, body]),
          [
            [id, "done\n"],
            [id, "skipped\nIt still holds, says the user.\n"],
          ],
        );
        assert.match(fake.marks[0]?.type ?? "", /^text\/plain/);

        // What Context Locker says when it refuses, and when it can't be reached
        fake.marked = {
          status: 409,
          text: '{"error":"already_closed","message":"This Tidy-up item is already done with."}',
        };
        const closed = await run(shell, machine, {
          mode: "fix",
          args: ["--done", id],
        });
        assert.equal(closed.status, 1);
        assert.equal(
          closed.stderr,
          "Context Locker: This Tidy-up item is already done with.\n",
        );
        fake.marked = { status: 403, text: '{"error":"forbidden"}' };
        const reader = await run(shell, machine, {
          mode: "fix",
          args: ["--done", id],
        });
        assert.equal(reader.status, 1);
        assert.match(
          reader.stderr,
          /Codex may only read your playbook, so it can't mark Tidy-up items\./,
        );
        fake.fixes = { status: 500, text: '{"error":"internal"}' };
        const down = await run(shell, machine, { mode: "fix" });
        assert.equal(down.status, 1);
        assert.equal(
          down.stderr,
          "Context Locker answered 500. Try again in a minute.\n",
        );
      });

      it("takes fix's options only for fix, one mark at a time, with a reason to skip", async () => {
        const machine = computer(shell);
        const id = randomUUID();
        for (const [mode, args] of [
          ["fix", ["--done", "not-an-id"]],
          ["fix", ["--done", id.toUpperCase()]],
          ["fix", ["--skip", id]],
          ["fix", ["--skip", id, "--reason", "   "]],
          ["fix", ["--done", id, "--reason", "Fixed."]],
          ["fix", ["--done", id, "--skip", id, "--reason", "Both."]],
          ["fix", ["--all", "--done", id]],
          ["fix", ["--reason", "Nothing to mark."]],
          ["map", ["--done", id]],
          ["doctor", ["--reason", "No."]],
        ] as const) {
          const refused = await run(shell, machine, { mode, args: [...args] });
          assert.equal(
            refused.status,
            2,
            `${mode} ${args.join(" ")}: ${refused.stdout}${refused.stderr}`,
          );
          assert.match(refused.stderr, /fix <app> (?:--done|-Done) <id>/);
        }
        assert.deepEqual(fake.marks, []);
      });

      it("passes a doctor with nothing wrong, and sums it up in one line", async () => {
        const machine = computer(shell);
        assert.equal((await run(shell, machine)).status, 0);
        addHook(machine.home, shell);
        const doctor = await run(shell, machine, { mode: "doctor" });
        assert.equal(doctor.status, 0, doctor.stdout + doctor.stderr);
        assert.match(
          doctor.stdout,
          /^PASS {2}Preferences: 1 of 50 everywhere\.$/m,
        );
        assert.match(doctor.stdout, /^PASS {2}Skills: 1 of 20\.$/m);
        // code-review, and Context Locker's own Import skill
        assert.match(
          doctor.stdout,
          /^PASS {2}1 block and 2 skills in place\.$/m,
        );
        assert.doesNotMatch(doctor.stdout, /^(WARN|FAIL) /m);
        assert.ok(
          doctor.stdout.endsWith("\nAll checks passed.\n"),
          doctor.stdout,
        );
      });

      it("warns as a limit fills up, fails only once one is over, and exits 1 then", async () => {
        const machine = computer(shell);
        assert.equal((await run(shell, machine)).status, 0);
        addHook(machine.home, shell);

        fake.caps.text =
          "context-locker-caps 1\nPASS  Preferences: 1 of 50 everywhere.\nWARN  Notes and pointers: 913 of the 1,000 the Free plan holds. Retire the ones you no longer need before it fills up.\n";
        const near = await run(shell, machine, { mode: "doctor" });
        assert.equal(near.status, 0, near.stdout + near.stderr);
        assert.match(
          near.stdout,
          /^WARN {2}Notes and pointers: 913 of the 1,000 the Free plan holds\. Retire the ones you no longer need before it fills up\.$/m,
        );
        assert.ok(
          near.stdout.endsWith("\nWorking, with 1 warning.\n"),
          near.stdout,
        );

        fake.caps.text =
          "context-locker-caps 1\nFAIL  Preferences: 51 everywhere, over the 50 a scope holds. Merge or retire some to get back under it.\nWARN  Skills: 19 of 20.\n";
        const over = await run(shell, machine, { mode: "doctor" });
        assert.equal(over.status, 1, over.stdout + over.stderr);
        assert.match(
          over.stdout,
          /^FAIL {2}Preferences: 51 everywhere, over the 50 a scope holds\./m,
        );
        assert.ok(
          over.stdout.endsWith("\n1 problem to fix, and 1 warning.\n"),
          over.stdout,
        );

        // An answer that isn't the caps is a warning, and nothing it says shows
        fake.caps = { status: 200, text: "FAIL  Not from Context Locker.\n" };
        const odd = await run(shell, machine, { mode: "doctor" });
        assert.equal(odd.status, 0, odd.stdout + odd.stderr);
        assert.doesNotMatch(odd.stdout, /Not from Context Locker/);
        assert.match(
          odd.stdout,
          /^WARN {2}Couldn't check how full your playbook's limits are: Context Locker answered 200\.$/m,
        );
        fake.caps = { status: 500, text: '{"error":"x"}' };
        const down = await run(shell, machine, { mode: "doctor" });
        assert.equal(down.status, 0, down.stdout + down.stderr);
        assert.match(
          down.stdout,
          /^WARN {2}Couldn't check how full your playbook's limits are: Context Locker answered 500\.$/m,
        );
      });

      it(
        "warns about instruction and memory files with lines Context Locker doesn't manage",
        { skip: !HAVE_GIT && "git isn't installed" },
        async () => {
          const machine = computer(shell);
          assert.equal((await run(shell, machine)).status, 0);
          addHook(machine.home, shell);
          const agents = join(machine.home, ".codex", "AGENTS.md");
          writeFileSync(agents, `# Mine\n\nKeep this.\n\n${read(agents)}\n\n`);
          mkdirSync(join(machine.home, ".codex", "memories", "2026"), {
            recursive: true,
          });
          writeFileSync(
            join(machine.home, ".codex", "memories", "2026", "oct.md"),
            "One.\nTwo.\n\nThree.\n",
          );
          writeFileSync(
            join(machine.home, ".codex", "memories", "notes.txt"),
            "Four.\n",
          );
          writeFileSync(
            join(machine.home, ".codex", "memories", ".hidden.md"),
            "Hidden.\n",
          );
          // A file reached through a link isn't read, as Gather doesn't follow links
          writeFileSync(join(machine.home, "outside.md"), "Outside.\n");
          symlinkSync(
            join(machine.home, "outside.md"),
            join(machine.home, ".codex", "memories", "linked.md"),
          );
          const repo = join(machine.home, "repo");
          mkdirSync(repo);
          spawnSync("git", ["init", "-q", repo]);
          writeFileSync(
            join(repo, "CLAUDE.md"),
            "# Team rules\n\nRun the tests.\n",
          );
          writeFileSync(join(repo, "AGENTS.md"), "");

          const doctor = await run(shell, machine, {
            mode: "doctor",
            cwd: repo,
          });
          assert.equal(doctor.status, 0, doctor.stdout + doctor.stderr);
          const choice = (path: string) =>
            escape(
              `Bring them into your playbook with Import (${runLine(shell)} gather codex), or keep them in Codex only (${runLine(shell)} keep codex ${path}).`,
            );
          assert.match(
            doctor.stdout,
            new RegExp(
              `^WARN {2}~/\\.codex/AGENTS\\.md has 2 lines outside Context Locker's block\\. ${choice("~/.codex/AGENTS.md")}$`,
              "m",
            ),
          );
          assert.match(
            doctor.stdout,
            new RegExp(
              `^WARN {2}Codex's memories, in ~/\\.codex/memories, 2 files hold 4 lines outside Context Locker\\. ${choice("~/.codex/memories")}$`,
              "m",
            ),
          );
          assert.match(
            doctor.stdout,
            new RegExp(
              `^WARN {2}~/repo/CLAUDE\\.md has 2 lines outside Context Locker's block\\. ${choice("~/repo/CLAUDE.md")}$`,
              "m",
            ),
          );
          // An empty one has nothing to bring in
          assert.doesNotMatch(doctor.stdout, /repo\/AGENTS\.md/);
          assert.ok(
            doctor.stdout.endsWith("\nWorking, with 3 warnings.\n"),
            doctor.stdout,
          );
        },
      );

      it("asks about each source once, and again only once something in it is new or changed (G1-115)", async () => {
        const machine = computer(shell);
        assert.equal((await run(shell, machine)).status, 0);
        addHook(machine.home, shell);
        const memories = join(machine.home, ".codex", "memories");
        mkdirSync(memories, { recursive: true });
        writeFileSync(join(memories, "notes.md"), "One.\nTwo.\n");
        writeFileSync(join(memories, "tools.md"), "Three.\n");
        const today = escape(dayOf(new Date()));
        const choice = (path: string) =>
          escape(
            `Bring them into your playbook with Import (${runLine(shell)} gather codex), or keep them in Codex only (${runLine(shell)} keep codex ${path}).`,
          );
        const memoriesAsked = (what: string) =>
          new RegExp(
            `^WARN {2}Codex's memories, in ~/\\.codex/memories, ${what} ${choice("~/.codex/memories")}$`,
            "m",
          );
        const memoriesKept = new RegExp(
          `^PASS {2}Codex's memories, in ~/\\.codex/memories, stay in Codex only, as you chose on ${today}\\.$`,
          "m",
        );

        const asked = await run(shell, machine, { mode: "doctor" });
        assert.equal(asked.status, 0, asked.stdout + asked.stderr);
        assert.match(
          asked.stdout,
          memoriesAsked("2 files hold 3 lines outside Context Locker\\."),
        );
        assert.ok(
          asked.stdout.endsWith("\nWorking, with 1 warning.\n"),
          asked.stdout,
        );

        // Kept in Codex only, by the path the doctor gave
        const kept = await run(shell, machine, {
          mode: "keep",
          args: ["~/.codex/memories"],
        });
        assert.equal(kept.status, 0, kept.stdout + kept.stderr);
        assert.equal(
          kept.stdout,
          `Kept in Codex only: 2 files in ~/.codex/memories. The doctor asks about them again only once one is new or changes. To bring them into your playbook later, run Import: ${runLine(shell)} gather codex\n`,
        );
        const sources = read(join(machine.home, ".contextlocker", "sources"))
          .split("\n")
          .filter(Boolean);
        const day = new Date().toISOString().slice(0, 10);
        assert.deepEqual(
          sources.sort(),
          [
            "context-locker-sources 1",
            `keep\t${day}\t${sha256("One.\nTwo.\n")}\t${join(memories, "notes.md")}`,
            `keep\t${day}\t${sha256("Three.\n")}\t${join(memories, "tools.md")}`,
          ].sort(),
        );
        const settled = await run(shell, machine, { mode: "doctor" });
        assert.match(settled.stdout, memoriesKept);
        assert.ok(
          settled.stdout.endsWith("\nAll checks passed.\n"),
          settled.stdout,
        );

        // Blank lines and Windows line ends aren't a change, and a file
        // that's gone isn't something new
        writeFileSync(join(memories, "notes.md"), "One.\r\n\r\nTwo.\r\n");
        rmSync(join(memories, "tools.md"));
        assert.match(
          (await run(shell, machine, { mode: "doctor" })).stdout,
          memoriesKept,
        );

        // A new file is, and so is a changed one
        writeFileSync(join(memories, "people.md"), "Ada leads.\nBo reviews.\n");
        assert.match(
          (await run(shell, machine, { mode: "doctor" })).stdout,
          memoriesAsked(
            `have 1 new or changed file since you kept them in Codex on ${today}, with 2 lines outside Context Locker\\.`,
          ),
        );
        writeFileSync(join(memories, "notes.md"), "One.\nTwo, now.\n");
        assert.match(
          (await run(shell, machine, { mode: "doctor" })).stdout,
          memoriesAsked(
            `have 2 new or changed files since you kept them in Codex on ${today}, with 4 lines outside Context Locker\\.`,
          ),
        );

        // A file of its own, kept by its full path, with only what's outside
        // Context Locker's block counted
        const agents = join(machine.home, ".codex", "AGENTS.md");
        writeFileSync(agents, `# Mine\n\nKeep this.\n\n${read(agents)}`);
        assert.match(
          (await run(shell, machine, { mode: "doctor" })).stdout,
          new RegExp(
            `^WARN {2}~/\\.codex/AGENTS\\.md has 2 lines outside Context Locker's block\\. ${choice("~/.codex/AGENTS.md")}$`,
            "m",
          ),
        );
        const keptFile = await run(shell, machine, {
          mode: "keep",
          args: [agents],
        });
        assert.equal(keptFile.status, 0, keptFile.stdout + keptFile.stderr);
        assert.equal(
          keptFile.stdout,
          `Kept in Codex only: ~/.codex/AGENTS.md. The doctor asks about it again only once it changes. To bring it into your playbook later, run Import: ${runLine(shell)} gather codex\n`,
        );
        assert.match(
          (await run(shell, machine, { mode: "doctor" })).stdout,
          /^PASS {2}~\/\.codex\/AGENTS\.md stays in Codex only, as you chose on .+\.$/m,
        );
        writeFileSync(
          agents,
          read(agents).replace("Keep this.", "Keep this, please."),
        );
        assert.match(
          (await run(shell, machine, { mode: "doctor" })).stdout,
          new RegExp(
            `^WARN {2}~/\\.codex/AGENTS\\.md has changed since you kept it in Codex on ${today}, and has 2 lines outside Context Locker's block\\. ${choice("~/.codex/AGENTS.md")}$`,
            "m",
          ),
        );

        // Nothing to keep, nothing there, a link, or no path at all
        writeFileSync(
          join(machine.home, "ours.md"),
          "<!-- context-locker:start -->\nOurs.\n<!-- context-locker:end -->\n\n",
        );
        const ours = await run(shell, machine, {
          mode: "keep",
          args: ["~/ours.md"],
        });
        assert.equal(ours.status, 0, ours.stdout + ours.stderr);
        assert.equal(
          ours.stdout,
          "~/ours.md holds nothing outside Context Locker's blocks, so there's nothing to keep.\n",
        );
        const nothing = await run(shell, machine, {
          mode: "keep",
          args: ["~/nowhere"],
        });
        assert.equal(nothing.status, 1);
        assert.match(
          nothing.stderr,
          /there's no file or folder at ~\/nowhere, so nothing was kept\./,
        );
        symlinkSync(memories, join(machine.home, "linked"));
        const linked = await run(shell, machine, {
          mode: "keep",
          args: ["~/linked"],
        });
        assert.equal(linked.status, 1);
        assert.match(
          linked.stderr,
          /~\/linked is a link, and Context Locker doesn't follow links, so nothing was kept\./,
        );
        const bare = await run(shell, machine, { mode: "keep" });
        assert.equal(bare.status, 2);
      });

      it("doesn't ask about a project file its playbook links to, or one that only points at one (G1-115)", async () => {
        const machine = computer(shell);
        assert.equal((await run(shell, machine)).status, 0);
        addHook(machine.home, shell);
        const repo = project(machine.home);
        writeFileSync(
          join(repo, "AGENTS.md"),
          "# Agents\n\nRun the tests.\nUse plain words.\n",
        );
        writeFileSync(
          join(repo, "CLAUDE.md"),
          "# CLAUDE.md\n\nClaude Code reads this file instead of AGENTS.md, so it imports AGENTS.md.\n\n@AGENTS.md\n",
        );
        mkdirSync(join(repo, ".claude"));
        writeFileSync(join(repo, ".claude", "CLAUDE.md"), "@../AGENTS.md\n");
        writeFileSync(
          join(repo, "CLAUDE.local.md"),
          "@AGENTS.md\nDeploy on Fridays.\n",
        );
        const lock = join(
          machine.home,
          ".contextlocker",
          "codex",
          "projects",
          `${PROJECT}.lock`,
        );
        mkdirSync(join(lock, ".."), { recursive: true });
        writeFileSync(
          lock,
          `context-locker-lock 1\nentry link ${randomUUID()} AGENTS.md\n`,
        );
        const choice = (path: string) =>
          escape(
            `Bring them into your playbook with Import (${runLine(shell)} gather codex), or keep them in Codex only (${runLine(shell)} keep codex ${path}).`,
          );

        const linked = await run(shell, machine, { mode: "doctor", cwd: repo });
        assert.match(
          linked.stdout,
          /^PASS {2}~\/repo\/AGENTS\.md is in your playbook as a link\.$/m,
        );
        assert.match(
          linked.stdout,
          /^PASS {2}~\/repo\/CLAUDE\.md only points at AGENTS\.md, which your playbook links to\.$/m,
        );
        assert.match(
          linked.stdout,
          /^PASS {2}~\/repo\/\.claude\/CLAUDE\.md only points at AGENTS\.md, which your playbook links to\.$/m,
        );
        // A line of its own besides the import is something to ask about
        assert.match(
          linked.stdout,
          new RegExp(
            `^WARN {2}~/repo/CLAUDE\\.local\\.md has 2 lines outside Context Locker's block\\. ${choice("~/repo/CLAUDE.local.md")}$`,
            "m",
          ),
        );

        // Without the link, each one is asked about
        writeFileSync(lock, "context-locker-lock 1\n");
        const unlinked = await run(shell, machine, {
          mode: "doctor",
          cwd: repo,
        });
        assert.match(
          unlinked.stdout,
          new RegExp(
            `^WARN {2}~/repo/AGENTS\\.md has 3 lines outside Context Locker's block\\. ${choice("~/repo/AGENTS.md")}$`,
            "m",
          ),
        );
        assert.match(
          unlinked.stdout,
          new RegExp(
            `^WARN {2}~/repo/CLAUDE\\.md has 3 lines outside Context Locker's block\\. ${choice("~/repo/CLAUDE.md")}$`,
            "m",
          ),
        );
        assert.doesNotMatch(unlinked.stdout, /points at/);
      });

      it("says what drifted since the last sync, and fails without the hook", async () => {
        const machine = computer(shell);
        assert.equal((await run(shell, machine)).status, 0);
        addHook(machine.home, shell);
        const agents = join(machine.home, ".codex", "AGENTS.md");
        const skill = join(machine.home, ".agents", "skills", "code-review");
        const lock = join(
          machine.home,
          ".contextlocker",
          "codex",
          "global.lock",
        );

        // Edits in the block and the skill that no sync has sent yet
        writeFileSync(
          agents,
          read(agents).replace("Use plain words.", "Use plain, short words."),
        );
        writeFileSync(
          join(skill, "SKILL.md"),
          `${read(join(skill, "SKILL.md"))}\nAnd the docs.\n`,
        );
        const edited = await run(shell, machine, { mode: "doctor" });
        assert.equal(edited.status, 0, edited.stdout + edited.stderr);
        assert.match(
          edited.stdout,
          new RegExp(
            `^WARN {2}Context Locker's block in ${escape(agents)} has an edit that isn't saved in Context Locker yet\\. The next sync sends it\\.$`,
            "m",
          ),
        );
        assert.match(
          edited.stdout,
          new RegExp(
            `^WARN {2}The skill code-review at ${escape(skill)} has an edit that isn't saved in Context Locker yet\\. The next sync sends it\\.$`,
            "m",
          ),
        );

        // One that waits for approval, and one Context Locker couldn't take
        const blockNow = blockHash(extractBlock(read(agents)) as string);
        writeFileSync(
          lock,
          `${read(lock)}entry hold ${blockNow} {codex}/AGENTS.md\n`,
        );
        const held = await run(shell, machine, { mode: "doctor" });
        assert.match(
          held.stdout,
          new RegExp(
            `^PASS {2}Your edit to Context Locker's block in ${escape(agents)} is saved in Context Locker, and waits for approval in its inbox\\.$`,
            "m",
          ),
        );
        writeFileSync(
          lock,
          read(lock).replace(`entry hold ${blockNow}`, `refused ${blockNow}`),
        );
        const refused = await run(shell, machine, { mode: "doctor" });
        assert.match(
          refused.stdout,
          new RegExp(
            `^WARN {2}Context Locker couldn't take the edit to Context Locker's block in ${escape(agents)}, so it won't update until the edit is undone or fixed\\.$`,
            "m",
          ),
        );

        // What the lockfile says was written, and isn't there
        rmSync(agents);
        rmSync(skill, { recursive: true });
        const missing = await run(shell, machine, { mode: "doctor" });
        assert.equal(missing.status, 0, missing.stdout + missing.stderr);
        assert.match(
          missing.stdout,
          new RegExp(
            `^WARN {2}${escape(agents)} is missing\\. The next sync writes it again\\.$`,
            "m",
          ),
        );
        assert.match(
          missing.stdout,
          new RegExp(
            `^WARN {2}The skill at ${escape(skill)} is missing\\. The next sync adds it again\\.$`,
            "m",
          ),
        );

        // No sync for over a week, a newer script, and no hook
        const old = new Date(Date.now() - 10 * 86400 * 1000);
        const stamp = old.toISOString().replace(/\.\d{3}Z$/, "Z");
        writeFileSync(
          lock,
          read(lock)
            .replace(/^synced .*$/m, `synced ${stamp}`)
            .replace(
              /^entry script \d+$/m,
              `entry script ${SYNC_SCRIPT_VERSION + 1}`,
            ),
        );
        rmSync(join(machine.home, ".codex", "hooks.json"));
        const late = await run(shell, machine, { mode: "doctor" });
        assert.equal(late.status, 1, late.stdout + late.stderr);
        assert.match(
          late.stdout,
          new RegExp(
            `^WARN {2}The last sync was on ${dayOf(old)} at \\d{2}:\\d{2} UTC, 10 days ago\\. Check that the session-start hook runs, or sync now: ${escape(runLine(shell))} codex ${shell === "pwsh" ? "-Now" : "--now"}$`,
            "m",
          ),
        );
        assert.match(
          late.stdout,
          /^WARN {2}A newer version of the sync script is out\./m,
        );
        assert.match(late.stdout, /^FAIL {2}The session-start hook isn't in /m);
        assert.ok(
          late.stdout.endsWith("\n1 problem to fix, and 4 warnings.\n"),
          late.stdout,
        );
      });

      it("exports into a new folder, and refuses a folder that holds anything before downloading", async () => {
        const machine = computer(shell);
        const here = join(machine.home, "work");
        mkdirSync(here);
        const exported = await run(shell, machine, {
          mode: "export",
          cwd: here,
        });
        assert.equal(exported.status, 0, exported.stdout + exported.stderr);
        const folder = join(here, `Context Locker export ${dayOf(new Date())}`);
        assert.equal(
          exported.stdout,
          [
            `Context Locker exported the playbook to ${folder}:`,
            "- 4 preferences, 2 of them About facts",
            "- 1 skill",
            "- 3 notes and 2 pointers",
            "- 1 project",
            "- 21 events and 12 versions in the history",
            "README.md there says what each file is.",
            "",
          ].join("\n"),
        );
        assert.equal(
          read(join(folder, "everywhere", "preferences.md")),
          "# Preferences\n",
        );
        // Only this account can open it
        assert.equal(statSync(folder).mode & 0o077, 0);

        // Refused before anything comes down: a folder that holds anything,
        // and a file
        const full = join(here, "full");
        mkdirSync(full);
        writeFileSync(join(full, "mine.txt"), "Mine.\n");
        writeFileSync(join(here, "a-file"), "A file.\n");
        fake.requests = [];
        const into = await run(shell, machine, {
          mode: "export",
          cwd: here,
          args: ["--to", "full"],
        });
        assert.equal(into.status, 1, into.stdout);
        assert.match(
          into.stderr,
          /already holds files, and an export only goes into a new or empty folder, so nothing was exported\./,
        );
        const file = await run(shell, machine, {
          mode: "export",
          cwd: here,
          args: ["--to", "a-file"],
        });
        assert.equal(file.status, 1, file.stdout);
        assert.match(
          file.stderr,
          /is there already, and isn't a folder, so nothing was exported\./,
        );
        assert.deepEqual(
          fake.requests.filter((request) =>
            request.startsWith("GET /v1/export"),
          ),
          [],
        );
        assert.deepEqual(readdirSync(full), ["mine.txt"]);
        assert.equal(read(join(here, "a-file")), "A file.\n");

        // A new folder --to names, made with the folders above it
        const named = await run(shell, machine, {
          mode: "export",
          cwd: here,
          args: ["--to", "backups/october"],
        });
        assert.equal(named.status, 0, named.stdout + named.stderr);
        assert.ok(existsSync(join(here, "backups", "october", "export.json")));

        // What Context Locker says when it refuses
        fake.exported = {
          status: 429,
          body: Buffer.from(
            '{"error":"rate_limited","message":"This playbook was exported 10 times in the last hour, the most it can be. Try again in 5 minutes."}',
          ),
        };
        const limited = await run(shell, machine, {
          mode: "export",
          cwd: here,
          args: ["--to", "later"],
        });
        assert.equal(limited.status, 1, limited.stdout);
        assert.equal(
          limited.stderr,
          "Context Locker: This playbook was exported 10 times in the last hour, the most it can be. Try again in 5 minutes.\n",
        );
        assert.ok(!existsSync(join(here, "later")));
      });

      it("never unpacks an export that would write anywhere else, or holds links", async () => {
        const machine = computer(shell);
        const here = join(machine.home, "work");
        mkdirSync(here);
        const top = "Context Locker export 21 Oct 2026";
        const cases: Array<[string, Buffer, RegExp]> = [
          [
            "a path up a folder",
            exportArchive(top, [
              { path: `${top}/../../escaped.txt`, data: "Out.\n" },
            ]),
            /couldn't be unpacked safely/,
          ],
          [
            "a link",
            exportArchive(top, [{ path: `${top}/linked`, link: "/etc" }]),
            /couldn't be unpacked safely/,
          ],
          // GNU tar lists and unpacks this one without its first /, inside
          [
            "a path from the top",
            exportArchive(top, [
              { path: "/tmp/ctx-escaped.txt", data: "Out.\n" },
            ]),
            /couldn't be unpacked safely|isn't laid out as an export/,
          ],
          [
            "two folders",
            exportArchive(top, [{ path: "Another", directory: true }]),
            /isn't laid out as an export/,
          ],
          [
            "no export.json",
            gzipSync(
              tarOf([
                { path: top, directory: true },
                { path: `${top}/README.md`, data: "x\n" },
              ]),
            ),
            /isn't laid out as an export/,
          ],
          [
            "not gzip",
            Buffer.from("not an archive"),
            /couldn't be unpacked safely/,
          ],
        ];
        for (const [what, body, said] of cases) {
          fake.exported = { status: 200, body };
          const to = join(here, what.replace(/ /g, "-"));
          const result = await run(shell, machine, {
            mode: "export",
            cwd: here,
            args: ["--to", to],
          });
          assert.equal(
            result.status,
            1,
            `${what}: ${result.stdout}${result.stderr}`,
          );
          assert.match(result.stderr, said, what);
          assert.ok(!existsSync(to), what);
        }
        assert.ok(!existsSync(join(machine.home, "escaped.txt")));
        assert.ok(!existsSync(join(here, "escaped.txt")));
        assert.ok(!existsSync("/tmp/ctx-escaped.txt"));
      });

      it("moves notes out only once every file is written, says each is a pointer now, and takes back the ones that changed", async () => {
        const machine = computer(shell);
        const repo = project(machine.home);
        const plan = note("release-plan.md");
        const idea = note("dark-mode.md", 3);
        fake.notes = [idea, plan];
        const decisions = join(repo, "docs", "decisions");
        fake.watch = decisions;
        fake.answer = () => ({
          status: 200,
          text: `context-locker-move-out 2\nmoved ${plan.id} release-plan.md\nchanged ${idea.id} dark-mode.md\ndocs-home notes docs/decisions\n`,
        });
        const moved = await run(shell, machine, {
          mode: "notes-move-out",
          cwd: repo,
          args: ["--to", "docs/decisions"],
        });
        assert.equal(moved.status, 0, moved.stdout + moved.stderr);
        assert.equal(moved.stderr, "");
        // Every file was there when Context Locker heard of the move
        assert.equal(fake.posted.length, 1);
        assert.deepEqual(fake.posted[0]?.files, [
          "dark-mode.md",
          "release-plan.md",
        ]);
        assert.equal(
          fake.posted[0]?.body,
          `context-locker-move-out 2\nfolder docs/decisions\nnote ${idea.id} 3 dark-mode.md\nnote ${plan.id} 1 release-plan.md\n`,
        );
        assert.equal(
          moved.stdout,
          [
            "Moved 1 note from Context Locker into docs/decisions:",
            "- docs/decisions/release-plan.md",
            "Each one is a pointer in Context Locker now, to its file here, with the same id, and History says where each one went. Restoring an earlier version in Context Locker brings a note's text back.",
            "The docs home for Docs site is docs/decisions now, instead of Notes.",
            "1 note changed in Context Locker while it was moving, so it stays there: dark-mode.md. The file this move wrote for it came out again. Run this again to move it.",
            "",
          ].join("\n"),
        );
        assert.deepEqual(readdirSync(decisions), ["release-plan.md"]);
        assert.equal(read(join(decisions, "release-plan.md")), plan.text);
      });

      it("never writes over a file, outside the project, or through a link", async () => {
        const machine = computer(shell);
        const repo = project(machine.home);
        fake.notes = [note("release-plan.md"), note("dark-mode.md")];
        const moveOut = (to: string) =>
          run(shell, machine, {
            mode: "notes-move-out",
            cwd: repo,
            args: ["--to", to],
          });

        // A different file there already stops it before anything is written
        const decisions = join(repo, "docs", "decisions");
        mkdirSync(decisions, { recursive: true });
        writeFileSync(join(decisions, "release-plan.md"), "Mine.\n");
        const over = await moveOut("docs/decisions");
        assert.equal(over.status, 1, over.stdout);
        assert.match(
          over.stderr,
          /^Context Locker: nothing moved, as notes-move-out never writes over anything, and a different file or folder is there already: docs\/decisions\/release-plan\.md\. Move it away, or name another folder\.$/m,
        );
        assert.deepEqual(readdirSync(decisions), ["release-plan.md"]);
        assert.equal(read(join(decisions, "release-plan.md")), "Mine.\n");
        rmSync(join(repo, "docs"), { recursive: true });

        // Nowhere outside the project, nor its top folder, .git or .context-locker
        const refusals: Array<[string, RegExp]> = [
          ["../elsewhere", /isn't inside the project's folder/],
          [
            join(machine.home, "elsewhere"),
            /isn't inside the project's folder/,
          ],
          [".", /not its top folder/],
          ["docs/..", /not its top folder/],
          [".git/notes", /can't move into \.context-locker or \.git/],
          [
            ".context-locker/notes",
            /can't move into \.context-locker or \.git/,
          ],
        ];
        for (const [to, said] of refusals) {
          const result = await moveOut(to);
          assert.equal(result.status, 1, `${to}: ${result.stdout}`);
          assert.match(result.stderr, said, to);
        }
        assert.ok(!existsSync(join(machine.home, "elsewhere")));

        // Nor through a link, at any part of the way
        const outside = join(machine.home, "outside");
        mkdirSync(outside);
        symlinkSync(outside, join(repo, "docs"));
        const linked = await moveOut("docs/decisions");
        assert.equal(linked.status, 1, linked.stdout);
        assert.match(
          linked.stderr,
          /docs is a link, and notes-move-out never follows one, so nothing moved\./,
        );
        assert.deepEqual(readdirSync(outside), []);
        rmSync(join(repo, "docs"));
        writeFileSync(join(machine.home, "theirs.md"), "Theirs.\n");
        mkdirSync(decisions, { recursive: true });
        symlinkSync(
          join(machine.home, "theirs.md"),
          join(decisions, "dark-mode.md"),
        );
        const file = await moveOut("docs/decisions");
        assert.equal(file.status, 1, file.stdout);
        assert.match(
          file.stderr,
          /a different file or folder is there already: docs\/decisions\/dark-mode\.md\./,
        );
        assert.equal(read(join(machine.home, "theirs.md")), "Theirs.\n");

        // None of it got as far as Context Locker
        assert.deepEqual(fake.posted, []);
      });

      it("refuses notes that come down wrong, and takes back what it wrote when the move fails", async () => {
        const machine = computer(shell);
        const repo = project(machine.home);
        const decisions = join(repo, "docs", "decisions");
        const moveOut = () =>
          run(shell, machine, {
            mode: "notes-move-out",
            cwd: repo,
            args: ["--to", "docs/decisions"],
          });

        // A file named to go somewhere else, or whose hash is wrong
        const text = "A note.\n";
        for (const index of [
          `note ${randomUUID()} 1 ${sha256(text)} ../escaped.md`,
          `note ${randomUUID()} 1 ${sha256("other")} fine.md`,
        ]) {
          fake.moveArchive = tarOf([
            { path: sha256(text), data: text },
            {
              path: "index",
              data: `context-locker-move-out 2\nproject ${PROJECT} Docs site\n${index}\n`,
            },
          ]);
          const bad = await moveOut();
          assert.equal(bad.status, 1, bad.stdout);
          assert.match(
            bad.stderr,
            /the notes that came down couldn't be read safely, so nothing moved/,
          );
          assert.ok(!existsSync(join(repo, "docs")));
          assert.ok(!existsSync(join(repo, "escaped.md")));
        }
        fake.moveArchive = null;

        // Refused: the files it wrote come out again, with the folders it made
        fake.notes = [note("release-plan.md")];
        fake.answer = () => ({
          status: 400,
          text: '{"error":"invalid_request","message":"The folder\'s path must be at most 500 characters."}',
        });
        const refused = await moveOut();
        assert.equal(refused.status, 1, refused.stdout);
        assert.equal(
          refused.stderr,
          "Context Locker: nothing moved: The folder's path must be at most 500 characters. The files it wrote came out again.\n",
        );
        assert.ok(!existsSync(join(repo, "docs")));

        // No answer: the files stay, and running it again finishes the move
        fake.answer = () => "drop";
        const dropped = await moveOut();
        assert.equal(dropped.status, 1, dropped.stdout);
        assert.match(
          dropped.stderr,
          /the notes are written in docs\/decisions, but Context Locker couldn't be reached to turn them into pointers, so it isn't known whether they moved\. Run the same command again/,
        );
        assert.deepEqual(readdirSync(decisions), ["release-plan.md"]);
        fake.answer = new FakeLocker().answer;
        const again = await moveOut();
        assert.equal(again.status, 0, again.stdout + again.stderr);
        assert.match(
          again.stdout,
          /^Moved 1 note from Context Locker into docs\/decisions:$/m,
        );
        assert.deepEqual(readdirSync(decisions), ["release-plan.md"]);

        // With nothing left to move, it says so
        fake.notes = [];
        const none = await moveOut();
        assert.equal(none.status, 0, none.stdout + none.stderr);
        assert.equal(
          none.stdout,
          "Docs site has no notes of its own in Context Locker to move.\n",
        );
      });

      it("takes no title for a move, as each note becomes a pointer to its own file", async () => {
        const machine = computer(shell);
        const repo = project(machine.home);
        fake.notes = [note("release-plan.md")];
        const titled = await run(shell, machine, {
          mode: "notes-move-out",
          cwd: repo,
          args: ["--to", "docs/decisions", "--title", "Decision log"],
        });
        assert.equal(titled.status, 2, titled.stdout + titled.stderr);
        assert.ok(!existsSync(join(repo, "docs")));
        assert.deepEqual(fake.posted, []);
      });

      it(
        "takes sync.sh's spelling of --to, and no --title",
        { skip: shell !== "pwsh" && "only PowerShell spells them differently" },
        async () => {
          const machine = computer(shell);
          const here = join(machine.home, "work");
          mkdirSync(here);
          const spelled = await run(shell, machine, {
            command: "export codex --to spelled",
            cwd: here,
          });
          assert.equal(spelled.status, 0, spelled.stdout + spelled.stderr);
          assert.ok(existsSync(join(here, "spelled", "export.json")));
          const wrong = await run(shell, machine, {
            command: "export codex --title x",
            cwd: here,
          });
          assert.equal(wrong.status, 2, wrong.stdout + wrong.stderr);
          assert.match(wrong.stderr, /Usage: sync\.ps1/);
        },
      );
    });
  }
});
