import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { getByokDataDir, readState, writeState, readCache, writeCache, writeJsonAtomic, updateCacheForProvider, getCachedModelIds, testModelCacheFresh } from './lib/state.mjs';
import { loadProviderConfig, addProvider, normalizeConfig, validateConfig, ConfigValidationError } from './lib/config.mjs';
import { expandTemplateValue, resolveCliArgs, buildRuntimeEnvMap, resolveChosenModel, getSensitiveEnvKeys } from './lib/env.mjs';
import { fetchModels, getSafeModelFetchErrorMessage, canUseStaleCacheForModelFetchError } from './lib/http.mjs';
import { launchCli } from './lib/launcher.mjs';
import { parseArgs, UsageError } from './lib/args.mjs';
import { encodeShellPlan, ShellPlanError } from './lib/shell-plan.mjs';
import { readState as readExtensionState, updateState as updateExtensionState } from '../extension/lib/shared.mjs';

describe('BYOK Bridge Node Manager Unit & Integration Tests', () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-test-'));
  });

  afterEach(() => {
    if (tmpDir && fs.existsSync(tmpDir)) {
      try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
    }
  });

  test('Config loading and normalization', () => {
    const rawConfig = {
      version: 1,
      clis: {
        copilot: {
          name: 'GitHub Copilot CLI',
          command: 'copilot',
          args: ['--experimental'],
          modelEnvName: 'COPILOT_MODEL',
          environment: {
            COPILOT_PROVIDER_BASE_URL: '{url}',
            COPILOT_PROVIDER_API_KEY: '{api_key}',
            COPILOT_MODEL: '{model}'
          }
        }
      },
      providers: {
        testprov: {
          name: 'Test Provider',
          enabled: true,
          baseUrl: 'http://localhost:8080/v1',
          apiKeyEnv: ['TEST_API_KEY'],
          modelEnvNames: ['TEST_MODEL']
        }
      }
    };

    const norm = normalizeConfig(rawConfig, path.join(tmpDir, 'providers.json'));
    assert.equal(norm.clis.length, 1);
    assert.equal(norm.clis[0].id, 'copilot');
    assert.equal(norm.providers.length, 1);
    assert.equal(norm.providers[0].id, 'testprov');
  });

  test('Add new provider dynamically', () => {
    const config = loadProviderConfig(tmpDir);
    const added = addProvider('My Custom Endpoint', 'http://127.0.0.1:5000/v1', 'sk-test123', null, tmpDir);

    assert.ok(added.id.startsWith('my-custom-endpoint'));
    const reloaded = loadProviderConfig(tmpDir);
    const found = reloaded.providers.find(p => p.id === added.id);
    assert.ok(found);
    assert.equal(found.name, 'My Custom Endpoint');
    assert.equal(found.baseUrl, 'http://127.0.0.1:5000/v1');
  });

  test('State & Cache atomic read and write', () => {
    const stateObj = {
      cliId: 'copilot',
      providerId: 'openai-compatible',
      model: 'gpt-4o',
      updatedAt: new Date().toISOString()
    };
    writeState(stateObj, tmpDir);
    const loadedState = readState(tmpDir);
    assert.equal(loadedState.cliId, 'copilot');
    assert.equal(loadedState.model, 'gpt-4o');

    updateCacheForProvider('prov1', 'http://localhost/v1', '/models', ['model-a', 'model-b'], tmpDir);
    const cache = readCache(tmpDir);
    assert.deepEqual(cache.caches['prov1'].models.map(m => m.id), ['model-a', 'model-b']);
    assert.deepEqual(getCachedModelIds('prov1', tmpDir), ['model-a', 'model-b']);
    assert.ok(testModelCacheFresh('prov1', { modelCacheTtlSeconds: 3600 }, tmpDir));
  });

  test('Template expansion and dynamic buildRuntimeEnvMap matching Windows behavior', () => {
    const provider = {
      id: 'custom-prov',
      name: 'Custom Provider',
      apiKeyEnvNames: ['COPILOT_PROVIDER_API_KEY'],
      modelEnvNames: ['COPILOT_MODEL'],
      environment: {
        DIRECT_PROVIDER_VALUE: '{provider_id}:{model}',
        OVERRIDE_ORDER: 'provider-wide',
        copilot: { OVERRIDE_ORDER: 'cli-specific', PROVIDER_AUTH: 'Bearer {api_key}' }
      }
    };

    const cli = {
      id: 'copilot',
      args: ['--experimental'],
      modelEnvName: 'COPILOT_MODEL',
      defaultApiKeyEnv: ['COPILOT_PROVIDER_API_KEY'],
      environment: {
        COPILOT_PROVIDER_BASE_URL: '{url}',
        COPILOT_PROVIDER_API_KEY: '{api_key}',
        COPILOT_PROVIDER_TYPE: 'openai',
        COPILOT_MODEL: '{model}',
        BYOK_MODEL_PROVIDER_ID: '{provider_id}'
      }
    };

    const baseUrl = 'http://localhost:1234/v1';
    const model = 'claude-3-5-sonnet';
    const apiKey = 'sk-secret-key-xyz';
    const providerId = 'custom-prov';

    const envMap = buildRuntimeEnvMap(provider, baseUrl, model, apiKey, providerId, cli);

    assert.equal(envMap['COPILOT_PROVIDER_BASE_URL'], 'http://localhost:1234/v1');
    assert.equal(envMap['COPILOT_PROVIDER_API_KEY'], 'sk-secret-key-xyz');
    assert.equal(envMap['COPILOT_PROVIDER_TYPE'], 'openai');
    assert.equal(envMap['COPILOT_MODEL'], 'claude-3-5-sonnet');
    assert.equal(envMap['BYOK_MODEL_PROVIDER_ID'], 'custom-prov');
    assert.equal(envMap['DIRECT_PROVIDER_VALUE'], 'custom-prov:claude-3-5-sonnet');
    assert.equal(envMap['OVERRIDE_ORDER'], 'cli-specific');
    assert.equal(envMap['PROVIDER_AUTH'], 'Bearer sk-secret-key-xyz');

    const cliArgs = resolveCliArgs(cli, provider, baseUrl, model, apiKey, providerId);
    assert.deepEqual(cliArgs, ['--experimental']);
  });

  test('resolveChosenModel selection fallback logic', () => {
    // 1. Requested model flag wins
    assert.equal(resolveChosenModel('flag-model', 'env-model', 'rem-model', ['m1', 'm2']), 'flag-model');
    // 2. Env model second
    assert.equal(resolveChosenModel('', 'env-model', 'rem-model', ['m1', 'm2']), 'env-model');
    // 3. Remembered model if available and provider unchanged
    assert.equal(resolveChosenModel('', '', 'rem-model', ['rem-model', 'm2'], false), 'rem-model');
    // 4. Reset to first available if provider changed
    assert.equal(resolveChosenModel('', '', 'rem-model', ['m1', 'm2'], true), 'm1');
  });

  test('HTTP fetchModels with mock server', async () => {
    const server = http.createServer((req, res) => {
      if (req.url === '/v1/models' && req.headers['authorization'] === 'Bearer test-token') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          data: [{ id: 'mock-model-1' }, { id: 'mock-model-2' }]
        }));
      } else {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Unauthorized' }));
      }
    });

    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const port = server.address().port;
    const baseUrl = `http://127.0.0.1:${port}/v1`;

    const provider = {
      modelsApi: { path: '/models', itemsPath: 'data', idPath: 'id' }
    };

    const models = await fetchModels(provider, baseUrl, 'test-token');
    assert.deepEqual(models, ['mock-model-1', 'mock-model-2']);

    await new Promise((resolve) => server.close(resolve));
  });

  test('Only transport and authentication failures permit stale model cache fallback', async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{ invalid json');
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
      const baseUrl = `http://127.0.0.1:${server.address().port}`;
      await assert.rejects(fetchModels({ modelsApi: { path: '/models' } }, baseUrl), error => {
        assert.equal(canUseStaleCacheForModelFetchError(error), false);
        assert.match(error.message, /invalid JSON/);
        return true;
      });
    } finally {
      await new Promise(resolve => server.close(resolve));
    }

    await assert.rejects(fetchModels({ modelsApi: { path: '/models' } }, 'http://127.0.0.1:1'), error => {
      assert.equal(canUseStaleCacheForModelFetchError(error), true);
      return true;
    });
  });

  test('HTTP header values reject injection without leaking API keys', async () => {
    const baseUrl = 'http://127.0.0.1:1/v1';
    const cases = [
      {
        name: 'provider prefix',
        provider: {
          apiKeyPrefix: 'Bearer legit\r\nX-Injected: yes\r\nAnother: ',
          modelsApi: { path: '/models' }
        },
        apiKey: 'PROVIDER_PREFIX_TEST_KEY'
      },
      {
        name: 'models API prefix',
        provider: {
          apiKeyPrefix: 'Bearer ',
          modelsApi: { path: '/models', apiKeyPrefix: 'Token\u007f' }
        },
        apiKey: 'MODELS_PREFIX_TEST_KEY'
      },
      {
        name: 'API key',
        provider: { modelsApi: { path: '/models' } },
        apiKey: 'API_KEY_SAFE_PART\r\nX-Injected: API_KEY_SECRET_PART'
      }
    ];

    for (const fixture of cases) {
      await assert.rejects(fetchModels(fixture.provider, baseUrl, fixture.apiKey), error => {
        assert.match(error.message, /control characters/, fixture.name);
        assert.equal(error.message.includes(fixture.apiKey), false, `${fixture.name} leaked the API key`);
        assert.equal(error.message.includes('API_KEY_SECRET_PART'), false, `${fixture.name} leaked a secret fragment`);
        return true;
      });
    }

    const apiKey = 'API_KEY_THAT_MUST_NOT_LEAK';
    assert.equal(
      getSafeModelFetchErrorMessage(new Error(`Native header failure: Bearer ${apiKey}`), apiKey),
      'Model fetch failed.'
    );
    assert.equal(
      getSafeModelFetchErrorMessage(new Error('Connection refused.'), apiKey),
      'Connection refused.'
    );
    assert.equal(
      getSafeModelFetchErrorMessage(new Error('Connection refused.'), ''),
      'Connection refused.'
    );
  });

  test('Launcher dry-run mode', async () => {
    const exitCode = await launchCli('node', ['--version'], { TEST_ENV: '123' }, { dryRun: true });
    assert.equal(exitCode, 0);
  });

  test('Strict argument parser rejects unknown, missing, duplicate, and unsafe emit options', () => {
    assert.throws(() => parseArgs(['--api-key', '--dry-run']), UsageError);
    assert.throws(() => parseArgs(['--wat']), UsageError);
    assert.throws(() => parseArgs(['--emit-env']), UsageError);
    assert.throws(() => parseArgs(['--model', 'a', '--model', 'b']), UsageError);
    assert.throws(() => parseArgs(['--dry-run', '--provider', '+']), UsageError);
    const selfCheck = parseArgs(['--data-dir', '/tmp/byok-test', '--self-check']);
    assert.equal(selfCheck.selfCheck, true);
    assert.equal(selfCheck.dataDir, '/tmp/byok-test');
    assert.equal(parseArgs(['--internal-shell-plan-fd', '3', '--help']).internalShellPlanFd, '3');
    assert.throws(() => parseArgs(['--internal-shell-plan-fd', '1']), UsageError);
    assert.throws(() => parseArgs(['--self-check', '--provider', 'local']), UsageError);
    assert.equal(parseArgs(['--no-clear']).noClear, true);
    assert.deepEqual(parseArgs(['--cli', 'copilot', '--', '--verbose']).passthroughArgs, ['--verbose']);
  });

  test('Shell plan protocol encodes data without emitting executable shell syntax', () => {
    const payload = encodeShellPlan({
      action: 'launch',
      command: 'copilot',
      args: ['', 'space value', '$(not-executed)', '繁體中文'],
      environment: {
        TEST_EMPTY: '',
        TEST_SECRET: 'line one\nline two\t$`"',
        TEST_BOOLEAN: false,
        TEST_NUMBER: 0
      }
    });
    assert.match(payload, /^BYOK_BRIDGE_SHELL_PLAN\t1\nACTION\tlaunch\n/);
    assert.ok(payload.includes(`ENV\tTEST_SECRET\t${Buffer.from('line one\nline two\t$`"').toString('hex')}\n`));
    assert.ok(payload.includes(`ARG\t${Buffer.from('$(not-executed)').toString('hex')}\n`));
    assert.doesNotMatch(payload, /export|line one|not-executed/);
    assert.throws(() => encodeShellPlan({ action: 'launch', command: 'x', args: [], environment: { PATH: '/tmp' } }), ShellPlanError);
    assert.throws(() => encodeShellPlan({ action: 'launch', command: 'x', args: [], environment: { _BYOK_BRIDGE_TEST: 'x' } }), ShellPlanError);
    assert.throws(() => encodeShellPlan({ action: 'launch', command: 'x\0y', args: [], environment: {} }), ShellPlanError);
    assert.equal(encodeShellPlan({ action: 'none' }), 'BYOK_BRIDGE_SHELL_PLAN\t1\nACTION\tnone\nEND\t1\n');
  });

  test('Manager emits a resolved launch plan on FD 3 without launching the CLI', () => {
    const config = {
      version: 1,
      clis: {
        test: {
          command: process.execPath,
          args: ['--version'],
          environment: {
            TEST_URL: '{url}',
            TEST_KEY: '{api_key}',
            TEST_MODEL: '{model}'
          }
        }
      },
      providers: {
        static: {
          baseUrl: 'https://example.test/v1',
          apiKeyEnv: ['TEST_KEY'],
          models: ['model-a'],
          environment: { TEST_PROVIDER: '{provider_id}' }
        }
      }
    };
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), config);
    const managerPath = fileURLToPath(new URL('./manager.mjs', import.meta.url));
    const result = spawnSync(process.execPath, [
      managerPath,
      '--internal-shell-plan-fd', '3',
      '--data-dir', tmpDir,
      '--cli', 'test',
      '--provider', 'static',
      '--model', 'model-a',
      '--api-key', 'shell-secret'
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe', 'pipe'] });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.output[3], /^BYOK_BRIDGE_SHELL_PLAN\t1\nACTION\tlaunch\n/);
    assert.ok(result.output[3].includes(`ENV\tTEST_KEY\t${Buffer.from('shell-secret').toString('hex')}\n`));
    assert.ok(result.output[3].includes(`COMMAND\t${Buffer.from(process.execPath).toString('hex')}\n`));
    assert.match(result.stdout, /TEST_KEY=\[set\]/);
    assert.doesNotMatch(result.stdout + result.stderr, /shell-secret/);
    assert.doesNotMatch(result.stdout, /v\d+\.\d+\.\d+/);

    const dryRun = spawnSync(process.execPath, [
      managerPath,
      '--internal-shell-plan-fd', '3',
      '--data-dir', tmpDir,
      '--cli', 'test',
      '--provider', 'static',
      '--model', 'model-a',
      '--dry-run'
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe', 'pipe'] });
    assert.equal(dryRun.status, 0, dryRun.stderr || dryRun.stdout);
    assert.equal(dryRun.output[3], 'BYOK_BRIDGE_SHELL_PLAN\t1\nACTION\tnone\nEND\t1\n');
  });

  test('Config validation reports JSON paths and preserves a damaged user config', () => {
    const invalid = {
      version: 1,
      clis: { copilot: { command: 'copilot', environment: { 'BAD-NAME': '{api_key}' } } },
      providers: {}
    };
    assert.throws(() => validateConfig(invalid), (error) => {
      assert.ok(error instanceof ConfigValidationError);
      assert.match(error.message, /BAD-NAME/);
      return true;
    });
    assert.throws(() => validateConfig({
      version: 1,
      clis: { unsafe: { command: 'tool', args: ['--token', '{api_key}'] } },
      providers: {}
    }), /process arguments/);

    const configPath = path.join(tmpDir, 'providers.json');
    fs.writeFileSync(configPath, '{ damaged json', 'utf8');
    assert.throws(() => loadProviderConfig(tmpDir), /Invalid JSON/);
    assert.equal(fs.readFileSync(configPath, 'utf8'), '{ damaged json');
  });

  test('Cache freshness is scoped to endpoint identity and migrates legacy field names', () => {
    updateCacheForProvider('alpha', 'https://one.example/v1', '/models', ['m1'], tmpDir);
    const provider = { modelCacheTtlSeconds: 3600 };
    assert.equal(testModelCacheFresh('alpha', provider, tmpDir, {
      baseUrl: 'https://one.example/v1', apiPath: '/models'
    }), true);
    assert.equal(testModelCacheFresh('alpha', provider, tmpDir, {
      baseUrl: 'https://two.example/v1', apiPath: '/models'
    }), false);

    writeJsonAtomic(path.join(tmpDir, 'models-cache.json'), {
      version: 1,
      caches: {
        legacy: {
          lastQueried: new Date().toISOString(),
          baseUrl: 'https://legacy.example/v1',
          modelsApiPath: '/legacy-models',
          models: [{ id: 'legacy-model', available: true }]
        }
      }
    });
    const migrated = readCache(tmpDir).caches.legacy;
    assert.ok(migrated.updatedAt);
    assert.equal(migrated.apiPath, '/legacy-models');
  });

  test('Secret redaction follows API-key-derived values instead of variable names', () => {
    const map = buildRuntimeEnvMap(
      { environment: { copilot: { AUTH: 'Bearer {api_key}', visible: '{model}' } } },
      'https://example.test/v1',
      'm1',
      'super-secret',
      'p1',
      { id: 'copilot', environment: {} }
    );
    const sensitive = getSensitiveEnvKeys(map, 'super-secret');
    assert.equal(sensitive.has('AUTH'), true);
    assert.equal(sensitive.has('visible'), false);
  });

  test('Manager dry-run performs no persistent write and does not support shell env output', () => {
    const config = {
      version: 1,
      clis: {
        test: {
          command: 'node',
          args: [],
          modelEnvName: 'TEST_MODEL',
          environment: { TEST_MODEL: '{model}' }
        }
      },
      providers: {
        static: {
          enabled: true,
          baseUrl: 'https://example.test/v1',
          apiKeyRequired: false,
          models: ['model-a'],
          environment: {}
        }
      }
    };
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), config);
    const managerPath = fileURLToPath(new URL('./manager.mjs', import.meta.url));
    const result = spawnSync(process.execPath, [
      managerPath,
      '--data-dir', tmpDir,
      '--cli', 'test',
      '--provider', 'static',
      '--dry-run'
    ], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(path.join(tmpDir, 'state.json')), false);
    assert.equal(fs.existsSync(path.join(tmpDir, 'models-cache.json')), false);

    const legacyDir = path.join(tmpDir, 'legacy-only');
    fs.mkdirSync(path.join(legacyDir, 'config'), { recursive: true });
    fs.writeFileSync(path.join(legacyDir, 'config', 'providers.json'), `${JSON.stringify(config, null, 2)}\n`, 'utf8');
    const legacyDryRun = spawnSync(process.execPath, [
      managerPath,
      '--data-dir', legacyDir,
      '--cli', 'test',
      '--provider', 'static',
      '--dry-run'
    ], { encoding: 'utf8' });
    assert.equal(legacyDryRun.status, 0, legacyDryRun.stderr);
    assert.equal(fs.existsSync(path.join(legacyDir, 'providers.json')), false);
    assert.equal(fs.existsSync(path.join(legacyDir, 'state.json')), false);
    assert.equal(fs.existsSync(path.join(legacyDir, 'models-cache.json')), false);

    const rejected = spawnSync(process.execPath, [managerPath, '--emit-env'], { encoding: 'utf8' });
    assert.equal(rejected.status, 2);
    assert.match(rejected.stderr, /Unknown option/);
  });

  test('HTTP response reader enforces a body-size limit', async () => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'x'.repeat(200) }] }));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
      const port = server.address().port;
      await assert.rejects(
        fetchModels({ modelsApi: { path: '/models' } }, `http://127.0.0.1:${port}`, '', 1000, 32),
        /exceeds/
      );
    } finally {
      await new Promise(resolve => server.close(resolve));
    }
  });

  test('Extension performs a locked state merge and preserves damaged state', () => {
    writeState({ providerId: 'alpha', providerName: 'Alpha', model: 'old' }, tmpDir);
    updateExtensionState(current => ({ ...current, model: 'new' }), tmpDir);
    assert.deepEqual(readExtensionState(tmpDir), {
      providerId: 'alpha', providerName: 'Alpha', model: 'new'
    });

    const statePath = path.join(tmpDir, 'state.json');
    fs.writeFileSync(statePath, '{ damaged', 'utf8');
    assert.throws(() => updateExtensionState(current => current, tmpDir), /Invalid or unreadable/);
    assert.equal(fs.readFileSync(statePath, 'utf8'), '{ damaged');
  });
});
