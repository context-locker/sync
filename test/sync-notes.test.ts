// The sync scripts and what an earlier script left in a project's notes
// folder (CLK-423): a computer keeps no copies of notes, so a project's sync
// takes out each copy still as a sync wrote it, and the README, after a copy
// goes in the backups, and names every file that holds what Context Locker
// doesn't have. These run the real scripts against a fake API.
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
  renderNoteFile,
  sha256,
  type Blob,
} from "../src/index.js";
import { SCRIPT_PATH } from "./script-path.js";

const SCRIPT = fileURLToPath(new URL("../scripts/sync.sh", import.meta.url));
const PS_SCRIPT = fileURLToPath(
  new URL("../scripts/sync.ps1", import.meta.url),
);
const WORKSPACE = "6f1d2c4e-8a3b-4c5d-9e7f-0a1b2c3d4e5f";
const PROJECT = {
  id: "55555555-5555-4555-8555-555555555555",
  name: "Docs site",
};
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash", "pwsh"].filter(
  (shell) =>
    spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0 &&
    (!ONLY || ONLY.includes(shell)),
);
const HAVE_GIT = spawnSync("sh", ["-c", "command -v git"]).status === 0;

const NOTES = ".context-locker/notes";
const TARGET = `{project}/${NOTES}`;

/** A note's file as a sync before script 53 wrote it */
function noteFile(name: string, version: number, everywhere = false) {
  const id = randomUUID();
  return {
    id,
    version,
    text: renderNoteFile(
      {
        id,
        version,
        title: name,
        kind: "plan",
        useAs: "source-of-truth",
        summary: `About ${name}.`,
        tags: ["release"],
        text: `# ${name}\n\nWhat it says.`,
      },
      everywhere ? "everywhere" : PROJECT.name,
    ),
  };
}

/** The README a sync before script 53 wrote */
const README =
  "# Notes from Context Locker\n\nThis folder holds the notes for Docs site from Context Locker.\n";

/** A fake Context Locker that sends a project's manifest, and no notes */
class FakeLocker {
  requests: string[] = [];
  /** Sent in place of the project's manifest, with these blobs */
  override: { text: string; blobs: Map<string, Blob> } | null = null;
  blobs = new Map<string, Blob>();

  manifest(): string {
    if (this.override) {
      for (const [hash, blob] of this.override.blobs)
        this.blobs.set(hash, blob);
      return this.override.text;
    }
    return buildManifest({
      workspaceId: WORKSPACE,
      outputs: [],
      holds: [],
      projectGeneration: 1,
    }).text;
  }
}

