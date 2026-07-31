/**
 * Windows installer and uninstaller tests (Node.js).
 *
 * Mirrors the scenarios in tests/windows-installer.test.ps1 using the
 * manager/lib/windows-installer.mjs module directly (no PowerShell).
 *
 * Tests run only on Windows (skipped on other platforms).
 */

import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { installWindows, uninstallWindows, InstallerError } from '../manager/lib/windows-installer.mjs';
import { getUserPath, addToUserPath, removeFromUserPath } from '../manager/lib/windows-path.mjs';

const REPO_ROOT = path.resolve(fileURLToPath(import.meta.url), '..', '..');
const PKG = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8'));
const EXPECTED_VERSION = PKG.version;

const SKIP_NON_WIN = process.platform !== 'win32' ? { skip: 'Windows-only tests' } : {};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTestEnv(caseRoot) {
  const appRoot = path.join(caseRoot, 'app-root');
  const dataRoot = path.join(caseRoot, 'data');
  const copilotHome = path.join(caseRoot, 'copilot-home');
  const pathFile = path.join(caseRoot, 'user-path.txt');
  fs.mkdirSync(caseRoot, { recursive: true });
  fs.writeFileSync(pathFile, 'C:\\ExistingTool', 'utf8');
  process.env.BYOK_BRIDGE_INSTALL_ROOT = appRoot;
  process.env.BYOK_BRIDGE_DATA_DIR = dataRoot;
  process.env.COPILOT_HOME = copilotHome;
  process.env.BYOK_BRIDGE_TEST_USER_PATH_FILE = pathFile;
  delete process.env.BYOK_BRIDGE_TEST_FAIL_AT;
  return { appRoot, dataRoot, copilotHome, pathFile };
}

function getPathEntries(pathFile) {
  if (!fs.existsSync(pathFile)) return [];
  return fs.readFileSync(pathFile, 'utf8').split(';').filter(e => e.trim());
}

function makeInlineLegacyFixture(caseRoot) {
  const env = makeTestEnv(caseRoot);
  // Simulate old 0.0.1 layout in dataRoot
  fs.mkdirSync(path.join(env.dataRoot, 'manager'), { recursive: true });
  fs.mkdirSync(path.join(env.dataRoot, 'config'), { recursive: true });
  fs.writeFileSync(path.join(env.dataRoot, 'manager', 'start-byok-cli-hub.ps1'), '# legacy', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'manager', 'ByokManager.psm1'), '# legacy', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'run.cmd'), '@echo legacy-run', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'byok-cli-hub.cmd'), '@echo legacy-launcher', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'README.md'), 'legacy-readme', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'package.json'), '{"version":"0.0.1"}', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'unknown-user-file.txt'), 'preserve-me', 'utf8');
  fs.copyFileSync(
    path.join(REPO_ROOT, 'config', 'providers.example.json'),
    path.join(env.dataRoot, 'config', 'providers.json')
  );
  fs.writeFileSync(path.join(env.dataRoot, 'state.json'), '{"providerId":"legacy","model":"legacy-model"}', 'utf8');
  fs.writeFileSync(path.join(env.dataRoot, 'models-cache.json'), '{"version":1,"caches":{}}', 'utf8');
  fs.mkdirSync(path.join(env.copilotHome, 'extensions'), { recursive: true });
  const extSrc = path.join(REPO_ROOT, 'extension');
  const extDest = path.join(env.copilotHome, 'extensions', 'byok-bridge-copilot');
  copyRecursive(extSrc, extDest);
  fs.writeFileSync(env.pathFile, `${env.dataRoot};C:\\ExistingTool`, 'utf8');
  return env;
}

function copyRecursive(src, dest) {
  if (!fs.existsSync(src)) return;
  const stat = fs.statSync(src);
  if (stat.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const e of fs.readdirSync(src)) copyRecursive(path.join(src, e), path.join(dest, e));
  } else {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
  }
}

