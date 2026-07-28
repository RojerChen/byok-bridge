#!/usr/bin/env node

import fs from 'node:fs';

const BEGIN = '# >>> BYOK CLI Hub managed shell integration >>>';
const END = '# <<< BYOK CLI Hub managed shell integration <<<';
const MANAGED = '# BYOK_CLI_HUB_MANAGED_BASHRC=1';
const ORIGINAL_PREFIX = '# BYOK_CLI_HUB_BASHRC_ORIGINAL_FILE_PRESENT=';
const NEWLINE_PREFIX = '# BYOK_CLI_HUB_BASHRC_PREFIX_NEWLINE_ADDED=';

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

function locateManagedBlock(input) {
  const begin = findMarker(input, BEGIN);
  const end = findMarker(input, END);
  if (!begin && !end) return null;
  if (!begin || !end || end.start < begin.after) {
    fail('Bash startup file contains an incomplete or out-of-order BYOK CLI Hub managed block.');
  }

  const block = input.subarray(begin.start, end.after).toString('utf8');
  if (!block.split(/\r?\n/u).includes(MANAGED)) {
    fail('Bash startup block has BYOK markers but no ownership marker.');
  }
  const originalMatch = block.match(/^# BYOK_CLI_HUB_BASHRC_ORIGINAL_FILE_PRESENT=([01])$/mu);
  const newlineMatch = block.match(/^# BYOK_CLI_HUB_BASHRC_PREFIX_NEWLINE_ADDED=([01])$/mu);
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

function quoteForBash(value) {
  if (value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail('Shell integration helper path contains an unsupported character.');
  }
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function makeBlock(helperPath, originalFilePresent, prefixNewlineAdded) {
  const helper = quoteForBash(helperPath);
  return Buffer.from([
    BEGIN,
    MANAGED,
    `${ORIGINAL_PREFIX}${originalFilePresent ? '1' : '0'}`,
    `${NEWLINE_PREFIX}${prefixNewlineAdded ? '1' : '0'}`,
    `if [[ -r ${helper} ]]; then`,
    `  source ${helper}`,
    'fi',
    END,
    ''
  ].join('\n'));
}

function installBlock(input, helperPath, inputFilePresent) {
  const existing = locateManagedBlock(input);
  if (existing) {
    const block = makeBlock(helperPath, existing.originalFilePresent, existing.prefixNewlineAdded);
    return Buffer.concat([input.subarray(0, existing.start), block, input.subarray(existing.after)]);
  }

  const prefixNewlineAdded = input.length > 0 && input[input.length - 1] !== 0x0a;
  const separator = prefixNewlineAdded ? Buffer.from('\n') : Buffer.alloc(0);
  return Buffer.concat([input, separator, makeBlock(helperPath, inputFilePresent, prefixNewlineAdded)]);
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

const [action, inputPath, outputPath, helperPath] = process.argv.slice(2);
if (!['check-install', 'install', 'remove'].includes(action) || !inputPath) {
  fail('Usage: bashrc-integration.mjs check-install INPUT HELPER | install INPUT OUTPUT HELPER | remove INPUT OUTPUT');
}

const inputFilePresent = inputPath !== '-';
const input = inputFilePresent ? fs.readFileSync(inputPath) : Buffer.alloc(0);

if (action === 'check-install') {
  if (!outputPath) fail('check-install requires the shell helper path.');
  installBlock(input, outputPath, inputFilePresent);
  process.exit(0);
}

if (!outputPath) fail(`${action} requires an output path.`);
if (action === 'install') {
  if (!helperPath) fail('install requires the shell helper path.');
  fs.writeFileSync(outputPath, installBlock(input, helperPath, inputFilePresent));
  console.log('1 0');
} else {
  const result = removeBlock(input);
  fs.writeFileSync(outputPath, result.output);
  console.log(`${result.changed ? '1' : '0'} ${result.removeFile ? '1' : '0'}`);
}
