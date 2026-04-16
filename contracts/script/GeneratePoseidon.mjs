// GeneratePoseidon.mjs
// Generates Poseidon hash library bytecodes using circomlibjs.
// Run once: npm install circomlibjs@0.1.7 && node script/GeneratePoseidon.mjs
// Output is committed to poseidon/ — no need to re-run unless upgrading circomlibjs.

import { poseidonContract } from "circomlibjs";
import { writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const outDir = join(__dirname, "..", "poseidon");
mkdirSync(outDir, { recursive: true });

for (const n of [2, 3, 5, 6]) {
    const bytecode = poseidonContract.createCode(n);
    writeFileSync(join(outDir, `PoseidonUnit${n}L.hex`), bytecode);
    console.log(`PoseidonUnit${n}L: ${(bytecode.length - 2) / 2} bytes`);
}

console.log("Done. Poseidon bytecodes written to poseidon/");
