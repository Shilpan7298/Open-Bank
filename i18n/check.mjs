#!/usr/bin/env node
// Checks every catalog against the English source: same keys, same {placeholders}, valid metadata,
// and one cancel-reason message for every REASON_* code in contracts/src/LoanRegistry.sol.
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const load = (f) => JSON.parse(readFileSync(join(here, f), "utf8"));
const placeholders = (s) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");
const errors = [];

const en = load("en.json");
const enKeys = Object.keys(en.messages).sort();

const registry = readFileSync(join(here, "../contracts/src/LoanRegistry.sol"), "utf8");
for (const [, code] of registry.matchAll(/REASON_\w+ = "(\w+)"/g)) {
  if (!(`loan.cancel_reason.${code}` in en.messages)) errors.push(`en: missing loan.cancel_reason.${code}`);
}

// Loan purpose codes 1..N are the `sector` codes used on-chain (they also drive basket concentration caps).
for (let i = 1; `loan.purpose.${i}` in en.messages || i === 1; i++) {
  if (!(`loan.purpose.${i}` in en.messages)) errors.push(`en: missing loan.purpose.${i}`);
  if (i > 100) break;
}

const files = readdirSync(here).filter((f) => f.endsWith(".json"));
for (const f of files) {
  const c = load(f);
  const m = c._meta ?? {};
  if (`${m.code}.json` !== f) errors.push(`${f}: _meta.code must match the file name`);
  if (!["ltr", "rtl"].includes(m.dir)) errors.push(`${f}: _meta.dir must be ltr or rtl`);
  if (!["source", "needs_review", "reviewed"].includes(m.status)) errors.push(`${f}: bad _meta.status`);
  if (f !== "en.json" && m.status === "source") errors.push(`${f}: only en.json is the source`);
  const keys = Object.keys(c.messages ?? {}).sort();
  for (const k of enKeys) {
    if (!(k in c.messages)) errors.push(`${f}: missing ${k}`);
    else if (placeholders(c.messages[k]) !== placeholders(en.messages[k])) errors.push(`${f}: placeholders differ in ${k}`);
    else if (!c.messages[k].trim()) errors.push(`${f}: empty ${k}`);
  }
  for (const k of keys) if (!enKeys.includes(k)) errors.push(`${f}: extra key ${k} (add it to en.json first)`);
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`i18n ok: ${files.length} languages, ${enKeys.length} messages each`);
