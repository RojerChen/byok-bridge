import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  loadUiResources,
  renderUiChoices,
  renderUiProviderChoices,
  renderUiSelectionSummary,
  renderUiError,
  renderUiHeader,
  renderUiStatus,
  renderUiStep,
  renderUiSummary,
  uiMessage
} from '../manager/lib/ui.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(testDirectory, '..');
const goldenDirectory = path.join(testDirectory, 'golden', 'ui');

function golden(name) {
  return fs.readFileSync(path.join(goldenDirectory, name), 'utf8').replace(/\r\n/g, '\n').trimEnd();
}

function transcript(render) {
  const lines = [];
  render((line = '') => lines.push(line));
  return lines.join('\n').trimEnd();
}

test('shared renderer output matches the CLI and provider golden transcripts', () => {
  const ui = loadUiResources(appRoot);
  const cli = transcript((write) => {
    renderUiHeader(ui, write, 60);
    renderUiStep(ui, 1, ui.messages.app.steps.selectCli, write, 60);
    renderUiChoices(ui, ['GitHub Copilot CLI', 'OpenCode CLI'], 0, { includeExit: true }, write, 60);
    write(`${uiMessage(ui, 'prompts', 'selectCli', { min: 1, max: 2, default: 1 })}: 2`);
    write('');
    renderUiStatus(ui, 'selectedCli', { cli: 'OpenCode CLI' }, write);
  });
  assert.equal(cli, golden('select-cli.txt'));

  const provider = transcript((write) => {
    renderUiHeader(ui, write, 60);
    renderUiStep(ui, 2, ui.messages.app.steps.selectProvider, write, 60);
    renderUiProviderChoices(ui, ['OpenAI', 'My Provider'], 0, { includeAdd: true }, write, 60);
    write(`${uiMessage(ui, 'prompts', 'selectProvider', { min: 1, max: 4, default: 1 })}:`);
  });
  assert.equal(provider, golden('select-provider.txt'));
});

test('golden status and error messages are safe and stable', () => {
  const ui = loadUiResources(appRoot);
  const success = transcript((write) => {
    renderUiSummary(ui, 'OpenAI', 'gpt-4.1', 'test-secret', true, write);
    renderUiStatus(ui, 'configurationApplied', {}, write);
    renderUiStatus(ui, 'launching', { cli: 'GitHub Copilot CLI' }, write);
  });
  assert.equal(success, golden('success.txt'));
  assert.equal(success.includes('test-secret'), false);

  const error = transcript((write) => {
    renderUiSummary(ui, 'OpenAI', 'gpt-4.1', '', true, write);
    renderUiError(ui, 'invalidSelection', {}, write);
  });
  assert.equal(error, golden('error.txt'));
  assert.equal(transcript((write) => renderUiError(ui, 'cancelled', {}, write)), golden('cancelled.txt'));

  const invalid = transcript((write) => {
    const prompt = uiMessage(ui, 'prompts', 'selectCli', { min: 1, max: 2, default: 1 });
    write(`${prompt}: text`);
    renderUiError(ui, 'invalidSelection', {}, write);
    write(`${prompt}: 3`);
    renderUiError(ui, 'invalidSelection', {}, write);
    write(`${prompt}:`);
  });
  assert.equal(invalid, golden('invalid-selection.txt'));

  const suppliedSecret = 'never-render-this-secret';
  const apiKeyRequired = transcript((write) => {
    write(`${uiMessage(ui, 'prompts', 'apiKey', { provider: 'OpenAI' })}: <masked input>`);
    renderUiError(ui, 'apiKeyRequired', { provider: 'OpenAI' }, write);
  });
  assert.equal(apiKeyRequired, golden('api-key-required.txt'));
  assert.equal(apiKeyRequired.includes(suppliedSecret), false);
  assert.equal(transcript((write) => renderUiStatus(ui, 'exited', {}, write)), '[i] Operation exited.');
});

test('wizard screens preserve selected values without retaining prior menus', () => {
  const ui = loadUiResources(appRoot);
  const summary = transcript((write) => renderUiSelectionSummary(ui, {
    cli: 'OpenCode CLI',
    provider: 'Duotify'
  }, write));
  assert.equal(summary, 'Selected CLI: OpenCode CLI\n\nSelected BYOK Provider: Duotify');
});

test('a non-TTY run never selects interactive defaults', () => {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-ui-nontty-'));
  try {
    const config = {
      version: 1,
      clis: {
        first: { name: 'First CLI', command: process.execPath, args: [], modelEnvName: 'TEST_MODEL' },
        second: { name: 'Second CLI', command: process.execPath, args: [], modelEnvName: 'TEST_MODEL' }
      },
      providers: {
        local: { name: 'Local', baseUrl: 'http://127.0.0.1:1/v1', apiKeyRequired: false, models: ['test-model'] }
      }
    };
    fs.writeFileSync(path.join(temporaryRoot, 'providers.json'), `${JSON.stringify(config)}\n`, { mode: 0o600 });
    const result = spawnSync(process.execPath, [path.join(appRoot, 'manager', 'manager.mjs'), '--data-dir', temporaryRoot, '--dry-run'], {
      encoding: 'utf8'
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Interactive selection is unavailable/);
    assert.equal(fs.existsSync(path.join(temporaryRoot, 'state.json')), false);
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
});
