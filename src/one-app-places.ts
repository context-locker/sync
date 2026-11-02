// Places only one AI app can open (G1-157): a Claude artifact, chat or
// project, a ChatGPT, Gemini or Grok chat, or a page one computer serves.
// They're fine as views and working copies, never as the only home of a
// record another agent needs, as the user's other apps can't read them. A
// share link an app makes public is left out, as anyone can read it.

/** Who alone can open a place, and what it is, as a line says them */
export interface OneAppPlace {
  /** Such as Claude, or the computer that serves it */
  who: string;
  /** Such as a Claude artifact */
  place: string;
}

const APPS: ReadonlyArray<{
  hosts: readonly string[];
  who: string;
  places: ReadonlyArray<readonly [RegExp, string]>;
}> = [
  {
    hosts: ["claude.ai"],
    who: "Claude",
    places: [
      [/^\/(?:code\/)?artifact\//, "a Claude artifact"],
      [/^\/chat\//, "a Claude chat"],
      [/^\/project\//, "a Claude project"],
    ],
  },
  {
    hosts: ["chatgpt.com", "chat.openai.com"],
    who: "ChatGPT",
    places: [[/^\/(?:g\/[^/]+\/)?c\//, "a ChatGPT chat"]],
  },
  {
    hosts: ["gemini.google.com"],
    who: "Gemini",
    places: [[/^\/(?:app|gem)\//, "a Gemini chat"]],
  },
  {
    hosts: ["grok.com"],
    who: "Grok",
    places: [[/^\/(?:c|chat)\//, "a Grok chat"]],
  },
];

/** Hosts that only the computer serving them can open */
const ONE_COMPUTER = new Set(["localhost", "127.0.0.1", "[::1]", "0.0.0.0"]);

/**
 * Who alone can open an address, and what it is, or null for one every app
 * can reach, such as a page on the web, a public share or a path in the repo
 */
export function oneAppPlace(address: string): OneAppPlace | null {
  if (!URL.canParse(address)) return null;
  const url = new URL(address);
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  if (ONE_COMPUTER.has(host) || host.endsWith(".localhost")) {
    return {
      who: "the computer that serves it",
      place: "a page on one computer",
    };
  }
  const app = APPS.find(({ hosts }) => hosts.includes(host));
  if (!app || /^\/(?:public|share)\//.test(url.pathname)) return null;
  const place = app.places.find(([pattern]) => pattern.test(url.pathname));
  return place ? { who: app.who, place: place[1] } : null;
}
