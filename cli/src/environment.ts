import type { Environment } from "@internal/shared";

/** Only positive provider signals identify a cloud session. OS, SSH, Docker
 * and generic hostnames are ambiguous, so without a signal Context Locker
 * takes it to run on a device (G1-204). */
export function environmentOf(
  env: NodeJS.ProcessEnv,
  chosen?: Environment,
): Environment | undefined {
  if (chosen) return chosen;
  // https://docs.github.com/en/codespaces/developing-in-a-codespace/default-environment-variables-for-your-codespace
  // https://claude.com/resources/articles/how-to-configure-hooks
  if (env.CODESPACES === "true" || env.CLAUDE_CODE_REMOTE === "true")
    return "cloud";
  return undefined;
}

/**
 * A Claude cloud session, as Claude sets it up (G1-260): Claude in Cowork,
 * which gets Context Locker from the person's Claude account connector, or
 * another, such as Claude Code on the web, whose sandbox may not last.
 * Keyed on CLAUDE_CODE_REMOTE, never on the environment alone, so a
 * codespace sets up as before.
 */
export function claudeCloudOf(
  env: NodeJS.ProcessEnv,
): "cowork" | "other" | null {
  if (env.CLAUDE_CODE_REMOTE !== "true") return null;
  return env.CLAUDE_CODE_ENTRYPOINT === "remote_cowork" ? "cowork" : "other";
}

/** Why setup stops in Claude in Cowork, unless it's told to go on (G1-260) */
export const COWORK_REFUSAL =
  "This is a Claude cloud session, such as Cowork or Claude on the web. It gets Context Locker from your account's Claude connector, which covers every chat, so device sync isn't needed here. To connect this sandbox on purpose, add --environment cloud.";

/** What setup says, and goes on, in another Claude cloud session (G1-260) */
export const CLOUD_SANDBOX_WARNING =
  "This is a Claude cloud session, whose sandbox may not last: a device connection made here ends with it.";
