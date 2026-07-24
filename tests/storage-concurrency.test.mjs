import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';

import { readCache, updateCacheForProvider } from '../manager/lib/state.mjs';
import { withFileLock } from '../extension/lib/file-lock.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited ${code}: ${stderr || stdout}`));
    });
  });
}

async function waitForFile(filePath, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (!fs.existsSync(filePath)) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for fixture file '${filePath}'.`);
    await new Promise(resolve => setTimeout(resolve, 25));
  }
}

test('Node and PowerShell preserve concurrent provider cache updates', {
  skip: process.platform !== 'win32'
}, async () => {
  const powershell = 'powershell.exe';
  const available = spawnSync(powershell, ['-NoProfile', '-Command', 'exit 0']);
  if (available.status !== 0) return;

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-cross-runtime-'));
  const stateModuleUrl = pathToFileURL(path.join(repoRoot, 'manager', 'lib', 'state.mjs')).href;
  const psModule = path.join(repoRoot, 'manager', 'ByokManager.psm1').replaceAll("'", "''");
  const psDataDir = dataDir.replaceAll("'", "''");

  try {
    const operations = [];
    for (let index = 0; index < 6; index += 1) {
      const providerId = `node-${index}`;
      const code = `import { updateCacheForProvider } from ${JSON.stringify(stateModuleUrl)}; updateCacheForProvider(${JSON.stringify(providerId)}, 'https://node.example/v1', '/models', ['m-${index}'], process.argv[1]);`;
      operations.push(run(process.execPath, ['--input-type=module', '-e', code, dataDir]));
    }
    for (let index = 0; index < 6; index += 1) {
      const providerId = `powershell-${index}`;
      const script = `Import-Module '${psModule}' -DisableNameChecking; Update-ByokCacheForProvider -ProviderId '${providerId}' -BaseUrl 'https://powershell.example/v1' -ApiPath '/models' -ModelIds @('m-${index}') -DataDir '${psDataDir}' | Out-Null`;
      operations.push(run(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]));
    }
    await Promise.all(operations);

    const cache = readCache(dataDir);
    for (let index = 0; index < 6; index += 1) {
      assert.deepEqual(cache.caches[`node-${index}`].models.filter(model => model.available).map(model => model.id), [`m-${index}`]);
      assert.deepEqual(cache.caches[`powershell-${index}`].models.filter(model => model.available).map(model => model.id), [`m-${index}`]);
    }
  } finally {
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test('Node and PowerShell recover an abandoned cache lock', async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-stale-lock-'));
  const cachePath = path.join(dataDir, 'models-cache.json');
  const lockPath = `${cachePath}.lock`;

  function createAbandonedLock() {
    fs.writeFileSync(lockPath, '2147483647 2000-01-01T00:00:00.000Z\n', { mode: 0o600 });
    const stale = new Date(Date.now() - 60_000);
    fs.utimesSync(lockPath, stale, stale);
  }

  try {
    createAbandonedLock();
    updateCacheForProvider('node-recovered', 'https://node.example/v1', '/models', ['node-model'], dataDir);
    assert.equal(fs.existsSync(lockPath), false);

    if (process.platform === 'win32') {
      const powershell = 'powershell.exe';
      const available = spawnSync(powershell, ['-NoProfile', '-Command', 'exit 0']);
      if (available.status === 0) {
        createAbandonedLock();
        const psModule = path.join(repoRoot, 'manager', 'ByokManager.psm1').replaceAll("'", "''");
        const psDataDir = dataDir.replaceAll("'", "''");
        const script = `Import-Module '${psModule}' -DisableNameChecking; Update-ByokCacheForProvider -ProviderId 'powershell-recovered' -BaseUrl 'https://powershell.example/v1' -ApiPath '/models' -ModelIds @('powershell-model') -DataDir '${psDataDir}' | Out-Null`;
        await run(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
        assert.equal(fs.existsSync(lockPath), false);
      }
    }

    const cache = readCache(dataDir);
    assert.equal(cache.caches['node-recovered'].models[0].id, 'node-model');
    if (process.platform === 'win32') assert.equal(cache.caches['powershell-recovered'].models[0].id, 'powershell-model');
  } finally {
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test('Node and PowerShell honor their deadlines for an active aged exclusive lock', {
  skip: process.platform !== 'win32'
}, async () => {
  const powershell = 'powershell.exe';
  const available = spawnSync(powershell, ['-NoProfile', '-Command', 'exit 0']);
  if (available.status !== 0) return;

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-active-aged-lock-'));
  const cachePath = path.join(dataDir, 'models-cache.json');
  const lockPath = `${cachePath}.lock`;
  const readyPath = path.join(dataDir, 'holder.ready');
  fs.writeFileSync(lockPath, '2147483647 2000-01-01T00:00:00.000Z\n', { mode: 0o600 });
  const stale = new Date(Date.now() - 60_000);
  fs.utimesSync(lockPath, stale, stale);

  const psLockPath = lockPath.replaceAll("'", "''");
  const psReadyPath = readyPath.replaceAll("'", "''");
  const holderScript = [
    `$lockPath = '${psLockPath}'`,
    `$readyPath = '${psReadyPath}'`,
    '$stream = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)',
    'try { [IO.File]::WriteAllText($readyPath, "ready"); Start-Sleep -Seconds 8 } finally { $stream.Dispose() }'
  ].join('; ');
  const holder = spawn(powershell, ['-NoProfile', '-Command', holderScript], {
    stdio: ['ignore', 'pipe', 'pipe']
  });

  try {
    await waitForFile(readyPath);

    const nodeStarted = Date.now();
    assert.throws(
      () => withFileLock(cachePath, () => {}, 500, 0),
      /Timed out waiting for data lock/
    );
    const nodeElapsed = Date.now() - nodeStarted;
    assert.ok(nodeElapsed >= 400 && nodeElapsed < 2000, `Node deadline elapsed ${nodeElapsed}ms`);

    const psModule = path.join(repoRoot, 'manager', 'ByokManager.psm1').replaceAll("'", "''");
    const psDataDir = dataDir.replaceAll("'", "''");
    const contenderScript = `Import-Module '${psModule}' -DisableNameChecking; Update-ByokCacheForProvider -ProviderId 'blocked' -BaseUrl 'https://example.test/v1' -ApiPath '/models' -ModelIds @('m') -DataDir '${psDataDir}' | Out-Null`;
    const psStarted = Date.now();
    await assert.rejects(run(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', contenderScript]), /Timed out waiting for data lock/);
    const psElapsed = Date.now() - psStarted;
    assert.ok(psElapsed >= 2500 && psElapsed < 5000, `PowerShell deadline elapsed ${psElapsed}ms`);
  } finally {
    if (holder.exitCode === null) {
      await new Promise(resolve => {
        holder.once('close', resolve);
        holder.kill();
      });
    }
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});
