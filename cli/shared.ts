// The parts of Context Locker's shared package that the setup command uses,
// copied unchanged from the platform repo's packages/shared/src: the
// environments from connections.ts, and the harnesses, their names and the
// one-time code grant from identity.ts. cli/tsconfig.json points
// @internal/shared here, so cli/src stays as the platform repo has it.

/** Where an app runs, independently of which app it is and how it connects. */
export const ENVIRONMENTS = ["computer", "cloud"] as const;
export type Environment = (typeof ENVIRONMENTS)[number];

/** The coding agents that connect with a device code. */
export const HARNESSES = [
  "claude-code",
  "codex",
  "grok-build",
  "hermes",
  "openclaw",
  "other",
] as const;

export type Harness = (typeof HARNESSES)[number];

/**
 * Apps that connect over MCP. Claude and ChatGPT sign in with OAuth and are
 * recognised by their client ID metadata documents; any other app that signs
 * in is "mcp" and goes by the name it gives. Claude Code can connect this way
 * too, as "claude-code". An app in the cloud that sends a key, such as Muse or
 * Grok Bot, is "cloud".
 */
export const MCP_HARNESSES = ["claude", "chatgpt", "mcp", "cloud"] as const;

export type McpHarness = (typeof MCP_HARNESSES)[number];

/** Every kind of AI app an agent can be. */
export const AGENT_HARNESSES = [...HARNESSES, ...MCP_HARNESSES] as const;

export type AgentHarness = (typeof AGENT_HARNESSES)[number];

/** How each harness is named in the app */
export const HARNESS_NAMES: Readonly<Record<AgentHarness, string>> =
  Object.freeze({
    "claude-code": "Claude Code",
    codex: "Codex",
    "grok-build": "Grok Build",
    hermes: "Hermes",
    openclaw: "OpenClaw",
    other: "An AI app",
    claude: "Claude",
    chatgpt: "ChatGPT",
    mcp: "An AI app",
    cloud: "An AI app in the cloud",
  });

/**
 * The grant an AI app claims a one-time code with, at the token endpoint. It's
 * an extension grant (RFC 6749 4.5), as no standard grant fits a code the
 * person made before the app asked.
 */
export const INVITE_GRANT = "urn:context-locker:params:oauth:grant-type:invite";
