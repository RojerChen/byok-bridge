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

function withCli(cli) {
  return { ...baseConfig(), clis: { test: cli } };
}

function withProvider(provider) {
  return { ...baseConfig(), providers: { local: provider } };
}

function openCodeCli(overrides = {}) {
  return {
    command: 'opencode',
    args: [],
    adapter: 'opencode-config-v1',
    configEnvName: 'OPENCODE_CONFIG',
    configFileName: 'opencode.json',
    template: {
      provider: {
        '{opencode_provider_id}': {
          options: { baseURL: '{url}', apiKey: '{api_key_ref}' },
          models: '{models}'
        }
      },
      model: '{opencode_provider_id}/{model}'
    },
    environment: {},
    ...overrides
  };
}

const cases = [
  { name: 'minimal valid config', accepted: true, config: baseConfig() },
  {
    name: 'unknown fields are ignored',
    accepted: true,
    config: {
      ...baseConfig(),
      unknownRoot: { future: true },
      clis: { test: { command: 'node', unknownCli: ['future'] } },
      providers: { local: { unknownProvider: { future: true } } }
    }
  },
  {
    name: 'valid empty static model list',
    accepted: true,
    config: withProvider({ models: [] })
  },
  {
    name: 'valid scalar template values',
    accepted: true,
    config: {
      ...baseConfig(),
      clis: {
        test: {
          command: 'node',
          environment: { STRING_VALUE: 'value', NUMBER_VALUE: 1.5, BOOLEAN_VALUE: true },
          settings: { ZERO_VALUE: 0, FALSE_VALUE: false }
        }
      },
      providers: {
        local: {
          settings: { PROVIDER_NUMBER: 42 },
          environment: {
            PROVIDER_STRING: 'value',
            PROVIDER_NUMBER: 1.5,
            PROVIDER_BOOLEAN: false,
            test: { CLI_SPECIFIC: 'value' }
          }
        }
      }
    }
  },
  {
    name: 'valid provider URL header prefix and models API fields',
    accepted: true,
    config: withProvider({
      baseUrl: 'https://example.test/v1',
      modelCacheTtlSeconds: 0,
      apiKeyEnv: ['TEST_API_KEY'],
      apiKeyEnvNames: 'SECONDARY_API_KEY',
      modelEnvNames: ['TEST_MODEL'],
      apiKeyHeader: 'X-Api-Key',
      apiKeyPrefix: '',
      modelsApi: {
        path: '/models',
        itemsPath: 'data.items',
        idPath: 'model.id',
        apiKeyHeader: 'Authorization',
        apiKeyPrefix: 'Bearer '
      },
      models: ['model-a', { id: 'model-b' }]
    })
  },
  {
    name: 'valid simple executable name',
    accepted: true,
    config: withCli({ command: 'tool-name.exe' })
  },
  {
    name: 'valid OpenCode adapter template',
    accepted: true,
    config: withCli(openCodeCli())
  },
  {
    name: 'OpenCode adapter name is fixed',
    accepted: false,
    config: withCli(openCodeCli({ adapter: 'unknown-adapter' }))
  },
  {
    name: 'OpenCode config environment name is fixed',
    accepted: false,
    config: withCli(openCodeCli({ configEnvName: 'OTHER_CONFIG' }))
  },
  {
    name: 'OpenCode output filename is fixed',
    accepted: false,
    config: withCli(openCodeCli({ configFileName: 'providers.json' }))
  },
  {
    name: 'OpenCode plaintext API key placeholder is rejected',
    accepted: false,
    config: withCli(openCodeCli({ template: { value: '{api_key}' } }))
  },
  {
    name: 'legacy OpenCode API key placeholder name is rejected',
    accepted: false,
    config: withCli(openCodeCli({ template: { value: '{api_key_env}' } }))
  },
  {
    name: 'OpenCode unknown Hub placeholder is rejected',
    accepted: false,
    config: withCli(openCodeCli({ template: { value: '{unknown_token}' } }))
  },
  {
    name: 'OpenCode API key reference placeholder must be options.apiKey',
    accepted: false,
    config: withCli(openCodeCli({ template: { apiKey: '{api_key_ref}' } }))
  },
  {
    name: 'OpenCode fields require an adapter',
    accepted: false,
    config: withCli({ command: 'opencode', configFileName: 'opencode.json' })
  },
  {
    name: 'valid Windows drive-rooted command path',
    accepted: true,
    platforms: ['win32'],
    config: withCli({ command: 'C:\\tools\\cli.exe' })
  },
  {
    name: 'valid Windows UNC command path',
    accepted: true,
    platforms: ['win32'],
    config: withCli({ command: '\\\\server\\share\\cli.exe' })
  },
  {
    name: 'version string is rejected',
    accepted: false,
    config: { ...baseConfig(), version: '1' }
  },
  {
    name: 'version boolean is rejected',
    accepted: false,
    config: { ...baseConfig(), version: true }
  },
  {
    name: 'version object is rejected',
    accepted: false,
    config: { ...baseConfig(), version: { value: 1 } }
  },
  {
    name: 'provider apiKeyPrefix must be a string',
    accepted: false,
    config: withProvider({ apiKeyPrefix: 123 })
  },
  {
    name: 'provider apiKeyPrefix rejects CRLF injection',
    accepted: false,
    config: withProvider({ apiKeyPrefix: 'Bearer legit\r\nX-Injected: yes\r\nAnother: ' })
  },
  {
    name: 'modelsApi apiKeyPrefix must be a string',
    accepted: false,
    config: withProvider({ modelsApi: { apiKeyPrefix: 123 } })
  },
  {
    name: 'modelsApi apiKeyPrefix rejects DEL',
    accepted: false,
    config: withProvider({ modelsApi: { apiKeyPrefix: 'Bearer\u007f' } })
  },
  {
    name: 'modelsApi header must be a string token',
    accepted: false,
    config: withProvider({ modelsApi: { apiKeyHeader: 123 } })
  },
  {
    name: 'provider header rejects invalid token characters',
    accepted: false,
    config: withProvider({ apiKeyHeader: 'X Header' })
  },
  {
    name: 'modelsApi header rejects control characters',
    accepted: false,
    config: withProvider({ modelsApi: { apiKeyHeader: 'X-Test\r\nInjected' } })
  },
  {
    name: 'relative command paths are rejected',
    accepted: false,
    config: withCli({ command: 'tools\\cli.exe' })
  },
  {
    name: 'Windows drive-relative command paths are rejected',
    accepted: false,
    config: withCli({ command: 'C:tools\\cli.exe' })
  },
  {
    name: 'models API queries are rejected',
    accepted: false,
    config: withProvider({ modelsApi: { path: '/models?limit=10' } })
  },
  {
    name: 'models API fragments are rejected',
    accepted: false,
    config: withProvider({ modelsApi: { path: '/models#fragment' } })
  },
  {
    name: 'models API path rejects control characters',
    accepted: false,
    config: withProvider({ modelsApi: { path: '/models\u0000suffix' } })
  },
  {
    name: 'models API path must be a string',
    accepted: false,
    config: withProvider({ modelsApi: { path: 123 } })
  },
  {
    name: 'models API itemsPath must be a string',
    accepted: false,
    config: withProvider({ modelsApi: { itemsPath: false } })
  },
  {
    name: 'models API idPath must be a string',
    accepted: false,
    config: withProvider({ modelsApi: { idPath: ['id'] } })
  },
  {
    name: 'CLI args must be an array',
    accepted: false,
    config: withCli({ command: 'node', args: '--version' })
  },
  {
    name: 'CLI args must contain only strings',
    accepted: false,
    config: withCli({ command: 'node', args: [123] })
  },
  {
    name: 'CLI args cannot contain API key templates',
    accepted: false,
    config: withCli({ command: 'node', args: ['--api-key={api_key}'] })
  },
  {
    name: 'provider entries must be objects',
    accepted: false,
    config: { ...baseConfig(), providers: { local: 'invalid' } }
  },
  {
    name: 'null model environment name is allowed',
    accepted: true,
    config: withCli({ command: 'node', modelEnvName: null })
  },
  {
    name: 'null provider base URL is rejected',
    accepted: false,
    config: withProvider({ baseUrl: null })
  },
  {
    name: 'provider base URL credentials are rejected',
    accepted: false,
    config: withProvider({ baseUrl: 'https://user:password@example.test/v1' })
  },
  {
    name: 'provider base URL queries are rejected',
    accepted: false,
    config: withProvider({ baseUrl: 'https://example.test/v1?key=value' })
  },
  {
    name: 'provider base URL protocol must be HTTP or HTTPS',
    accepted: false,
    config: withProvider({ baseUrl: 'file:///tmp/models' })
  },
  {
    name: 'negative model cache TTL is rejected',
    accepted: false,
    config: withProvider({ modelCacheTtlSeconds: -1 })
  },
  {
    name: 'string model cache TTL is rejected',
    accepted: false,
    config: withProvider({ modelCacheTtlSeconds: '1' })
  },
  {
    name: 'CLI environment object template is rejected',
    accepted: false,
    config: withCli({ command: 'node', environment: { VALUE: { nested: 1 } } })
  },
  {
    name: 'CLI environment array template is rejected',
    accepted: false,
    config: withCli({ command: 'node', environment: { VALUE: ['nested'] } })
  },
  {
    name: 'CLI environment null template is rejected',
    accepted: false,
    config: withCli({ command: 'node', environment: { VALUE: null } })
  },
  {
    name: 'provider nested environment object template is rejected',
    accepted: false,
    config: withProvider({ environment: { test: { VALUE: { nested: 1 } } } })
  },
  {
    name: 'provider direct environment array template is rejected',
    accepted: false,
    config: withProvider({ environment: { VALUE: ['nested'] } })
  },
  {
    name: 'provider direct environment null template is rejected',
    accepted: false,
    config: withProvider({ environment: { VALUE: null } })
  },
  {
    name: 'provider settings array template is rejected',
    accepted: false,
    config: withProvider({ settings: { VALUE: ['nested'] } })
  },
  {
    name: 'invalid environment variable name is rejected',
    accepted: false,
    config: withCli({ command: 'node', environment: { 'BAD-NAME': 'value' } })
  },
  {
    name: 'static models must be an array',
    accepted: false,
    config: withProvider({ models: 'model-a' })
  },
  {
    name: 'static model IDs reject control characters',
    accepted: false,
    config: withProvider({ models: ['model-a\nmodel-b'] })
  }
];

