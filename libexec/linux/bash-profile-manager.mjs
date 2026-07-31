#!/usr/bin/env node

import fs from 'node:fs';

const BEGIN = '# >>> BYOK Bridge managed shell integration >>>';
const END = '# <<< BYOK Bridge managed shell integration <<<';
const MANAGED = '# BYOK_BRIDGE_MANAGED_BASHRC=1';
const ORIGINAL_PREFIX = '# BYOK_BRIDGE_BASHRC_ORIGINAL_FILE_PRESENT=';
const NEWLINE_PREFIX = '# BYOK_BRIDGE_BASHRC_PREFIX_NEWLINE_ADDED=';
// These are read only during a verified 0.0.x-to-0.1.0 installer migration.
const LEGACY = {
  begin: '# >>> BYOK CLI Hub managed shell integration >>>',
  end: '# <<< BYOK CLI Hub managed shell integration <<<',
  managed: '# BYOK_CLI_HUB_MANAGED_BASHRC=1',
  originalPrefix: '# BYOK_CLI_HUB_BASHRC_ORIGINAL_FILE_PRESENT=',
  newlinePrefix: '# BYOK_CLI_HUB_BASHRC_PREFIX_NEWLINE_ADDED='
};

function fail(message) {
  console.error(`Error: ${message}`);
  process.exit(2);
}

function findMarker(input, marker) {
  const needle = Buffer.from(marker);
  const positions = [];
  let offset = 0;
  while (offset <= input.length - needle.length) {
    const index = input.indexOf(needle, offset);
    if (index < 0) break;
    positions.push(index);
    offset = index + needle.length;
  }
  if (positions.length > 1) fail(`Bash startup file contains duplicate '${marker}' markers.`);
  if (positions.length === 0) return null;

  const start = positions[0];
  if (start > 0 && input[start - 1] !== 0x0a) {
    fail(`Bash startup marker '${marker}' is not on its own line.`);
  }
  let after = start + needle.length;
  if (after < input.length && input[after] === 0x0d && input[after + 1] === 0x0a) after += 2;
  else if (after < input.length && input[after] === 0x0a) after += 1;
  else if (after !== input.length) fail(`Bash startup marker '${marker}' is not on its own line.`);
  return { start, after };
}

function locateManagedBlock(input, format = {
  begin: BEGIN,
  end: END,
  managed: MANAGED,
  originalPrefix: ORIGINAL_PREFIX,
  newlinePrefix: NEWLINE_PREFIX,
  label: 'BYOK Bridge'
}) {
  const begin = findMarker(input, format.begin);
  const end = findMarker(input, format.end);
  if (!begin && !end) return null;
  if (!begin || !end || end.start < begin.after) {
    fail(`Bash startup file contains an incomplete or out-of-order ${format.label || 'BYOK Bridge'} managed block.`);
  }

  const block = input.subarray(begin.start, end.after).toString('utf8');
  if (!block.split(/\r?\n/u).includes(format.managed)) {
    fail('Bash startup block has BYOK markers but no ownership marker.');
  }
  const originalMatch = block.match(new RegExp(`^${escapeRegExp(format.originalPrefix)}([01])$`, 'mu'));
  const newlineMatch = block.match(new RegExp(`^${escapeRegExp(format.newlinePrefix)}([01])$`, 'mu'));
  if (!originalMatch || !newlineMatch) {
    fail('Bash startup block is missing restoration metadata.');
  }
  return {
    start: begin.start,
    after: end.after,
    originalFilePresent: originalMatch[1] === '1',
    prefixNewlineAdded: newlineMatch[1] === '1'
  };
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function quoteForBash(value) {
  if (value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail('Shell integration helper path contains an unsupported character.');
  }
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function makeBlock(helperPath, commandPath, originalFilePresent, prefixNewlineAdded) {
  const helper = quoteForBash(helperPath);
  const command = quoteForBash(commandPath);
  return Buffer.from([
    BEGIN,
    MANAGED,
    `${ORIGINAL_PREFIX}${originalFilePresent ? '1' : '0'}`,
    `${NEWLINE_PREFIX}${prefixNewlineAdded ? '1' : '0'}`,
    `if [[ -r ${helper} ]]; then`,
    `  source ${helper} --byok-managed-command ${command}`,
    'fi',
    END,
    ''
  ].join('\n'));
}

function installBlock(input, helperPath, commandPath, inputFilePresent) {
  const existing = locateManagedBlock(input);
  if (existing) {
    const block = makeBlock(helperPath, commandPath, existing.originalFilePresent, existing.prefixNewlineAdded);
    return Buffer.concat([input.subarray(0, existing.start), block, input.subarray(existing.after)]);
  }

  const prefixNewlineAdded = input.length > 0 && input[input.length - 1] !== 0x0a;
  const separator = prefixNewlineAdded ? Buffer.from('\n') : Buffer.alloc(0);
  return Buffer.concat([input, separator, makeBlock(helperPath, commandPath, inputFilePresent, prefixNewlineAdded)]);
}

function migrateBlock(input, helperPath, commandPath, inputFilePresent) {
  const current = locateManagedBlock(input);
  const legacy = locateManagedBlock(input, { ...LEGACY, label: 'BYOK CLI Hub' });
  if (current && legacy) fail('Bash startup file contains both legacy and BYOK Bridge managed blocks.');
  if (!legacy) return installBlock(input, helperPath, commandPath, inputFilePresent);
  const replacement = makeBlock(helperPath, commandPath, legacy.originalFilePresent, legacy.prefixNewlineAdded);
  return Buffer.concat([input.subarray(0, legacy.start), replacement, input.subarray(legacy.after)]);
}

function removeBlock(input) {
  const existing = locateManagedBlock(input);
  if (!existing) return { output: input, changed: false, removeFile: false };

  let prefixEnd = existing.start;
  const suffix = input.subarray(existing.after);
  if (existing.prefixNewlineAdded && suffix.length === 0 && prefixEnd > 0 && input[prefixEnd - 1] === 0x0a) {
    prefixEnd -= 1;
  }
  const output = Buffer.concat([input.subarray(0, prefixEnd), suffix]);
  return {
    output,
    changed: true,
    removeFile: !existing.originalFilePresent && output.length === 0
  };
}

const [action, inputPath, outputPath, helperPath, commandPath] = process.argv.slice(2);
if (!['check-install', 'install', 'migrate', 'remove'].includes(action) || !inputPath) {
  fail('Usage: bash-profile-manager.mjs check-install INPUT HELPER COMMAND | install INPUT OUTPUT HELPER COMMAND | migrate INPUT OUTPUT HELPER COMMAND | remove INPUT OUTPUT');
}

const inputFilePresent = inputPath !== '-';
const input = inputFilePresent ? fs.readFileSync(inputPath) : Buffer.alloc(0);

if (action === 'check-install') {
  if (!outputPath || !helperPath) fail('check-install requires the shell helper and command paths.');
  installBlock(input, outputPath, helperPath, inputFilePresent);
  process.exit(0);
}

if (!outputPath) fail(`${action} requires an output path.`);
if (action === 'install' || action === 'migrate') {
  if (!helperPath || !commandPath) fail('install requires the shell helper and command paths.');
  fs.writeFileSync(outputPath, action === 'migrate'
    ? migrateBlock(input, helperPath, commandPath, inputFilePresent)
    : installBlock(input, helperPath, commandPath, inputFilePresent));
  console.log('1 0');
} else {
  const result = removeBlock(input);
  fs.writeFileSync(outputPath, result.output);
  console.log(`${result.changed ? '1' : '0'} ${result.removeFile ? '1' : '0'}`);
}
