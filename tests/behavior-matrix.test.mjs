/**
 * Behavior Matrix Tests — Phase 0 baseline
 *
 * Verifies Node manager (manager.mjs) behavior across the scenarios documented
 * in doc/behavior-matrix.md. All tests run non-interactively (no TTY) with
 * temporary data directories; real network I/O is replaced by mock HTTP servers.
 *
 * Row numbers in test descriptions match the matrix table in behavior-matrix.md.
 */

import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { spawnSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeJsonAtomic, updateCacheForProvider } from '../manager/lib/state.mjs';

const __filename = fileURLToPath(import.meta.url);
const MANAGER = fileURLToPath(new URL('../manager/manager.mjs', import.meta.url));
const NODE = process.execPath;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeConfig({ command = NODE, commandArgs = ['--version'], models = ['model-a', 'model-b'], extraCliEnv = {}, adapter = undefined, baseUrl = null, apiKeyRequired = true } = {}) {
  const cliDef = {
    name: 'Test CLI',
    command,
    args: commandArgs,
    modelEnvName: 'TEST_MODEL',
    environment: {
      TEST_URL: '{url}',
      TEST_KEY: '{api_key}',
      TEST_MODEL: '{model}',
      ...extraCliEnv
    },
    ...(adapter ? { adapter } : {})
  };

  const providerDef = {
    name: 'Test Provider',
    enabled: true,
    ...(baseUrl ? { baseUrl } : { baseUrl: 'http://127.0.0.1:65535/v1' }),
    apiKeyEnv: ['TEST_KEY'],
    apiKeyRequired,
    models
  };

  return {
    version: 1,
    clis: { test: cliDef },
    providers: { testprov: providerDef }
  };
}

function makeConfigNoModels({ serverPort }) {
  return {
    version: 1,
    clis: {
      test: {
        name: 'Test CLI',
        command: NODE,
        args: ['--version'],
        modelEnvName: 'TEST_MODEL',
        environment: { TEST_URL: '{url}', TEST_KEY: '{api_key}', TEST_MODEL: '{model}' }
      }
    },
    providers: {
      testprov: {
        name: 'Test Provider',
        enabled: true,
        baseUrl: `http://127.0.0.1:${serverPort}/v1`,
        apiKeyEnv: ['TEST_KEY'],
        modelsApi: { path: '/models', itemsPath: 'data', idPath: 'id' }
      }
    }
  };
}

function runManager(args, { tmpDir, env = {}, withFd3 = true } = {}) {
  const fdArgs = withFd3 ? ['--internal-shell-plan-fd', '3'] : [];
  return spawnSync(NODE, [MANAGER, ...fdArgs, '--data-dir', tmpDir, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
    env: {
      ...process.env,
      // Suppress TTY detection so we stay non-interactive
      TERM: 'dumb',
      NO_COLOR: '1',
      ...env
    },
    timeout: 15000
  });
}

/**
 * Async version of runManager — required when a mock HTTP server is running in
 * the same process, because spawnSync blocks the event loop and prevents the
 * server from accepting new connections.
 */
function runManagerAsync(args, { tmpDir, env = {}, withFd3 = true } = {}) {
  const fdArgs = withFd3 ? ['--internal-shell-plan-fd', '3'] : [];
  return new Promise((resolve) => {
    const child = spawn(NODE, [MANAGER, ...fdArgs, '--data-dir', tmpDir, ...args], {
      stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
      env: { ...process.env, TERM: 'dumb', NO_COLOR: '1', ...env }
    });
    let stdout = '', stderr = '', fd3 = '';
    child.stdout.on('data', d => { stdout += d.toString(); });
    child.stderr.on('data', d => { stderr += d.toString(); });
    if (child.stdio[3]) child.stdio[3].on('data', d => { fd3 += d.toString(); });
    child.on('close', (code) => resolve({ status: code, stdout, stderr, output: [null, stdout, stderr, fd3] }));
  });
}

function decodePlan(raw) {
  if (!raw) return null;
  const lines = raw.trim().split('\n');
  const plan = {};
  const envVars = {};
  const args = [];
  for (const line of lines) {
    const parts = line.split('\t');
    const tag = parts[0];
    if (tag === 'ACTION') plan.action = parts[1];
    else if (tag === 'COMMAND') plan.command = Buffer.from(parts[1], 'hex').toString('utf8');
    else if (tag === 'ENV') envVars[parts[1]] = Buffer.from(parts[2], 'hex').toString('utf8');
    else if (tag === 'ARG') args.push(Buffer.from(parts[1], 'hex').toString('utf8'));
  }
  plan.environment = envVars;
  plan.args = args;
  return plan;
}

