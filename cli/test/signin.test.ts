import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, it } from "node:test";

import { safeLink } from "../src/browser.js";
import { placeFrom } from "../src/place.js";
import { claimCode, deviceSignin, readToken } from "../src/signin.js";

const work = mkdtempSync(join(tmpdir(), "ctx-cli-signin-"));
after(() => rmSync(work, { recursive: true, force: true }));

const API = "https://api.example.test";
const LINK = "https://app.context.locker/device?code=BCDF-GHJK";
const TOKEN_A = `ctxl_at_${"A".repeat(43)}`;
const TOKEN_B = `ctxl_at_${"B".repeat(43)}`;

interface Sent {
  path: string;
  body: Record<string, unknown>;
  at: number;
}

/** A Context Locker that answers each path from a list, one answer a request */
function fakeApi(
  answers: Record<string, Array<[number, Record<string, unknown>]>>,
  clock: { now: number },
) {
  const sent: Sent[] = [];
  const fetchImpl = (async (url: string | URL, init?: RequestInit) => {
    const path = String(url).slice(API.length);
    sent.push({
      path,
      body: JSON.parse(String(init?.body ?? "{}")),
      at: clock.now,
    });
    const queue = answers[path] ?? [];
    const [status, body] =
      queue.length > 1
        ? (queue.shift() as [number, object])
        : (queue[0] ?? [404, {}]);
    return new Response(JSON.stringify(body), { status });
  }) as typeof fetch;
  return { sent, fetchImpl };
}

function computer() {
  const home = mkdtempSync(join(work, "home-"));
  return { home, place: placeFrom({ HOME: home, PATH: "" }, "linux") };
}

const started: [number, Record<string, unknown>] = [
  200,
  {
    device_code: "ctxl_dc_abc",
    user_code: "BCDF-GHJK",
    verification_uri_complete: LINK,
    expires_in: 900,
    interval: 5,
  },
];
const pending: [number, Record<string, unknown>] = [
  400,
  { error: "authorization_pending" },
];

