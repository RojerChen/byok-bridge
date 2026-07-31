import { describe, test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  OPENCODE_API_KEY_ENV,
  OPENCODE_MAX_JSON_BYTES,
  OPENCODE_MAX_MODELS,
  buildOpenCodeConfig,
  getOpenCodeConfigPath,
  getOpenCodeProviderId,
  validateOpenCodeTemplate,
  writeOpenCodeConfig
} from './lib/opencode.mjs';

const template = {
  '$schema': 'https://opencode.ai/config.json',
  provider: {
    '{opencode_provider_id}': {
      npm: '@ai-sdk/openai-compatible',
      name: '{provider_name} (BYOK Bridge)',
      options: { baseURL: '{url}', apiKey: '{api_key_ref}' },
      models: '{models}'
    }
  },
  model: '{opencode_provider_id}/{model}',
  preserved: '{env:UNRELATED_VALUE}'
};

const managerPath = fileURLToPath(new URL('./manager.mjs', import.meta.url));

function writeManagerConfig(dataDir, command = process.execPath, apiKeyRequired = true) {
  fs.writeFileSync(path.join(dataDir, 'providers.json'), `${JSON.stringify({
    version: 1,
    clis: {
      opencode: {
        name: 'OpenCode CLI',
        command,
        args: ['--version'],
        adapter: 'opencode-config-v1',
        configEnvName: 'OPENCODE_CONFIG',
        configFileName: 'opencode.json',
        template,
        environment: { CLI_ONLY: '{model}' }
      }
    },
    providers: {
      'Company.Gateway': {
        name: 'Company Gateway',
        baseUrl: 'https://gateway.example/v1',
        apiKeyRequired,
        apiKeyEnv: ['COPILOT_PROVIDER_API_KEY'],
        modelEnvNames: ['COPILOT_MODEL'],
        models: ['Model/A', 'Model/B'],
        environment: {
          PROVIDER_WIDE: '{provider_id}:{model}',
          opencode: { OPENCODE_ONLY: '{provider_id}' }
        }
      }
    }
  }, null, 2)}\n`, 'utf8');
}

