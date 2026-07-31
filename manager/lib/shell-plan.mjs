import fs from 'node:fs';

const ENV_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const MAX_PAYLOAD_BYTES = 1024 * 1024;
const MAX_ENVIRONMENT_RECORDS = 1024;
const MAX_ARGUMENT_RECORDS = 4096;
const RESERVED_ENVIRONMENT_NAMES = new Set([
  'BASH_ENV',
  'ENV',
  'IFS',
  'SHELLOPTS',
  'BASHOPTS',
  'CDPATH',
  'GLOBIGNORE',
  'PROMPT_COMMAND',
  'PS0',
  'PS1',
  'PS2',
  'PS3',
  'PS4',
  'PATH',
  'PWD',
  'OLDPWD',
  'SHLVL',
  'HOME',
  'SHELL',
  'LD_PRELOAD',
  'LD_LIBRARY_PATH',
  'NODE_OPTIONS'
]);

export class ShellPlanError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ShellPlanError';
  }
}

function fail(message) {
  throw new ShellPlanError(message);
}

function encodeHex(value, label) {
  if (typeof value !== 'string') fail(`${label} must be a string.`);
  if (value.includes('\0')) fail(`${label} must not contain NUL.`);
  return Buffer.from(value, 'utf8').toString('hex');
}

export function validateShellEnvironmentName(name) {
  if (!ENV_NAME_PATTERN.test(name)) fail(`Shell environment name '${name}' is invalid.`);
  if (RESERVED_ENVIRONMENT_NAMES.has(name) || name.startsWith('_BYOK_BRIDGE_')) {
    fail(`Shell environment name '${name}' is reserved and cannot be applied to the caller shell.`);
  }
  return name;
}

export function encodeShellPlan(plan) {
  if (!plan || !['launch', 'none'].includes(plan.action)) {
    fail("Shell plan action must be 'launch' or 'none'.");
  }

  const lines = ['BYOK_BRIDGE_SHELL_PLAN\t1', `ACTION\t${plan.action}`];
  let recordCount = 1;

  if (plan.action === 'none') {
    if (plan.command !== undefined || plan.args !== undefined || plan.environment !== undefined) {
      fail('A non-launch shell plan must not contain command, arguments, or environment.');
    }
  } else {
    const environmentEntries = Object.entries(plan.environment || {});
    if (environmentEntries.length > MAX_ENVIRONMENT_RECORDS) {
      fail(`Shell plan exceeds the ${MAX_ENVIRONMENT_RECORDS}-variable limit.`);
    }
    for (const [name, rawValue] of environmentEntries) {
      validateShellEnvironmentName(name);
      if (!['string', 'number', 'boolean'].includes(typeof rawValue)) {
        fail(`Shell environment value for '${name}' must be scalar.`);
      }
      lines.push(`ENV\t${name}\t${encodeHex(String(rawValue), `Shell environment value for '${name}'`)}`);
      recordCount += 1;
    }

    if (typeof plan.command !== 'string' || !plan.command) fail('Shell plan command must be a non-empty string.');
    const args = plan.args || [];
    if (!Array.isArray(args) || args.some(argument => typeof argument !== 'string')) {
      fail('Shell plan arguments must be an array of strings.');
    }
    if (args.length > MAX_ARGUMENT_RECORDS) {
      fail(`Shell plan exceeds the ${MAX_ARGUMENT_RECORDS}-argument limit.`);
    }

    lines.push(`COMMAND\t${encodeHex(plan.command, 'Shell plan command')}`);
    recordCount += 1;
    for (const argument of args) {
      lines.push(`ARG\t${encodeHex(argument, 'Shell plan argument')}`);
      recordCount += 1;
    }
  }

  lines.push(`END\t${recordCount}`);
  const payload = `${lines.join('\n')}\n`;
  if (Buffer.byteLength(payload, 'ascii') > MAX_PAYLOAD_BYTES) {
    fail(`Shell plan exceeds the ${MAX_PAYLOAD_BYTES}-byte limit.`);
  }
  return payload;
}

export function writeShellPlan(fd, plan) {
  if (fd !== 3) fail('Internal shell plan file descriptor must be 3.');
  const buffer = Buffer.from(encodeShellPlan(plan), 'ascii');
  let offset = 0;
  while (offset < buffer.length) {
    const written = fs.writeSync(fd, buffer, offset, buffer.length - offset);
    if (written <= 0) fail('Unable to write the internal shell plan.');
    offset += written;
  }
}
