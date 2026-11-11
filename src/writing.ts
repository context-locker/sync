/**
 * Writing for AI apps (G1-310): the mechanical checks of the standard in
 * AGENTS.md, which the tests run over every text an AI app reads. Each
 * check finds what a text says that the standard rules out: a length over
 * its budget, history, a reference, a hash, a date, a dash, an American
 * spelling, a second word for the person, or a sentence said twice.
 */

/** Length budgets, in characters, for each kind of text an AI app reads */
export const AI_TEXT_BUDGETS = Object.freeze({
  /** The standing rules, before their slots are filled */
  rules: 2_500,
  /** The MCP server's instructions */
  serverInstructions: 3_000,
  /** One tool's description, without its fields */
  toolDescription: 800,
  /** One field's description */
  fieldDescription: 300,
  /** get_context's text before the playbook's own content */
  contextHead: 3_000,
  /** One topic of the guide */
  guideTopic: 4_000,
  /** One line of the session start, such as what waits for the app */
  sessionStartLine: 600,
  /** One tool reply's fixed message */
  reply: 600,
  /** The line the per-prompt hook and every tool reply add */
  promptLine: 300,
});

export type AiTextBudget = keyof typeof AI_TEXT_BUDGETS;

/**
 * Each part of an MCP tool's description, and of a sync script command's
 * help, at most (G1-309): what it does, its fields and the limits that make a
 * call valid or safe, before the line naming its topic in the guide
 */
export const DOC_PARTS = Object.freeze({
  does: 200,
  fields: 210,
  limits: 280,
});

/** One text an AI app reads, as a test gathers it */
export interface AiText {
  /** What it is, such as "tool write_ticket" or "the setup skill" */
  id: string;
  /** The text as an app reads it */
  text: string;
  /** The budget it keeps within, when its kind has one */
  budget?: AiTextBudget;
  /** A field's description may show a date's format, such as 2026-10-20 */
  formatExamples?: boolean;
  /**
   * Texts built from one source for places no app reads together, such as a
   * project's block in a repo and the same project's session start, share
   * it, so the duplicate check counts a sentence in them once
   */
  source?: string;
  /**
   * Text this one carries from sources gathered on their own, such as the
   * standing rules (G1-309) or where documents go (G1-321): checked there,
   * so nothing in it counts here again, though its length does
   */
  includes?: string | readonly string[];
}

/** A text's own words, without what it carries from sources checked on their own */
function ownText(text: AiText): string {
  const carried =
    typeof text.includes === "string" ? [text.includes] : (text.includes ?? []);
  return carried.reduce((own, part) => own.split(part).join("\n"), text.text);
}

export type FindingRule =
  | "budget"
  | "history"
  | "reference"
  | "hash"
  | "date"
  | "dash"
  | "spelling"
  | "glossary"
  | "duplicate";

/** One way a text breaks the standard */
export interface Finding {
  /** The text's id, or for a duplicate the ids of every text that says it */
  text: string;
  rule: FindingRule;
  /** What matched, as the checks write it: lower case, or the sentence */
  match: string;
  /** How many times it matched, or for a budget the text's length */
  count: number;
}

/** History an app can't act on: compatibility notes and ticket trails */
const HISTORY = /\b(still works?|still accepted|older|since G1-)/gi;

/** A ticket or change number: G1-152, CL-123 or #123 */
const REFERENCE = /\b[A-Z][A-Z0-9]{0,3}-\d{1,5}\b|(?<![\w&])#\d{1,6}\b/g;
/** Names of standards that look like references, such as SHA-256 */
const NOT_A_REFERENCE = /^(?:SHA|UTF|ISO|RFC|TLS|HTTP|ES|RS|PS|HS)-\d+$/;

/** A run of hex an app can't act on: a commit, a release or a hash */
const HASH = /\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,}\b/g;
const UUID =
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;

const MONTHS =
  "Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?";
/** A date in words, such as 9 Nov 2026 or November 2026 */
const WORD_DATE = new RegExp(
  `\\b(?:\\d{1,2} (?:${MONTHS}) \\d{4}|(?:${MONTHS}) \\d{4})\\b`,
  "g",
);
/** A date in figures, such as 2026-11-09 */
const ISO_DATE = /\b\d{4}-\d{2}-\d{2}\b/g;

const DASH = /[–—]/g;

/** American spellings, each with its British one in the standard */
const AMERICAN = [
  "color",
  "colors",
  "behavior",
  "behaviors",
  "favorite",
  "favorites",
  "center",
  "centers",
  "canceled",
  "canceling",
  "catalog",
  "catalogs",
  "license",
  "organization",
  "organizations",
  "organize",
  "organized",
  "prioritize",
  "prioritized",
  "recognize",
  "recognized",
  "summarize",
  "summarized",
  "customize",
  "customized",
  "analyze",
  "analyzed",
  "realize",
  "minimize",
  "normalize",
  "normalized",
  "optimize",
  "authorize",
  "authorized",
  "authorization",
  "finalize",
  "serialize",
  "apologize",
  "emphasize",
  "utilize",
];
const SPELLING = new RegExp(`\\b(?:${AMERICAN.join("|")})\\b`, "gi");

