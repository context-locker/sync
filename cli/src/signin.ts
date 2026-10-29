// Connecting the selected app: one device code, which the
// person approves in their browser (RFC 8628), or a one-time code they made
// in Context Locker. Only the link and the code the person checks are shown:
// each token goes straight into a file only this account can read, where the
// sync script finds it, and never on screen.
import { execFileSync } from "node:child_process";
import type { Environment } from "@internal/shared";
import { environmentOf } from "./environment.js";
import { randomBytes } from "node:crypto";
import { readFileSync, rmSync } from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";

import { INVITE_GRANT } from "@internal/shared";

import { appName, namesOf, type App } from "./apps.js";
import { safeLink } from "./browser.js";
import { privateFolder, writeFile } from "./files.js";
import { VERSION, call, text, type Fetch } from "./http.js";
import type { Place } from "./place.js";

const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code";
const TOKEN = /^ctxl_at_[A-Za-z0-9_-]+$/;

/** Where an app's connection is kept, as the sync script reads it */
export function tokenFile(place: Place, app: App): string {
  return join(place.clHome, app, "token");
}

export function readToken(place: Place, app: App): string | null {
  try {
    const line = readFileSync(tokenFile(place, app), "utf8").split(/\r?\n/)[0];
    return line && TOKEN.test(line.trim()) ? line.trim() : null;
  } catch {
    return null;
  }
}

export function saveToken(place: Place, app: App, token: string): void {
  privateFolder(join(place.clHome, app));
  writeFile(tokenFile(place, app), `${token}\n`, 0o600);
  // A sign-in the sync script was waiting on isn't needed any more
  rmSync(join(place.clHome, app, "device"), { force: true });
}

export interface Connection {
  app: App;
  name: string;
  machine: string | null;
  workspace: string | null;
}

/**
 * An app's connection, from its saved token: null when it has none or it
 * stopped working, such as one revoked in Context Locker
 */
export async function connectionOf(
  place: Place,
  api: string,
  app: App,
  fetchImpl?: Fetch,
): Promise<Connection | null | { problem: string }> {
  const token = readToken(place, app);
  if (!token) return null;
  const reply = await call(api, "/v1/agent", { token, fetch: fetchImpl });
  if (reply.status === 401) return null;
  if (reply.status === 0) {
    return {
      problem: `Can't reach Context Locker at ${api}. Check the internet connection and try again.`,
    };
  }
  if (reply.status !== 200) {
    return {
      problem: `Context Locker answered ${reply.status}. Try again in a minute.`,
    };
  }
  const agent = (reply.body.agent ?? {}) as Record<string, unknown>;
  const workspace = (reply.body.workspace ?? {}) as Record<string, unknown>;
  return {
    app,
    name: text(agent, "name") ?? appName(app),
    machine: text(agent, "machine_name"),
    workspace: text(workspace, "name"),
  };
}

/** "Claude Code on Ada's laptop, in the Personal workspace", as the sync script says it */
export function connectedAs(connection: Connection): string {
  let said = connection.name;
  // A name the person chose says which this is; the app's own name needs the computer
  if (connection.machine && connection.name === appName(connection.app)) {
    said += ` on ${connection.machine}`;
  }
  if (connection.workspace)
    said += `, in the ${connection.workspace} workspace`;
  return clean(said);
}

/** Text from a reply, with control characters taken out before it's shown */
function clean(said: string): string {
  return said.replace(/[\u0000-\u001f\u007f]/g, "");
}

/**
 * This computer's name, as the approval page shows it: its first name with a
 * letter or digit once cut down to plain characters, as the scripts find it
 */
