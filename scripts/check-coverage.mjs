#!/usr/bin/env node
/**
 * Fail CI when branch coverage of a production contract drops below its floor.
 *
 *   forge coverage --ir-minimum --report lcov && node scripts/check-coverage.mjs
 *
 * Branch coverage, not line coverage: the branches are the guards, and a guard
 * nobody tests is a guard nobody knows works. The floors are set just below
 * what the suite reaches today, so a new untested branch fails the build.
 *
 * TaskEscrow's floor is below 100% only because forge cannot instrument
 * inline assembly: the two `if` blocks inside `_walletOf` and `_tryTransfer`
 * always read as uncovered, though unit tests drive both (V2Findings H3).
 */
import {readFileSync} from 'node:fs';

const FLOORS = {
  'src/TaskEscrow.sol': 95,
  'src/StakeVault.sol': 100,
  'src/AgentAccount.sol': 100,
  'src/AgentAccountFactory.sol': 100,
};

const lcov = readFileSync(process.argv[2] ?? 'lcov.info', 'utf8');
const stats = {};
let file = null;
for (const raw of lcov.split('\n')) {
  const line = raw.trim();
  if (line.startsWith('SF:')) file = line.slice(3).replaceAll('\\', '/');
  else if (file && line.startsWith('BRF:')) (stats[file] ??= {}).found = Number(line.slice(4));
  else if (file && line.startsWith('BRH:')) (stats[file] ??= {}).hit = Number(line.slice(4));
}

let failed = 0;
for (const [path, floor] of Object.entries(FLOORS)) {
  const s = stats[path];
  if (!s || !s.found) {
    console.error(`  ✗ ${path}: no branch data — did coverage run?`);
    failed++;
    continue;
  }
  const pct = (100 * s.hit) / s.found;
  const ok = pct + 1e-9 >= floor;
  console.log(`  ${ok ? '✓' : '✗'} ${path.padEnd(28)} ${pct.toFixed(2)}% branches (floor ${floor}%)`);
  if (!ok) failed++;
}
if (failed) {
  console.error(`\n${failed} contract(s) below their branch-coverage floor.`);
  process.exit(1);
}