function cleanEnv() {
  for (const k of ['BYOK_BRIDGE_INSTALL_ROOT', 'BYOK_BRIDGE_DATA_DIR', 'COPILOT_HOME',
      'BYOK_BRIDGE_TEST_USER_PATH_FILE', 'BYOK_BRIDGE_TEST_FAIL_AT', 'BYOK_BRIDGE_SKIP_PATH_UPDATE']) {
    delete process.env[k];
  }
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

describe('Windows installer (Node.js)', SKIP_NON_WIN, () => {
  let testRoot;

  beforeEach(() => {
    testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'byok-win-install-'));
  });

  afterEach(() => {
    cleanEnv();
    try { fs.rmSync(testRoot, { recursive: true, force: true }); } catch {}
  });

  // -------------------------------------------------------------------------
  // PATH utilities
  // -------------------------------------------------------------------------

  test('windows-path: add/remove from user PATH via test file', () => {
    const pathFile = path.join(testRoot, 'test-path.txt');
    fs.writeFileSync(pathFile, 'C:\\Existing', 'utf8');
    process.env.BYOK_BRIDGE_TEST_USER_PATH_FILE = pathFile;

    const newDir = path.join(testRoot, 'new-tool');
    assert.equal(addToUserPath(newDir, pathFile), true, 'should add');
    assert.equal(addToUserPath(newDir, pathFile), false, 'already present');
    assert.ok(fs.readFileSync(pathFile, 'utf8').toLowerCase().includes(newDir.toLowerCase()));

    assert.equal(removeFromUserPath(newDir, pathFile), true, 'should remove');
    assert.equal(removeFromUserPath(newDir, pathFile), false, 'already absent');
    assert.ok(!fs.readFileSync(pathFile, 'utf8').toLowerCase().includes(newDir.toLowerCase()));
  });

  // -------------------------------------------------------------------------
  // Fresh install
  // -------------------------------------------------------------------------

  test('fresh install: creates app, manifest, config, PATH entry', async () => {
    const { appRoot, dataRoot, copilotHome, pathFile } = makeTestEnv(path.join(testRoot, 'fresh'));

    await installWindows({ withExtension: true });

    const appDir = path.join(appRoot, 'app');
    assert.ok(fs.existsSync(appDir), 'application dir must exist');
    const manifestPath = path.join(appDir, '.byok-bridge-install.json');
    assert.ok(fs.existsSync(manifestPath), 'manifest must exist');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    assert.equal(manifest.appVersion, EXPECTED_VERSION);
    assert.equal(manifest.withExtension, true);
    assert.equal(manifest.migratedFrom, null);
    assert.ok(fs.existsSync(path.join(dataRoot, 'providers.json')), 'canonical config must exist');
    const extDir = path.join(copilotHome, 'extensions', 'byok-bridge-copilot');
    assert.ok(fs.existsSync(path.join(extDir, '.byok-bridge-managed')), 'extension marker must exist');
    assert.ok(getPathEntries(pathFile).some(e => e.toLowerCase() === appDir.toLowerCase()),
      'app dir must be in PATH');

    const launcher = spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/c', path.join(appDir, 'byok.cmd'), '--help'], {
      encoding: 'utf8',
      timeout: 15000
    });
    assert.equal(launcher.status, 0, launcher.stderr || launcher.stdout);
    assert.match(launcher.stdout, /BYOK Bridge Manager/);
    assert.doesNotMatch(`${launcher.stdout}\n${launcher.stderr}`, /not recognized as an internal or external command/i);

    // Managed upgrade must succeed and preserve extension choice
    await installWindows();
    const manifest2 = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    assert.equal(manifest2.withExtension, true, 'extension choice preserved');
  });

  // -------------------------------------------------------------------------
  // Managed upgrade rejects relocation
  // -------------------------------------------------------------------------

  test('managed upgrade: rejects extension directory relocation', async () => {
    const { appRoot, dataRoot, copilotHome } = makeTestEnv(path.join(testRoot, 'reloc'));
    await installWindows({ withExtension: true });
    const origCopilotHome = process.env.COPILOT_HOME;
    process.env.COPILOT_HOME = path.join(path.dirname(copilotHome), 'relocated-copilot-home');
    await assert.rejects(installWindows, /relocate.*extension|extension.*relocate/i);
    process.env.COPILOT_HOME = origCopilotHome;
  });

  // -------------------------------------------------------------------------
  // Downgrade rejection
  // -------------------------------------------------------------------------

  test('managed upgrade: rejects downgrade', async () => {
    const { appRoot } = makeTestEnv(path.join(testRoot, 'downgrade'));
    await installWindows();
    const appDir = path.join(appRoot, 'app');
    const manifestPath = path.join(appDir, '.byok-bridge-install.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    const parts = manifest.appVersion.split('.').map(Number);
    manifest.appVersion = `${parts[0] + 1}.0.0`;
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
    await assert.rejects(installWindows, /downgrade/i);
  });

  // -------------------------------------------------------------------------
  // Malformed canonical config
  // -------------------------------------------------------------------------

  test('malformed canonical config: rejected and preserved', async () => {
    const { dataRoot } = makeTestEnv(path.join(testRoot, 'malformed'));
    fs.mkdirSync(dataRoot, { recursive: true });
    const configPath = path.join(dataRoot, 'providers.json');
    fs.writeFileSync(configPath, '{"version":1,}', 'utf8');
    const originalBytes = fs.readFileSync(configPath);
    await assert.rejects(installWindows, err => {
      assert.ok(err.message.includes(configPath), `error should mention config path, got: ${err.message}`);
      return true;
    });
    assert.deepEqual(fs.readFileSync(configPath), originalBytes, 'malformed config must not be modified');
  });

  // -------------------------------------------------------------------------
  // Failure injection & rollback
  // -------------------------------------------------------------------------

  const ROLLBACK_FAILURE_POINTS = [
    'after-app-backup', 'after-extension-backup', 'installed-smoke',
    'after-path-remove', 'before-backup-cleanup'
  ];

  for (const failurePoint of ROLLBACK_FAILURE_POINTS) {
    test(`rollback at '${failurePoint}': app and PATH restored`, async () => {
      const { appRoot, copilotHome, pathFile } = makeTestEnv(path.join(testRoot, `fp-${failurePoint}`));

      // Fresh install to get a rollback target
      await installWindows({ withExtension: true });
      const appDir = path.join(appRoot, 'app');
      const extDir = path.join(copilotHome, 'extensions', 'byok-bridge-copilot');
      fs.writeFileSync(path.join(appDir, 'rollback-sentinel.txt'), failurePoint, 'utf8');
      fs.writeFileSync(path.join(extDir, 'rollback-sentinel.txt'), failurePoint, 'utf8');
      const pathBefore = fs.readFileSync(pathFile, 'utf8');

      process.env.BYOK_BRIDGE_TEST_FAIL_AT = failurePoint;
      await assert.rejects(installWindows, InstallerError, `failure point '${failurePoint}' must reject`);
      delete process.env.BYOK_BRIDGE_TEST_FAIL_AT;

      assert.equal(
        fs.readFileSync(path.join(appDir, 'rollback-sentinel.txt'), 'utf8').trim(),
        failurePoint,
        `app rollback failed at '${failurePoint}'`
      );
      assert.equal(
        fs.readFileSync(path.join(extDir, 'rollback-sentinel.txt'), 'utf8').trim(),
        failurePoint,
        `extension rollback failed at '${failurePoint}'`
      );
      assert.equal(
        fs.readFileSync(pathFile, 'utf8'),
        pathBefore,
        `PATH rollback failed at '${failurePoint}'`
      );
    });
  }

  test('fresh install rollback: cleans up fully', async () => {
    const { appRoot, dataRoot } = makeTestEnv(path.join(testRoot, 'fresh-rollback'));
    process.env.BYOK_BRIDGE_TEST_FAIL_AT = 'after-app-backup';
    await assert.rejects(installWindows, InstallerError);
    delete process.env.BYOK_BRIDGE_TEST_FAIL_AT;
    assert.ok(!fs.existsSync(dataRoot), 'rollback must not leave data dir');
    assert.ok(!fs.existsSync(path.join(appRoot, 'app')), 'rollback must not leave app snapshot');
  });

  // -------------------------------------------------------------------------
  // Uninstall
  // -------------------------------------------------------------------------

  test('uninstall: removes app and extension, preserves data', async () => {
    const { appRoot, dataRoot, copilotHome, pathFile } = makeTestEnv(path.join(testRoot, 'uninstall'));
    await installWindows({ withExtension: true });
    const appDir = path.join(appRoot, 'app');
    const extDir = path.join(copilotHome, 'extensions', 'byok-bridge-copilot');

    await uninstallWindows();
    assert.ok(!fs.existsSync(appDir), 'application must be removed');
    assert.ok(!fs.existsSync(extDir), 'managed extension must be removed');
    assert.ok(fs.existsSync(path.join(dataRoot, 'providers.json')), 'data must be preserved');
    assert.ok(!getPathEntries(pathFile).some(e => e.toLowerCase() === appDir.toLowerCase()),
      'PATH entry must be removed');
  });

  test('uninstall --purge-data --yes: removes data directory', async () => {
    const { dataRoot } = makeTestEnv(path.join(testRoot, 'purge'));
    await installWindows();
    await uninstallWindows({ purgeData: true, yes: true });
    assert.ok(!fs.existsSync(dataRoot), 'data must be removed');
  });

  // -------------------------------------------------------------------------
  // Inline legacy (0.0.1) migration
  // -------------------------------------------------------------------------

  test('inline legacy migration: migrates 0.0.1 layout, rollback restores it', async () => {
    const env = makeInlineLegacyFixture(path.join(testRoot, 'legacy'));
    const pathBefore = fs.readFileSync(env.pathFile, 'utf8');

    process.env.BYOK_BRIDGE_TEST_FAIL_AT = 'after-path-remove';
    await assert.rejects(installWindows, InstallerError);
    delete process.env.BYOK_BRIDGE_TEST_FAIL_AT;

    // manager dir must be restored
    assert.ok(fs.existsSync(path.join(env.dataRoot, 'manager')), 'legacy manager must be restored');
    assert.ok(fs.existsSync(path.join(env.dataRoot, 'byok-cli-hub.cmd')), 'legacy launcher must be restored');
    assert.ok(!fs.existsSync(path.join(env.dataRoot, 'providers.json')), 'rollback must not leave canonical config');
    assert.ok(!fs.existsSync(path.join(env.appRoot, 'app')), 'rollback must not leave new app snapshot');
    assert.equal(fs.readFileSync(env.pathFile, 'utf8'), pathBefore, 'PATH must be restored');
  });

  // -------------------------------------------------------------------------
  // Unowned directory rejection
  // -------------------------------------------------------------------------

  test('install: rejects unowned application directory', async () => {
    const { appRoot } = makeTestEnv(path.join(testRoot, 'unowned'));
    // Create app dir without a manifest
    fs.mkdirSync(path.join(appRoot, 'app'), { recursive: true });
    await assert.rejects(installWindows, /unowned/i);
  });
});
