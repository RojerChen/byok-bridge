import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const APP_ROOT = path.resolve(__dirname, '..', '..');
const MESSAGE_FILES = ['app', 'prompts', 'status', 'errors', 'hints'];
const REQUIRED_MESSAGES = {
  app: ['name', 'description', 'steps.selectCli', 'steps.selectProvider', 'summary.cli', 'summary.provider'],
  prompts: ['selectCli', 'selectProvider', 'apiKey', 'back', 'addProvider', 'exit'],
  status: ['selectedCli', 'selectedProvider', 'configurationApplied', 'launching', 'exited'],
  errors: ['invalidSelection', 'cancelled'],
  hints: ['number']
};
const ANSI = {
  reset: '\x1b[0m',
  header: '\x1b[1;36m',
  title: '\x1b[1;37m',
  section: '\x1b[36m',
  info: '\x1b[36m',
  success: '\x1b[32m',
  warning: '\x1b[33m',
  error: '\x1b[31m',
  muted: '\x1b[90m'
};

export class UiResourceError extends Error {
  constructor(resourcePath, message) {
    super(`UI resource '${resourcePath}': ${message}`);
    this.name = 'UiResourceError';
    this.resourcePath = resourcePath;
  }
}

function readJson(resourcePath) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(resourcePath, 'utf8'));
  } catch (error) {
    const detail = error instanceof SyntaxError ? 'is malformed JSON.' : 'could not be read.';
    throw new UiResourceError(resourcePath, detail);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new UiResourceError(resourcePath, 'must contain a JSON object.');
  }
  if (parsed.schemaVersion !== 1) {
    throw new UiResourceError(resourcePath, 'has an unsupported schemaVersion.');
  }
  return parsed;
}

function getPath(object, dottedPath) {
  return dottedPath.split('.').reduce((value, part) => value?.[part], object);
}

function validateMessageGroup(group, messages, resourcePath) {
  for (const messagePath of REQUIRED_MESSAGES[group]) {
    if (typeof getPath(messages, messagePath) !== 'string' || !getPath(messages, messagePath)) {
      throw new UiResourceError(resourcePath, `is missing the string message '${messagePath}'.`);
    }
  }
}

function wrapText(text, width) {
  if (width < 1) return [text];
  const lines = [];
  for (const originalLine of String(text).split(/\r?\n/)) {
    let remainder = originalLine;
    do {
      if (remainder.length <= width) {
        lines.push(remainder);
        remainder = '';
        continue;
      }
      const candidate = remainder.slice(0, width + 1);
      const breakAt = candidate.lastIndexOf(' ');
      const cut = breakAt > 0 ? breakAt : width;
      lines.push(remainder.slice(0, cut));
      remainder = remainder.slice(cut).replace(/^\s+/, '');
    } while (remainder);
  }
  return lines.length ? lines : [''];
}

function colorIsEnabled(output) {
  return (output === console.log || output === console.error)
    && process.stdout.isTTY
    && process.env.NO_COLOR === undefined
    && process.env.BYOK_UI_COLOR !== '0'
    && process.env.TERM !== 'dumb';
}

function writeUi(output, text, role = null) {
  const color = role && colorIsEnabled(output) ? ANSI[role] : null;
  output(color ? `${color}${text}${ANSI.reset}` : text);
}

export function loadUiResources(appRoot = APP_ROOT) {
  const uiDirectory = path.join(appRoot, 'ui');
  const themePath = path.join(uiDirectory, 'theme.json');
  const theme = readJson(themePath);
  if (theme.preferredWidth !== undefined &&
      (!Number.isInteger(theme.preferredWidth) || theme.preferredWidth < 40 || theme.preferredWidth > 100)) {
    throw new UiResourceError(themePath, 'preferredWidth must be an integer from 40 through 100.');
  }
  for (const symbol of ['default', 'success', 'warning', 'error', 'info']) {
    if (typeof theme.symbols?.[symbol] !== 'string' || !theme.symbols[symbol]) {
      throw new UiResourceError(themePath, `is missing the string symbol '${symbol}'.`);
    }
  }

  const messages = {};
  for (const group of MESSAGE_FILES) {
    const resourcePath = path.join(uiDirectory, 'messages', `${group}.json`);
    messages[group] = readJson(resourcePath);
    validateMessageGroup(group, messages[group], resourcePath);
  }
  return { theme, messages, appRoot, uiDirectory };
}

export function formatUiMessage(template, values = {}) {
  return template.replace(/\{([A-Za-z][A-Za-z0-9_]*)\}/g, (match, name) => {
    if (!Object.hasOwn(values, name) || values[name] === undefined || values[name] === null) {
      throw new Error(`UI message requires placeholder '${name}'.`);
    }
    return String(values[name]);
  });
}

