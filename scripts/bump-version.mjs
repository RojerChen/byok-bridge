#!/usr/bin/env node
/**
 * bump-version.mjs
 *
 * Bumps the project version, updates CHANGELOG.md, and creates an annotated git tag.
 *
 * Usage:
 *   node scripts/bump-version.mjs patch
 *   node scripts/bump-version.mjs minor
 *   node scripts/bump-version.mjs major
 *   node scripts/bump-version.mjs patch --dry-run
 *   node scripts/bump-version.mjs 1.2.3        # set an explicit version
 */

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const PACKAGE_JSON = path.join(ROOT, 'package.json');
const CHANGELOG_MD = path.join(ROOT, 'CHANGELOG.md');

// ── helpers ──────────────────────────────────────────────────────────────────

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, data) {
  fs.writeFileSync(filePath, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
}

function bumpSemver(current, type) {
  const match = current.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) throw new Error(`Cannot parse version: "${current}"`);
  let [, major, minor, patch] = match.map(Number);
  switch (type) {
    case 'major': major++; minor = 0; patch = 0; break;
    case 'minor': minor++; patch = 0; break;
    case 'patch': patch++; break;
    default: throw new Error(`Unknown bump type: "${type}". Use patch, minor, or major.`);
  }
  return `${major}.${minor}.${patch}`;
}

function isExplicitVersion(str) {
  return /^\d+\.\d+\.\d+$/.test(str);
}

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

function git(cmd, dryRun = false) {
  const label = dryRun ? '[DRY-RUN] git' : 'git';
  console.log(`  ${label} ${cmd}`);
  if (!dryRun) {
    return execSync(`git ${cmd}`, { cwd: ROOT, stdio: 'pipe' }).toString().trim();
  }
  return '';
}

function checkGitClean() {
  const status = execSync('git status --porcelain', { cwd: ROOT, stdio: 'pipe' }).toString().trim();
  const lines = status.split('\n').filter(Boolean);
  // Allow only untracked or already-staged changes to the files we are about to touch
  const problemLines = lines.filter(l => {
    const file = l.slice(3);
    return file !== 'package.json' && file !== 'CHANGELOG.md';
  });
  if (problemLines.length > 0) {
    console.error('Working tree has uncommitted changes (excluding package.json / CHANGELOG.md):');
    problemLines.forEach(l => console.error(` ${l}`));
    console.error('Please commit or stash them before bumping the version.');
    process.exit(1);
  }
}

function tagExists(tag) {
  try {
    execSync(`git rev-parse "refs/tags/${tag}"`, { cwd: ROOT, stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

// ── changelog ────────────────────────────────────────────────────────────────

const CHANGELOG_SECTION_TEMPLATE = (version, date) => `## [${version}] - ${date}

### Added

- 

### Changed

- 

### Fixed

- 

`;

function insertChangelogSection(version, date, dryRun) {
  const content = fs.readFileSync(CHANGELOG_MD, 'utf8');

  // Find the line after the first "# Changelog" heading (and any blank lines / intro text)
  // to insert before the first existing version section.
  const insertMarker = /^## \[/m;
  const insertIndex = content.search(insertMarker);

  let updated;
  if (insertIndex === -1) {
    // No existing sections — append after header block
    updated = content.trimEnd() + '\n\n' + CHANGELOG_SECTION_TEMPLATE(version, date);
  } else {
    updated = content.slice(0, insertIndex) + CHANGELOG_SECTION_TEMPLATE(version, date) + content.slice(insertIndex);
  }

  if (dryRun) {
    console.log('\n[DRY-RUN] CHANGELOG.md — new section that would be inserted:');
    console.log('─'.repeat(60));
    console.log(CHANGELOG_SECTION_TEMPLATE(version, date).trimEnd());
    console.log('─'.repeat(60));
  } else {
    fs.writeFileSync(CHANGELOG_MD, updated, 'utf8');
  }
}

// ── main ─────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const positional = args.filter(a => !a.startsWith('--'));

if (positional.length === 0) {
  console.error('Usage: node scripts/bump-version.mjs <patch|minor|major|x.y.z> [--dry-run]');
  process.exit(1);
}

const bumpArg = positional[0];

// Read current version
const pkg = readJson(PACKAGE_JSON);
const currentVersion = pkg.version;

// Resolve new version
let newVersion;
if (isExplicitVersion(bumpArg)) {
  newVersion = bumpArg;
} else {
  newVersion = bumpSemver(currentVersion, bumpArg);
}

const tag = `v${newVersion}`;
const today = todayIso();

console.log(`\nBYOK Bridge — version bump`);
console.log(`  ${currentVersion}  →  ${newVersion}  (tag: ${tag})${dryRun ? '  [DRY-RUN]' : ''}\n`);

// Guard: tag must not already exist
if (!dryRun && tagExists(tag)) {
  console.error(`Error: git tag "${tag}" already exists. Aborting.`);
  process.exit(1);
}

// Guard: working tree must be clean (except the files we will modify)
if (!dryRun) {
  checkGitClean();
}

// 1. Update package.json
console.log('1. Updating package.json ...');
if (!dryRun) {
  pkg.version = newVersion;
  writeJson(PACKAGE_JSON, pkg);
  console.log(`   ✅ version set to "${newVersion}"`);
} else {
  console.log(`   [DRY-RUN] would set version to "${newVersion}"`);
}

// 2. Update CHANGELOG.md
console.log('2. Inserting CHANGELOG section ...');
insertChangelogSection(newVersion, today, dryRun);
if (!dryRun) console.log(`   ✅ inserted ## [${newVersion}] - ${today}`);

// 3. Git commit
console.log('3. Committing changes ...');
git('add package.json CHANGELOG.md', dryRun);
git(`commit -m "chore: bump version to ${newVersion}"`, dryRun);
if (!dryRun) console.log('   ✅ committed');

// 4. Annotated git tag
console.log('4. Creating annotated git tag ...');
git(`tag -a "${tag}" -m "Release ${newVersion}"`, dryRun);
if (!dryRun) console.log(`   ✅ tag ${tag} created`);

// Summary
console.log(`
${dryRun ? '[DRY-RUN] ' : ''}Done! Next steps:
  • Fill in the ${newVersion} section in CHANGELOG.md
  • Push:  git push origin main --tags
`);