/**
 * The words one glossary retires, in what people and agents read alike
 * (G1-319), each with the word that takes its place, as AGENTS.md's glossary
 * says. The writing test finds them in what agents read, and the people's
 * words test in the web app, the site and the emails.
 */
export const RETIRED_WORDS = Object.freeze([
  { word: "user", say: "the person" },
  { word: "owner", say: "the person, apart from a team's owner" },
  { word: "Everywhere", say: "My playbook" },
  { word: "playbook", say: "a project, apart from My playbook and a team's" },
  { word: "ticket", say: "a task" },
  { word: "AI app", say: "an agent" },
  { word: "AI inbox", say: "an agent's inbox" },
  { word: "connection", say: "an agent" },
  { word: "workspace", say: "a team, or nothing" },
  { word: "suggestion", say: "a change" },
  { word: "persona", say: "nothing, as it was never built" },
] as const);

/** Owner as a team's role: the team's owner, or beside admins */
const TEAM_OWNER = [
  /\bteams?(?:'s|')?\s+owners?\b/gi,
  /\bowners?(?:,\s*|\s+(?:and|or)\s+)(?:the\s+|an?\s+)?admins?\b/gi,
  /\badmins?(?:,\s*|\s+(?:and|or)\s+)(?:the\s+|an?\s+)?owners?\b/gi,
];
/** What a playbook stays after: My playbook, yours, and a team's */
const KEPT_PLAYBOOK = /(?:\bmy|\byour|\bteam|\bteam's|\bteams')\s+$/i;

/**
 * How often prose uses each retired word. Owner counts only where it isn't a
 * team's role, and playbook wherever it means one body of work, as a tool's
 * name such as playbook_map does. Everywhere counts as the place, with its
 * capital; everywhere as a plain word stays.
 */
