// Where each app keeps its own memory on a computer (G1-299, decided by Alan
// on 8 Nov 2026), the only thing known per app about its memory, as data, so
// another persistent agent is a new entry rather than new code. Once the
// person brings them in, each file there maps onto one note in its
// connection's memory, in the app's own format, both ways. A file that also
// holds Context Locker's block has one owner, the sync: its note holds the
// text outside the block, and the sync builds the file from that and the
// block, as Hermes's SOUL.md and OpenClaw's workspace AGENTS.md do. Each
// app's places are in its entry in DEVICE_APPS; the sync scripts hold the
// same list.
import type { CompiledHarness } from "./types.js";
import { byApp, type MemoryPlace } from "./device-apps.js";

export type { MemoryPlace };

/** Where each app keeps its own memory, from its entry in DEVICE_APPS */
export const MEMORY_PLACES: Readonly<
  Record<CompiledHarness, readonly MemoryPlace[]>
> = byApp((app) => app.memory);

/** The files in a memory folder that count, by their endings, as the doctor reads them */
export const MEMORY_FILE_ENDINGS = [
  ".md",
  ".markdown",
  ".mdx",
  ".mdc",
  ".txt",
] as const;

/** As every target the manifest names, with no hidden folder or file */
const TARGET = /^\{[a-z-]+\}(\/[A-Za-z0-9_-][A-Za-z0-9._-]*)+$/;

/** The longest target a memory note keeps, as items_memory_path_check has it */
export const MEMORY_TARGET_CHARACTERS = 512;

/** The memory place a target is in, if its app keeps memory there */
export function memoryPlaceOf(
  harness: CompiledHarness,
  target: string,
): MemoryPlace | null {
  if (target.length > MEMORY_TARGET_CHARACTERS || !TARGET.test(target))
    return null;
  const parts = target.split("/");
  for (const place of MEMORY_PLACES[harness]) {
    if (place.depth === undefined) {
      if (target === place.path) return place;
      continue;
    }
    const folder = place.path.split("/");
    if (
      parts.length <= folder.length ||
      parts.length > folder.length + place.depth
    )
      continue;
    if (!folder.every((part, at) => part === "*" || part === parts[at]))
      continue;
    const name = parts.at(-1)!.toLowerCase();
    if (MEMORY_FILE_ENDINGS.some((ending) => name.endsWith(ending)))
      return place;
  }
  return null;
}
