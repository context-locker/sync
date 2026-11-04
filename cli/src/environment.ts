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