export function uiMessage(ui, group, messageId, values = {}) {
  const template = getPath(ui.messages[group], messageId);
  if (typeof template !== 'string') throw new Error(`UI message '${group}.${messageId}' is unavailable.`);
  return formatUiMessage(template, values);
}

export function getUiWidth(ui, columns = process.stdout.columns) {
  const preferred = ui.theme.preferredWidth ?? 60;
  // Transcript and redirected output have no terminal geometry. The preferred
  // width is the stable fallback used by golden tests and non-interactive logs.
  if (!process.stdout.isTTY) return preferred;
  if (!Number.isInteger(columns) || columns <= 0) return preferred;
  return Math.max(4, Math.min(preferred, columns));
}

export function renderUiHeader(ui, output = console.log, width = getUiWidth(ui)) {
  const innerWidth = Math.max(1, width - 2);
  const border = `+${'-'.repeat(innerWidth)}+`;
  writeUi(output, border, 'header');
  for (const text of [ui.messages.app.name, ui.messages.app.description]) {
    for (const line of wrapText(text, innerWidth - 2)) {
      writeUi(output, `| ${line.padEnd(innerWidth - 2)} |`, 'header');
    }
  }
  writeUi(output, border, 'header');
}

export function renderUiStep(ui, step, title, output = console.log, width = getUiWidth(ui)) {
  output('');
  writeUi(output, `[ Step ${step} of 2 ]  ${title}`, 'title');
  writeUi(output, '-'.repeat(width), 'muted');
  output('');
}

export function renderUiChoices(ui, items, defaultIndex, { includeBack = false, includeExit = false } = {}, output = console.log, width = getUiWidth(ui)) {
  for (let index = 0; index < items.length; index += 1) {
    const marker = index === defaultIndex ? ui.theme.symbols.default : ' ';
    writeUi(output, `${marker} ${index + 1}. ${items[index]}`, index === defaultIndex ? 'success' : null);
  }
  if (includeBack) writeUi(output, `  ${uiMessage(ui, 'prompts', 'back')}`, 'muted');
  if (includeExit) writeUi(output, `  0. ${uiMessage(ui, 'prompts', 'exit')}`, 'muted');
  output('');
  writeUi(output, '-'.repeat(width), 'muted');
  writeUi(output, uiMessage(ui, 'hints', 'number'), 'muted');
}

export function renderUiProviderChoices(ui, providers, defaultIndex, { includeAdd = false, includeExit = true } = {}, output = console.log, width = getUiWidth(ui)) {
  for (let index = 0; index < providers.length; index += 1) {
    const marker = index === defaultIndex ? ui.theme.symbols.default : ' ';
    writeUi(output, `${marker} ${index + 1}. ${providers[index]}`, index === defaultIndex ? 'success' : null);
  }
  if (includeAdd || includeExit) output('');
  if (includeAdd) writeUi(output, `  ${providers.length + 1}. ${uiMessage(ui, 'prompts', 'addProvider')}`, 'warning');
  if (includeExit) writeUi(output, `  ${providers.length + (includeAdd ? 2 : 1)}. ${uiMessage(ui, 'prompts', 'exit')}`, 'muted');
  writeUi(output, `  ${uiMessage(ui, 'prompts', 'back')}`, 'muted');
  output('');
  writeUi(output, '-'.repeat(width), 'muted');
  writeUi(output, uiMessage(ui, 'hints', 'number'), 'muted');
}

export function renderUiStatus(ui, messageId, values = {}, output = console.log) {
  writeUi(output, `${ui.theme.symbols.info} ${uiMessage(ui, 'status', messageId, values)}`, 'info');
}

export function renderUiSelectionSummary(ui, { cli = null, provider = null } = {}, output = console.log) {
  if (cli) {
    writeUi(output, uiMessage(ui, 'app', 'summary.cli', { cli }), 'info');
    output('');
  }
  if (provider) {
    writeUi(output, uiMessage(ui, 'app', 'summary.provider', { provider }), 'info');
    output('');
  }
}

export function renderUiError(ui, messageId, values = {}, output = console.error) {
  writeUi(output, `${ui.theme.symbols.error} ${uiMessage(ui, 'errors', messageId, values)}`, 'error');
}

export function renderUiSummary(ui, provider, model, apiKey, apiKeyRequired, output = console.log) {
  const keyStatus = apiKey ? '[set]' : (apiKeyRequired === false ? '[not required]' : '[missing]');
  writeUi(output, `Provider: ${provider}`, 'info');
  writeUi(output, `Model: ${model}`, 'info');
  writeUi(output, `API key: ${keyStatus}`, apiKey ? 'success' : (apiKeyRequired === false ? 'muted' : 'warning'));
}
