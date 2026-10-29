// Talking to Context Locker's API: JSON in and out, a time limit on each
// request, and an answer of 0 when it can't be reached at all.
import { readFileSync } from "node:fs";

/** This command's version, from its package.json */
export const VERSION: string = (() => {
  try {
    const found = JSON.parse(
      readFileSync(new URL("../package.json", import.meta.url), "utf8"),
    ) as { version?: unknown };
    return typeof found.version === "string" ? found.version : "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

export interface Reply {
  /** The HTTP status, or 0 when Context Locker couldn't be reached */
  status: number;
  body: Record<string, unknown>;
}

export type Fetch = typeof fetch;

export async function call(
  api: string,
  path: string,
  options: {
    method?: "GET" | "POST";
    json?: unknown;
    token?: string;
    timeoutMs?: number;
    fetch?: Fetch;
  } = {},
): Promise<Reply> {
  const headers: Record<string, string> = {
    accept: "application/json",
    "user-agent": `context-locker/${VERSION}`,
  };
  if (options.token) headers.authorization = `Bearer ${options.token}`;
  if (options.json !== undefined) headers["content-type"] = "application/json";
  try {
    const response = await (options.fetch ?? fetch)(`${api}${path}`, {
      method: options.method ?? (options.json === undefined ? "GET" : "POST"),
      headers,
      body:
        options.json === undefined ? undefined : JSON.stringify(options.json),
      signal: AbortSignal.timeout(options.timeoutMs ?? 30_000),
    });
    let body: Record<string, unknown> = {};
    try {
      const parsed: unknown = await response.json();
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        body = parsed as Record<string, unknown>;
      }
    } catch {
      body = {};
    }
    return { status: response.status, body };
  } catch {
    return { status: 0, body: {} };
  }
}

/** A text field from a reply, or null */
export function text(
  body: Record<string, unknown>,
  key: string,
): string | null {
  const value = body[key];
  return typeof value === "string" ? value : null;
}
