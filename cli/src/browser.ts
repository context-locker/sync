// Opening the approval link in the person's browser. The link comes from a
// reply, so it's checked before anything opens it: a web address of plain
// characters only, as the sync scripts check it, which no shell can read as
// anything else. Opening it is never needed: the link is always printed
// first, so it can be opened on another device.
import { spawn } from "node:child_process";

/** The link if it's safe to show and open, or null */
export function safeLink(raw: string | null): string | null {
  if (!raw || !/^[A-Za-z0-9:/.?=_-]+$/.test(raw)) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol === "https:") return raw;
  // A local Context Locker, for working on it
  if (
    url.protocol === "http:" &&
    ["localhost", "127.0.0.1"].includes(url.hostname)
  ) {
    return raw;
  }
  return null;
}

/**
 * Whether a browser here would be in front of the person: not in CI, not over
 * SSH, where it would open on the wrong computer, and on Linux only with a
 * display
 */
export function canOpenBrowser(
  env: NodeJS.ProcessEnv,
  platform: NodeJS.Platform,
): boolean {
  if (env.CI || env.CONTEXT_LOCKER_NO_BROWSER) return false;
  if (env.SSH_CONNECTION || env.SSH_TTY) return false;
  if (platform === "linux" && !env.DISPLAY && !env.WAYLAND_DISPLAY) {
    return false;
  }
  return true;
}

/** Starts the browser on a link already checked with safeLink. Whether it started, never whether anyone saw it */
export function openBrowser(link: string, platform: NodeJS.Platform): boolean {
  const [command, args] =
    platform === "darwin"
      ? ["open", [link]]
      : platform === "win32"
        ? // No cmd.exe, which would read the link's characters as its own
          ["rundll32.exe", ["url.dll,FileProtocolHandler", link]]
        : ["xdg-open", [link]];
  try {
    const child = spawn(command as string, args as string[], {
      stdio: "ignore",
      detached: true,
      shell: false,
      windowsHide: true,
    });
    child.on("error", () => {});
    child.unref();
    return true;
  } catch {
    return false;
  }
}