describe('OpenCode config adapter', () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-opencode-'));
  });

  afterEach(() => {
    if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  test('creates a deterministic runtime provider ID', () => {
    assert.equal(getOpenCodeProviderId('company-gateway'), 'byok-bridge-company-gateway');
    const source = 'Company Gateway/台灣';
    const hash = crypto.createHash('sha256').update(source, 'utf8').digest('hex').slice(0, 8);
    assert.equal(getOpenCodeProviderId(source), `byok-bridge-company-gateway-${hash}`);
  });

  test('renders models as typed object keys and references the key through the environment', () => {
    const apiKey = 'secret-that-must-not-be-written';
    const originalTemplate = JSON.stringify(template);
    const result = buildOpenCodeConfig(template, {
      providerId: 'company-gateway',
      providerName: 'Company Gateway',
      baseUrl: 'https://gateway.example/v1',
      apiKey,
      apiKeyRequired: true,
      availableModels: ['Model/A', '__proto__', 'constructor', 'space model', 'quote"model', 'back\\slash', '模型', 'foo', 'Foo', 'Model/A'],
      chosenModel: 'Extra/Model',
      chosenModelSource: 'option'
    });

    const provider = result.config.provider['byok-bridge-company-gateway'];
    assert.deepEqual(Object.keys(provider.models), [
      'Model/A', '__proto__', 'constructor', 'space model', 'quote"model', 'back\\slash', '模型', 'foo', 'Foo', 'Extra/Model'
    ]);
    assert.equal(provider.models['__proto__'].name, '__proto__');
    assert.equal(provider.options.apiKey, `{env:${OPENCODE_API_KEY_ENV}}`);
    assert.equal(result.config.model, 'byok-bridge-company-gateway/Extra/Model');
    assert.equal(result.config.preserved, '{env:UNRELATED_VALUE}');
    assert.equal(JSON.stringify(result.config).includes(apiKey), false);
    assert.equal(JSON.stringify(template), originalTemplate);
  });

  test('omits options.apiKey for an optional provider without a key', () => {
    const result = buildOpenCodeConfig(template, {
      providerId: 'local',
      providerName: 'Local',
      baseUrl: 'http://127.0.0.1:1234/v1',
      apiKey: '',
      apiKeyRequired: false,
      availableModels: ['local-model'],
      chosenModel: 'local-model',
      chosenModelSource: 'first-available'
    });
    assert.equal(Object.hasOwn(result.config.provider['byok-bridge-local'].options, 'apiKey'), false);
  });

  test('rejects unsafe placeholders, misplaced typed values, and key collisions', () => {
    assert.throws(() => validateOpenCodeTemplate({ value: '{api_key}' }), /plaintext API key/);
    assert.throws(() => validateOpenCodeTemplate({ value: '{api_key_env}' }), /Unknown/);
    assert.throws(() => validateOpenCodeTemplate({ value: '{unknown_token}' }), /Unknown/);
    assert.throws(() => validateOpenCodeTemplate({ value: 'prefix-{models}' }), /complete template value/);
    assert.throws(() => validateOpenCodeTemplate({ apiKey: '{api_key_ref}' }), /only allowed/);
    assert.throws(() => buildOpenCodeConfig({
      provider: { '{provider_id}': {}, 'provider-id': {} },
      model: '{opencode_provider_id}/{model}'
    }, {
      providerId: 'provider-id', providerName: 'Provider', baseUrl: 'https://example.test/v1',
      apiKey: '', apiKeyRequired: false, availableModels: ['m1'], chosenModel: 'm1', chosenModelSource: 'option'
    }), /duplicate/);
  });

  test('enforces template depth, model count, generated size, and required schema limits', () => {
    let deep = { leaf: true };
    for (let index = 0; index < 33; index += 1) deep = { nested: deep };
    assert.throws(() => validateOpenCodeTemplate(deep), /maximum depth/);

    const context = {
      providerId: 'local', providerName: 'Local', baseUrl: 'http://localhost:1234/v1',
      apiKey: '', apiKeyRequired: false, chosenModel: 'm0', chosenModelSource: 'first-available'
    };
    assert.throws(() => buildOpenCodeConfig(template, {
      ...context,
      availableModels: Array.from({ length: OPENCODE_MAX_MODELS + 1 }, (_, index) => `m${index}`)
    }), /maximum/);
    assert.throws(() => buildOpenCodeConfig({ ...template, oversized: 'x'.repeat(OPENCODE_MAX_JSON_BYTES) }, {
      ...context,
      availableModels: ['m0']
    }), /UTF-8 bytes/);
    const noSchema = structuredClone(template);
    delete noSchema.$schema;
    assert.throws(() => buildOpenCodeConfig(noSchema, { ...context, availableModels: ['m0'] }), /\$schema/);
  });

  test('writes only the requested opencode.json path as valid JSON', () => {
    const result = buildOpenCodeConfig(template, {
      providerId: 'local',
      providerName: 'Local',
      baseUrl: 'http://localhost:1234/v1',
      apiKey: '',
      apiKeyRequired: false,
      availableModels: ['m1'],
      chosenModel: 'm1',
      chosenModelSource: 'first-available'
    });
    const configPath = getOpenCodeConfigPath(tmpDir);
    writeOpenCodeConfig(configPath, result.config);
    assert.equal(path.basename(configPath), 'opencode.json');
    assert.deepEqual(JSON.parse(fs.readFileSync(configPath, 'utf8')), JSON.parse(JSON.stringify(result.config)));
    assert.equal(fs.existsSync(path.join(tmpDir, 'config', 'providers.json')), false);
  });

  test('manager writes opencode.json and emits all configured environment values', () => {
    writeManagerConfig(tmpDir);
    const result = spawnSync(process.execPath, [
      managerPath,
      '--internal-shell-plan-fd', '3',
      '--data-dir', tmpDir,
      '--cli', 'opencode',
      '--provider', 'Company.Gateway',
      '--model', 'Custom/Model',
      '--api-key', 'integration-secret'
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe', 'pipe'] });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    const generatedPath = path.join(tmpDir, 'opencode.json');
    const generated = JSON.parse(fs.readFileSync(generatedPath, 'utf8'));
    const runtimeProviderId = getOpenCodeProviderId('Company.Gateway');
    assert.equal(generated.model, `${runtimeProviderId}/Custom/Model`);
    assert.equal(generated.provider[runtimeProviderId].models['Custom/Model'].name, 'Custom/Model');
    assert.equal(generated.provider[runtimeProviderId].options.apiKey, `{env:${OPENCODE_API_KEY_ENV}}`);
    assert.equal(fs.readFileSync(generatedPath, 'utf8').includes('integration-secret'), false);

    const plan = result.output[3];
    assert.ok(plan.includes(`ENV\tOPENCODE_CONFIG\t${Buffer.from(generatedPath).toString('hex')}\n`));
    assert.ok(plan.includes(`ENV\t${OPENCODE_API_KEY_ENV}\t${Buffer.from('integration-secret').toString('hex')}\n`));
    assert.ok(plan.includes(`ENV\tCLI_ONLY\t${Buffer.from('Custom/Model').toString('hex')}\n`));
    assert.ok(plan.includes(`ENV\tOPENCODE_ONLY\t${Buffer.from('Company.Gateway').toString('hex')}\n`));
    assert.ok(plan.includes(`ENV\tPROVIDER_WIDE\t${Buffer.from('Company.Gateway:Custom/Model').toString('hex')}\n`));
    assert.ok(plan.includes(`ENV\tCOPILOT_PROVIDER_API_KEY\t${Buffer.from('integration-secret').toString('hex')}\n`));
    assert.ok(plan.includes(`ENV\tCOPILOT_MODEL\t${Buffer.from('Custom/Model').toString('hex')}\n`));
    const state = JSON.parse(fs.readFileSync(path.join(tmpDir, 'state.json'), 'utf8'));
    assert.equal(state.modelSource, 'option');
    assert.equal(state.runtimeProviderId, runtimeProviderId);
    assert.equal(state.runtimeConfigType, 'opencode-config-v1');
  });

  test('direct launch fake OpenCode loads the generated file and runtime API key', () => {
    writeManagerConfig(tmpDir);
    const fakeCliPath = path.join(tmpDir, 'fake-opencode.mjs');
    fs.writeFileSync(fakeCliPath, [
      "import fs from 'node:fs';",
      "const config = JSON.parse(fs.readFileSync(process.env.OPENCODE_CONFIG, 'utf8'));",
      "const providerId = Object.keys(config.provider).find(id => id.startsWith('byok-bridge-'));",
      "if (!providerId || config.model !== providerId + '/Model/A') process.exit(21);",
      "if (process.env.BYOK_BRIDGE_OPENCODE_API_KEY !== 'fake-launch-secret') process.exit(22);",
      "if (process.env.COPILOT_PROVIDER_API_KEY !== 'fake-launch-secret' || process.env.COPILOT_MODEL !== 'Model/A') process.exit(23);",
      "if (process.env.PROVIDER_WIDE !== 'Company.Gateway:Model/A') process.exit(24);",
      "console.log('FAKE_OPENCODE_LOADED=' + providerId);"
    ].join('\n'), 'utf8');
    const providerConfigPath = path.join(tmpDir, 'providers.json');
    const providerConfig = JSON.parse(fs.readFileSync(providerConfigPath, 'utf8'));
    providerConfig.clis.opencode.args = [fakeCliPath];
    fs.writeFileSync(providerConfigPath, `${JSON.stringify(providerConfig, null, 2)}\n`, 'utf8');

    const result = spawnSync(process.execPath, [
      managerPath,
      '--data-dir', tmpDir,
      '--cli', 'opencode',
      '--provider', 'Company.Gateway',
      '--model', 'Model/A',
      '--api-key', 'fake-launch-secret'
    ], {
      encoding: 'utf8',
      env: { ...process.env, COPILOT_PROVIDER_API_KEY: 'parent-copilot', COPILOT_MODEL: 'parent-model' }
    });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /FAKE_OPENCODE_LOADED=byok-bridge-/);
    assert.doesNotMatch(result.stdout + result.stderr, /fake-launch-secret/);
  });

  test('dry-run shows a missing required key without writing opencode.json or state', () => {
    writeManagerConfig(tmpDir);
    const result = spawnSync(process.execPath, [
      managerPath,
      '--data-dir', tmpDir,
      '--cli', 'opencode',
      '--provider', 'Company.Gateway',
      '--model', 'Model/A',
      '--dry-run'
    ], { encoding: 'utf8' });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /OpenCode API key: \[missing\]/);
    assert.doesNotMatch(result.stdout, /BYOK_BRIDGE_OPENCODE_API_KEY=/);
    assert.equal(fs.existsSync(path.join(tmpDir, 'opencode.json')), false);
    assert.equal(fs.existsSync(path.join(tmpDir, 'state.json')), false);
  });

  test('failed executable preflight preserves prior OpenCode config and state', () => {
    writeManagerConfig(tmpDir, 'definitely-missing-opencode-command');
    const configPath = path.join(tmpDir, 'opencode.json');
    const statePath = path.join(tmpDir, 'state.json');
    fs.writeFileSync(configPath, '{"existing":true}\n', 'utf8');
    fs.writeFileSync(statePath, '{"model":"existing"}\n', 'utf8');

    const result = spawnSync(process.execPath, [
      managerPath,
      '--data-dir', tmpDir,
      '--cli', 'opencode',
      '--provider', 'Company.Gateway',
      '--model', 'Model/A',
      '--api-key', 'secret'
    ], { encoding: 'utf8' });

    assert.equal(result.status, 5, result.stderr || result.stdout);
    assert.equal(fs.readFileSync(configPath, 'utf8'), '{"existing":true}\n');
    assert.equal(fs.readFileSync(statePath, 'utf8'), '{"model":"existing"}\n');
  });

  test('refresh updates state without executable preflight or OpenCode config writes', () => {
    writeManagerConfig(tmpDir, 'definitely-missing-opencode-command', false);
    const providerConfigPath = path.join(tmpDir, 'providers.json');
    const providerConfig = JSON.parse(fs.readFileSync(providerConfigPath, 'utf8'));
    providerConfig.clis.opencode.template = { diagnosticOnly: '{model}' };
    fs.writeFileSync(providerConfigPath, `${JSON.stringify(providerConfig, null, 2)}\n`, 'utf8');
    const configPath = path.join(tmpDir, 'opencode.json');
    fs.writeFileSync(configPath, '{"existing":true}\n', 'utf8');
    const result = spawnSync(process.execPath, [
      managerPath,
      '--data-dir', tmpDir,
      '--cli', 'opencode',
      '--provider', 'Company.Gateway',
      '--model', 'Model/A',
      '--refresh'
    ], { encoding: 'utf8' });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.equal(fs.readFileSync(configPath, 'utf8'), '{"existing":true}\n');
    const state = JSON.parse(fs.readFileSync(path.join(tmpDir, 'state.json'), 'utf8'));
    assert.equal(state.model, 'Model/A');
    assert.equal(state.runtimeConfigType, 'opencode-config-v1');
  });

  test('PowerShell manager writes and loads the generated OpenCode config path', { skip: process.platform !== 'win32' }, () => {
    writeManagerConfig(tmpDir, 'pwsh', false);
    const providerConfigPath = path.join(tmpDir, 'providers.json');
    const providerConfig = JSON.parse(fs.readFileSync(providerConfigPath, 'utf8'));
    providerConfig.clis.opencode.args = ['-NoProfile', '-Command', 'exit 0'];
    fs.writeFileSync(providerConfigPath, `${JSON.stringify(providerConfig, null, 2)}\n`, 'utf8');
    const scriptPath = fileURLToPath(new URL('./start-copilot-byok.ps1', import.meta.url));

    const result = spawnSync('pwsh', [
      '-NoProfile',
      '-File', scriptPath,
      '-Cli', 'opencode',
      '-Provider', 'Company.Gateway',
      '-Model', 'Model/A'
    ], {
      encoding: 'utf8',
      env: { ...process.env, BYOK_BRIDGE_DATA_DIR: tmpDir }
    });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    const generated = JSON.parse(fs.readFileSync(path.join(tmpDir, 'opencode.json'), 'utf8'));
    const runtimeProviderId = getOpenCodeProviderId('Company.Gateway');
    assert.equal(generated.model, `${runtimeProviderId}/Model/A`);
    assert.equal(Object.hasOwn(generated.provider[runtimeProviderId].options, 'apiKey'), false);
    const expected = buildOpenCodeConfig(template, {
      providerId: 'Company.Gateway',
      providerName: 'Company Gateway',
      baseUrl: 'https://gateway.example/v1',
      apiKey: '',
      apiKeyRequired: false,
      availableModels: ['Model/A', 'Model/B'],
      chosenModel: 'Model/A',
      chosenModelSource: 'option'
    }).config;
    assert.deepEqual(generated, JSON.parse(JSON.stringify(expected)));
    const state = JSON.parse(fs.readFileSync(path.join(tmpDir, 'state.json'), 'utf8'));
    assert.equal(state.runtimeProviderId, runtimeProviderId);
    assert.equal(state.runtimeConfigType, 'opencode-config-v1');

    providerConfig.clis.opencode.template = { diagnosticOnly: '{model}' };
    fs.writeFileSync(providerConfigPath, `${JSON.stringify(providerConfig, null, 2)}\n`, 'utf8');
    const generatedPath = path.join(tmpDir, 'opencode.json');
    fs.writeFileSync(generatedPath, '{"existing":true}\n', 'utf8');
    const refresh = spawnSync('pwsh', [
      '-NoProfile', '-File', scriptPath,
      '-Cli', 'opencode', '-Provider', 'Company.Gateway', '-Model', 'Model/B', '-Refresh'
    ], { encoding: 'utf8', env: { ...process.env, BYOK_BRIDGE_DATA_DIR: tmpDir } });
    assert.equal(refresh.status, 0, refresh.stderr || refresh.stdout);
    assert.equal(fs.readFileSync(generatedPath, 'utf8'), '{"existing":true}\n');
    const refreshedState = JSON.parse(fs.readFileSync(path.join(tmpDir, 'state.json'), 'utf8'));
    assert.equal(refreshedState.model, 'Model/B');
    assert.equal(refreshedState.modelSource, 'option');
  });

  test('installed OpenCode loads OPENCODE_CONFIG', {
    skip: process.env.BYOK_TEST_REAL_OPENCODE !== '1'
  }, () => {
    const runOpenCode = (args, options = {}) => process.platform === 'win32'
      ? spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `opencode.cmd ${args.join(' ')}`], options)
      : spawnSync('opencode', args, options);
    const version = runOpenCode(['--version'], { encoding: 'utf8' });
    assert.equal(version.status, 0, version.stderr || 'OpenCode is not installed.');

    const liveTemplate = structuredClone(template);
    delete liveTemplate.preserved;
    const result = buildOpenCodeConfig(liveTemplate, {
      providerId: 'live-check',
      providerName: 'Live Check',
      baseUrl: 'http://127.0.0.1:1234/v1',
      apiKey: '',
      apiKeyRequired: false,
      availableModels: ['Model/A', 'model/a'],
      chosenModel: 'Model/A',
      chosenModelSource: 'first-available'
    });
    const configPath = getOpenCodeConfigPath(tmpDir);
    writeOpenCodeConfig(configPath, result.config);

    const debug = runOpenCode(['debug', 'config'], {
      encoding: 'utf8',
      env: { ...process.env, OPENCODE_CONFIG: configPath }
    });
    assert.equal(debug.status, 0, debug.stderr || debug.stdout);
    assert.match(debug.stdout, /byok-bridge-live-check/);
    assert.match(debug.stdout, /Model\/A/);
  });
});