export function retiredWords(prose: string): Map<string, number> {
  const counts = new Map<string, number>();
  const count = (word: string, pattern: RegExp, text = prose) => {
    for (const _ of text.matchAll(pattern))
      counts.set(word, (counts.get(word) ?? 0) + 1);
  };
  count("user", /\busers?(?:'s|s')?\b/gi);
  count(
    "owner",
    /\bowners?(?:'s|s')?\b/gi,
    TEAM_OWNER.reduce((text, role) => text.replace(role, " "), prose),
  );
  count("Everywhere", /\bEverywhere\b/g);
  for (const found of prose.matchAll(/\b\w*playbooks?\w*\b/gi))
    if (
      // A name in code that holds my_playbook, such as a field's, is My
      // playbook's (G1-321)
      !/my_playbooks?(?![a-z])/i.test(found[0]) &&
      (!/^playbook$/i.test(found[0]) ||
        !KEPT_PLAYBOOK.test(
          prose.slice(Math.max(0, found.index - 12), found.index),
        ))
    )
      counts.set("playbook", (counts.get("playbook") ?? 0) + 1);
  count("ticket", /\b\w*tickets?\w*\b/gi);
  count("AI app", /\bAI\s+apps?(?:'s|s')?\b/gi);
  count("AI inbox", /\bAI\s+inbox(?:es|'s)?\b/gi);
  count("connection", /\bconnections?(?:'s|s')?\b/gi);
  count("workspace", /\bworkspaces?(?:'s|s')?\b/gi);
  count("suggestion", /\bsuggestions?\b/gi);
  count("persona", /\bpersonas?\b/gi);
  return counts;
}

/** Text that isn't prose: code spans, code blocks and addresses */
function prose(text: string): string {
  return text
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`[^`\n]*`/g, " ")
    .replace(/\bhttps?:\/\/\S+/g, " ")
    .replace(/\]\([^)\s]*\)/g, "]")
    .replace(/\b[\w.-]+\/[\w./-]+/g, " ");
}

function countMatches(
  text: string,
  pattern: RegExp,
  normalise: (match: string) => string | undefined,
) {
  const counts = new Map<string, number>();
  for (const found of text.matchAll(pattern)) {
    const key = normalise(found[0]);
    if (key !== undefined) counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

/** What one text breaks of the standard, apart from duplicates across texts */
export function checkAiText(text: AiText): Finding[] {
  const findings: Finding[] = [];
  const add = (rule: FindingRule, counts: Map<string, number>) => {
    for (const [match, count] of counts)
      findings.push({ text: text.id, rule, match, count });
  };
  if (
    text.budget !== undefined &&
    text.text.length > AI_TEXT_BUDGETS[text.budget]
  ) {
    findings.push({
      text: text.id,
      rule: "budget",
      match: text.budget,
      count: text.text.length,
    });
  }
  const own = ownText(text);
  const words = prose(own);
  add(
    "history",
    countMatches(words, HISTORY, (match) => match.toLowerCase()),
  );
  add(
    "reference",
    countMatches(words, REFERENCE, (match) =>
      NOT_A_REFERENCE.test(match) ? undefined : match,
    ),
  );
  add(
    "hash",
    countMatches(words.replace(UUID, " "), HASH, () => "a hash"),
  );
  add(
    "date",
    countMatches(words, WORD_DATE, (match) => match),
  );
  if (!text.formatExamples)
    add(
      "date",
      countMatches(words, ISO_DATE, (match) => match),
    );
  add(
    "dash",
    countMatches(own, DASH, (match) => (match === "—" ? "em dash" : "en dash")),
  );
  add(
    "spelling",
    countMatches(words, SPELLING, (match) => match.toLowerCase()),
  );
  add("glossary", retiredWords(words));
  return findings;
}

/**
 * A text's sentences as the duplicate check compares them: code blocks and
 * Markdown's marks taken off, in lower case, with sentences of fewer than
 * six words left out, as short ones such as "Read it with read_note." recur
 * by design.
 */
export function sentencesOf(text: string): string[] {
  const sentences: string[] = [];
  for (const rawLine of text.replace(/```[\s\S]*?```/g, "").split("\n")) {
    const line = rawLine
      .replace(/^\s*(?:#{1,6}\s+|[-*+]\s+(?:\[[ x]\]\s+)?|\d+\.\s+|>\s+)/, "")
      .replace(/\|/g, " ")
      .replace(/\*\*|__|`/g, "")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .trim();
    if (!line) continue;
    for (const piece of line.split(/(?<=[.!?:;])\s+(?=[A-Z"'(])/)) {
      const sentence = piece
        .replace(/\s+/g, " ")
        .replace(/[.!?:;,]+$/, "")
        .trim()
        .toLowerCase();
      if (sentence.split(" ").length >= 6) sentences.push(sentence);
    }
  }
  return sentences;
}

/**
 * Every sentence said more than once, in one text or across several. Texts
 * that share a source count as one, by the most times any of them says it.
 */
export function duplicateSentences(texts: AiText[]): Finding[] {
  const seen = new Map<
    string,
    { ids: Set<string>; bySource: Map<string, number> }
  >();
  for (const text of texts) {
    const inThis = new Map<string, number>();
    for (const sentence of sentencesOf(ownText(text))) {
      inThis.set(sentence, (inThis.get(sentence) ?? 0) + 1);
    }
    for (const [sentence, count] of inThis) {
      const entry = seen.get(sentence) ?? {
        ids: new Set<string>(),
        bySource: new Map(),
      };
      const source = text.source ?? text.id;
      entry.ids.add(text.id);
      entry.bySource.set(
        source,
        Math.max(entry.bySource.get(source) ?? 0, count),
      );
      seen.set(sentence, entry);
    }
  }
  const findings: Finding[] = [];
  for (const [sentence, { ids, bySource }] of seen) {
    const count = [...bySource.values()].reduce((sum, n) => sum + n, 0);
    if (count > 1) {
      findings.push({
        text: [...ids].sort().join(" + "),
        rule: "duplicate",
        match: sentence,
        count,
      });
    }
  }
  return findings;
}

/** Every finding across a set of texts */
export function checkAiTexts(texts: AiText[]): Finding[] {
  return [...texts.flatMap(checkAiText), ...duplicateSentences(texts)];
}

/** A finding's key in a baseline: a duplicate is the same sentence wherever it moves */
export function findingKey(
  finding: Pick<Finding, "text" | "rule" | "match">,
): string {
  return finding.rule === "duplicate"
    ? `duplicate\u0000${finding.match}`
    : `${finding.text}\u0000${finding.rule}\u0000${finding.match}`;
}

/** How a set of findings compares with a baseline that may only shrink */
export interface BaselineComparison {
  /** Findings the baseline doesn't hold, or that matched more often than it allows */
  added: Finding[];
  /** Baseline entries no text breaks any more, to take out of it */
  stale: Finding[];
  /** Baseline entries a text now breaks less often, to lower */
  lower: Array<{ entry: Finding; now: number }>;
}

/** Compares findings with a baseline, which only ever shrinks */
export function compareWithBaseline(
  findings: Finding[],
  baseline: Finding[],
): BaselineComparison {
  const allowed = new Map(baseline.map((entry) => [findingKey(entry), entry]));
  const current = new Map(
    findings.map((finding) => [findingKey(finding), finding]),
  );
  const added: Finding[] = [];
  const lower: BaselineComparison["lower"] = [];
  for (const [key, finding] of current) {
    const entry = allowed.get(key);
    if (!entry || finding.count > entry.count) added.push(finding);
    else if (finding.count < entry.count)
      lower.push({ entry, now: finding.count });
  }
  const stale = baseline.filter((entry) => !current.has(findingKey(entry)));
  return { added, stale, lower };
}