export function machineName(place: Place): string | null {
  const names: string[] = [];
  if (place.mac) {
    try {
      names.push(
        execFileSync("scutil", ["--get", "ComputerName"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
          timeout: 5000,
        }),
      );
    } catch {
      // Not there, or no answer
    }
  }
  try {
    names.push(hostname());
  } catch {
    // No name
  }
  for (const name of names) {
    const plain = name
      .replaceAll("’", "'")
      .replace(/[^A-Za-z0-9 ._'-]/g, "")
      .slice(0, 120)
      .trim();
    if (/[A-Za-z0-9]/.test(plain)) return plain;
  }
  return null;
}

/**
 * A random id for this computer, kept beside the connections, so connecting
 * an app again replaces its old connection instead of adding another. The
 * sync scripts keep the same one.
 */
export function machineId(place: Place): string | null {
  const file = join(place.clHome, "machine-id");
  try {
    const id = readFileSync(file, "utf8").split(/\r?\n/)[0]?.trim() ?? "";
    if (/^[a-f0-9]{32}$/.test(id)) return id;
  } catch {
    // None yet
  }
  const id = randomBytes(16).toString("hex");
  try {
    privateFolder(place.clHome);
    writeFile(file, `${id}\n`, 0o600);
    return id;
  } catch {
    return null;
  }
}

export function osName(place: Place): string {
  return place.windows ? "Windows" : place.mac ? "macOS" : "Linux";
}

/** What an app says about itself and its computer when it asks for a code */
function about(place: Place, chosen?: Environment): Record<string, string> {
  const environment = environmentOf(place.env, chosen);
  const name = machineName(place);
  const id = machineId(place);
  return {
    client_version: `context-locker ${VERSION}`,
    ...(environment ? { environment } : {}),
    ...(name ? { machine_name: name } : {}),
    ...(id ? { machine_id: id } : {}),
    os: osName(place),
  };
}

export type SigninResult =
  /** bringIn: the person ticked Bring in as they approved it (G1-89) */
  | { kind: "connected"; bringIn?: boolean }
  | { kind: "waiting" }
  | { kind: "failed"; message: string };

const failed = (message: string): SigninResult => ({ kind: "failed", message });

/** A sign-in waiting for approval, kept between runs of the command */
interface Pending {
  device_code: string;
  user_code: string;
  link: string;
  /** When the code stops working, in milliseconds */
  expires: number;
  /** Seconds between polls */
  interval: number;
  /** When it was last polled, in milliseconds */
  last: number;
  apps: App[];
}

function pendingFile(place: Place, apps: readonly App[]): string {
  // Setup passes one app. Keep separate storage for each selection so one
  // app's approval cannot overwrite or consume another app's pending code.
  return join(place.clHome, apps.join("+"), "setup-device");
}

/** The sign-in already waiting for these apps, if it's still good */
function readPending(place: Place, apps: App[], now: number): Pending | null {
  let found: Partial<Pending>;
  try {
    found = JSON.parse(
      readFileSync(pendingFile(place, apps), "utf8"),
    ) as Partial<Pending>;
  } catch {
    return null;
  }
  const good =
    typeof found.device_code === "string" &&
    /^ctxl_dc_[A-Za-z0-9_-]+$/.test(found.device_code) &&
    typeof found.user_code === "string" &&
    /^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(found.user_code) &&
    safeLink(found.link ?? null) !== null &&
    typeof found.expires === "number" &&
    found.expires > now &&
    typeof found.interval === "number" &&
    typeof found.last === "number" &&
    Array.isArray(found.apps) &&
    found.apps.join(" ") === apps.join(" ");
  return good ? (found as Pending) : null;
}

function savePending(place: Place, pending: Pending): void {
  privateFolder(join(place.clHome, pending.apps.join("+")));
  writeFile(
    pendingFile(place, pending.apps),
    `${JSON.stringify(pending)}\n`,
    0o600,
  );
}

function clearPending(place: Place, apps: readonly App[]): void {
  rmSync(pendingFile(place, apps), { force: true });
}

export interface DeviceSigninOptions {
  place: Place;
  api: string;
  apps: App[];
  environment?: Environment | undefined;
  out: (line: string) => void;
  /**
   * How long this run waits for the approval: seconds; "expiry", until the
   * code expires; or "auto", 50 seconds, or none when the link opened nowhere
   * and an app has to pass it on
   */
  wait: number | "expiry" | "auto";
  /** Opens the link in the browser, saying whether it could */
  open: (link: string) => boolean;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  fetch?: Fetch;
}

/**
 * Connects every app with one device code. The code is kept between runs, so
 * running the command again keeps waiting for the same approval.
 */
export async function deviceSignin(
  options: DeviceSigninOptions,
): Promise<SigninResult> {
  const { place, api, apps, out } = options;
  const now = options.now ?? Date.now;
  const sleep =
    options.sleep ??
    ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));

  let pending = readPending(place, apps, now());
  let started = false;
  if (!pending) {
    const [first] = apps;
    const reply = await call(api, "/oauth/device_authorization", {
      json: {
        ...(apps.length === 1 ? { harness: first } : { harnesses: apps }),
        ...about(place, options.environment),
      },
      fetch: options.fetch,
    });
    if (reply.status === 0) {
      return failed(
        `Can't reach Context Locker at ${api}. Check the internet connection and try again.`,
      );
    }
    if (reply.status === 429) {
      return failed(
        "Too many sign-ins from this network just now. Try again in a few minutes.",
      );
    }
    if (reply.status !== 200) {
      const said = text(reply.body, "error_description");
      return failed(
        `Couldn't start the sign-in: ${said ? clean(said) : `Context Locker answered ${reply.status}.`}`,
      );
    }
    const deviceCode = text(reply.body, "device_code") ?? "";
    const userCode = text(reply.body, "user_code") ?? "";
    const link = safeLink(text(reply.body, "verification_uri_complete"));
    const expiresIn = reply.body.expires_in;
    const interval = reply.body.interval;
    if (
      !/^ctxl_dc_[A-Za-z0-9_-]+$/.test(deviceCode) ||
      !/^[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(userCode) ||
      !link ||
      typeof expiresIn !== "number" ||
      typeof interval !== "number"
    ) {
      return failed(
        "The sign-in reply didn't make sense, so nothing was saved. Try again.",
      );
    }
    pending = {
      device_code: deviceCode,
      user_code: userCode,
      link,
      expires: now() + expiresIn * 1000,
      interval,
      last: 0,
      apps,
    };
    savePending(place, pending);
    started = true;
  }

  out(
    `To connect ${namesOf(apps)} on this computer, open this link and approve the request:`,
  );
  out("");
  out(`  ${pending.link}`);
  out("");
  out(`Check that the page shows the code ${pending.user_code}.`);
  // A code shown before may still be open in the browser, so it opens only once
  const opened = started && options.open(pending.link);
  if (opened) out("It's opening in your browser.");

  const wait =
    options.wait === "expiry"
      ? Number.POSITIVE_INFINITY
      : options.wait === "auto"
        ? started && !opened
          ? 0
          : 50
        : options.wait;
  if (wait <= 0) {
    out("");
    out("Waiting for approval. Once it's approved, run this command again.");
    return { kind: "waiting" };
  }
  out("");
  out("Waiting for approval…");

  const deadline = Math.min(now() + wait * 1000, pending.expires);
  let polled = false;
  let unreachable = 0;
  for (;;) {
    // Never poll faster than the interval, even across runs
    const interval = Math.min(Math.max(pending.interval, 5), 60);
    const pause = pending.last + interval * 1000 + 1000 - now();
    if (pause > 0) {
      if (polled && now() + pause > deadline) break;
      await sleep(pause);
    }
    const reply = await call(api, "/oauth/token", {
      json: { grant_type: DEVICE_GRANT, device_code: pending.device_code },
      fetch: options.fetch,
    });
    polled = true;
    pending.last = now();
    const error = reply.status === 400 ? text(reply.body, "error") : null;

    if (reply.status === 200) {
      const tokens = tokensFrom(reply.body, apps);
      clearPending(place, apps);
      if (!tokens) {
        return failed(
          "The reply didn't include a usable token for each app. Run this command again to start over.",
        );
      }
      for (const app of apps) saveToken(place, app, tokens.get(app) as string);
      return reply.body.bring_in === true
        ? { kind: "connected", bringIn: true }
        : { kind: "connected" };
    }
    if (reply.status === 0) {
      unreachable += 1;
      if (unreachable >= 3) {
        savePending(place, pending);
        return failed(
          `Can't reach Context Locker at ${api}. Run this command again to keep waiting.`,
        );
      }
    } else {
      unreachable = 0;
      if (error === "slow_down") {
        pending.interval += 5;
      } else if (error === "access_denied") {
        clearPending(place, apps);
        return failed(
          "The request was turned down, so nothing was connected. Run this command again to start over.",
        );
      } else if (error === "expired_token") {
        clearPending(place, apps);
        return failed(
          "The code expired before it was approved. Run this command again for a new one.",
        );
      } else if (error === "invalid_grant") {
        clearPending(place, apps);
        return failed(
          "This code can't be used any more. Run this command again for a new one.",
        );
      } else if (error !== "authorization_pending") {
        savePending(place, pending);
        return failed(
          `Context Locker answered ${reply.status}. Run this command again to keep waiting.`,
        );
      }
    }
    savePending(place, pending);
    if (now() >= deadline) break;
  }

  savePending(place, pending);
  if (now() >= pending.expires) {
    clearPending(place, apps);
    return failed(
      "The code expired before it was approved. Run this command again for a new one.",
    );
  }
  out(
    "Still waiting for approval. Once it's approved, run this command again.",
  );
  return { kind: "waiting" };
}

/** Each app's token from a reply: one app's access_token, or the tokens list for several */
function tokensFrom(
  body: Record<string, unknown>,
  apps: App[],
): Map<App, string> | null {
  const tokens = new Map<App, string>();
  if (Array.isArray(body.tokens)) {
    for (const entry of body.tokens as unknown[]) {
      if (!entry || typeof entry !== "object") continue;
      const harness = text(entry as Record<string, unknown>, "harness");
      const token = text(entry as Record<string, unknown>, "access_token");
      if (harness && token && TOKEN.test(token)) {
        tokens.set(harness as App, token);
      }
    }
  } else if (apps.length === 1) {
    const token = text(body, "access_token");
    if (token && TOKEN.test(token)) tokens.set(apps[0] as App, token);
  }
  return apps.every((app) => tokens.has(app)) ? tokens : null;
}

/**
 * Connects one app with a one-time code the person made in Context Locker,
 * for a connection they named, so there's nothing to approve. The code is
 * never printed.
 */
export async function claimCode(options: {
  place: Place;
  api: string;
  app: App;
  code: string;
  environment?: Environment | undefined;
  fetch?: Fetch;
}): Promise<SigninResult> {
  const { place, api, app } = options;
  const reply = await call(api, "/oauth/token", {
    json: {
      grant_type: INVITE_GRANT,
      invite_code: options.code,
      harness: app,
      agent_name: appName(app),
      ...about(place, options.environment),
    },
    fetch: options.fetch,
  });
  if (reply.status === 0) {
    return failed(
      `Can't reach Context Locker at ${api}. Check the internet connection and try again.`,
    );
  }
  if (reply.status === 400) {
    return failed(
      "That code can't be used. It works once, for 15 minutes. Ask for a new one: the person makes it in Context Locker, from the connection's New code.",
    );
  }
  if (reply.status === 429) {
    return failed(
      "Too many codes tried from this network just now. Try again in a few minutes.",
    );
  }
  const token = text(reply.body, "access_token");
  if (reply.status !== 200 || !token || !TOKEN.test(token)) {
    const said = text(reply.body, "error_description");
    return failed(
      `Couldn't connect with the code: ${said ? clean(said) : `Context Locker answered ${reply.status}.`}`,
    );
  }
  saveToken(place, app, token);
  // The person ticked Bring in as they made the code (G1-89)
  return reply.body.bring_in === true
    ? { kind: "connected", bringIn: true }
    : { kind: "connected" };
}
