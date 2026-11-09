// The computer's name as a sync script says it, never "this computer", as the
// person may read what it says on another computer or their phone (G1-299).
// A test can't choose the name, so it asks the script's own function, with
// the PATH the test runs the script with: machine_name in sh, and
// Get-MachineName in PowerShell.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { SCRIPT_PATH } from "./script-path.js";

const SCRIPTS = new URL("../scripts/", import.meta.url);

/** What a script holds that matches a pattern, which must be there once */
function once(script: string, pattern: RegExp): string {
  const found = [...script.matchAll(pattern)];
  if (found.length !== 1) {
    throw new Error(`${pattern} is in the script ${found.length} times`);
  }
  return found[0]![0];
}

const found = new Map<string, string>();

/** The computer's name as the script in this shell says it: dash, bash or pwsh */
export function computerName(shell: string, path = SCRIPT_PATH): string {
  const key = `${shell}\n${path}`;
  const known = found.get(key);
  if (known !== undefined) return known;
  const powershell = shell === "pwsh";
  const script = readFileSync(
    fileURLToPath(new URL(powershell ? "sync.ps1" : "sync.sh", SCRIPTS)),
    "utf8",
  );
  const code = powershell
    ? [
        once(script, /^\$OnMac = .*$/gm),
        once(script, /^function Get-MachineName \{\n[\s\S]*?^\}$/gm),
        "Get-MachineName",
      ].join("\n")
    : [
        once(script, /^have\(\) \{ .* \}$/gm),
        once(script, /^machine_name\(\) \{\n[\s\S]*?^\}$/gm),
        "machine_name",
      ].join("\n");
  const run = spawnSync(
    shell,
    powershell ? ["-NoProfile", "-Command", code] : ["-c", code],
    { encoding: "utf8", env: { ...process.env, PATH: path } },
  );
  const name = run.stdout.replace(/\r?\n$/, "");
  if (run.status !== 0 || !name) {
    throw new Error(`${shell} found no name for the computer: ${run.stderr}`);
  }
  found.set(key, name);
  return name;
}

/** The name as a regular expression matches it */
export function computerPattern(shell: string, path = SCRIPT_PATH): string {
  return computerName(shell, path).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
