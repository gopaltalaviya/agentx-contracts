#!/usr/bin/env node
/**
 * Refuse to commit secrets in tracked files.
 *
 * `.env.example` is TRACKED, and its whole job is to sit next to `.env` with
 * the same variable names — which makes pasting a real value into the wrong
 * one of the two an easy, quiet mistake. This is the check that makes it
 * loud instead.
 *
 * Runs in CI and is worth wiring to a pre-commit hook.
 */
import {execSync} from 'node:child_process';
import {readFileSync, existsSync} from 'node:fs';

const PATTERNS = [
  {name: '32-byte private key', re: /0x[0-9a-fA-F]{64}/},
  {name: 'Anthropic API key', re: /sk-ant-[A-Za-z0-9_-]{10,}/},
  {name: 'AWS access key id', re: /AKIA[0-9A-Z]{16}/},
  {name: 'PEM private key', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/},
  {name: 'BIP-39 style mnemonic', re: /\b(?:[a-z]{3,8}\s+){11,}[a-z]{3,8}\b/},
];

// Addresses, tx hashes and Solidity constants are 20- or 32-byte hex too, so
// only scan files where a secret would actually be pasted.
const SCANNED = /(^|\/)(\.env\.example|\.env\.sample|.*\.env)$|\.(md|json|ya?ml)$/;

const tracked = execSync('git ls-files', {encoding: 'utf8'}).split('\n').filter(Boolean);
const problems = [];

for (const file of tracked) {
  if (!SCANNED.test(file)) continue;
  if (!existsSync(file)) continue;
  // deployments/*.json holds addresses, never keys — and PROGRESS-style docs
  // legitimately quote hashes.
  const text = readFileSync(file, 'utf8');
  for (const {name, re} of PATTERNS) {
    const m = re.exec(text);
    if (!m) continue;
    // A keystore ciphertext is not a key, and lock files are noise.
    if (file.includes('lock')) continue;
    problems.push(`${file}: looks like a ${name}`);
  }
}

if (problems.length) {
  console.error('\n✗ Secrets found in TRACKED files\n');
  for (const p of problems) console.error(`  • ${p}`);
  console.error('\n  Secrets belong in .env (gitignored), never .env.example.\n');
  process.exit(1);
}

console.log(`✓ No secrets in ${tracked.length} tracked files`);
