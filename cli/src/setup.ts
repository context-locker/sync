// Set up only the invoking app, or the one explicitly selected with --app.
// Other installed apps are not permission to register or configure them.
import { existsSync } from "node:fs";
import { join } from "node:path";

import { GATHER_SKILL_NAME, hookRun } from "@internal/compilers";
import type { Environment } from "@internal/shared";
import { appName, selectApp, namesOf, type App } from "./apps.js";
import { canOpenBrowser, openBrowser } from "./browser.js";
import { stamp } from "./files.js";
import { addHook } from "./hooks.js";
import { VERSION, type Fetch } from "./http.js";
import { apiOf, hookTargetOf, shown, type Place } from "./place.js";
import { bundledScripts, installScript, runScript } from "./script.js";
import {
  claimCode,
  connectedAs,
  connectionOf,
  deviceSignin,
  type DeviceSigninOptions,
} from "./signin.js";

export interface SetupOptions {
  place: Place;
  /** One explicitly selected app, or none to identify the invoking app */
  apps: App[];
  environment?: Environment | undefined;
  /** A one-time code the person made in Context Locker, for one app */
  code: string | null;
  /** Whether setup may open the approval link in the browser */
  browser: boolean;
  wait: DeviceSigninOptions["wait"];
  out: (line: string) => void;
  platform?: NodeJS.Platform;
  /** Where the scripts that come with this command are */
  scripts?: string;
  open?: (link: string) => boolean;
  fetch?: Fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

/** Exit codes: done, a problem, the command was used wrongly, or still waiting for approval */
export const DONE = 0;
export const FAILED = 1;
export const USAGE = 2;
export const WAITING = 3;

const plural = (count: number, one: string, many: string) =>
  `${count} ${count === 1 ? one : many}`;

/** A line from the sync script, under its app's name */
const indented = (line: string) => (line ? `  ${line}` : "");

export async function setup(options: SetupOptions): Promise<number> {
  const { place, out } = options;
  const platform = options.platform ?? process.platform;
  const api = apiOf(place);
  out(`Context Locker setup, version ${VERSION}`);
  out("");

  const selected = selectApp(options.apps, place.env);
  if ("problem" in selected) {
    out(selected.problem);
    return USAGE;
  }
  const apps = [selected.app];
  out(`Setting up ${appName(selected.app)}.`);

  const installed = installScript(place, options.scripts ?? bundledScripts());
  const version =
    installed.version === null ? "" : `, version ${installed.version},`;
  out(
    installed.state === "saved"
      ? `Saved the sync script${version} at ${shown(place, installed.path)}.`
      : installed.state === "same"
        ? `The sync script${version} is already at ${shown(place, installed.path)}.`
        : `A newer sync script${version} is already at ${shown(place, installed.path)}, so setup keeps it.`,
  );

  // Apps already connected on this computer keep their connection
  const toConnect: App[] = [];
  for (const app of apps) {
    if (options.code) {
      toConnect.push(app);
      continue;
    }
    const connection = await connectionOf(place, api, app, options.fetch);
    if (connection && "problem" in connection) {
      out(connection.problem);
      return FAILED;
    }
    if (connection) {
      out(`${appName(app)} is already connected: ${connectedAs(connection)}.`);
    } else {
      toConnect.push(app);
    }
  }

  // Whether the person ticked Bring in as they approved it (G1-89)
  let bringIn = false;
  if (toConnect.length > 0) {
    out("");
    const result = options.code
      ? await claimCode({
          place,
          api,
          environment: options.environment,
          app: toConnect[0] as App,
          code: options.code,
          fetch: options.fetch,
        })
      : await deviceSignin({
          place,
          api,
          environment: options.environment,
          apps: toConnect,
          out,
          wait: options.wait,
          open: (link) =>
            options.browser &&
            canOpenBrowser(place.env, platform) &&
            (options.open ?? ((url) => openBrowser(url, platform)))(link),
          fetch: options.fetch,
          now: options.now,
          sleep: options.sleep,
        });
    if (result.kind === "waiting") return WAITING;
    if (result.kind === "failed") {
      out(result.message);
      return FAILED;
    }
    bringIn = result.bringIn === true;
    for (const app of toConnect) {
      const connection = await connectionOf(place, api, app, options.fetch);
      out(
        connection && !("problem" in connection)
          ? `Connected: ${connectedAs(connection)}.`
          : `Connected ${appName(app)}.`,
      );
    }
  }

  // Each app: its files, its hook, then the doctor
  const when = stamp();
  let problems = 0;
  for (const app of apps) {
    out("");
    out(appName(app));
    const synced = await runScript(place, [app], (line) => {
      // What an app's hook reads, which isn't for people
      if (!line.startsWith('{"hookSpecificOutput"')) out(indented(line));
    });
    if (synced === 0) {
      out("  Its files match your playbook.");
    } else {
      problems += 1;
      if (synced === null) out("  The sync script didn't run.");
    }
    const hook = await addHook(app, place, when);
    out(`  ${hook.said}`);
    // The doctor's checks that passed go without saying
    const report: string[] = [];
    const doctor = await runScript(place, ["doctor", app], (line) => {
      if (!line.startsWith("PASS ")) report.push(line);
    });
    while (report[0] === "") report.shift();
    while (report.at(-1) === "") report.pop();
    for (const line of report) out(indented(line));
    if (doctor !== 0) problems += 1;
    // Hermes and OpenClaw can also sync once a day from their own
    // schedulers, which needs the person's yes of its own (G1-87). The
    // doctor keeps the job it finds in daily-job.
    if (
      (app === "hermes" || app === "openclaw") &&
      !existsSync(join(place.clHome, app, "daily-job"))
    ) {
      out(
        indented(
          `${appName(app)} can also run the sync once a day from its own scheduler, with no model call, so it keeps up between sessions. Ask the person, and only if they say yes, run: ${hookRun(hookTargetOf(place))} daily-job ${app}`,
        ),
      );
    }
  }

  out("");
  out(
    problems === 0
      ? `Context Locker is set up for ${namesOf(apps)}.`
      : `Setup finished with ${plural(problems, "problem", "problems")} to fix, as it says above. Fix them and run this command again.`,
  );
  // Gather is for an app's first setup; setting up again needn't repeat it.
  // The person ticked Bring in as they approved it, so the app imports now,
  // and its session start says so until it has (G1-89)
  if (toConnect.length > 0) {
    out(
      bringIn
        ? `Next, the person asked for what their AI apps on this computer already know to come into Context Locker. If they're with you, follow Context Locker's Import skill, ${GATHER_SKILL_NAME}, now. The import waits in their inbox, and nothing in their playbook changes until they pick from it.`
        : `To bring in what your AI apps on this computer already know, ask your AI app to follow Context Locker's Import skill, ${GATHER_SKILL_NAME}. The import waits in your inbox, and nothing changes until you pick from it.`,
    );
  }
  return problems === 0 ? DONE : FAILED;
}
