// Each MCP tool's twin in the sync script (G1-335): the command that does
// the same job under the agent's own connection, taking the tool's fields as
// a JSON file and giving its reply, so nothing an agent can do over MCP is
// out of reach on device sync. The API's tests check that every tool is
// here, and the scripts' tests that every command is in both scripts' help.

/** A tool's command, as the script's help writes it, or why it has none */
export type ToolCommand = { command: string } | { none: string };

export const TOOL_COMMANDS: Readonly<Record<string, ToolCommand>> =
  Object.freeze({
    get_context: { command: "context" },
    get_skill: {
      none: "The sync puts every skill, the guide too, in the skills folder.",
    },
    project_map: { command: "map" },
    manage_project: { command: "projects manage" },
    list_notes: { command: "notes list" },
    search_notes: { command: "notes search" },
    read_note: { command: "notes read" },
    list_versions: { command: "versions list" },
    read_version: { command: "versions read" },
    write_note: { command: "notes write" },
    record_docs_home: { command: "projects docs-home" },
    list_tasks: { command: "tasks list" },
    read_task: { command: "tasks read" },
    write_task: { command: "tasks write" },
    record_work_places: { command: "tasks places" },
    remember: { command: "remember" },
    suggest: { command: "suggest" },
    submit_import: { command: "import-submit" },
    upload: {
      none: "The script sends a big import plan in parts itself.",
    },
    pending_changes: { command: "requests list" },
    read_request: { command: "requests read" },
    decide_request: { command: "requests answer" },
    decide_change: { command: "requests decide" },
    fix_list: { command: "fix" },
    mark_fix: { command: "fix --done|--skip|--working|--waiting" },
    message: { command: "message" },
    record_skill_source: { command: "skills source" },
    whoami: { command: "whoami" },
  });

/**
 * A command with the app's name in its place, after the command's first
 * word, as the script takes it: `notes codex write`, or `notes <app> write`
 */
export function commandLine(command: string, app: string): string {
  const space = command.indexOf(" ");
  return space === -1
    ? `${command} ${app}`
    : `${command.slice(0, space)} ${app}${command.slice(space)}`;
}

/** A tool's command for an app, or null when it has none */
export function toolCommand(tool: string, app: string): string | null {
  const twin = Object.hasOwn(TOOL_COMMANDS, tool)
    ? TOOL_COMMANDS[tool]
    : undefined;
  return twin && "command" in twin ? commandLine(twin.command, app) : null;
}
