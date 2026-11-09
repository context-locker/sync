// The PATH a sync script under test runs with: this computer's, without the
// AI apps the scripts call, such as `hermes cron list` in the plan and the
// doctor, or `openclaw hooks disable` in remove. A test never runs an app
// installed here: in each test's fresh home, Hermes took most of a minute to
// set itself up, so under load a run passed its 60-second limit and was
// stopped (G1-305). A test that needs an app puts a fake of its own first.
// A folder that holds an app is stood in for by links to everything else in
// it, as it can hold what the scripts need, such as pwsh.
import { mkdtempSync, readdirSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

const APPS = ["hermes", "openclaw"];

export function withoutApps(path: string): string {
  const standIns = new Map<string, string>();
  return path
    .split(delimiter)
    .map((dir) => {
      let entries: string[];
      try {
        entries = readdirSync(dir);
      } catch {
        return dir;
      }
      if (!APPS.some((app) => entries.includes(app))) return dir;
      let standIn = standIns.get(dir);
      if (!standIn) {
        standIn = mkdtempSync(join(tmpdir(), "ctx-no-apps-"));
        for (const entry of entries)
          if (!APPS.includes(entry))
            symlinkSync(join(dir, entry), join(standIn, entry));
        standIns.set(dir, standIn);
      }
      return standIn;
    })
    .join(delimiter);
}

export const SCRIPT_PATH = withoutApps(process.env.PATH ?? "");
