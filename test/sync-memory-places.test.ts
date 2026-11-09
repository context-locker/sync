// The sync scripts keep their own copy of where each app keeps its own
// memory (G1-299), which must stay the same as MEMORY_PLACES: the same
// places, the same endings, and the same targets in them as memoryPlaceOf
// finds. A file that holds Context Locker's block too syncs only the text
// outside it, which both scripts read and write back the same way: the
// memory text of a file rebuilt from a text is that text again, byte for
// byte, and the block stays as it was.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, describe, it } from "node:test";

import {
  BLOCK_END,
  BLOCK_START,
  MEMORY_FILE_ENDINGS,
  MEMORY_PLACES,
  memoryPlaceOf,
} from "../src/index.js";
import type { CompiledHarness } from "../src/types.js";
import { SCRIPT_PATH } from "./script-path.js";

const SCRIPT = readFileSync(
  fileURLToPath(new URL("../scripts/sync.sh", import.meta.url)),
  "utf8",
);
const PS_SCRIPT = readFileSync(
  fileURLToPath(new URL("../scripts/sync.ps1", import.meta.url)),
  "utf8",
);
const have = (shell: string) =>
  spawnSync("sh", ["-c", `command -v ${shell}`]).status === 0;
// SYNC_TEST_SHELLS=dash,pwsh runs only those, while working on the scripts
const ONLY = process.env.SYNC_TEST_SHELLS?.split(",");
const SHELLS = ["dash", "bash"].filter(
  (shell) => have(shell) && (!ONLY || ONLY.includes(shell)),
);
const PWSH = have("pwsh") && (!ONLY || ONLY.includes("pwsh"));
const HARNESSES = Object.keys(MEMORY_PLACES) as CompiledHarness[];

/** MEMORY_PLACES as the scripts write it: the app, how, and where, a line each */
function placesText(): string {
  return HARNESSES.flatMap((harness) =>
    MEMORY_PLACES[harness].map(
      (place) =>
        `${harness} ${place.depth ?? (place.outsideBlock ? "outside" : "file")} ${place.path}`,
    ),
  ).join("\n");
}

/** What a script holds between two patterns, which must be there once */
function between(text: string, pattern: RegExp): string {
  const found = [...text.matchAll(pattern)];
  assert.equal(found.length, 1, `${pattern} once`);
  return found[0]![1]!;
}

/** A shell function from sync.sh, on one line or many, as it's written there */
function shFunction(name: string): string {
  const oneLine = `^(${name}\\(\\) \\{ .* \\})$`;
  if (new RegExp(oneLine, "m").test(SCRIPT))
    return between(SCRIPT, new RegExp(oneLine, "gm"));
  return between(
    SCRIPT,
    new RegExp(`^(${name}\\(\\) \\{\\n[\\s\\S]*?^\\})$`, "gm"),
  );
}

/** A function from sync.ps1, as it's written there */
function psFunction(name: string): string {
  return between(
    PS_SCRIPT,
    new RegExp(`^(function ${name}\\b[\\s\\S]*?^\\})$`, "gm"),
  );
}

/** A line of sync.ps1 that sets a variable, as it's written there */
function psLine(name: string): string {
  return between(PS_SCRIPT, new RegExp(`^(\\$${name} = .*)$`, "gm"));
}

const SH_PLACES = between(SCRIPT, /^MEMORY_PLACES='([^']*)'$/gm);
const SH_ENDINGS = between(SCRIPT, /^MEMORY_ENDINGS='([^']*)'$/gm);
const SH_AWK = between(SCRIPT, /^MEMORY_AWK='([^']*)'$/gm);
const PS_PLACES = between(PS_SCRIPT, /^\$MemoryPlaces = @'\n([\s\S]*?)\n'@$/gm);
const PS_ENDINGS = between(PS_SCRIPT, /^\$MemoryEndings = '([^']*)'$/gm);

