// Places only one AI app can open (G1-157)
import assert from "node:assert/strict";
import { test } from "node:test";
import { oneAppPlace } from "../src/one-app-places.js";
import { docsLocationsRule, startHereLine } from "../src/render.js";

test("names the one app that can open an artifact, a chat or a project", () => {
  for (const [address, who, place] of [
    ["https://claude.ai/artifact/82cf5fce", "Claude", "a Claude artifact"],
    [
      "https://claude.ai/code/artifact/5d0b77a3-12fe-4bda-b5c1-f55691d86a78",
      "Claude",
      "a Claude artifact",
    ],
    ["https://claude.ai/chat/0b1c2d3e", "Claude", "a Claude chat"],
    ["https://Claude.AI/project/9f8e7d", "Claude", "a Claude project"],
    ["https://chatgpt.com/c/68a1b2c3", "ChatGPT", "a ChatGPT chat"],
    [
      "https://chatgpt.com/g/g-p-123abc/c/68a1b2c3",
      "ChatGPT",
      "a ChatGPT chat",
    ],
    ["https://chat.openai.com/c/68a1b2c3", "ChatGPT", "a ChatGPT chat"],
    ["https://gemini.google.com/app/4f5e6d", "Gemini", "a Gemini chat"],
    ["https://grok.com/c/7a8b9c", "Grok", "a Grok chat"],
  ] as const) {
    assert.deepEqual(oneAppPlace(address), { who, place }, address);
  }
});

test("names the computer for a page only it serves", () => {
  for (const address of [
    "http://localhost:3000/dashboard",
    "http://127.0.0.1:8080/",
    "http://[::1]:4000/queue",
    "http://tracking.localhost/",
  ]) {
    assert.deepEqual(
      oneAppPlace(address),
      { who: "the computer that serves it", place: "a page on one computer" },
      address,
    );
  }
});

test("leaves out what every app can read: public shares, the web and the repo", () => {
  for (const address of [
    "https://claude.ai/public/artifacts/82cf5fce",
    "https://chatgpt.com/share/68a1b2c3",
    "https://grok.com/share/7a8b9c",
    "https://claude.ai/",
    "https://www.notion.so/acme/Posting-Queue-1a2b",
    "https://github.com/v20x/context-locker/pull/198",
    "https://docs.google.com/document/d/1abc/edit",
    "docs/runbook.md",
    "",
  ]) {
    assert.equal(oneAppPlace(address), null, address);
  }
});

test("a Start here link or a documentation location says when only one app can open it", () => {
  const entry = {
    id: "q",
    version: 1,
    title: "Posting Queue",
    kind: "plan",
    summary: "What goes out next.",
    address: "https://claude.ai/artifact/9f1e2d" as string | null,
    name: "posting-queue",
  };
  assert.equal(
    startHereLine(entry),
    "- [Posting Queue](https://claude.ai/artifact/9f1e2d) (plan, only Claude can open it): What goes out next.",
  );
  assert.equal(
    startHereLine({ ...entry, address: "docs/queue.md" }),
    "- [Posting Queue](docs/queue.md) (plan): What goes out next.",
  );
  const rule = docsLocationsRule([
    {
      id: "a",
      name: "Dashboard",
      kind: "place",
      place: "http://localhost:3000/",
      purpose: "",
      is_default: false,
    },
    {
      id: "n",
      name: "Notes",
      kind: "notes",
      place: null,
      purpose: "",
      is_default: true,
    },
  ]);
  assert.match(
    rule,
    /Keep anything another AI app needs where every app can read it: a place only one app can open, such as a Claude artifact, a chat, a session's own files or a page on localhost, is fine as a view or a working copy, never as its only home\./,
  );
  assert.match(
    rule,
    /- Dashboard: http:\/\/localhost:3000\/ \(only the computer that serves it can open it\)/,
  );
  assert.match(rule, /- Notes \(default\): Context Locker Notes$/m);
});
