// Context Locker's command line: what each command and option means.
import { appList, parseApp, type App } from "./apps.js";
import type { Environment } from "@internal/shared";
import { VERSION } from "./http.js";
import { placeFrom } from "./place.js";
import { DONE, FAILED, USAGE, setup } from "./setup.js";

const HELP = `Context Locker setup: connect one AI app.

  npx context-locker setup [options]

Sets up only the app running this command. If it cannot be identified,
choose one with --app. Other installed apps stay as they are. Setup connects
the selected app with your browser approval, saves the shared sync script,
writes that app's files, adds its hooks and checks everything.

Options:
  --app <name>      Set up one app: ${appList()}.
                    Run setup separately for each app you want to connect.
  --environment <computer|cloud>  Where this app runs; otherwise the approval
                    page asks when it cannot be detected.
  --code <code>     Connect one app with a one-time code made in Context
                    Locker, with nothing to approve.
  --no-browser      Show the approval link without opening it.
  --wait <seconds>  How long to wait for the approval. Run the command again
                    to keep waiting.
  --version         Show the version.
  --help            Show this.

Exit codes: 0 done, 1 a problem, 2 the command was used wrongly, 3 still
waiting for approval.

More at https://context.locker/setup`;

export interface Parsed {
  command: "setup" | "help" | "version";
  apps: App[];
  environment?: Environment;
  code: string | null;
  browser: boolean;
  wait: number | null;
}

/** The command line, or what's wrong with it */
export function parse(args: string[]): Parsed | { problem: string } {
  const parsed: Parsed = {
    command: "help",
    apps: [],
    code: null,
    browser: true,
    wait: null,
  };
  const rest = [...args];
  const first = rest[0];
  if (first === undefined || ["help", "--help", "-h"].includes(first)) {
    return parsed;
  }
  if (["--version", "-v", "version"].includes(first)) {
    return { ...parsed, command: "version" };
  }
  if (first !== "setup") {
    return {
      problem: `There's no command ${first}. Run: npx context-locker setup`,
    };
  }
  parsed.command = "setup";
  rest.shift();
  while (rest.length > 0) {
    const option = rest.shift() as string;
    const [name, inline] =
      option.startsWith("--") && option.includes("=")
        ? [
            option.slice(0, option.indexOf("=")),
            option.slice(option.indexOf("=") + 1),
          ]
        : [option, undefined];
    const value = () => inline ?? rest.shift();
    switch (name) {
      case "--app": {
        const given = value();
        const app = given ? parseApp(given) : null;
        if (!app) {
          return {
            problem: `--app takes the app's name: ${appList()}.`,
          };
        }
        if (parsed.apps.length > 0 && !parsed.apps.includes(app)) {
          return {
            problem: "Setup connects one app at a time. Use --app once.",
          };
        }
        if (!parsed.apps.includes(app)) parsed.apps.push(app);
        break;
      }
      case "--environment": {
        const given = value();
        if (given !== "computer" && given !== "cloud")
          return { problem: "--environment takes computer or cloud." };
        parsed.environment = given;
        break;
      }
      case "--code": {
        const given = value();
        if (!given || !/^ctxl_ic_[A-Za-z0-9_-]{43}$/.test(given)) {
          return {
            problem:
              "--code takes the one-time code made in Context Locker, which starts with ctxl_ic_.",
          };
        }
        parsed.code = given;
        break;
      }
      case "--no-browser":
        parsed.browser = false;
        break;
      case "--wait": {
        const given = value();
        if (!given || !/^\d{1,4}$/.test(given) || Number(given) > 900) {
          return { problem: "--wait takes a number of seconds, up to 900." };
        }
        parsed.wait = Number(given);
        break;
      }
      case "--help":
      case "-h":
        return { ...parsed, command: "help" };
      default:
        return {
          problem: `setup has no option ${name}. Run: npx context-locker --help`,
        };
    }
  }
  return parsed;
}

export async function main(
  args: string[],
  out: (line: string) => void = (line) => process.stdout.write(`${line}\n`),
): Promise<number> {
  const parsed = parse(args);
  if ("problem" in parsed) {
    out(parsed.problem);
    return USAGE;
  }
  if (parsed.command === "version") {
    out(VERSION);
    return DONE;
  }
  if (parsed.command === "help") {
    out(HELP);
    return DONE;
  }
  // In a terminal, the person is there to approve, so it waits until the
  // code expires; an AI app running it gets the link back sooner
  const interactive = Boolean(process.stdout.isTTY && process.stdin.isTTY);
  try {
    return await setup({
      place: placeFrom(),
      apps: parsed.apps,
      environment: parsed.environment,
      code: parsed.code,
      browser: parsed.browser,
      wait: parsed.wait ?? (interactive ? "expiry" : "auto"),
      out,
    });
  } catch (error) {
    out(
      `Setup stopped: ${error instanceof Error ? error.message : String(error)}`,
    );
    return FAILED;
  }
}