// Targets in and out of each app's memory places, by memoryPlaceOf
const TARGETS = [
  "{claude}/projects/-home-mia-site/memory/MEMORY.md",
  "{claude}/projects/-home-mia-site/memory/people/mia.md",
  "{claude}/projects/x/memory/a/b/notes.TXT",
  "{claude}/projects/x/memory/a/b/c/deep.md",
  "{claude}/projects/x/memory/.hidden.md",
  "{claude}/projects/x/memory/picture.png",
  "{claude}/projects/x/memory/MEMORY.md.conflict",
  "{claude}/projects/x/memory",
  "{claude}/projects/memory/x.md",
  "{claude}/rules/context-locker.md",
  "{claude}/CLAUDE.md",
  "{codex}/memories/notes.md",
  "{codex}/memories/people/mia.Markdown",
  "{codex}/memories/a/b/c.mdx",
  "{codex}/memories/a/b/c/d.mdc",
  "{codex}/memories/_private.md",
  "{codex}/memories/-dash.md",
  "{codex}/AGENTS.md",
  "{hermes}/SOUL.md",
  "{hermes}/USER.md",
  "{hermes}/MEMORY.md",
  "{hermes}/memories/MEMORY.md",
  "{hermes}/memories/old/MEMORY.md",
  "{hermes}/SOUL.md/x.md",
  "{openclaw}/AGENTS.md",
  "{openclaw}/SOUL.md",
  "{openclaw}/IDENTITY.md",
  "{openclaw}/USER.md",
  "{openclaw}/MEMORY.md",
  "{openclaw}/memory/2026-11-09.md",
  "{openclaw}/HEARTBEAT.md",
  "{project}/AGENTS.md",
  "{claude}//x.md",
  "claude/projects/x/memory/a.md",
  "{Claude}/projects/x/memory/a.md",
  // As long as a note's path may be, and a character longer
  `{codex}/memories/${"a".repeat(512 - "{codex}/memories/.md".length)}.md`,
  `{codex}/memories/${"a".repeat(513 - "{codex}/memories/.md".length)}.md`,
];

function expected(harness: CompiledHarness): string {
  return TARGETS.map((target) => {
    const place = memoryPlaceOf(harness, target);
    return `${target}\t${place ? (place.outsideBlock ? "outside" : "file") : ""}`;
  }).join("\n");
}

// Files that hold Context Locker's block, or don't, and the memory texts
// that go in their place: each line keeps its carriage return, if it has one
const BLOCK = `${BLOCK_START}\n- plain-words: Use plain words.\n${BLOCK_END}\n`;
const FILES = [
  BLOCK,
  `# Soul\n\nCalm.\n\n${BLOCK}`,
  `${BLOCK}\nAfter the block.\n`,
  `Before.\n${BLOCK}After.\n`,
  `\n\n${BLOCK}\n\n`,
  "Before.\r\n\r\n<!-- context-locker:start v2 -->\r\n- a: b\r\n<!-- context-locker:end -->\r\n\r\nAfter.\r\n",
  "No block at all.\n",
  "No block, and no newline at the end",
  "",
  `Before.\n\n${BLOCK.trimEnd()}`,
];
const TEXTS = [
  "",
  "One line.\n",
  "Two lines,\n\n",
  "\n",
  "\n\nAfter blank lines.\n",
  "Windows\r\nlines\r\n",
  "  \n",
  "Text\n \n",
  "Café, naïve and 日本語.\n",
];

