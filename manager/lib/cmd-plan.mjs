/**
 * Windows CMD launch-plan writer.
 *
 * Produces a temporary .cmd file that run.cmd can `call` to apply the
 * resolved environment into the caller CMD session and record the launch plan.
 *
 * Security contract:
 *  - Variable names must match /^[A-Za-z_][A-Za-z0-9_]*$/.
 *  - Values must not contain NUL, CR, or LF characters.
 *  - Values must not contain double-quote characters (used in the quoted
 *    `set "NAME=VALUE"` assignment form which is injection-safe for other
 *    cmd metacharacters).
 *  - Percent signs are doubled to prevent CMD variable expansion inside the
 *    plan file (e.g., `%PATH%` would otherwise be expanded at parse time).
 *  - Arguments are individually quoted when they contain spaces or
 *    double-quotes (matching the Windows CreateProcess argument conventions).
 *
 * The generated file format is intentionally simple:
 *   @echo off
 *   set "VAR1=value1"
 *   ...
 *   set "__BYOK_BRIDGE_ACTION=launch"
 *   set "__BYOK_BRIDGE_EXECUTABLE=C:\path\to\cli.exe"
 *   set "__BYOK_BRIDGE_ARGUMENTS=arg1 arg2"
 *   set "__BYOK_BRIDGE_CLI_ID=copilot"
 *
 * run.cmd reads ACTION, EXECUTABLE, ARGUMENTS, and CLI_ID from these
 * control variables after executing the plan file.
 */

import fs from 'node:fs';
import path from 'node:path';

const ENV_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

export class CmdPlanError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CmdPlanError';
  }
}

function fail(message) {
  throw new CmdPlanError(message);
}

/**
 * Validates and encodes a single environment variable name.
 */
function validateEnvName(name) {
  if (!ENV_NAME_PATTERN.test(name)) {
    fail(`Cannot write invalid CMD environment variable name '${name}'.`);
  }
  return name;
}

/**
 * Encodes a value for use in a quoted CMD `set "NAME=VALUE"` line.
 *
 * - Rejects NUL, CR, LF (cannot be represented on a single CMD line).
 * - Rejects double-quote (would break the quoted assignment form).
 * - Doubles percent signs to prevent CMD variable expansion.
 */
function encodeCmdValue(name, value) {
  const text = String(value);
  if (text.includes('\0')) fail(`Environment variable '${name}' contains a NUL byte.`);
  if (text.includes('\r') || text.includes('\n')) {
    fail(`Environment variable '${name}' contains a CR or LF that cannot be represented in a CMD launch plan.`);
  }
  if (text.includes('"')) {
    fail(`Environment variable '${name}' contains a double-quote that cannot be safely applied to the caller CMD session.`);
  }
  return text.replaceAll('%', '%%');
}

/**
 * Formats a single `set "NAME=VALUE"` line.
 */
function makeCmdSetLine(name, value) {
  validateEnvName(name);
  return `set "${name}=${encodeCmdValue(name, value)}"`;
}

/**
 * Formats a list of CLI arguments as a single CMD-compatible argument string.
 *
 * Each argument is quoted with double-quotes if it contains spaces or
 * double-quotes. The resulting string is stored in a single SET variable and
 * expanded by run.cmd when launching the CLI; therefore each argument must
 * not contain NUL, CR, or LF.
 */
export function formatCmdArgs(args) {
  if (!Array.isArray(args)) return '';
  const parts = [];
  for (const arg of args) {
    const text = String(arg ?? '');
    if (text.includes('\0') || text.includes('\r') || text.includes('\n')) {
      fail('A CLI argument contains a character that cannot be represented in a CMD launch plan.');
    }
    if (/[\s"]/.test(text)) {
      parts.push(`"${text.replaceAll('"', '""')}"`);
    } else {
      parts.push(text);
    }
  }
  return parts.join(' ');
}

/**
 * Writes the CMD launch plan to `filePath`.
 *
 * @param {string}   filePath     Absolute path for the plan file. Must not exist.
 * @param {object}   plan
 * @param {string}   plan.action  'launch' | 'none'
 * @param {object}   [plan.environment]   ENV_NAME → string value pairs.
 * @param {string}   [plan.command]       Executable path (required for launch).
 * @param {string[]} [plan.args]          CLI arguments (may be empty).
 * @param {string}   [plan.cliId]         CLI identifier for the caller.
 */
export function writeCmdPlan(filePath, plan) {
  if (!path.isAbsolute(filePath)) fail('The CMD launch-plan path must be absolute.');
  if (!plan || !['launch', 'none'].includes(plan.action)) {
    fail("CMD launch plan action must be 'launch' or 'none'.");
  }

  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) fail(`CMD launch-plan directory does not exist: ${dir}`);

  const lines = ['@echo off'];

  if (plan.action === 'launch') {
    const environment = plan.environment ?? {};
    for (const [name, value] of Object.entries(environment)) {
      lines.push(makeCmdSetLine(name, value));
    }
    if (!plan.command || typeof plan.command !== 'string') {
      fail('CMD launch plan command must be a non-empty string for action=launch.');
    }
    lines.push(makeCmdSetLine('__BYOK_BRIDGE_ACTION', 'launch'));
    lines.push(makeCmdSetLine('__BYOK_BRIDGE_EXECUTABLE', plan.command));
    lines.push(makeCmdSetLine('__BYOK_BRIDGE_ARGUMENTS', formatCmdArgs(plan.args ?? [])));
    lines.push(makeCmdSetLine('__BYOK_BRIDGE_CLI_ID', plan.cliId ?? ''));
  } else {
    lines.push(makeCmdSetLine('__BYOK_BRIDGE_ACTION', 'none'));
  }

  const content = lines.join('\r\n') + '\r\n';
  // CreateNew prevents clobbering an existing file.
  const fd = fs.openSync(filePath, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL);
  try {
    fs.writeSync(fd, content, 0, 'utf8');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}