function casesForCurrentPlatform() {
  return cases.filter(fixture => !fixture.platforms || fixture.platforms.includes(process.platform));
}

function evaluateWithNode(fixtures) {
  return fixtures.map((fixture) => {
    let accepted = true;
    try { validateConfig(fixture.config); } catch { accepted = false; }
    return { name: fixture.name, accepted };
  });
}

test('Node config validator follows the shared acceptance contract', () => {
  const activeCases = casesForCurrentPlatform();
  assert.deepEqual(
    evaluateWithNode(activeCases),
    activeCases.map(fixture => ({ name: fixture.name, accepted: fixture.accepted }))
  );
});

test('PowerShell config validator follows the shared acceptance contract', {
  skip: 'PowerShell implementation removed in Phase 5 of nodejs-migration-plan.md'
}, () => {
  const powershell = 'powershell.exe';
  const available = spawnSync(powershell, ['-NoProfile', '-Command', 'exit 0']);
  if (available.status !== 0) return;

  const testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-config-contract-'));
  const fixturePath = path.join(testDir, 'fixtures.json');
  const modulePath = path.join(repoRoot, 'manager', 'ByokManager.psm1');
  const activeCases = casesForCurrentPlatform();
  fs.writeFileSync(fixturePath, `${JSON.stringify(activeCases)}\n`, 'utf8');

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
      activeCases.map(item => ({ name: item.name, accepted: item.accepted }))
    );
    assert.deepEqual(
      actual.map(item => ({ name: item.name, accepted: item.accepted })),
      evaluateWithNode(activeCases),
      'Node and PowerShell validators disagreed on the shared fixture set'
    );
  } finally {
    fs.rmSync(testDir, { recursive: true, force: true });
  }
});
