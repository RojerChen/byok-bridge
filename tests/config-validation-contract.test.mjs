import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { validateConfig } from '../manager/lib/config.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function baseConfig() {
  return {
    version: 1,
    clis: { test: { command: 'node', args: [] } },
    providers: {}
  };
}

const cases = [
  { name: 'minimal valid config', accepted: true, config: baseConfig() },
  {
    name: 'valid empty static model list',
    accepted: true,
    config: { ...baseConfig(), providers: { local: { models: [] } } }
  },
  {
    name: 'provider apiKeyPrefix must be a string',
    accepted: false,
    config: { ...baseConfig(), providers: { local: { apiKeyPrefix: 123 } } }
  },
  {
    name: 'modelsApi apiKeyPrefix must be a string',
    accepted: false,
    config: { ...baseConfig(), providers: { local: { modelsApi: { apiKeyPrefix: 123 } } } }
  },
  {
    name: 'modelsApi header must be a string token',
    accepted: false,
    config: { ...baseConfig(), providers: { local: { modelsApi: { apiKeyHeader: 123 } } } }
  },
  {
    name: 'relative command paths are rejected',
    accepted: false,
    config: { ...baseConfig(), clis: { test: { command: 'tools\\cli.exe' } } }
  },
  {
    name: 'models API queries are rejected',
    accepted: false,
    config: { ...baseConfig(), providers: { local: { modelsApi: { path: '/models?limit=10' } } } }
  },
  {
    name: 'CLI args must be an array',
    accepted: false,
    config: { ...baseConfig(), clis: { test: { command: 'node', args: '--version' } } }
  },
  {
    name: 'provider entries must be objects',
    accepted: false,
    config: { ...baseConfig(), providers: { local: 'invalid' } }
  },
  {
    name: 'null model environment name is allowed',
    accepted: true,
    config: { ...baseConfig(), clis: { test: { command: 'node', modelEnvName: null } } }
  },
  {
    name: 'null provider base URL is rejected',
    accepted: false,
    config: { ...baseConfig(), providers: { local: { baseUrl: null } } }
  }
];

test('Node config validator follows the shared acceptance contract', () => {
  for (const fixture of cases) {
    let accepted = true;
    try { validateConfig(fixture.config); } catch { accepted = false; }
    assert.equal(accepted, fixture.accepted, fixture.name);
  }
});

test('PowerShell config validator follows the shared acceptance contract', {
  skip: process.platform !== 'win32'
}, () => {
  const powershell = 'powershell.exe';
  const available = spawnSync(powershell, ['-NoProfile', '-Command', 'exit 0']);
  if (available.status !== 0) return;

  const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-config-contract-'));
  const fixturePath = path.join(testDir, 'fixtures.json');
  const modulePath = path.join(repoRoot, 'manager', 'ByokManager.psm1');
  fs.writeFileSync(fixturePath, `${JSON.stringify(cases)}\n`, 'utf8');

  const psFixturePath = fixturePath.replaceAll("'", "''");
  const psModulePath = modulePath.replaceAll("'", "''");
  const script = [
    `$fixturePath = '${psFixturePath}'`,
    `$modulePath = '${psModulePath}'`,
    'Import-Module $modulePath -DisableNameChecking -Force',
    '$fixtures = Get-Content -Raw -LiteralPath $fixturePath -Encoding UTF8 | ConvertFrom-Json',
    '$result = @()',
    'foreach ($fixture in $fixtures) {',
    '  $accepted = $true',
    '  try { Assert-ByokProviderConfig $fixture.config | Out-Null } catch { $accepted = $false }',
    '  $result += [pscustomobject]@{ name = $fixture.name; accepted = $accepted }',
    '}',
    '$result | ConvertTo-Json -Compress'
  ].join('\n');

  try {
    const result = spawnSync(powershell, [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-Command', script
    ], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const actual = JSON.parse(result.stdout.trim());
    assert.deepEqual(
      actual.map(item => ({ name: item.name, accepted: item.accepted })),
      cases.map(item => ({ name: item.name, accepted: item.accepted }))
    );
  } finally {
    fs.rmSync(testDir, { recursive: true, force: true });
  }
});
