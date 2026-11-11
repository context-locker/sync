export {
  BLOCK_END,
  BLOCK_START,
  BrokenBlockError,
  extractBlock,
  findBlock,
  isMarkerLine,
  spliceBlock,
} from "./blocks.js";
export type { BlockPosition } from "./blocks.js";
export {
  BUNDLE_HEADER,
  DELTA_BUNDLE_HEADER,
  BundleError,
  parseBundle,
  writeBundle,
} from "./bundle.js";
export {
  BUDGETS,
  OPENCLAW_AGENTS_MD,
  OPENCLAW_USER_MD,
  ROOM_MEASURED,
  TARGETS,
  compile,
  notesSynced,
} from "./compile.js";
export {
  IMPORT_PLAN_EXAMPLE,
  IMPORT_SKILL_DESCRIPTION,
  IMPORT_NOW,
  IMPORT_SKILL_ID,
  IMPORT_SKILL_LIMITS,
  IMPORT_SKILL_MODEL,
  IMPORT_SKILL_NAME,
  IMPORT_SKILL_VERSION,
  LEGACY_IMPORT_SKILL_NAME,
  RESERVED_SKILL_PREFIX,
  importSkill,
  importSkillFiles,
  isReservedSkillName,
} from "./import-skill.js";
export {
  MANAGED_MARKER,
  blockHash,
  fileBytes,
  isIgnoredFile,
  sha256,
  treeHash,
} from "./hash.js";
export {
  MEMORY_FILE_ENDINGS,
  MEMORY_PLACES,
  MEMORY_TARGET_CHARACTERS,
  memoryPlaceOf,
} from "./memory-places.js";
export type { MemoryPlace } from "./memory-places.js";
export { DEVICE_APPS } from "./device-apps.js";
export type { DeviceApp } from "./device-apps.js";
export {
  MANIFEST_HEADER,
  MEMORY_FILES,
  SYNC_SCRIPT_RELEASE,
  SYNC_SCRIPT_VERSION,
  buildManifest,
  parseManifest,
} from "./manifest.js";
export type {
  Blob,
  Hold,
  Manifest,
  ManifestEntry,
  MemoryFiles,
  RepoLink,
  ScriptRelease,
  ScriptShell,
} from "./manifest.js";
export {
  EVERYWHERE_FOLDER,
  NOTES_FOLDER,
  NOTES_PATH,
  NOTES_README,
  NOTE_FILE_RULES,
  NOTE_REPLY_HEADER,
  README_TEXT,
  isNoteFileName,
  isReservedNoteName,
  noteFileName,
  noteTarget,
  notesFolderOutputs,
  parseNoteReply,
  parseNoteTarget,
  renderNoteFile,
  renderNotesReadme,
  splitNoteFile,
  writeNoteReply,
  yamlString,
} from "./notes.js";
export type { NoteReply } from "./notes.js";
export {
  DOCS_LOCATIONS_RULE,
  NO_DOCS_LOCATIONS,
  OLD_INTROS,
  START_HERE_MOST,
  startHereShown,
  TEXT,
  docsHomeRule,
  docsLocationsRule,
  oneAppOnly,
  workPlacesRule,
  linkDestination,
  plainMarkdown,
  ASK_PROTOCOL,
  LOG_DECISIONS,
  preferenceLine,
  startHereLine,
} from "./render.js";
export {
  SKILL_NAME,
  allowedTargets,
  isProjectTarget,
  parseTarget,
} from "./targets.js";
export type { ParsedTarget } from "./targets.js";
export {
  TAR_END,
  blobArchive,
  blobArchiveParts,
  resolvedBlobArchiveParts,
  tarHeader,
  tarPadding,
  writeTar,
} from "./tar.js";
export type { TarEntry } from "./tar.js";
export {
  HOOK_EVENTS,
  OPENCLAW_HOOK_NAME,
  PROMPT_HOOK_EVENTS,
  PROMPT_HOOK_TIMEOUT,
  SYNC_SCRIPT_PATTERN,
  hermesHookCommand,
  hermesHookYaml,
  hermesPromptCommand,
  hookArgs,
  hookRun,
  installedScript,
  openclawHandler,
  openclawHookMd,
  promptHook,
  scriptName,
  sessionStartHook,
  shellQuote,
} from "./hooks.js";
export type { HookShell, HookTarget, SessionStartHook } from "./hooks.js";
export {
  injectionMatches,
  injectionEvidence,
  type InjectionEvidence,
} from "./threats.js";
export { COMPILED_HARNESSES, isCompiledHarness } from "./types.js";
export type {
  CompileInput,
  Compiled,
  CompiledHarness,
  DocsHome,
  ItemRef,
  NoteInput,
  Output,
  PreferenceInput,
  ProjectLayer,
  SkillFile,
  SkillInput,
  StartHereInput,
} from "./types.js";

export type { DocsLocation, WorkPlace } from "./types.js";
export { oneAppPlace, type OneAppPlace } from "./one-app-places.js";

export { indexedTreeHash } from "./hash.js";

export {
  AI_TEXT_BUDGETS,
  DOC_PARTS,
  RETIRED_WORDS,
  checkAiText,
  checkAiTexts,
  compareWithBaseline,
  duplicateSentences,
  findingKey,
  retiredWords,
  sentencesOf,
} from "./writing.js";
export type {
  AiText,
  AiTextBudget,
  BaselineComparison,
  Finding as AiTextFinding,
  FindingRule as AiTextFindingRule,
} from "./writing.js";

export {
  RULE_FILLS,
  RULE_SLOTS,
  STANDING_RULES,
  standingRules,
} from "./standing-rules.js";
export type { RuleSlot, RulesEnvironment } from "./standing-rules.js";

export {
  GUIDE_SKILL_ID,
  GUIDE_SKILL_NAME,
  GUIDE_SKILL_VERSION,
  guideForPeople,
  guideSkill,
  guideSkillFiles,
  guideTopics,
} from "./guide.js";
export type { GuideEnvironment } from "./guide.js";
