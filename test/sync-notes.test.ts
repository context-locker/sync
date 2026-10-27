// The sync scripts and a project's notes folder: notes come down as files,
// edits and new files go up, and nothing is written outside the folder.
// These run the real scripts against a fake API that keeps notes the way
// Context Locker does, rendering them with the real compilers.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
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
  parseNoteTarget,
  renderNoteFile,
  sha256,
  splitNoteFile,
  writeNoteReply,
  type Blob,
  type NoteInput,
} from "../src/index.js";

const SCRIPT = fileURLToPath(new URL("../scripts/sync.sh", import.meta.url));
const PS_SCRIPT = fileURLToPath(
  new URL("../scripts/sync.ps1", import.meta.url),
);
// The scripts that setup v3 installed, which know nothing of notes
const V3 = fileURLToPath(
  new URL("../setup/v3/", import.meta.url),
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

interface Upload {
  target: string;
  base: string | null;
  body: string;
}

/** Front matter as the canonical files write it: JSON values, or plain words */
function readFront(text: string): Record<string, unknown> {
  const values: Record<string, unknown> = {};
  for (const line of text.split("\n")) {
    const match = /^([a-z_]+):\s*(.*)$/.exec(line);
    if (!match) continue;
    const raw = (match[2] ?? "").trim();
    try {
      values[match[1] as string] = JSON.parse(raw);
    } catch {
      values[match[1] as string] = raw;
    }
  }
  return values;
}

/** A fake Context Locker that keeps a project's notes */
class FakeLocker {
  notes = new Map<string, NoteInput>();
  tags = ["release", "q4", "writing"];
  requests: string[] = [];
  uploads: Upload[] = [];
  /** Answers for uploads of these targets, instead of saving */
  refuse = new Map<
    string,
    { status: number; error: string; message: string }
  >();
  /** Sent in place of the project's manifest, with these blobs */
  override: { text: string; blobs: Map<string, Blob> } | null = null;
  /** Sent back for an upload instead of the saved file, to test the script's checks */
  replyOverride: ((upload: Upload) => Buffer) | null = null;
  /** The project's links to paths in its repo, as the manifest lists them */
  links: Array<{ id: string; path: string }> = [];
  blobs = new Map<string, Blob>();

  add(note: Partial<NoteInput> & { name: string }): NoteInput {
    const full: NoteInput = {
      id: randomUUID(),
      version: 1,
      title: note.name,
      kind: "plan",
      useAs: "source-of-truth",
      summary: `About ${note.name}.`,
      tags: ["release"],
      text: `# ${note.name}\n\nWhat it says.`,
      everywhere: false,
      ...note,
    };
    this.notes.set(full.id, full);
    return full;
  }

  manifest(harness: string, layer: "repo" | "personal"): string {
    if (this.override) {
      for (const [hash, blob] of this.override.blobs)
        this.blobs.set(hash, blob);
      return this.override.text;
    }
    const outputs = compile({
      harness: harness as "claude-code",
      project: { ...PROJECT, layer },
      preferences: [],
      skills: [],
      notes: [...this.notes.values()],
      tags: this.tags,
    }).outputs;
    const manifest = buildManifest({
      workspaceId: WORKSPACE,
      outputs,
      holds: [],
      links: this.links,
    });
    for (const [hash, blob] of manifest.blobs) this.blobs.set(hash, blob);
    return manifest.text;
  }

  /** The note's file as the folder should have it */
  file(note: NoteInput): string {
    return renderNoteFile(note, note.everywhere ? "everywhere" : PROJECT.name);
  }

  save(upload: Upload): { status: number; type: string; body: Buffer } {
    const json = (status: number, error: string, message: string) => ({
      status,
      type: "application/json",
      body: Buffer.from(JSON.stringify({ error, message })),
    });
    if (this.replyOverride) {
      return {
        status: 200,
        type: "text/plain; charset=utf-8",
        body: this.replyOverride(upload),
      };
    }
    const refusal = this.refuse.get(upload.target);
    if (refusal) return json(refusal.status, refusal.error, refusal.message);
    const target = parseNoteTarget(upload.target);
    if (!target) return json(400, "not_managed", "That isn't a note's file.");
    const split = splitNoteFile(upload.body);
    if (!split) return json(400, "invalid_note", "It needs front matter.");
    const front = readFront(split.frontMatter);
    if (!Array.isArray(front.tags)) {
      return json(400, "invalid_note", "tags is missing.");
    }
    const text = split.body.replace(/^(?:[ \t]*\n)+/, "").trimEnd();
    let note: NoteInput;
    let status: "saved" | "same" = "saved";
    if (upload.base) {
      const [id, version] = upload.base.split(" ");
      const current = this.notes.get(id ?? "");
      if (!current) return json(409, "gone", "Its note isn't here.");
      if (current.version !== Number(version)) {
        return json(409, "version_conflict", "It changed.");
      }
      const next = {
        ...current,
        title: String(front.title),
        kind: String(front.kind),
        useAs:
          front.use_as === undefined ? current.useAs : String(front.use_as),
        summary: String(front.summary),
        tags: front.tags as string[],
        text,
      };
      if (this.file(next) === this.file(current)) {
        status = "same";
        note = current;
      } else {
        note = { ...next, version: current.version + 1 };
      }
    } else {
      if (front.id !== undefined) {
        return json(
          400,
          "invalid_note",
          "id is for a note already in Context Locker.",
        );
      }
      note = {
        id: randomUUID(),
        version: 1,
        name: target.name,
        title: String(front.title),
        kind: String(front.kind),
        useAs: String(front.use_as ?? "source-of-truth"),
        summary: String(front.summary),
        tags: front.tags as string[],
        text,
        everywhere: target.everywhere,
      };
    }
    this.notes.set(note.id, note);
    const file = this.file(note);
    return {
      status: 200,
      type: "text/plain; charset=utf-8",
      body: writeNoteReply({
        status,
        id: note.id,
        version: note.version,
        hash: sha256(file),
        target: upload.target,
        file,
      }),
    };
  }
}

describe("a project's notes folder", () => {
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
          const project = url.searchParams.get("project");
          send(
            200,
            "text/plain",
            project
              ? fake.manifest(
                  String(request.headers["user-agent"]).match(
                    /\((\S+);/,
                  )?.[1] ?? "claude-code",
                  url.searchParams.get("layer") === "repo"
                    ? "repo"
                    : "personal",
                )
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
        } else if (url.pathname === "/v1/sync/notes") {
          const upload: Upload = {
            target: String(request.headers["context-locker-target"] ?? ""),
            base: request.headers["context-locker-base"]
              ? String(request.headers["context-locker-base"])
              : null,
            body: body.toString("utf8"),
          };
          fake.uploads.push(upload);
          const answer = fake.save(upload);
          send(answer.status, answer.type, answer.body);
        } else if (url.pathname === "/v1/sync/done") {
          send(200, "application/json", '{"status":"recorded"}');
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

  /** Connects another app on the computer */
  function connect(machine: { home: string }, harness: string) {
    mkdirSync(join(machine.home, ".contextlocker", harness), {
      recursive: true,
    });
    writeFileSync(
      join(machine.home, ".contextlocker", harness, "token"),
      "ctxl_at_test\n",
    );
  }

  function run(
    shell: string,
    machine: { home: string },
    options: {
      cwd?: string;
      args?: string[];
      harness?: string;
      v3?: boolean;
    } = {},
  ): Promise<{ status: number | null; stdout: string; stderr: string }> {
    const harness = options.harness ?? "claude-code";
    const args =
      shell === "pwsh"
        ? [
            "-NoProfile",
            "-NonInteractive",
            "-File",
            options.v3 ? join(V3, "sync.ps1") : PS_SCRIPT,
            harness,
            ...(options.args ?? []).map((arg) =>
              arg === "--project" ? "-Project" : arg,
            ),
          ]
        : [
            options.v3 ? join(V3, "sync.sh") : SCRIPT,
            harness,
            ...(options.args ?? []),
          ];
    return new Promise((resolve, reject) => {
      const child = spawn(shell, args, {
        cwd: options.cwd ?? join(machine.home, "repo"),
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

  /** Every file under a folder, leaving out the script's own state, PowerShell's cache and git's */
  function files(dir: string, prefix = ""): string[] {
    return readdirSync(join(dir, prefix), { withFileTypes: true })
      .flatMap((entry) => {
        const path = prefix ? `${prefix}/${entry.name}` : entry.name;
        if (
          path === ".contextlocker" ||
          path === ".cache" ||
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

  for (const shell of SHELLS) {
    describe(`in ${shell}`, () => {
      it("brings a project's notes and the ones for everywhere down, with the README", async () => {
        const machine = computer();
        const plan = fake.add({
          name: "release-plan",
          title: "Release plan",
          version: 3,
        });
        const voice = fake.add({
          name: "writing-voice",
          everywhere: true,
          kind: "profile",
        });

        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        assert.equal(first.stderr, "");
        assert.deepEqual(files(machine.home), [
          "repo/.context-locker/notes/.ctx-managed",
          "repo/.context-locker/notes/README.md",
          "repo/.context-locker/notes/everywhere/writing-voice.md",
          "repo/.context-locker/notes/release-plan.md",
          "repo/.contextlocker.json",
        ]);
        assert.equal(
          read(join(machine.notes, "release-plan.md")),
          fake.file(plan),
        );
        assert.equal(
          read(join(machine.notes, "everywhere", "writing-voice.md")),
          fake.file(voice),
        );
        assert.match(
          read(join(machine.notes, "README.md")),
          /^# Notes from Context Locker\n/,
        );
        assert.match(
          read(join(machine.notes, ".ctx-managed")),
          new RegExp(`^context-locker-notes 1 ${PROJECT.id}\n`),
        );
        // Nothing to send, so nothing went up
        assert.equal(fake.uploads.length, 0);

        // A note that changes in Context Locker comes down again, and one
        // that's retired goes, with a copy kept
        fake.notes.set(plan.id, {
          ...plan,
          version: 4,
          text: "# Release plan\n\nMoved to December.",
        });
        fake.notes.delete(voice.id);
        const second = await run(shell, machine);
        assert.equal(second.status, 0, second.stderr);
        assert.equal(second.stderr, "");
        assert.match(
          read(join(machine.notes, "release-plan.md")),
          /Moved to December\./,
        );
        assert.equal(
          existsSync(join(machine.notes, "everywhere", "writing-voice.md")),
          false,
        );
        assert.ok(
          backups(machine.home).some((path) =>
            path.endsWith(
              "project-.context-locker-notes-everywhere-writing-voice.md",
            ),
          ),
        );
        assert.equal(fake.uploads.length, 0);
      });

      it("mirrors the notes in a folder linked on this computer too", async () => {
        const machine = computer();
        fake.add({ name: "release-plan" });
        const theirs = join(machine.home, "theirs");
        mkdirSync(theirs);
        const result = await run(shell, machine, {
          cwd: theirs,
          args: ["--project", PROJECT.id],
        });
        assert.equal(result.status, 0, result.stderr);
        assert.ok(existsSync(join(theirs, NOTES, "release-plan.md")));
        assert.ok(existsSync(join(theirs, NOTES, "README.md")));
        // The repo's own files stay as they are
        assert.deepEqual(files(theirs), [
          ".context-locker/notes/.ctx-managed",
          ".context-locker/notes/README.md",
          ".context-locker/notes/release-plan.md",
        ]);
      });

      it("leaves the folder as it is in a sync that doesn't keep it, for the app that does", async () => {
        const machine = computer();
        connect(machine, "hermes");
        const plan = fake.add({ name: "release-plan", version: 2 });
        const theirs = join(machine.home, "theirs");
        mkdirSync(theirs);
        const notes = join(theirs, NOTES);
        // Claude Code keeps the notes folder in a folder linked on this computer
        const first = await run(shell, machine, {
          cwd: theirs,
          args: ["--project", PROJECT.id],
        });
        assert.equal(first.status, 0, first.stderr);
        const path = join(notes, "release-plan.md");
        const edited = read(path).replace("What it says.", "My edit.");
        writeFileSync(path, edited);
        writeFileSync(
          join(notes, "new-idea.md"),
          '---\ntitle: "New idea"\nkind: "idea"\nuse_as: "source-of-truth"\nsummary: "An idea."\ntags: ["release"]\napplies_to: "Docs site"\n---\n\nAn idea.\n',
        );
        writeFileSync(join(notes, "My idea.md"), "mine\n");
        const snapshot = () =>
          files(theirs).map((file) => [file, read(join(theirs, file))]);
        const before = snapshot();

        // Hermes keeps no notes folder outside a linked repo, and a Context
        // Locker that sends none keeps none: neither sends, writes or warns
        const hermes = await run(shell, machine, {
          cwd: theirs,
          harness: "hermes",
        });
        assert.equal(hermes.status, 0, hermes.stderr);
        assert.equal(hermes.stderr, "");
        fake.override = {
          text: `${MANIFEST_HEADER}\nworkspace ${WORKSPACE}\n`,
          blobs: new Map(),
        };
        const older = await run(shell, machine, { cwd: theirs });
        assert.equal(older.status, 0, older.stderr);
        assert.equal(older.stderr, "");
        assert.equal(fake.uploads.length, 0);
        assert.deepEqual(snapshot(), before);

        // So Claude Code's next sync still tells the edit from the note it wrote
        fake.override = null;
        const after = await run(shell, machine, { cwd: theirs });
        assert.equal(after.status, 0, after.stderr);
        assert.match(
          after.stderr,
          /left \.context-locker\/notes\/My idea\.md as it is/,
        );
        assert.deepEqual(
          fake.uploads.map((upload) => [upload.target, upload.base]),
          [
            [`{project}/${NOTES}/new-idea.md`, null],
            [`{project}/${NOTES}/release-plan.md`, `${plan.id} 2`],
          ],
        );
        assert.equal(fake.notes.get(plan.id)?.version, 3);
        assert.match(read(path), /My edit\./);
      });

      it("is skipped cleanly by the scripts setup v3 installed", async () => {
        const machine = computer();
        fake.add({ name: "release-plan" });
        fake.add({ name: "writing-voice", everywhere: true });
        // Nor do they check links, or say anything of a newer script
        fake.links = [{ id: randomUUID(), path: "docs/not here.md" }];
        assert.match(fake.manifest("claude-code", "repo"), /^note /m);
        assert.match(fake.manifest("claude-code", "repo"), /^link /m);
        const result = await run(shell, machine, { v3: true });
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stderr, "");
        assert.deepEqual(files(machine.repo), [".contextlocker.json"]);
        assert.equal(fake.uploads.length, 0);
      });

      it("saves an edit at once, and keeps the file as Context Locker has it", async () => {
        const machine = computer();
        const plan = fake.add({
          name: "release-plan",
          title: "Release plan",
          version: 3,
        });
        assert.equal((await run(shell, machine)).status, 0);
        const path = join(machine.notes, "release-plan.md");
        const edited = read(path).replace(
          "What it says.",
          "What it says, and when.",
        );
        writeFileSync(path, edited);

        const result = await run(shell, machine);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stderr, "");
        assert.equal(fake.uploads.length, 1);
        assert.equal(
          fake.uploads[0]?.target,
          `{project}/${NOTES}/release-plan.md`,
        );
        assert.equal(fake.uploads[0]?.base, `${plan.id} 3`);
        assert.equal(fake.uploads[0]?.body, edited);
        const saved = fake.notes.get(plan.id);
        assert.equal(saved?.version, 4);
        assert.equal(read(path), fake.file(saved as NoteInput));
        assert.match(read(path), /^version: 4$/m);
        // What was replaced is kept
        assert.ok(
          backups(machine.home).some((file) =>
            file.endsWith("notes-release-plan.md"),
          ),
        );

        // Nothing more to send
        const again = await run(shell, machine);
        assert.equal(again.status, 0, again.stderr);
        assert.equal(again.stderr, "");
        assert.equal(fake.uploads.length, 1);
      });

      it("saves a new file as a new note, named after the file", async () => {
        const machine = computer();
        assert.equal((await run(shell, machine)).status, 0);
        const body = [
          "---",
          'title: "Q4 launch"',
          'kind: "plan"',
          'use_as: "source-of-truth"',
          'summary: "What launches in Q4."',
          'tags: ["release"]',
          'applies_to: "Docs site"',
          "---",
          "",
          "Search, then the theme.",
          "",
        ].join("\n");
        writeFileSync(join(machine.notes, "q4-launch.md"), body);
        mkdirSync(join(machine.notes, "everywhere"), { recursive: true });
        writeFileSync(
          join(machine.notes, "everywhere", "house-style.md"),
          body
            .replace("Docs site", "everywhere")
            .replace("Q4 launch", "House style"),
        );

        const result = await run(shell, machine);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stderr, "");
        assert.deepEqual(
          fake.uploads.map((upload) => [upload.target, upload.base]),
          [
            [`{project}/${NOTES}/everywhere/house-style.md`, null],
            [`{project}/${NOTES}/q4-launch.md`, null],
          ],
        );
        const added = [...fake.notes.values()].find(
          (note) => note.name === "q4-launch",
        );
        assert.ok(added);
        assert.equal(
          read(join(machine.notes, "q4-launch.md")),
          fake.file(added),
        );
        assert.match(
          read(join(machine.notes, "q4-launch.md")),
          /^version: 1$/m,
        );
        const style = [...fake.notes.values()].find(
          (note) => note.name === "house-style",
        );
        assert.equal(style?.everywhere, true);

        const again = await run(shell, machine);
        assert.equal(again.status, 0, again.stderr);
        assert.equal(fake.uploads.length, 2);
      });

      it("prints a refusal, keeps the file and tries again at the next sync", async () => {
        const machine = computer();
        assert.equal((await run(shell, machine)).status, 0);
        const path = join(machine.notes, "half-done.md");
        writeFileSync(
          path,
          '---\ntitle: "Half done"\n---\n\nNo summary yet.\n',
        );
        fake.refuse.set(`{project}/${NOTES}/half-done.md`, {
          status: 400,
          error: "invalid_note",
          message: "kind, summary, tags and applies_to are missing.",
        });

        const first = await run(shell, machine);
        assert.equal(first.status, 0);
        assert.equal(
          first.stderr,
          `Context Locker: couldn't save ${NOTES}/half-done.md: kind, summary, tags and applies_to are missing.\n`,
        );
        assert.equal(
          read(path),
          '---\ntitle: "Half done"\n---\n\nNo summary yet.\n',
        );

        const second = await run(shell, machine);
        assert.equal(fake.uploads.length, 2);
        assert.match(
          second.stderr,
          /couldn't save .+half-done\.md: kind, summary/,
        );
        assert.equal(
          read(path),
          '---\ntitle: "Half done"\n---\n\nNo summary yet.\n',
        );
      });

      it("keeps an edit beside the note when the note changed in Context Locker too, in the same part", async () => {
        const machine = computer();
        const plan = fake.add({ name: "release-plan", version: 2 });
        assert.equal((await run(shell, machine)).status, 0);
        const path = join(machine.notes, "release-plan.md");
        const edited = read(path).replace("What it says.", "My edit.");
        writeFileSync(path, edited);
        fake.notes.set(plan.id, {
          ...plan,
          version: 3,
          text: "Changed in Context Locker.",
        });

        const result = await run(shell, machine);
        assert.equal(result.status, 0);
        assert.equal(
          result.stderr,
          `Context Locker: ${NOTES}/release-plan.md changed in Context Locker too, in the same part as your edit, so the note has the newer version now. Your edit is kept in ${NOTES}/release-plan.md.conflict.\n`,
        );
        // The newer version takes the note's place, and the edit is kept
        // beside it, and in the backups
        assert.match(read(path), /Changed in Context Locker\./);
        assert.equal(read(`${path}.conflict`), edited);
        const context = JSON.parse(result.stdout).hookSpecificOutput
          .additionalContext as string;
        assert.ok(
          context
            .trimEnd()
            .endsWith(
              `\nContext Locker: your edit to ${NOTES}/release-plan.md and a change made in Context Locker since touch the same part, so the note has the newer version now, and your edit is kept beside it in ${NOTES}/release-plan.md.conflict. Put the two together in the note, and the next sync saves it.`,
            ),
          context,
        );

        // The copy never goes up, and stays until it's dealt with
        const sent = fake.uploads.length;
        const after = await run(shell, machine);
        assert.equal(after.status, 0, after.stderr);
        assert.equal(after.stderr, "");
        assert.equal(fake.uploads.length, sent);
        assert.equal(read(`${path}.conflict`), edited);
        assert.match(read(path), /Changed in Context Locker\./);
      });

      it("brings a deleted file back, and never retires its note", async () => {
        const machine = computer();
        const plan = fake.add({ name: "release-plan" });
        assert.equal((await run(shell, machine)).status, 0);
        rmSync(join(machine.notes, "release-plan.md"));
        rmSync(join(machine.notes, "README.md"));
        const result = await run(shell, machine);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stderr, "");
        assert.equal(
          read(join(machine.notes, "release-plan.md")),
          fake.file(plan),
        );
        assert.ok(existsSync(join(machine.notes, "README.md")));
        assert.equal(fake.uploads.length, 0);
        assert.ok(fake.notes.has(plan.id));
      });

      it("sends 20 files a sync at most, and the rest at the next one", async () => {
        const machine = computer();
        assert.equal((await run(shell, machine)).status, 0);
        for (let index = 1; index <= 23; index += 1) {
          writeFileSync(
            join(machine.notes, `note-${String(index).padStart(2, "0")}.md`),
            `---\ntitle: "Note ${index}"\nkind: "idea"\nuse_as: "source-of-truth"\nsummary: "Idea ${index}."\ntags: ["release"]\napplies_to: "Docs site"\n---\n\nIdea ${index}.\n`,
          );
        }
        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        assert.equal(fake.uploads.length, 20);
        assert.equal(
          first.stderr,
          `Context Locker: 3 more files in ${NOTES} wait for the next sync, which saves up to 20.\n`,
        );
        const second = await run(shell, machine);
        assert.equal(second.status, 0, second.stderr);
        assert.equal(second.stderr, "");
        assert.equal(fake.uploads.length, 23);
        assert.deepEqual(
          fake.uploads.slice(20).map((upload) => upload.target),
          ["note-21", "note-22", "note-23"].map(
            (name) => `{project}/${NOTES}/${name}.md`,
          ),
        );
      });

      it("refuses a file over 512 KB before sending it, and one named as no note's file is", async () => {
        const machine = computer();
        assert.equal((await run(shell, machine)).status, 0);
        const big = join(machine.notes, "big.md");
        writeFileSync(
          big,
          `---\ntitle: "Big"\n---\n\n${"x".repeat(525_000)}\n`,
        );
        writeFileSync(
          join(machine.notes, "My Plan.md"),
          '---\ntitle: "Mine"\n---\n',
        );
        writeFileSync(
          join(machine.notes, "con.md"),
          '---\ntitle: "Con"\n---\n',
        );
        const result = await run(shell, machine);
        assert.equal(result.status, 0);
        assert.equal(fake.uploads.length, 0);
        assert.match(
          result.stderr,
          new RegExp(
            `couldn't save ${NOTES}/big\\.md: it's 513 KB, and a note can hold at most 512 KB\\.`,
          ),
        );
        assert.match(
          result.stderr,
          /left \.context-locker\/notes\/My Plan\.md as it is: a note's file is named with lowercase letters/,
        );
        assert.match(
          result.stderr,
          /left \.context-locker\/notes\/con\.md as it is/,
        );
        assert.ok(
          existsSync(big) && existsSync(join(machine.notes, "My Plan.md")),
        );
      });

      it(
        "keeps the folder out of git through .git/info/exclude, once, and only in a git work tree",
        { skip: !HAVE_GIT && "git isn't installed" },
        async () => {
          const plain = computer();
          fake.add({ name: "release-plan" });
          assert.equal((await run(shell, plain)).status, 0);
          assert.equal(existsSync(join(plain.repo, ".git")), false);

          const machine = computer({ git: true });
          fake.add({ name: "release-plan" });
          const exclude = join(machine.repo, ".git", "info", "exclude");
          const before = read(exclude);
          const first = await run(shell, machine);
          assert.equal(first.status, 0, first.stderr);
          assert.equal(
            read(exclude),
            `${before.replace(/\n?$/, "\n")}.context-locker/\n`,
          );
          // Git leaves the folder out, and nothing it tracks changed
          const status = spawnSync(
            "git",
            ["-C", machine.repo, "status", "--porcelain"],
            {
              encoding: "utf8",
            },
          ).stdout;
          assert.equal(status, "?? .contextlocker.json\n");

          fake.add({ name: "another-plan" });
          const second = await run(shell, machine);
          assert.equal(second.status, 0, second.stderr);
          assert.equal(
            read(exclude)
              .split("\n")
              .filter((line) => line === ".context-locker/").length,
            1,
          );
          assert.equal(existsSync(join(machine.repo, ".gitignore")), false);

          // Never through a link
          const linked = computer({ git: true });
          fake.add({ name: "release-plan" });
          const outside = join(linked.home, "outside.txt");
          writeFileSync(outside, "keep me\n");
          const info = join(linked.repo, ".git", "info");
          rmSync(join(info, "exclude"));
          symlinkSync(outside, join(info, "exclude"));
          const result = await run(shell, linked);
          assert.equal(result.status, 0);
          assert.equal(read(outside), "keep me\n");
          assert.ok(lstatSync(join(info, "exclude")).isSymbolicLink());
          assert.match(result.stderr, /exclude alone: it's a link or in one/);
        },
      );

      it("writes nothing outside the notes folder, whatever the manifest or the answers say", async () => {
        const machine = computer();
        const text = '---\ntitle: "x"\n---\n\nx\n';
        const hash = sha256(text);
        const id = randomUUID();
        fake.override = {
          text: [
            MANIFEST_HEADER,
            `workspace ${WORKSPACE}`,
            `note ${hash} {project}/.context-locker/notes/../escape.md ${id} 1`,
            `note ${hash} {project}/.context-locker/notes/deep/x.md ${id} 1`,
            `note ${hash} {project}/.context-locker/x.md ${id} 1`,
            `note ${hash} {project}/AGENTS.md ${id} 1`,
            `note ${hash} {claude}/rules/note.md ${id} 1`,
            `note ${hash} {project}/.context-locker/notes/con.md ${id} 1`,
            `note ${hash} {project}/.context-locker/notes/Bad_Name.md ${id} 1`,
            `note ${hash} {project}/.context-locker/notes/readme.md ${id} 1`,
            `file ${hash} {project}/.context-locker/notes/other.md`,
            `file ${hash} {project}/.context-locker/notes/README.md`,
            `note ${hash} {project}/.context-locker/notes/fine.md ${id} 1`,
            "",
          ].join("\n"),
          blobs: new Map([[hash, { kind: "file", bytes: Buffer.from(text) }]]),
        };
        const first = await run(shell, machine);
        assert.equal(first.status, 0, first.stderr);
        assert.deepEqual(files(machine.home), [
          "repo/.context-locker/notes/.ctx-managed",
          "repo/.context-locker/notes/README.md",
          "repo/.context-locker/notes/fine.md",
          "repo/.contextlocker.json",
        ]);
        assert.equal(
          (
            first.stderr.match(/isn't a file claude-code's sync may write/g) ??
            []
          ).length,
          9,
        );

        // An answer that names another file is never written there
        writeFileSync(join(machine.notes, "new-one.md"), text);
        fake.override = null;
        fake.replyOverride = () =>
          writeNoteReply({
            status: "saved",
            id,
            version: 1,
            hash: sha256("---\nescaped\n---\n"),
            target: "{project}/.context-locker/notes/../../escape.md",
            file: "---\nescaped\n---\n",
          });
        const answered = await run(shell, machine);
        assert.equal(answered.status, 0);
        assert.match(
          answered.stderr,
          /couldn't make sense of Context Locker's answer for \.context-locker\/notes\/new-one\.md/,
        );
        assert.equal(read(join(machine.notes, "new-one.md")), text);
        assert.equal(existsSync(join(machine.home, "escape.md")), false);

        // A folder in the way that's a link is never written through
        fake.replyOverride = null;
        const linked = computer();
        fake.add({ name: "release-plan" });
        const elsewhere = join(linked.home, "elsewhere");
        mkdirSync(elsewhere);
        symlinkSync(elsewhere, join(linked.repo, ".context-locker"));
        const result = await run(shell, linked);
        assert.equal(result.status, 0);
        assert.deepEqual(readdirSync(elsewhere), []);
        assert.match(
          result.stderr,
          /\.context-locker alone: part of its path is a link/,
        );

        // Nor is a note's file that's a link
        const filed = computer();
        fake.add({ name: "release-plan" });
        mkdirSync(filed.notes, { recursive: true });
        const target = join(filed.home, "target.md");
        writeFileSync(target, "mine\n");
        symlinkSync(target, join(filed.notes, "release-plan.md"));
        const link = await run(shell, filed);
        assert.equal(link.status, 0);
        assert.equal(read(target), "mine\n");
        assert.match(link.stderr, /release-plan\.md alone: it's a link/);
        assert.equal(fake.uploads.length, 0);
      });
    });
  }
});