describe("signing in with a device code", () => {
  it("sends the detected cloud location with only the selected app", async () => {
    const { place } = computer();
    place.env.CLAUDE_CODE_REMOTE = "true";
    const clock = { now: 1_000_000 };
    const api = fakeApi({ "/oauth/device_authorization": [started] }, clock);
    await deviceSignin({
      place,
      api: API,
      apps: ["claude-code"],
      out: () => {},
      wait: 0,
      open: () => false,
      now: () => clock.now,
      fetch: api.fetchImpl,
    });
    assert.equal(api.sent[0]?.body.environment, "cloud");
    assert.equal(api.sent[0]?.body.harness, "claude-code");
    assert.equal(api.sent[0]?.body.harnesses, undefined);
  });

  it("keeps separate pending approvals and leaves legacy approvals untouched", async () => {
    const { place } = computer();
    const clock = { now: 1_000_000 };
    mkdirSync(place.clHome, { recursive: true });
    const legacy = join(place.clHome, "setup-device");
    writeFileSync(legacy, "old multi-app approval\n");
    const apiA = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [[200, { access_token: TOKEN_A }]],
      },
      clock,
    );
    const apiB = fakeApi(
      {
        "/oauth/device_authorization": [
          [200, { ...started[1], device_code: "ctxl_dc_other" }],
        ],
        "/oauth/token": [[200, { access_token: TOKEN_B }]],
      },
      clock,
    );
    const run = (app: "codex" | "hermes", fake: ReturnType<typeof fakeApi>) =>
      deviceSignin({
        place,
        api: API,
        apps: [app],
        out: () => {},
        wait: "auto",
        open: () => false,
        now: () => clock.now,
        sleep: async (ms) => {
          clock.now += ms;
        },
        fetch: fake.fetchImpl,
      });
    assert.deepEqual(await run("codex", apiA), { kind: "waiting" });
    assert.deepEqual(await run("hermes", apiB), { kind: "waiting" });
    const hermesPending = readFileSync(
      join(place.clHome, "hermes", "setup-device"),
      "utf8",
    );
    clock.now += 30_000;
    assert.deepEqual(await run("codex", apiA), { kind: "connected" });
    assert.equal(
      readFileSync(join(place.clHome, "hermes", "setup-device"), "utf8"),
      hermesPending,
    );
    assert.deepEqual(await run("hermes", apiB), { kind: "connected" });
    assert.equal(readToken(place, "codex"), TOKEN_A);
    assert.equal(readToken(place, "hermes"), TOKEN_B);
    assert.equal(
      apiA.sent.filter((r) => r.path === "/oauth/device_authorization").length,
      1,
    );
    assert.equal(
      apiB.sent.filter((r) => r.path === "/oauth/device_authorization").length,
      1,
    );
    assert.equal(readFileSync(legacy, "utf8"), "old multi-app approval\n");
  });

  it("says when the person ticked Bring in as they approved it (G1-89)", async () => {
    const { place } = computer();
    const clock = { now: 1_000_000 };
    const api = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [[200, { access_token: TOKEN_A, bring_in: true }]],
      },
      clock,
    );
    const run = () =>
      deviceSignin({
        place,
        api: API,
        apps: ["claude-code"],
        out: () => {},
        wait: "auto",
        open: () => false,
        now: () => clock.now,
        sleep: async (ms) => {
          clock.now += ms;
        },
        fetch: api.fetchImpl,
      });
    assert.deepEqual(await run(), { kind: "waiting" });
    clock.now += 30_000;
    assert.deepEqual(await run(), { kind: "connected", bringIn: true });
    assert.equal(readToken(place, "claude-code"), TOKEN_A);
  });

  it("says what the person picked for the import to read, leaving out names it doesn't know (G1-11)", async () => {
    const { place } = computer();
    const clock = { now: 1_000_000 };
    const api = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [
          [
            200,
            {
              access_token: TOKEN_A,
              bring_in: true,
              bring_in_apps: ["project", "safari", "codex", 7],
            },
          ],
        ],
      },
      clock,
    );
    const run = () =>
      deviceSignin({
        place,
        api: API,
        apps: ["claude-code"],
        out: () => {},
        wait: "auto",
        open: () => false,
        now: () => clock.now,
        sleep: async (ms) => {
          clock.now += ms;
        },
        fetch: api.fetchImpl,
      });
    assert.deepEqual(await run(), { kind: "waiting" });
    clock.now += 30_000;
    assert.deepEqual(await run(), {
      kind: "connected",
      bringIn: true,
      bringInApps: ["codex", "project"],
    });
  });

  it("can read the legacy multi-app response, with separate tokens", async () => {
    const { place } = computer();
    const clock = { now: 1_000_000 };
    const { sent, fetchImpl } = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [
          pending,
          [
            200,
            {
              access_token: TOKEN_A,
              tokens: [
                { harness: "claude-code", access_token: TOKEN_A },
                { harness: "codex", access_token: TOKEN_B },
              ],
            },
          ],
        ],
      },
      clock,
    );
    const lines: string[] = [];
    const opened: string[] = [];
    const result = await deviceSignin({
      place,
      api: API,
      apps: ["claude-code", "codex"],
      out: (line) => lines.push(line),
      wait: "auto",
      open: (link) => {
        opened.push(link);
        return true;
      },
      now: () => clock.now,
      sleep: async (ms) => {
        clock.now += ms;
      },
      fetch: fetchImpl,
    });
    assert.deepEqual(result, { kind: "connected" });
    assert.deepEqual(opened, [LINK]);

    const ask = sent[0] as Sent;
    assert.equal(ask.path, "/oauth/device_authorization");
    assert.deepEqual(ask.body.harnesses, ["claude-code", "codex"]);
    assert.equal(ask.body.harness, undefined);
    assert.match(
      String(ask.body.client_version),
      /^context-locker \d+\.\d+\.\d+$/,
    );
    assert.equal(ask.body.os, "Linux");
    assert.match(String(ask.body.machine_id), /^[a-f0-9]{32}$/);
    // The same id the sync scripts keep
    assert.equal(
      readFileSync(join(place.clHome, "machine-id"), "utf8").trim(),
      ask.body.machine_id,
    );

    // Polls no faster than the interval, plus a second
    const polls = sent.filter((request) => request.path === "/oauth/token");
    assert.equal(polls.length, 2);
    assert.ok((polls[1] as Sent).at - (polls[0] as Sent).at >= 6000);

    assert.equal(readToken(place, "claude-code"), TOKEN_A);
    assert.equal(readToken(place, "codex"), TOKEN_B);
    assert.equal(
      statSync(join(place.clHome, "codex", "token")).mode & 0o777,
      0o600,
    );
    assert.equal(
      existsSync(join(place.clHome, "codex", "setup-device")),
      false,
    );
    const said = lines.join("\n");
    assert.ok(said.includes(`  ${LINK}`));
    assert.ok(said.includes("Check that the page shows the code BCDF-GHJK."));
    assert.ok(!said.includes(TOKEN_A) && !said.includes("ctxl_dc_abc"));
  });

  it("hands the link back at once when it opened nowhere, then waits for the same code", async () => {
    const { place } = computer();
    const clock = { now: 1_000_000 };
    const { sent, fetchImpl } = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [[200, { access_token: TOKEN_A }]],
      },
      clock,
    );
    const run = (lines: string[]) =>
      deviceSignin({
        place,
        api: API,
        apps: ["codex"],
        out: (line) => lines.push(line),
        wait: "auto",
        open: () => false,
        now: () => clock.now,
        sleep: async (ms) => {
          clock.now += ms;
        },
        fetch: fetchImpl,
      });

    const first: string[] = [];
    assert.deepEqual(await run(first), { kind: "waiting" });
    assert.equal(sent.length, 1);
    assert.ok(
      first.includes(
        "Waiting for approval. Once it's approved, run this command again.",
      ),
    );
    assert.ok(existsSync(join(place.clHome, "codex", "setup-device")));

    clock.now += 30_000;
    const second: string[] = [];
    assert.deepEqual(await run(second), { kind: "connected" });
    // The same code, never a new one
    assert.equal(
      sent.filter((r) => r.path === "/oauth/device_authorization").length,
      1,
    );
    assert.equal((sent[1] as Sent).body.device_code, "ctxl_dc_abc");
    assert.equal(readToken(place, "codex"), TOKEN_A);
  });

  it("slows down when asked, and says it's still waiting when its time runs out", async () => {
    const { place } = computer();
    const clock = { now: 1_000_000 };
    const { sent, fetchImpl } = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [[400, { error: "slow_down" }], pending],
      },
      clock,
    );
    const lines: string[] = [];
    const result = await deviceSignin({
      place,
      api: API,
      apps: ["codex"],
      out: (line) => lines.push(line),
      wait: 40,
      open: () => true,
      now: () => clock.now,
      sleep: async (ms) => {
        clock.now += ms;
      },
      fetch: fetchImpl,
    });
    assert.deepEqual(result, { kind: "waiting" });
    const polls = sent.filter((request) => request.path === "/oauth/token");
    assert.ok(polls.length >= 2);
    assert.ok((polls[1] as Sent).at - (polls[0] as Sent).at >= 11_000);
    assert.equal(
      lines.at(-1),
      "Still waiting for approval. Once it's approved, run this command again.",
    );
    const kept = JSON.parse(
      readFileSync(join(place.clHome, "codex", "setup-device"), "utf8"),
    );
    assert.equal(kept.interval, 10);
    assert.equal(
      statSync(join(place.clHome, "codex", "setup-device")).mode & 0o777,
      0o600,
    );
  });

  for (const [error, said] of [
    ["access_denied", "The request was turned down, so nothing was connected."],
    ["expired_token", "The code expired before it was approved."],
    ["invalid_grant", "This code can't be used any more."],
  ] as const) {
    it(`stops on ${error}`, async () => {
      const { place } = computer();
      const clock = { now: 1_000_000 };
      const { fetchImpl } = fakeApi(
        {
          "/oauth/device_authorization": [started],
          "/oauth/token": [[400, { error }]],
        },
        clock,
      );
      const result = await deviceSignin({
        place,
        api: API,
        apps: ["codex"],
        out: () => {},
        wait: 30,
        open: () => true,
        now: () => clock.now,
        sleep: async (ms) => {
          clock.now += ms;
        },
        fetch: fetchImpl,
      });
      assert.equal(result.kind, "failed");
      assert.ok(result.kind === "failed" && result.message.startsWith(said));
      assert.equal(
        existsSync(join(place.clHome, "codex", "setup-device")),
        false,
      );
      assert.equal(readToken(place, "codex"), null);
    });
  }

  it("trusts no link but a plain web address, and no reply without every app's token", async () => {
    assert.equal(safeLink(LINK), LINK);
    assert.equal(
      safeLink("http://localhost:3000/device?code=X"),
      "http://localhost:3000/device?code=X",
    );
    assert.equal(safeLink("http://app.context.locker/device"), null);
    assert.equal(safeLink("javascript:alert(1)"), null);
    assert.equal(
      safeLink("https://app.context.locker/device?code=X&y=1"),
      null,
    );
    assert.equal(safeLink('https://app.context.locker/device?code="x"'), null);

    const { place } = computer();
    const clock = { now: 1_000_000 };
    const odd = fakeApi(
      {
        "/oauth/device_authorization": [
          [
            200,
            { ...started[1], verification_uri_complete: "file:///etc/passwd" },
          ],
        ],
      },
      clock,
    );
    const refused = await deviceSignin({
      place,
      api: API,
      apps: ["codex"],
      out: () => {},
      wait: 30,
      open: () => true,
      fetch: odd.fetchImpl,
    });
    assert.deepEqual(refused, {
      kind: "failed",
      message:
        "The sign-in reply didn't make sense, so nothing was saved. Try again.",
    });

    const short = fakeApi(
      {
        "/oauth/device_authorization": [started],
        "/oauth/token": [
          [
            200,
            {
              access_token: TOKEN_A,
              tokens: [{ harness: "claude-code", access_token: TOKEN_A }],
            },
          ],
        ],
      },
      clock,
    );
    const missing = await deviceSignin({
      place,
      api: API,
      apps: ["claude-code", "codex"],
      out: () => {},
      wait: 30,
      open: () => true,
      now: () => clock.now,
      sleep: async (ms) => {
        clock.now += ms;
      },
      fetch: short.fetchImpl,
    });
    assert.equal(missing.kind, "failed");
    assert.equal(readToken(place, "claude-code"), null);
  });
});