describe("an app's own memory places in the sync scripts (G1-299)", () => {
  const work = mkdtempSync(join(tmpdir(), "ctx-memory-places-"));
  after(() => rmSync(work, { recursive: true, force: true }));

  it("lists each app's memory places and endings as MEMORY_PLACES does", () => {
    assert.equal(SH_PLACES, placesText());
    assert.equal(PS_PLACES.replace(/\r/g, ""), placesText());
    assert.equal(SH_ENDINGS, MEMORY_FILE_ENDINGS.join(" "));
    assert.equal(PS_ENDINGS, MEMORY_FILE_ENDINGS.join(" "));
  });

  it("finds the same targets in them as memoryPlaceOf, in awk", () => {
    const targets = join(work, "targets");
    writeFileSync(targets, `${TARGETS.join("\n")}\n`);
    for (const harness of HARNESSES) {
      const places = join(work, `places-${harness}`);
      writeFileSync(
        places,
        SH_PLACES.split("\n")
          .map((line) => line.split(" "))
          .filter(([app]) => app === harness)
          .map(([, how, where]) => `${how} ${where}\n`)
          .join(""),
      );
      const found = spawnSync(
        "awk",
        [
          "-v",
          `ends=${SH_ENDINGS}`,
          `${SH_AWK}
            BEGIN { endings = split(ends, ending, " ") }
            FILENAME == ARGV[1] { places++; how[places] = $1; where[places] = $2; next }
            { print $0 "\\t" inplace($0) }`,
          places,
          targets,
        ],
        { encoding: "utf8", env: { PATH: SCRIPT_PATH, LC_ALL: "C" } },
      );
      assert.equal(found.status, 0, found.stderr);
      assert.equal(found.stdout.replace(/\n$/, ""), expected(harness), harness);
    }
  });

  it(
    "finds the same targets in them as memoryPlaceOf, in PowerShell",
    { skip: !PWSH && "pwsh isn't installed" },
    () => {
      for (const harness of HARNESSES) {
        const script = join(work, `places-${harness}.ps1`);
        writeFileSync(
          script,
          [
            "Set-StrictMode -Version 2.0",
            "$ErrorActionPreference = 'Stop'",
            `$Harness = '${harness}'`,
            `$MemoryPlaces = @'\n${PS_PLACES}\n'@`,
            psLine("MemoryEndings"),
            psLine("MemoryTargetMax"),
            psFunction("Get-MemoryPlaces"),
            psFunction("Get-MemoryPlaceOf"),
            `foreach ($target in @(${TARGETS.map((target) => `'${target}'`).join(", ")})) { [Console]::Out.Write("$target\`t$(Get-MemoryPlaceOf $target)\`n") }`,
          ].join("\n"),
        );
        const found = spawnSync(
          "pwsh",
          ["-NoProfile", "-NonInteractive", "-File", script],
          {
            encoding: "utf8",
            env: { ...process.env, POWERSHELL_TELEMETRY_OPTOUT: "1" },
          },
        );
        assert.equal(found.status, 0, found.stderr);
        assert.equal(
          found.stdout.replace(/\n$/, ""),
          expected(harness),
          harness,
        );
      }
    },
  );

  /** A folder for each file and text, with what each shell made of them */
  function cases(name: string): string[] {
    const root = join(work, name);
    const folders: string[] = [];
    FILES.forEach((file, f) =>
      TEXTS.forEach((text, t) => {
        const folder = join(root, `${f}-${t}`);
        mkdirSync(folder, { recursive: true });
        writeFileSync(join(folder, "file"), file);
        writeFileSync(join(folder, "text"), text);
        folders.push(folder);
      }),
    );
    return folders;
  }

  /** The block's lines in a file, without their carriage returns, as its hash reads them */
  const blockOf = (bytes: Buffer) => {
    const text = bytes.toString("latin1");
    const start = text.search(/^<!-- context-locker:start/m);
    if (start < 0) return "";
    const end = text.indexOf(BLOCK_END, start);
    return text.slice(start, end + BLOCK_END.length).replace(/\r/g, "");
  };

  function checkRoundTrip(folders: string[], shell: string) {
    for (const folder of folders) {
      const file = readFileSync(join(folder, "file"));
      const text = readFileSync(join(folder, "text"));
      const built = readFileSync(join(folder, "built"));
      const back = readFileSync(join(folder, "back"));
      const what = `${shell}: ${JSON.stringify(file.toString())} with ${JSON.stringify(text.toString())}`;
      assert.deepEqual(back, text, what);
      assert.equal(blockOf(built), blockOf(file), what);
      // and with no text, the block alone, with no blank line before it
      if (text.length === 0 && blockOf(file))
        assert.ok(
          built.toString("latin1").startsWith("<!-- context-locker:start"),
          what,
        );
    }
  }

  /** What each shell reads as a file's memory, and builds from a text */
  const made = new Map<string, Map<string, Buffer>>();
  const remember = (shell: string, folders: string[]) =>
    made.set(
      shell,
      new Map(
        folders.flatMap((folder) =>
          ["built", "read"].map((name) => [
            `${folder.split("/").at(-1)}/${name}`,
            readFileSync(join(folder, name)),
          ]),
        ),
      ),
    );

  for (const shell of SHELLS) {
    it(`reads a file's memory outside the block, and writes it back with the block as it was, in ${shell}`, () => {
      const folders = cases(shell);
      const script = join(work, `memory-${shell}.sh`);
      writeFileSync(
        script,
        [
          shFunction("block_position"),
          shFunction("ends_with_newline"),
          shFunction("memory_text"),
          shFunction("memory_build"),
          'for dir in "$@"; do',
          '  memory_text "$dir/file" "$dir/read" || : >"$dir/read"',
          '  memory_build "$dir/file" "$dir/text" "$dir/built" || exit 1',
          '  memory_text "$dir/built" "$dir/back" || exit 1',
          "done",
        ].join("\n"),
      );
      const ran = spawnSync(shell, [script, ...folders], {
        encoding: "utf8",
        env: { PATH: SCRIPT_PATH },
      });
      assert.equal(ran.status, 0, ran.stderr);
      checkRoundTrip(folders, shell);
      remember(shell, folders);
    });
  }

  it(
    "reads a file's memory outside the block, and writes it back with the block as it was, in PowerShell",
    { skip: !PWSH && "pwsh isn't installed" },
    () => {
      const folders = cases("pwsh");
      const script = join(work, "memory.ps1");
      writeFileSync(
        script,
        [
          "Set-StrictMode -Version 2.0",
          "$ErrorActionPreference = 'Stop'",
          psLine("StartLine"),
          psLine("EndLine"),
          psLine("Bytewise"),
          psFunction("Get-Lines"),
          psFunction("Get-BlockPosition"),
          psFunction("Get-MemoryText"),
          psFunction("Get-MemoryBuild"),
          "foreach ($dir in $args) {",
          "  $read = Get-MemoryText ([IO.File]::ReadAllBytes((Join-Path $dir 'file')))",
          "  if ($null -eq $read) { $read = [byte[]]@() }",
          "  [IO.File]::WriteAllBytes((Join-Path $dir 'read'), $read)",
          "  $built = Get-MemoryBuild (Join-Path $dir 'file') ([IO.File]::ReadAllBytes((Join-Path $dir 'text')))",
          "  if ($built.Why) { throw $built.Why }",
          "  [IO.File]::WriteAllBytes((Join-Path $dir 'built'), $built.Bytes)",
          "  $back = Get-MemoryText $built.Bytes",
          "  [IO.File]::WriteAllBytes((Join-Path $dir 'back'), [byte[]]$back)",
          "}",
        ].join("\n"),
      );
      const ran = spawnSync(
        "pwsh",
        ["-NoProfile", "-NonInteractive", "-File", script, ...folders],
        {
          encoding: "utf8",
          env: { ...process.env, POWERSHELL_TELEMETRY_OPTOUT: "1" },
        },
      );
      assert.equal(ran.status, 0, ran.stderr);
      checkRoundTrip(folders, "pwsh");
      remember("pwsh", folders);
    },
  );

  it("reads and builds the same bytes in every shell", (context) => {
    const shells = [...made.keys()];
    if (shells.length < 2) {
      context.skip("only one shell ran");
      return;
    }
    const [first, ...rest] = shells;
    for (const shell of rest)
      for (const [name, bytes] of made.get(first!)!)
        assert.deepEqual(
          made.get(shell)!.get(name),
          bytes,
          `${shell}: ${name}`,
        );
  });
});