describe("what an earlier script left in a project's notes folder", () => {
  let server: Server;
  let baseUrl: string;
  let fake = new FakeLocker();
  const work = mkdtempSync(join(tmpdir(), "ctx-notes-"));

  before(async () => {
    server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        const url = new URL(request.url ?? "/", "http://fake");
        fake.requests.push(`${request.method} ${url.pathname}`);
        const body = Buffer.concat(chunks);
        const send = (status: number, type: string, data: Buffer | string) => {
          response.writeHead(status, { "content-type": type });
          response.end(data);
        };
        if (url.pathname === "/v1/sync") {
          send(
            200,
            "text/plain",
            url.searchParams.get("project")
              ? fake.manifest()
              : `${MANIFEST_HEADER}\nworkspace ${WORKSPACE}\nscript ${SYNC_SCRIPT_VERSION}\n`,
          );
        } else if (url.pathname === "/v1/sync/blobs") {
          const wanted = body.toString("utf8").split("\n").filter(Boolean);
          const blobs: Array<[string, Blob]> = [];
          for (const hash of wanted) {
            const blob = fake.blobs.get(hash);
            if (!blob) {
              send(409, "application/json", '{"error":"changed"}');
              return;
            }
            blobs.push([hash, blob]);
          }
          send(200, "application/x-tar", blobArchive(blobs, 0));
        } else if (url.pathname === "/v1/sync/done") {
          send(200, "application/json", '{"status":"recorded"}');
        } else if (url.pathname === "/v1/sync/repo") {
          // A project with no repository, which --project links (CLK-420)
          send(200, "application/json", '{"repo":false,"git_remote":null}');
        } else {
          send(404, "application/json", '{"error":"not_found"}');
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

  /** A computer with Claude Code connected, and a repo linked to the project */
  function computer(options: { git?: boolean } = {}) {
    fake = new FakeLocker();
    const home = mkdtempSync(join(work, "home-"));
    mkdirSync(join(home, ".contextlocker", "claude-code"), { recursive: true });
    writeFileSync(join(home, ".contextlocker", "config"), `api=${baseUrl}\n`);
    writeFileSync(
      join(home, ".contextlocker", "claude-code", "token"),
      "ctxl_at_test\n",
    );
    const repo = join(home, "repo");
    mkdirSync(repo);
    writeFileSync(
      join(repo, ".contextlocker.json"),
      JSON.stringify({ workspace: WORKSPACE, project: PROJECT.id }),
    );
    if (options.git) {
      spawnSync("git", ["init", "-q", repo]);
    }
    return { home, repo, notes: join(repo, NOTES) };
  }

  /**
   * The notes folder as script 52 left it: copies still as it wrote them,
   * the README, and its list, with a copy changed here, a new file, an edit
   * kept beside a note, and a file named as no note's file is
   */
  function oldFolder(notes: string, records = true) {
    mkdirSync(join(notes, "everywhere"), { recursive: true });
    const plan = noteFile("release-plan", 3);
    const voice = noteFile("writing-voice", 1, true);
    const decision = noteFile("decision", 2);
    writeFileSync(join(notes, "README.md"), README);
    writeFileSync(join(notes, "release-plan.md"), plan.text);
    writeFileSync(join(notes, "everywhere", "writing-voice.md"), voice.text);
    writeFileSync(
      join(notes, "decision.md"),
      decision.text.replace("What it says.", "My edit."),
    );
    writeFileSync(join(notes, "decision.md.conflict"), "An edit kept.\n");
    writeFileSync(join(notes, "new-idea.md"), "---\ntitle: x\n---\n\nIdea.\n");
    writeFileSync(join(notes, "My idea.md"), "mine\n");
    if (records) {
      writeFileSync(
        join(notes, ".ctx-managed"),
        [
          `context-locker-notes 1 ${PROJECT.id}`,
          "# What Context Locker last wrote in this folder.",
          `wrote file ${sha256(README)} ${TARGET}/README.md - -`,
          `wrote note ${sha256(plan.text)} ${TARGET}/release-plan.md ${plan.id} 3`,
          `wrote note ${sha256(voice.text)} ${TARGET}/everywhere/writing-voice.md ${voice.id} 1`,
          `wrote note ${sha256(decision.text)} ${TARGET}/decision.md ${decision.id} 2`,
          `refused ${sha256("x")} ${TARGET}/new-idea.md`,
          "",
        ].join("\n"),
      );
    }
  }

  function run(
    shell: string,
    machine: { home: string },
    words: string[] = ["claude-code"],
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const args =
      shell === "pwsh"
        ? [
            "-NoProfile",
            "-NonInteractive",
            "-File",
            PS_SCRIPT,
            ...words.map((word) => (word === "--yes" ? "-Yes" : word)),
          ]
        : [SCRIPT, ...words];
    return new Promise((resolve, reject) => {
      const child = spawn(shell, args, {
        cwd: join(machine.home, "repo"),
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

  /** What the session start says, from Claude Code's hook output */
  function sessionStart(stdout: string): string {
    const line = stdout.trim().split("\n").at(-1) ?? "";
    if (!line.startsWith("{")) return "";
    return String(
      (JSON.parse(line) as { hookSpecificOutput?: Record<string, unknown> })
        .hookSpecificOutput?.additionalContext ?? "",
    );
  }

  /** Every file under a folder, leaving out the script's own state, PowerShell's cache and git's */
  function files(dir: string, prefix = ""): string[] {
    return readdirSync(join(dir, prefix), { withFileTypes: true })
      .flatMap((entry) => {
        const path = prefix ? `${prefix}/${entry.name}` : entry.name;
        if (
          path === ".contextlocker" ||
          path === ".cache" ||
          path === ".git" ||
          path.endsWith("/.git")
        ) {
          return [];
        }
        return entry.isDirectory() && !entry.isSymbolicLink()
          ? files(dir, path)
          : [path];
      })
      .sort();
  }

  const read = (path: string) => readFileSync(path, "utf8");

  const backups = (home: string): string[] => {
    const root = join(home, ".contextlocker", "backups");
    return existsSync(root) ? files(root) : [];
  };

  /** The line that names what's left, in the session start and the warnings */
  const NAMED =
    /4 files in \S+\/\.context-locker\/notes hold what Context Locker doesn't have, and no sync reads them: My idea\.md, decision\.md, decision\.md\.conflict, new-idea\.md\. Save what's needed with `[^`]+ notes claude-code write`, then delete each\./;

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("takes out the copies still as a sync wrote them and the README, once, and names the files that hold what Context Locker doesn't have", async () => {
        const machine = computer({ git: HAVE_GIT });
        oldFolder(machine.notes);

        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        assert.deepEqual(files(machine.repo), [
          ".context-locker/notes/My idea.md",
          ".context-locker/notes/decision.md",
          ".context-locker/notes/decision.md.conflict",
          ".context-locker/notes/new-idea.md",
          ".context-locker/project-generation",
          ".contextlocker.json",
        ]);
        // Each copy that went is in the backups
        for (const name of [
          "README.md",
          "release-plan.md",
          "everywhere-writing-voice.md",
        ]) {
          assert.ok(
            backups(machine.home).some((path) =>
              path.endsWith(`project-.context-locker-notes-${name}`),
            ),
            name,
          );
        }
        assert.match(read(join(machine.notes, "decision.md")), /My edit\./);
        // Named for the agent at the start of the session, and for the
        // person once, as the copies go
        assert.match(sessionStart(first.stdout), NAMED);
        assert.match(first.stderr, NAMED);
        // Nothing went up or came down for notes
        assert.ok(!fake.requests.some((r) => r.includes("/v1/sync/notes")));
        // .context-locker/ stays out of git, as the project's generation is there
        if (HAVE_GIT) {
          assert.match(
            read(join(machine.repo, ".git", "info", "exclude")),
            /^\.context-locker\/$/m,
          );
        }

        // Each sync after names what's left at the start of the session,
        // and takes nothing more out
        const second = await run(shell, machine);
        assert.equal(second.status, 0, second.stderr);
        assert.equal(second.stderr, "");
        assert.match(sessionStart(second.stdout), NAMED);
        assert.equal(files(machine.repo).length, 6);

        // Once the person saved and deleted them, the folder goes, and
        // nothing more is said
        for (const name of [
          "My idea.md",
          "decision.md",
          "decision.md.conflict",
          "new-idea.md",
        ]) {
          rmSync(join(machine.notes, name));
        }
        const third = await run(shell, machine);
        assert.equal(third.status, 0, third.stderr);
        assert.equal(third.stderr, "");
        assert.doesNotMatch(third.stdout, /what Context Locker doesn't have/);
        assert.deepEqual(files(machine.repo), [
          ".context-locker/project-generation",
          ".contextlocker.json",
        ]);
      });

      it("takes out the README a sync wrote, and names every other file, when the folder's list is gone", async () => {
        const machine = computer();
        oldFolder(machine.notes, false);
        const result = await run(shell, machine);
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual(files(machine.notes), [
          "My idea.md",
          "decision.md",
          "decision.md.conflict",
          "everywhere/writing-voice.md",
          "new-idea.md",
          "release-plan.md",
        ]);
        assert.match(
          sessionStart(result.stdout),
          /6 files in \S+\/\.context-locker\/notes hold what Context Locker doesn't have, and no sync reads them: My idea\.md, decision\.md, decision\.md\.conflict, everywhere\/writing-voice\.md, new-idea\.md and 1 more\./,
        );
      });

      it("names what the next sync takes out and what stays in the doctor, and remove takes the copies out as the sync does", async () => {
        const machine = computer();
        // A sync first, so the folder is linked and the project has its lock
        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        oldFolder(machine.notes);

        const doctor = await run(shell, machine, ["doctor", "claude-code"]);
        assert.match(
          doctor.stdout,
          /WARN {2}\S+\/\.context-locker\/notes holds 3 copies of notes that the next sync in this project takes out\. Read notes with `[^`]+ notes claude-code read`\./,
        );
        assert.match(doctor.stdout, new RegExp(`WARN {2}${NAMED.source}`));

        const listed = await run(shell, machine, ["remove", "claude-code"]);
        assert.equal(listed.status, 0, listed.stdout + listed.stderr);
        assert.match(
          listed.stdout,
          /takes out:\n(- .*\n)*- 3 copies of notes in \S+\/\.context-locker\/notes\n/,
        );
        assert.match(
          listed.stdout,
          new RegExp(`It leaves:\\n- ${NAMED.source}`),
        );
        assert.ok(existsSync(join(machine.notes, "release-plan.md")));

        const removed = await run(shell, machine, [
          "remove",
          "claude-code",
          "--yes",
        ]);
        assert.equal(removed.status, 0, removed.stdout + removed.stderr);
        assert.deepEqual(files(machine.notes), [
          "My idea.md",
          "decision.md",
          "decision.md.conflict",
          "new-idea.md",
        ]);
        assert.match(
          removed.stdout,
          new RegExp(`It left:\\n- ${NAMED.source}`),
        );
      });

      it("writes no note, whatever an older manifest lists, and follows no link", async () => {
        const machine = computer();
        const text = '---\ntitle: "x"\n---\n\nx\n';
        const hash = sha256(text);
        const id = randomUUID();
        fake.override = {
          text: [
            MANIFEST_HEADER,
            `workspace ${WORKSPACE}`,
            `file ${hash} ${TARGET}/README.md`,
            `note ${hash} ${TARGET}/release-plan.md ${id} 1`,
            `note ${hash} ${TARGET}/everywhere/voice.md ${id} 1`,
            "",
          ].join("\n"),
          blobs: new Map([[hash, { kind: "file", bytes: Buffer.from(text) }]]),
        };
        const older = await run(shell, machine);
        assert.equal(older.status, 0, older.stderr);
        assert.equal(older.stderr, "");
        assert.deepEqual(files(machine.repo), [".contextlocker.json"]);

        // What a sync left behind a link stays as it is
        const linked = computer();
        fake.override = {
          text: `${MANIFEST_HEADER}\nworkspace ${WORKSPACE}\n`,
          blobs: new Map(),
        };
        const elsewhere = join(linked.home, "elsewhere");
        oldFolder(join(elsewhere, "notes"));
        const before = files(elsewhere);
        symlinkSync(elsewhere, join(linked.repo, ".context-locker"));
        const result = await run(shell, linked);
        assert.equal(result.status, 0, result.stderr);
        assert.deepEqual(files(elsewhere), before);
        assert.deepEqual(backups(linked.home), []);
      });
    });
  }
});
