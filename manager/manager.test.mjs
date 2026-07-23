import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';

import { getByokDataDir, readState, writeState, readCache, writeCache, updateCacheForProvider, getCachedModelIds, testModelCacheFresh } from './lib/state.mjs';
import { loadProviderConfig, addProvider, normalizeConfig } from './lib/config.mjs';
import { expandTemplateValue, resolveCliArgs, buildRuntimeEnvMap, resolveChosenModel } from './lib/env.mjs';
import { fetchModels } from './lib/http.mjs';
import { launchCli } from './lib/launcher.mjs';

describe('BYOK CLI Hub Node Manager Unit & Integration Tests', () => {
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
      modelEnvNames: ['COPILOT_MODEL']
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

  test('Launcher dry-run mode', async () => {
    const exitCode = await launchCli('node', ['--version'], { TEST_ENV: '123' }, { dryRun: true });
    assert.equal(exitCode, 0);
  });
});
