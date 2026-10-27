// Wording that AI apps treat as prompt injection. Hermes scans the files it
// loads and refuses a whole project file (such as a repo's AGENTS.md) when any
// line matches, so a compiled block must never match, and a preference that
// matches is left out of shared project files.
//
// These follow the context-file patterns in Hermes's tools/threat_patterns.py
// (NousResearch/hermes-agent at 5851be7, 17 Oct 2026). They are written from
// its pattern list and lean broad: leaving a line out costs less than a
// refused file.

// Up to eight words between the key words, as Hermes allows
const FILLER = String.raw`(?:\w+\s+){0,8}`;

const PATTERNS: ReadonlyArray<readonly [string, RegExp]> = [
  [
    "prompt_injection",
    new RegExp(
      String.raw`\bignore\s+${FILLER}(?:previous|all|above|prior)\s+${FILLER}instructions\b`,
      "iu",
    ),
  ],
  ["sys_prompt_override", /\bsystem\s+prompt\s+override\b/iu],
  [
    "disregard_rules",
    new RegExp(
      String.raw`\bdisregard\s+${FILLER}(?:your|all|any)\s+${FILLER}(?:rules|instructions|guidelines)\b`,
      "iu",
    ),
  ],
  [
    "bypass_restrictions",
    new RegExp(
      String.raw`\b(?:bypass|act\s+as\s+if\s+you\s+have\s+no)\s+${FILLER}(?:restrictions|limits|rules|filters)\b`,
      "iu",
    ),
  ],
  [
    "html_comment_injection",
    /<!--[^>]{0,512}(?:ignore|override|system|secret|hidden)[^>]{0,512}-->/iu,
  ],
  ["hidden_div", /<div\s+style\s*=\s*["'][^"']*display\s*:\s*none/iu],
  [
    "translate_execute",
    new RegExp(
      String.raw`\btranslate\s+${FILLER}(?:and|then)\s+(?:execute|run|eval)\b`,
      "iu",
    ),
  ],
  [
    "deception_hide",
    new RegExp(
      String.raw`\b(?:do\s+not|don't|never)\s+${FILLER}(?:tell|inform|show)\s+${FILLER}the\s+user\b`,
      "iu",
    ),
  ],
  [
    "exfil_curl",
    /\b(?:curl|wget)\b[^\n]{0,200}\$\{?\w*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)/iu,
  ],
  [
    "read_secrets",
    /\bcat\s+[^\n]{0,80}(?:\.env\b|credentials|\.netrc|\.pgpass|id_rsa)/iu,
  ],
  [
    "role_hijack",
    new RegExp(String.raw`\byou\s+are\s+${FILLER}now\s+(?:a|an|the)\b`, "iu"),
  ],
  [
    "role_pretend",
    new RegExp(String.raw`\bpretend\s+${FILLER}(?:to\s+be|you\s+are)\b`, "iu"),
  ],
  [
    "leak_system_prompt",
    new RegExp(
      String.raw`\b(?:output|print|reveal|repeat|show)\s+${FILLER}(?:system|initial|original)\s+(?:prompt|instructions)\b`,
      "iu",
    ),
  ],
  [
    "remove_filters",
    new RegExp(
      String.raw`\b(?:remove|disable|turn\s+off)\s+${FILLER}(?:filters|safety|guardrails|restrictions)\b`,
      "iu",
    ),
  ],
  [
    "fake_update",
    new RegExp(
      String.raw`\byou\s+have\s+been\s+${FILLER}(?:updated|upgraded|reprogrammed)\b`,
      "iu",
    ),
  ],
  ["identity_override", /\b(?:name|call)\s+yourself\b/iu],
  ["c2_node_registration", /\bregister\s+(?:\w+\s+){0,3}as\s+a\s+node\b/iu],
  ["c2_heartbeat", /\b(?:heartbeat|beacon|check[\s-]?in)\s+(?:to|with)\b/iu],
  ["c2_task_pull", /\bpull\s+(?:new\s+)?tasks\b/iu],
  ["c2_network_connect", /\bconnect\s+to\s+the\s+network\b/iu],
  [
    "forced_action",
    new RegExp(
      String.raw`\byou\s+must\s+${FILLER}(?:register|connect|report|beacon)\b`,
      "iu",
    ),
  ],
  [
    "anti_forensic",
    /\b(?:history\s+-c|shred\s+-|unset\s+HISTFILE|wipe\s+(?:the\s+)?logs?)\b/iu,
  ],
  [
    "env_var_unset_agent",
    /\bunset\s+[^\n]{0,40}(?:HERMES|CLAUDE|CODEX|OPENAI|ANTHROPIC)/iu,
  ],
  [
    "known_c2_framework",
    /\b(?:cobalt\s+strike|sliver|havoc|mythic|metasploit|brainworm)\b/iu,
  ],
  ["c2_explicit", /\bcommand[\s-]+and[\s-]+control\b/iu],
];

// Zero-width and direction-changing characters that hide text, as code point
// ranges, so this file holds none of them itself
const INVISIBLE: ReadonlyArray<readonly [number, number]> = [
  [0x200b, 0x200d],
  [0x2060, 0x2060],
  [0x2062, 0x2064],
  [0xfeff, 0xfeff],
  [0x202a, 0x202e],
  [0x2066, 0x2069],
];

function hasInvisible(text: string): boolean {
  for (const character of text) {
    const point = character.codePointAt(0) ?? 0;
    if (INVISIBLE.some(([low, high]) => point >= low && point <= high)) {
      return true;
    }
  }
  return false;
}

/** The ids of the injection patterns some text matches. Empty when it's clean. */
export function injectionMatches(text: string): string[] {
  const normalized = text.normalize("NFKC").slice(0, 65_536);
  const found = PATTERNS.filter(([, pattern]) => pattern.test(normalized)).map(
    ([id]) => id,
  );
  if (hasInvisible(text)) found.push("invisible_unicode");
  return found;
}

/** One occurrence of each matched rule, with offsets in the original text. */
export interface InjectionEvidence {
  id: string;
  start: number;
  end: number;
}

export function injectionEvidence(text: string): InjectionEvidence[] {
  const source = text.slice(0, 65_536);
  let normalized = source.normalize("NFKC");
  let starts: number[] | null = null;
  let ends: number[] | null = null;
  if (normalized !== source) {
    starts = [];
    ends = [];
    let mapped = "";
    // Graphemes keep combining sequences together. A normalised match
    // still points to its original characters, including full-width text.
    for (const part of new Intl.Segmenter("en", {
      granularity: "grapheme",
    }).segment(source)) {
      const value = part.segment.normalize("NFKC");
      mapped += value;
      for (let index = 0; index < value.length; index++) {
        starts.push(part.index);
        ends.push(part.index + part.segment.length);
      }
    }
    if (mapped !== normalized) return []; // Never invent a source location.
  }
  normalized = normalized.slice(0, 65_536);
  return PATTERNS.flatMap(([id, pattern]) => {
    const match = pattern.exec(normalized);
    if (!match) return [];
    const start = starts?.[match.index] ?? match.index;
    const last = match.index + match[0].length;
    const end = ends?.[last - 1] ?? last;
    return [{ id, start, end }];
  });
}