describe("connecting with a one-time code", () => {
  it("saves the token, or says the code can't be used", async () => {
    const { place } = computer();
    const clock = { now: 0 };
    const code = `ctxl_ic_${"c".repeat(43)}`;
    const ok = fakeApi(
      { "/oauth/token": [[200, { access_token: TOKEN_B }]] },
      clock,
    );
    assert.deepEqual(
      await claimCode({
        place,
        api: API,
        app: "hermes",
        code,
        fetch: ok.fetchImpl,
      }),
      { kind: "connected" },
    );
    const sent = ok.sent[0] as Sent;
    assert.equal(
      sent.body.grant_type,
      "urn:context-locker:params:oauth:grant-type:invite",
    );
    assert.equal(sent.body.invite_code, code);
    assert.equal(sent.body.harness, "hermes");
    assert.equal(readToken(place, "hermes"), TOKEN_B);

    // A code made with Bring in ticked says so, for setup's last line (G1-89)
    const ticked = fakeApi(
      { "/oauth/token": [[200, { access_token: TOKEN_A, bring_in: true }]] },
      clock,
    );
    assert.deepEqual(
      await claimCode({
        place,
        api: API,
        app: "claude-code",
        code,
        fetch: ticked.fetchImpl,
      }),
      { kind: "connected", bringIn: true },
    );

    const used = fakeApi(
      { "/oauth/token": [[400, { error: "invalid_grant" }]] },
      clock,
    );
    const refused = await claimCode({
      place,
      api: API,
      app: "hermes",
      code,
      fetch: used.fetchImpl,
    });
    assert.equal(refused.kind, "failed");
    assert.ok(
      refused.kind === "failed" &&
        /works once, for 15 minutes/.test(refused.message),
    );
  });
});