function startMockModelServer({ models = ['mock-model-1', 'mock-model-2'], statusCode = 200, body = null } = {}) {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      const responseBody = body ?? JSON.stringify({ data: models.map(id => ({ id })) });
      res.writeHead(statusCode, { 'Content-Type': 'application/json' });
      res.end(responseBody);
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Behavior Matrix — Node manager (Phase 0 baseline)', () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-matrix-'));
  });

  afterEach(() => {
    if (tmpDir && fs.existsSync(tmpDir)) {
      try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
    }
  });

  // -------------------------------------------------------------------------
  // Row 1 — Non-interactive launch, static models
  // -------------------------------------------------------------------------
  test('Row 1: non-interactive launch with static models emits action=launch plan', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--cli', 'test', '--provider', 'testprov', '--model', 'model-a', '--api-key', 'sk-secret'], { tmpDir });

    assert.equal(result.status, 0, result.stderr);
    const plan = decodePlan(result.output[3]);
    assert.equal(plan.action, 'launch');
    assert.equal(plan.environment.TEST_KEY, 'sk-secret');
    assert.equal(plan.environment.TEST_MODEL, 'model-a');
    assert.ok(plan.command, 'command must be set');
    // API key must not appear in stdout or stderr
    assert.doesNotMatch(result.stdout + result.stderr, /sk-secret/);
  });

  // -------------------------------------------------------------------------
  // Row 2 — --dry-run → action=none, no launch
  // -------------------------------------------------------------------------
  test('Row 2: --dry-run emits action=none and does not launch CLI', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--cli', 'test', '--provider', 'testprov', '--model', 'model-a', '--dry-run'], {
      tmpDir,
      env: { TEST_KEY: 'env-key-secret' }
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(decodePlan(result.output[3])?.action, 'none');
    assert.match(result.stdout, /DRY-RUN|dry run/i);
    assert.doesNotMatch(result.stdout + result.stderr, /env-key-secret/);
  });

  // -------------------------------------------------------------------------
  // Row 3 — --refresh forces model cache update via network
  // -------------------------------------------------------------------------
  test('Row 3: --refresh fetches models from network and updates cache', async () => {
    const server = await startMockModelServer({ models: ['refreshed-model'] });
    const port = server.address().port;
    try {
      writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfigNoModels({ serverPort: port }));
      const result = await runManagerAsync(
        ['--cli', 'test', '--provider', 'testprov', '--model', 'refreshed-model', '--refresh', '--api-key', 'sk-refresh'],
        { tmpDir }
      );
      assert.equal(result.status, 0, result.stderr);
      // --refresh → action=none (cache-only run, no launch)
      assert.equal(decodePlan(result.output[3])?.action, 'none');
      assert.match(result.stdout, /refreshed-model/);
      assert.doesNotMatch(result.stdout + result.stderr, /sk-refresh/);
    } finally {
      await new Promise(resolve => server.close(resolve));
    }
  });

  // -------------------------------------------------------------------------
  // Row 4 — --dry-run + --refresh is a UsageError
  // -------------------------------------------------------------------------
  test('Row 4: --dry-run combined with --refresh is rejected with exit code 2', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--dry-run', '--refresh'], { tmpDir });
    assert.equal(result.status, 2, 'expected exit code 2 (UsageError)');
    assert.match(result.stderr, /--refresh.*--dry-run|--dry-run.*--refresh/i);
  });

  // -------------------------------------------------------------------------
  // Row 5 — Unknown provider
  // -------------------------------------------------------------------------
  test('Row 5: unknown --provider exits non-zero', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--cli', 'test', '--provider', 'does-not-exist', '--api-key', 'k'], { tmpDir });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /does-not-exist|Unknown provider/i);
  });

  // -------------------------------------------------------------------------
  // Row 6 — Unknown CLI
  // -------------------------------------------------------------------------
  test('Row 6: unknown --cli exits non-zero', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--cli', 'does-not-exist', '--provider', 'testprov', '--api-key', 'k'], { tmpDir });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /does-not-exist|Unknown CLI/i);
  });

  // -------------------------------------------------------------------------
  // Row 7 — CLI executable not in PATH
  // -------------------------------------------------------------------------
  test('Row 7: CLI command not in PATH exits with error', () => {
    const cfg = makeConfig({ command: 'byok-nonexistent-executable-xyz' });
    // Remove static models so it won't go to network; provide explicit model
    cfg.providers.testprov.models = ['model-a'];
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), cfg);
    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--model', 'model-a', '--api-key', 'k'],
      { tmpDir, withFd3: false }
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not found|PATH/i);
  });

  // -------------------------------------------------------------------------
  // Row 8 — Passthrough args appear in shell plan
  // -------------------------------------------------------------------------
  test('Row 8: passthrough args after -- are included in shell plan ARGs', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--model', 'model-a', '--api-key', 'sk-pass', '--', '--verbose', '--extra=flag'],
      { tmpDir }
    );
    assert.equal(result.status, 0, result.stderr);
    const plan = decodePlan(result.output[3]);
    assert.equal(plan.action, 'launch');
    assert.ok(plan.args.includes('--verbose'), 'passthrough --verbose must be in plan args');
    assert.ok(plan.args.includes('--extra=flag'), 'passthrough --extra=flag must be in plan args');
  });

  // -------------------------------------------------------------------------
  // Row 9 — --help
  // -------------------------------------------------------------------------
  test('Row 9: --help exits 0 and prints usage', () => {
    // --help cannot be combined with any other option (including --data-dir);
    // invoke without the data-dir override.
    const result = spawnSync(NODE, [MANAGER, '--help'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, TERM: 'dumb', NO_COLOR: '1' },
      timeout: 5000
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Usage|--cli|--provider/i);
  });

  // -------------------------------------------------------------------------
  // Row 10 — --self-check
  // -------------------------------------------------------------------------
  test('Row 10: --self-check exits 0 and emits action=none', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--self-check'], { tmpDir });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(decodePlan(result.output[3])?.action, 'none');
    assert.match(result.stdout, /SELF-CHECK|preflight/i);
  });

  // -------------------------------------------------------------------------
  // Row 11 — Stale cache triggers network refresh
  // -------------------------------------------------------------------------
  test('Row 11: stale cache causes model re-fetch from network', async () => {
    const server = await startMockModelServer({ models: ['fresh-model'] });
    const port = server.address().port;
    try {
      const cfg = makeConfigNoModels({ serverPort: port });
      // Set zero TTL so cache is always stale
      cfg.providers.testprov.modelCacheTtlSeconds = 0;
      writeJsonAtomic(path.join(tmpDir, 'providers.json'), cfg);
      // Write a stale cache entry
      updateCacheForProvider('testprov', `http://127.0.0.1:${port}/v1`, '/models', ['stale-model'], tmpDir);

      const result = await runManagerAsync(
        ['--cli', 'test', '--provider', 'testprov', '--model', 'fresh-model', '--api-key', 'sk-stale'],
        { tmpDir }
      );
      assert.equal(result.status, 0, result.stderr);
      const plan = decodePlan(result.output[3]);
      assert.equal(plan.action, 'launch');
      assert.equal(plan.environment.TEST_MODEL, 'fresh-model');
      assert.doesNotMatch(result.stdout + result.stderr, /sk-stale/);
    } finally {
      await new Promise(resolve => server.close(resolve));
    }
  });

  // -------------------------------------------------------------------------
  // Row 12 — Fresh cache skips network
  // -------------------------------------------------------------------------
  test('Row 12: fresh cache is reused without network request', async () => {
    // Start a server that always fails — manager must NOT hit it
    const server = await startMockModelServer({ statusCode: 500, body: 'server error' });
    const port = server.address().port;
    try {
      const cfg = makeConfigNoModels({ serverPort: port });
      cfg.providers.testprov.modelCacheTtlSeconds = 3600;
      writeJsonAtomic(path.join(tmpDir, 'providers.json'), cfg);
      // Pre-populate a fresh cache
      updateCacheForProvider('testprov', `http://127.0.0.1:${port}/v1`, '/models', ['cached-model'], tmpDir);

      const result = runManager(
        ['--cli', 'test', '--provider', 'testprov', '--model', 'cached-model', '--api-key', 'sk-cache'],
        { tmpDir }
      );
      assert.equal(result.status, 0, result.stderr);
      const plan = decodePlan(result.output[3]);
      assert.equal(plan.action, 'launch');
      assert.match(result.stdout, /cached models|Using cached/i);
    } finally {
      await new Promise(resolve => server.close(resolve));
    }
  });

  // -------------------------------------------------------------------------
  // Row 13 — Network failure with stale cache falls back
  // -------------------------------------------------------------------------
  test('Row 13: network failure with stale cache uses stale cache and launches', async () => {
    // Port 1 is effectively unreachable (connection refused)
    const cfg = {
      version: 1,
      clis: {
        test: {
          name: 'Test CLI', command: NODE, args: ['--version'],
          modelEnvName: 'TEST_MODEL',
          environment: { TEST_URL: '{url}', TEST_KEY: '{api_key}', TEST_MODEL: '{model}' }
        }
      },
      providers: {
        testprov: {
          name: 'Test Provider', enabled: true,
          baseUrl: 'http://127.0.0.1:1/v1',
          apiKeyEnv: ['TEST_KEY'],
          modelCacheTtlSeconds: 0,
          modelsApi: { path: '/models', itemsPath: 'data', idPath: 'id' }
        }
      }
    };
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), cfg);
    updateCacheForProvider('testprov', 'http://127.0.0.1:1/v1', '/models', ['fallback-model'], tmpDir);

    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--model', 'fallback-model', '--api-key', 'sk-fallback'],
      { tmpDir }
    );
    assert.equal(result.status, 0, result.stderr);
    const plan = decodePlan(result.output[3]);
    assert.equal(plan.action, 'launch');
    assert.match(result.stdout + result.stderr, /stale|fallback|Warning/i);
    assert.doesNotMatch(result.stdout + result.stderr, /sk-fallback/);
  });

  // -------------------------------------------------------------------------
  // Row 14 — Network failure with no cache exits non-zero
  // -------------------------------------------------------------------------
  test('Row 14: network failure with no cache exits non-zero', () => {
    const cfg = {
      version: 1,
      clis: {
        test: {
          name: 'Test CLI', command: NODE, args: ['--version'],
          modelEnvName: 'TEST_MODEL',
          environment: { TEST_URL: '{url}', TEST_KEY: '{api_key}', TEST_MODEL: '{model}' }
        }
      },
      providers: {
        testprov: {
          name: 'Test Provider', enabled: true,
          baseUrl: 'http://127.0.0.1:1/v1',
          apiKeyEnv: ['TEST_KEY'],
          modelsApi: { path: '/models', itemsPath: 'data', idPath: 'id' }
        }
      }
    };
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), cfg);
    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--api-key', 'sk-nofallback'],
      { tmpDir }
    );
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout + result.stderr, /sk-nofallback/);
  });

  // -------------------------------------------------------------------------
  // Row 16 — API key from environment variable
  // -------------------------------------------------------------------------
  test('Row 16: API key is read from environment variable, not leaked to output', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--model', 'model-a'],
      { tmpDir, env: { TEST_KEY: 'env-secret-value' } }
    );
    assert.equal(result.status, 0, result.stderr);
    const plan = decodePlan(result.output[3]);
    assert.equal(plan.action, 'launch');
    assert.equal(plan.environment.TEST_KEY, 'env-secret-value');
    assert.doesNotMatch(result.stdout + result.stderr, /env-secret-value/);
  });

  // -------------------------------------------------------------------------
  // Row 17 — API key absent, non-interactive → NonInteractiveInputError
  // -------------------------------------------------------------------------
  test('Row 17: missing API key in non-interactive mode exits non-zero', () => {
    const cfg = makeConfig({ apiKeyRequired: true });
    // Remove static default env key
    delete cfg.providers.testprov.apiKeyEnv;
    cfg.providers.testprov.apiKeyEnv = ['BYOK_NO_SUCH_ENV_KEY_12345'];
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), cfg);
    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--model', 'model-a'],
      { tmpDir, env: { BYOK_NO_SUCH_ENV_KEY_12345: '' } }
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /non-interactive|Interactive|api.key|key/i);
  });

  // -------------------------------------------------------------------------
  // Row 18 — --dry-run + --provider + is rejected
  // -------------------------------------------------------------------------
  test('Row 18: --dry-run combined with --provider + is rejected with exit code 2', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(['--dry-run', '--provider', '+'], { tmpDir });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /--dry-run|provider.*\+/i);
  });

  // -------------------------------------------------------------------------
  // Row 19 — --internal-shell-plan-fd with non-3 value
  // -------------------------------------------------------------------------
  test('Row 19: --internal-shell-plan-fd with value other than 3 is rejected', () => {
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = spawnSync(NODE, [MANAGER, '--internal-shell-plan-fd', '1', '--data-dir', tmpDir], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 5000
    });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /internal.shell.plan.fd|descriptor 3/i);
  });

  // -------------------------------------------------------------------------
  // API-key redaction — cross-cutting safety check
  // -------------------------------------------------------------------------
  test('API key is never present in stdout, stderr, or shell plan hex for any row', () => {
    const SECRET = 'SUPER_SECRET_KEY_MUST_NOT_APPEAR_7x9z';
    writeJsonAtomic(path.join(tmpDir, 'providers.json'), makeConfig());
    const result = runManager(
      ['--cli', 'test', '--provider', 'testprov', '--model', 'model-a', '--api-key', SECRET],
      { tmpDir }
    );
    assert.equal(result.status, 0, result.stderr);
    // Secret must not appear in any printable output
    assert.doesNotMatch(result.stdout, new RegExp(SECRET));
    assert.doesNotMatch(result.stderr, new RegExp(SECRET));
    // The raw hex plan content must not contain the secret as a literal string either
    const rawPlan = result.output[3] || '';
    assert.doesNotMatch(rawPlan, new RegExp(SECRET));
    // But the decoded plan must contain the actual key
    const plan = decodePlan(rawPlan);
    assert.equal(plan?.environment?.TEST_KEY, SECRET, 'decoded plan must contain the key');
  });
});
