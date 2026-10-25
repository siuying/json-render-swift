import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const packageDir = join(dirname(fileURLToPath(import.meta.url)), "..");
export const repoDir = join(packageDir, "..", "..");
export const specsDir = join(repoDir, "fixtures", "specs");

export function readText(path: string): string {
  return readFileSync(path, "utf8");
}

export function readJSON<T = unknown>(path: string): T {
  return JSON.parse(readText(path)) as T;
}

/** All hand-authored fixture specs, keyed by file name. */
export function fixtureSpecs(): [string, Record<string, unknown>][] {
  return readdirSync(specsDir)
    .filter((file) => file.endsWith(".json"))
    .sort()
    .map((file) => [file, readJSON(join(specsDir, file))]);
}

/** Split text into chunks of `size` characters (deliberately ignoring line boundaries). */
export function chunk(text: string, size: number): string[] {
  const chunks: string[] = [];
  for (let i = 0; i < text.length; i += size)
    chunks.push(text.slice(i, i + size));
  return chunks;
}
