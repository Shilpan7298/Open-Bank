// SPDX-License-Identifier: AGPL-3.0-or-later
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Find the repo's i18n/ directory by walking up from this file (works from src/ and dist/src/). */
function catalogDir(): string {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (let i = 0; i < 6; i++) {
    if (existsSync(join(dir, "i18n", "en.json"))) return join(dir, "i18n");
    dir = dirname(dir);
  }
  throw new Error("i18n catalogs not found");
}

const cache = new Map<string, Record<string, string>>();

function catalog(language: string): Record<string, string> | undefined {
  const base = language.toLowerCase().split("-")[0]!;
  if (!cache.has(base)) {
    const file = join(catalogDir(), `${base}.json`);
    if (!existsSync(file)) return undefined;
    cache.set(base, (JSON.parse(readFileSync(file, "utf8")) as { messages: Record<string, string> }).messages);
  }
  return cache.get(base);
}

/** Message for `key` in `language`, falling back to English. Returns the language actually used. */
export function t(language: string, key: string, vars: Record<string, string | number> = {}): { language: string; text: string } {
  const own = catalog(language)?.[key];
  const used = own === undefined ? "en" : language.toLowerCase().split("-")[0]!;
  const template = own ?? catalog("en")![key];
  if (template === undefined) throw new Error(`unknown message ${key}`);
  return { language: used, text: template.replace(/\{(\w+)\}/g, (_, k: string) => String(vars[k] ?? `{${k}}`)) };
}

/** Percent in the language's own digits (e.g. Bengali or Arabic-Indic numerals). */
export function percent(language: string, fraction: number): string {
  try {
    return new Intl.NumberFormat(language, { style: "percent", maximumFractionDigits: 1 }).format(fraction);
  } catch {
    return new Intl.NumberFormat("en", { style: "percent", maximumFractionDigits: 1 }).format(fraction);
  }
}

export function number(language: string, n: number): string {
  try {
    return new Intl.NumberFormat(language).format(n);
  } catch {
    return String(n);
  }
}
