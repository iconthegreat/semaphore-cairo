/**
 * Extract the Semaphore verification key for depth 20 and save to artifacts.
 *
 * Usage: npx tsx scripts/extract-vk.ts
 */
import { extractVerificationKey } from "../src/proof.js";
import { writeFileSync, mkdirSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEPTH = 20;

console.log(`Extracting verification key for tree depth ${DEPTH}...`);

const vk = extractVerificationKey(DEPTH);

console.log(`  Protocol: ${vk.protocol}`);
console.log(`  Curve: ${vk.curve}`);
console.log(`  Public inputs: ${vk.nPublic}`);
console.log(`  IC length: ${vk.IC.length} (nPublic + 1 = ${vk.nPublic + 1})`);

const outDir = join(__dirname, "..", "artifacts");
mkdirSync(outDir, { recursive: true });
const outPath = join(outDir, `semaphore-${DEPTH}-vk.json`);
writeFileSync(outPath, JSON.stringify(vk, null, 2));

console.log(`\nVerification key written to: ${outPath}`);
