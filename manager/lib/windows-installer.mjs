/**
 * Windows installer and uninstaller for BYOK Bridge.
 *
 * Ports the PowerShell install.ps1 / uninstall.ps1 logic to Node.js.
 *
 * Installation strategy (mirrors install.ps1):
 *  1. Validate paths and existing manifests.
 *  2. Detect and validate legacy installations.
 *  3. Copy app files to a unique staging directory.
 *  4. Atomic switch: move staging → app; old app → backup.
 *  5. Update user PATH.
 *  6. Clean up backups on success; roll back on any failure.
 *
 * The same manifest schema is used so installs done by either the PS or Node
 * installer can be managed by either uninstaller during the migration period.
 */

import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getUserPath, setUserPath, addToUserPath, removeFromUserPath } from './windows-path.mjs';
import { loadProviderConfig } from './config.mjs';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MANIFEST_NAME = '.byok-bridge-install.json';
const MANAGED_MARKER = '.byok-bridge-managed';
const DATA_MARKER = '.byok-bridge-data';
const LEGACY_MANIFEST_NAME = '.byok-cli-hub-install.json';
const LEGACY_DATA_MARKER = '.byok-cli-hub-data';
const LEGACY_EXT_MARKER = '.byok-cli-hub-managed';

/** Docs included in the installed snapshot (must all exist at source). */
const INSTALLED_DOC_FILES = [
  'quick-start.md', 'installation.md', 'provider-configuration.md',
  'usage.md', 'maintenance.md'
];

/** Files/dirs copied from source root into the staged app directory. */
const APP_SOURCE_DIRS = ['manager', 'config', 'ui', 'extension'];
const APP_SOURCE_FILES = ['README.md', 'LICENSE', 'CHANGELOG.md', 'package.json'];
const WIN_BIN_FILES = ['run.cmd', 'byok.cmd', 'uninstall.cmd'];

// ---------------------------------------------------------------------------
// Path safety utilities
// ---------------------------------------------------------------------------

export class InstallerError extends Error {
  constructor(message) {
    super(message);
    this.name = 'InstallerError';
  }
}

function fail(message) {
  throw new InstallerError(message);
}

function isSameOrChild(parent, child) {
  const p = path.resolve(parent).replace(/[/\\]+$/, '') + path.sep;
  const c = path.resolve(child).replace(/[/\\]+$/, '') + path.sep;
  return c.toLowerCase().startsWith(p.toLowerCase());
}

function assertSafePath(label, p) {
  if (!p || !p.trim()) fail(`${label} cannot be empty.`);
  if (/[\r\n]/.test(p)) fail(`${label} must not contain newlines.`);
  const full = path.resolve(p);
  const root = path.parse(full).root;
  if (!full || full.toLowerCase() === root.toLowerCase().replace(/[/\\]+$/, '')) {
    fail(`${label} resolves to a filesystem root: ${full}`);
  }
  const userProfile = process.env.USERPROFILE || '';
  if (userProfile && full.toLowerCase() === path.resolve(userProfile).toLowerCase()) {
    fail(`${label} must not be the user profile.`);
  }
}

function assertNotOverlapping(leftLabel, left, rightLabel, right) {
  if (isSameOrChild(left, right) || isSameOrChild(right, left)) {
    fail(`${leftLabel} and ${rightLabel} must not overlap: '${left}' / '${right}'`);
  }
}

function resolveManifestPath(label, value) {
  if (!value || typeof value !== 'string' || !path.isAbsolute(value)) {
    fail(`${label} in the install manifest must be an absolute path.`);
  }
  return path.resolve(value);
}

// ---------------------------------------------------------------------------
// Failure injection (for tests)
// ---------------------------------------------------------------------------

function checkFailurePoint(name) {
  const inject = process.env.BYOK_BRIDGE_TEST_FAIL_AT;
  if (inject && inject === name) throw new InstallerError(`Injected installer failure at '${name}'.`);
}

// ---------------------------------------------------------------------------
// Manifest I/O
// ---------------------------------------------------------------------------

function readManifest(manifestPath) {
  if (!fs.existsSync(manifestPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (err) {
    fail(`The install manifest at '${manifestPath}' is not valid JSON: ${err.message}`);
  }
}

function validateManifest(manifest, manifestPath) {
  if (!manifest || manifest.product !== 'byok-bridge' || manifest.schemaVersion !== 1) {
    fail(`The install manifest at '${manifestPath}' is invalid.`);
  }
  if (typeof manifest.appVersion !== 'string' || !/^\d+\.\d+\.\d+$/.test(manifest.appVersion)) {
    fail(`The install manifest at '${manifestPath}' has an invalid appVersion.`);
  }
  if (typeof manifest.withExtension !== 'boolean') {
    fail(`The install manifest at '${manifestPath}' has an invalid withExtension value.`);
  }
  return manifest;
}

function readAndValidateManifest(manifestPath) {
  const m = readManifest(manifestPath);
  if (!m) fail(`No managed BYOK Bridge install was found at '${path.dirname(manifestPath)}'.`);
  return validateManifest(m, manifestPath);
}

// ---------------------------------------------------------------------------
// Provider config validation
// ---------------------------------------------------------------------------

function validateProviderConfigFile(configPath) {
  try {
    // loadProviderConfig throws on bad JSON or schema violations
    loadProviderConfig(path.dirname(configPath), { initialize: false });
  } catch (err) {
    fail(`Invalid provider configuration '${configPath}': ${err.message}`);
  }
}

// ---------------------------------------------------------------------------
// Legacy detection (0.0.x inline)
// ---------------------------------------------------------------------------

function isRecognizableInlineLegacy(dir) {
  return (
    fs.existsSync(path.join(dir, 'manager', 'start-byok-cli-hub.ps1')) &&
    fs.existsSync(path.join(dir, 'manager', 'ByokManager.psm1')) &&
    fs.existsSync(path.join(dir, 'run.cmd')) &&
    fs.existsSync(path.join(dir, 'byok-cli-hub.cmd')) &&
    (fs.existsSync(path.join(dir, 'config', 'providers.json')) ||
     fs.existsSync(path.join(dir, 'providers.json')))
  );
}

function isRecognizableLegacyExtension(extDir) {
  return (
    fs.existsSync(path.join(extDir, 'extension.mjs')) &&
    fs.existsSync(path.join(extDir, 'package.json'))
  );
}

// ---------------------------------------------------------------------------
// Source version
// ---------------------------------------------------------------------------

function readSourceVersion(sourceRoot) {
  const pkg = JSON.parse(fs.readFileSync(path.join(sourceRoot, 'package.json'), 'utf8'));
  const v = pkg.version;
  if (!/^\d+\.\d+\.\d+$/.test(v)) fail('Source package version must use numeric major.minor.patch format.');
  return v;
}

// ---------------------------------------------------------------------------
// File copy utilities
// ---------------------------------------------------------------------------

function copyRecursive(src, dest) {
  if (!fs.existsSync(src)) fail(`Source path does not exist: ${src}`);
  const stat = fs.statSync(src);
  if (stat.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src)) {
      copyRecursive(path.join(src, entry), path.join(dest, entry));
    }
  } else {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
  }
}

function atomicRename(src, dest) {
  fs.renameSync(src, dest);
}

// ---------------------------------------------------------------------------
// Node smoke test
// ---------------------------------------------------------------------------

function runNodeSmokeTest(appDir) {
  const managerPath = path.join(appDir, 'manager', 'manager.mjs');
  if (!fs.existsSync(managerPath)) fail(`Smoke test: manager.mjs not found at ${managerPath}`);
  const result = spawnSync(process.execPath, [managerPath, '--self-check', '--data-dir', appDir], {
    encoding: 'utf8',
    timeout: 15000
  });
  if (result.status !== 0) {
    fail(`Staged Node smoke test failed (exit ${result.status}):\n${result.stderr || result.stdout}`);
  }
}

// ---------------------------------------------------------------------------
// getUserPath / setUserPath wrappers that honour the test env var
// ---------------------------------------------------------------------------

function getTestPathFile() {
  return process.env.BYOK_BRIDGE_TEST_USER_PATH_FILE || null;
}

// ---------------------------------------------------------------------------
// Main install function
// ---------------------------------------------------------------------------

/**
 * Install or upgrade BYOK Bridge on Windows.
 *
 * @param {object} options
 * @param {string} [options.installRoot]     Override install root (env: BYOK_BRIDGE_INSTALL_ROOT)
 * @param {string} [options.dataDir]         Override data dir (env: BYOK_BRIDGE_DATA_DIR)
 * @param {string} [options.copilotHome]     Override Copilot home (env: COPILOT_HOME)
 * @param {boolean} [options.withExtension]  Install the Copilot extension
 * @param {boolean} [options.adoptLegacy]    Allow adopting an unowned legacy extension
 * @param {boolean} [options.skipPathUpdate] Skip PATH modification
 */
export async function installWindows(options = {}) {
  const testPathFile = getTestPathFile();

  // --- Resolve paths -------------------------------------------------------
  const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  const appVersion = readSourceVersion(sourceRoot);

  const installRoot = options.installRoot
    ?? (process.env.BYOK_BRIDGE_INSTALL_ROOT
      ? path.resolve(process.env.BYOK_BRIDGE_INSTALL_ROOT)
      : path.join(process.env.LOCALAPPDATA || '', 'byok-bridge'));
  let targetDir = path.join(installRoot, 'app');
  let dataDir = options.dataDir
    ?? (process.env.BYOK_BRIDGE_DATA_DIR
      ? path.resolve(process.env.BYOK_BRIDGE_DATA_DIR)
      : path.join(process.env.USERPROFILE || '', '.byok-bridge'));
  const copilotHome = options.copilotHome
    ?? (process.env.COPILOT_HOME
      ? path.resolve(process.env.COPILOT_HOME)
      : path.join(process.env.USERPROFILE || '', '.copilot'));
  let extensionDir = path.join(copilotHome, 'extensions', 'byok-bridge-copilot');
  let withExtension = !!options.withExtension;
  const adoptLegacy = !!options.adoptLegacy;
  const skipPathUpdate = options.skipPathUpdate ?? (process.env.BYOK_BRIDGE_SKIP_PATH_UPDATE === '1');

  // --- Path safety ---------------------------------------------------------
  assertSafePath('install root', installRoot);
  assertSafePath('application dir', targetDir);
  assertSafePath('data dir', dataDir);
  assertSafePath('extension dir', extensionDir);
  assertNotOverlapping('application dir', targetDir, 'data dir', dataDir);
  assertNotOverlapping('application dir', targetDir, 'extension dir', extensionDir);
  assertNotOverlapping('data dir', dataDir, 'extension dir', extensionDir);

  // --- Existing manifest check (upgrade scenario) --------------------------
  const existingManifestPath = path.join(targetDir, MANIFEST_NAME);
  let previousManifest = null;
  if (fs.existsSync(existingManifestPath)) {
    previousManifest = validateManifest(readManifest(existingManifestPath), existingManifestPath);
    const prevVer = previousManifest.appVersion.split('.').map(Number);
    const curVer = appVersion.split('.').map(Number);
    for (let i = 0; i < 3; i++) {
      if (prevVer[i] > curVer[i]) fail(`Refusing to downgrade installed version ${previousManifest.appVersion} to ${appVersion}.`);
      if (prevVer[i] < curVer[i]) break;
    }
    const mInstallDir = resolveManifestPath('installDir', previousManifest.installDir);
    if (mInstallDir.toLowerCase() !== path.resolve(targetDir).toLowerCase()) {
      fail('The existing install manifest does not own the target application directory.');
    }
    const mDataDir = resolveManifestPath('dataDir', previousManifest.dataDir);
    const mExtDir = resolveManifestPath('extensionDir', previousManifest.extensionDir);
    if (process.env.BYOK_BRIDGE_DATA_DIR &&
        mDataDir.toLowerCase() !== path.resolve(dataDir).toLowerCase()) {
      fail('A managed update cannot relocate the data directory. Uninstall and reinstall to choose a new path.');
    }
    if (process.env.COPILOT_HOME &&
        mExtDir.toLowerCase() !== path.resolve(extensionDir).toLowerCase()) {
      fail('A managed update cannot relocate the extension directory. Uninstall and reinstall to choose a new COPILOT_HOME.');
    }
    dataDir = mDataDir;
    extensionDir = mExtDir;
    if (previousManifest.withExtension) withExtension = true;
    assertSafePath('data dir', dataDir);
    assertSafePath('extension dir', extensionDir);
    assertNotOverlapping('application dir', targetDir, 'data dir', dataDir);
    assertNotOverlapping('application dir', targetDir, 'extension dir', extensionDir);
    assertNotOverlapping('data dir', dataDir, 'extension dir', extensionDir);
  }
  if (fs.existsSync(targetDir) && !fs.existsSync(existingManifestPath)) {
    fail(`Refusing to replace unowned application directory '${targetDir}'.`);
  }

  // --- Legacy managed install migration (from old appRoot) -----------------
  const legacyAppRoot = path.join(process.env.LOCALAPPDATA || '', 'byok-cli-hub');
  const legacyTargetDir = path.join(legacyAppRoot, 'app');
  const legacyManifestPath = path.join(legacyTargetDir, LEGACY_MANIFEST_NAME);
  let legacyMigration = false;
  let legacyDataDir = null;
  let legacyExtensionDir = null;
  let legacyAppVersion = null;
  let legacyExtensionOwned = false;

  if (!process.env.BYOK_BRIDGE_INSTALL_ROOT && !process.env.BYOK_BRIDGE_DATA_DIR &&
      !fs.existsSync(existingManifestPath) && fs.existsSync(legacyManifestPath)) {
    if (fs.existsSync(targetDir)) fail('New application directory already exists; refusing to merge a legacy installation.');
    if (fs.existsSync(dataDir)) fail('New data directory already exists; refusing to merge a legacy installation.');
    const lm = readManifest(legacyManifestPath);
    if (!lm || lm.product !== 'byok-cli-hub' || lm.schemaVersion !== 1 ||
        !/^\d+\.\d+\.\d+$/.test(String(lm.appVersion)) || typeof lm.withExtension !== 'boolean') {
      fail('The legacy install manifest is invalid. Refusing automatic migration.');
    }
    const mLegacyInstallDir = resolveManifestPath('legacy installDir', lm.installDir);
    if (mLegacyInstallDir.toLowerCase() !== path.resolve(legacyTargetDir).toLowerCase()) {
      fail('The legacy install manifest does not own the expected application directory.');
    }
    legacyDataDir = resolveManifestPath('legacy dataDir', lm.dataDir);
    legacyExtensionDir = resolveManifestPath('legacy extensionDir', lm.extensionDir);
    assertSafePath('legacy application dir', legacyTargetDir);
    assertSafePath('legacy data dir', legacyDataDir);
    assertSafePath('legacy extension dir', legacyExtensionDir);
    assertNotOverlapping('legacy application dir', legacyTargetDir, 'legacy data dir', legacyDataDir);
    assertNotOverlapping('legacy application dir', legacyTargetDir, 'legacy extension dir', legacyExtensionDir);
    if (!fs.existsSync(path.join(legacyDataDir, LEGACY_DATA_MARKER))) {
      fail(`Legacy data directory has no ownership marker; refusing automatic migration: ${legacyDataDir}`);
    }
    if (!fs.existsSync(path.join(legacyTargetDir, 'byok-cli-hub.cmd'))) {
      fail(`Legacy launcher is missing; refusing automatic migration: ${legacyTargetDir}`);
    }
    if (lm.withExtension) {
      if (!fs.existsSync(path.join(legacyExtensionDir, LEGACY_EXT_MARKER))) {
        fail(`Legacy extension has no ownership marker; refusing automatic migration: ${legacyExtensionDir}`);
      }
      withExtension = true;
      legacyExtensionOwned = true;
    }
    legacyAppVersion = String(lm.appVersion);
    legacyMigration = true;
  }

  // --- Inline legacy data (data dir contains old 0.0.1 layout) ------------
  const legacySignalFiles = ['manager', 'run.cmd', 'byok-cli-hub.cmd'];
  const legacySignals = legacySignalFiles.filter(f => fs.existsSync(path.join(dataDir, f)));
  const inlineLegacyMigration = isRecognizableInlineLegacy(dataDir);
  if (legacySignals.length > 0 && !inlineLegacyMigration) {
    fail(`Existing content in '${dataDir}' resembles an incomplete or unknown legacy installation. Refusing automatic migration.`);
  }
  const isLegacyMigration = legacyMigration || inlineLegacyMigration;

  // --- Extension ownership check -------------------------------------------
  const extensionExists = fs.existsSync(extensionDir);
  const extensionManaged = extensionExists && fs.existsSync(path.join(extensionDir, MANAGED_MARKER));
  const legacyExtensionRecognized = extensionExists && !extensionManaged && isRecognizableLegacyExtension(extensionDir);
  if (isLegacyMigration && legacyExtensionRecognized) {
    withExtension = true;
  } else if (withExtension && extensionExists && !extensionManaged) {
    if (!(adoptLegacy && legacyExtensionRecognized)) {
      fail(`Refusing to replace unowned extension '${extensionDir}'. Use --adopt-legacy only for a verified legacy install.`);
    }
  } else if (extensionExists && !extensionManaged) {
    console.warn(`Preserving unowned extension '${extensionDir}'; it will not be recorded in the install manifest.`);
  }

  // --- Provider config validation ------------------------------------------
  const configPath = path.join(dataDir, 'providers.json');
  const legacyConfig = path.join(dataDir, 'config', 'providers.json');
  const examplePath = path.join(dataDir, 'providers.example.json');
  if (legacyMigration) {
    for (const lc of [path.join(legacyDataDir, 'providers.json'), path.join(legacyDataDir, 'config', 'providers.json')]) {
      if (fs.existsSync(lc)) { validateProviderConfigFile(lc); break; }
    }
  }

  // --- Staging directories -------------------------------------------------
  const txId = randomBytes(16).toString('hex');
  const stagingDir = path.join(installRoot, `app.staging.${txId}`);
  const backupDir = path.join(installRoot, `app.backup.${txId}`);
  const extStagingDir = path.join(path.dirname(extensionDir), `byok-bridge-copilot.staging.${txId}`);
  const extBackupDir = path.join(path.dirname(extensionDir), `byok-bridge-copilot.backup.${txId}`);
  const legacyBackupDir = path.join(installRoot, `legacy-0.0.1.backup.${txId}`);
  const legacyDataStagingDir = legacyMigration
    ? path.join(path.dirname(dataDir), `.byok-bridge.data.staging.${txId}`)
    : null;

  // --- Track rollback state ------------------------------------------------
  const originalUserPath = getUserPath(testPathFile);
  const testPathFileExisted = testPathFile ? fs.existsSync(testPathFile) : false;
  const appRootExisted = fs.existsSync(installRoot);
  const dataDirExisted = fs.existsSync(dataDir);
  const exampleExisted = fs.existsSync(examplePath);
  const exampleBytes = exampleExisted ? fs.readFileSync(examplePath) : null;
  let exampleTouched = false;
  let createdCanonicalConfig = false;
  let appBackupCreated = false;
  let appInstalled = false;
  let extensionBackupCreated = false;
  let extensionInstalled = false;
  let pathTouched = false;
  let createdDataMarker = false;
  let legacyDataSwitched = false;

  try {
    // --- Legacy data migration -------------------------------------------
    if (legacyMigration && legacyDataStagingDir) {
      fs.mkdirSync(path.dirname(dataDir), { recursive: true });
      fs.mkdirSync(legacyDataStagingDir, { recursive: true });
      checkFailurePoint('legacy-data-copy');
      for (const entry of fs.readdirSync(legacyDataDir)) {
        copyRecursive(path.join(legacyDataDir, entry), path.join(legacyDataStagingDir, entry));
      }
      atomicRename(legacyDataStagingDir, dataDir);
      legacyDataSwitched = true;
    }

    fs.mkdirSync(installRoot, { recursive: true });
    fs.mkdirSync(dataDir, { recursive: true });

    // --- Config validation & initialization --------------------------------
    if (fs.existsSync(configPath)) {
      validateProviderConfigFile(configPath);
    } else {
      const sourceConfig = fs.existsSync(legacyConfig)
        ? legacyConfig
        : path.join(sourceRoot, 'config', 'providers.example.json');
      validateProviderConfigFile(sourceConfig);
      fs.copyFileSync(sourceConfig, configPath);
      createdCanonicalConfig = true;
      console.log(`Initialized provider configuration: ${configPath}`);
    }

    // --- Build staged app directory ----------------------------------------
    fs.mkdirSync(stagingDir);
    for (const dir of APP_SOURCE_DIRS) {
      copyRecursive(path.join(sourceRoot, dir), path.join(stagingDir, dir));
    }
    for (const file of APP_SOURCE_FILES) {
      const src = path.join(sourceRoot, file);
      if (fs.existsSync(src)) fs.copyFileSync(src, path.join(stagingDir, file));
    }
    const winBinSrc = path.join(sourceRoot, 'bin', 'win');
    for (const file of WIN_BIN_FILES) {
      const src = path.join(winBinSrc, file);
      if (fs.existsSync(src)) fs.copyFileSync(src, path.join(stagingDir, file));
    }
    // doc subdir (only public docs, no planning files)
    const docDest = path.join(stagingDir, 'doc');
    fs.mkdirSync(docDest);
    for (const docFile of INSTALLED_DOC_FILES) {
      const src = path.join(sourceRoot, 'doc', docFile);
      if (fs.existsSync(src)) fs.copyFileSync(src, path.join(docDest, docFile));
    }

    // Manifest
    const manifest = {
      schemaVersion: 1,
      product: 'byok-bridge',
      appVersion,
      installedAt: new Date().toISOString(),
      installDir: path.resolve(targetDir),
      dataDir: path.resolve(dataDir),
      extensionDir: path.resolve(extensionDir),
      withExtension,
      migratedFrom: legacyMigration ? legacyAppVersion : (inlineLegacyMigration ? '0.0.1' : null)
    };
    fs.writeFileSync(path.join(stagingDir, MANIFEST_NAME), JSON.stringify(manifest, null, 2) + '\n', 'utf8');

    // --- Staged smoke test --------------------------------------------------
    runNodeSmokeTest(stagingDir);

    // --- Extension staging --------------------------------------------------
    if (withExtension) {
      fs.mkdirSync(path.dirname(extensionDir), { recursive: true });
      copyRecursive(path.join(sourceRoot, 'extension'), extStagingDir);
      fs.writeFileSync(path.join(extStagingDir, MANAGED_MARKER), '', 'utf8');
    }

    // --- Atomic app switch --------------------------------------------------
    if (fs.existsSync(targetDir)) {
      atomicRename(targetDir, backupDir);
      appBackupCreated = true;
    }
    checkFailurePoint('after-app-backup');
    atomicRename(stagingDir, targetDir);
    appInstalled = true;

    // --- Atomic extension switch --------------------------------------------
    if (withExtension) {
      if (fs.existsSync(extensionDir)) {
        atomicRename(extensionDir, extBackupDir);
        extensionBackupCreated = true;
      }
      checkFailurePoint('after-extension-backup');
      atomicRename(extStagingDir, extensionDir);
      extensionInstalled = true;
    }

    // --- Installed smoke test -----------------------------------------------
    runNodeSmokeTest(targetDir);
    checkFailurePoint('installed-smoke');

    // --- Inline legacy cleanup move ----------------------------------------
    if (inlineLegacyMigration) {
      fs.mkdirSync(legacyBackupDir);
      for (const name of ['manager', 'run.cmd', 'byok-cli-hub.cmd', 'README.md', 'package.json']) {
        const src = path.join(dataDir, name);
        if (fs.existsSync(src)) {
          atomicRename(src, path.join(legacyBackupDir, name));
          checkFailurePoint(`after-legacy-move-${name}`);
        }
      }
    }

    // --- PATH update --------------------------------------------------------
    if (!skipPathUpdate) {
      if (legacyMigration) {
        pathTouched = true;
        removeFromUserPath(legacyTargetDir, testPathFile);
        checkFailurePoint('after-path-remove');
        addToUserPath(targetDir, testPathFile);
      } else if (inlineLegacyMigration) {
        pathTouched = true;
        removeFromUserPath(dataDir, testPathFile);
        checkFailurePoint('after-path-remove');
        addToUserPath(targetDir, testPathFile);
      } else {
        pathTouched = true;
        checkFailurePoint('after-path-remove');
        addToUserPath(targetDir, testPathFile);
      }
    }

    // --- Data ownership marker ----------------------------------------------
    const dataMarkerPath = path.join(dataDir, DATA_MARKER);
    if (!fs.existsSync(dataMarkerPath)) {
      fs.writeFileSync(dataMarkerPath, '', 'utf8');
      createdDataMarker = true;
    }
    if (legacyMigration) {
      const legacyDataMarkerPath = path.join(dataDir, LEGACY_DATA_MARKER);
      if (fs.existsSync(legacyDataMarkerPath)) fs.unlinkSync(legacyDataMarkerPath);
    }

    // --- providers.example.json ---------------------------------------------
    exampleTouched = true;
    fs.copyFileSync(path.join(sourceRoot, 'config', 'providers.example.json'), examplePath);

    checkFailurePoint('before-backup-cleanup');

    // --- Final cleanup ------------------------------------------------------
    for (const dir of [backupDir, extBackupDir, legacyBackupDir]) {
      if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
    }
    if (legacyMigration) {
      if (fs.existsSync(legacyTargetDir)) fs.rmSync(legacyTargetDir, { recursive: true, force: true });
      if (fs.existsSync(legacyAppRoot)) {
        try {
          if (fs.readdirSync(legacyAppRoot).length === 0) fs.rmdirSync(legacyAppRoot);
        } catch {}
      }
      if (legacyExtensionOwned && fs.existsSync(legacyExtensionDir)) {
        fs.rmSync(legacyExtensionDir, { recursive: true, force: true });
      }
      if (legacyDataDir && fs.existsSync(legacyDataDir)) {
        fs.rmSync(legacyDataDir, { recursive: true, force: true });
      }
    }

    console.log('\nInstallation complete.');
    console.log(`Version:     ${appVersion}`);
    console.log(`Application: ${targetDir}`);
    console.log(`Data:        ${dataDir}`);
    if (withExtension) console.log(`Extension:   ${extensionDir}`);
    if (legacyMigration) console.log(`Migrated managed BYOK CLI Hub installation from version ${legacyAppVersion}.`);
    else if (inlineLegacyMigration) console.log('Migrated Windows installation from version 0.0.1.');
    console.log('Open a new terminal, then run: byok');

  } catch (err) {
    // --- Rollback ----------------------------------------------------------
    if (pathTouched) {
      try { setUserPath(originalUserPath, testPathFile); } catch (e) {
        console.warn(`Failed to restore user PATH: ${e.message}`);
      }
    }
    // Restore legacy items moved to legacyBackup
    if (fs.existsSync(legacyBackupDir)) {
      for (const entry of fs.readdirSync(legacyBackupDir)) {
        const restorePath = path.join(dataDir, entry);
        if (!fs.existsSync(restorePath)) {
          try { atomicRename(path.join(legacyBackupDir, entry), restorePath); } catch (e) {
            console.warn(`Failed to restore legacy item '${entry}': ${e.message}`);
          }
        }
      }
    }
    if (extensionInstalled && fs.existsSync(extensionDir)) {
      try { fs.rmSync(extensionDir, { recursive: true, force: true }); } catch {}
    }
    if (extensionBackupCreated && fs.existsSync(extBackupDir)) {
      try { atomicRename(extBackupDir, extensionDir); } catch {}
    }
    if (appInstalled && fs.existsSync(targetDir)) {
      try { fs.rmSync(targetDir, { recursive: true, force: true }); } catch {}
    }
    if (appBackupCreated && fs.existsSync(backupDir)) {
      try { atomicRename(backupDir, targetDir); } catch {}
    }
    if (createdDataMarker) {
      try { fs.unlinkSync(path.join(dataDir, DATA_MARKER)); } catch {}
    }
    if (createdCanonicalConfig) {
      try { fs.unlinkSync(configPath); } catch {}
    }
    if (exampleTouched) {
      if (exampleExisted && exampleBytes) {
        try { fs.writeFileSync(examplePath, exampleBytes); } catch {}
      } else {
        try { fs.unlinkSync(examplePath); } catch {}
      }
    }
    if (legacyDataSwitched && fs.existsSync(dataDir)) {
      try { fs.rmSync(dataDir, { recursive: true, force: true }); } catch {}
    }
    if (!dataDirExisted && fs.existsSync(dataDir)) {
      try {
        if (fs.readdirSync(dataDir).length === 0) fs.rmdirSync(dataDir);
      } catch {}
    }
    if (!appRootExisted && fs.existsSync(installRoot)) {
      try {
        if (fs.readdirSync(installRoot).length === 0) fs.rmdirSync(installRoot);
      } catch {}
    }
    throw err;
  } finally {
    // Always clean up staging dirs
    for (const dir of [stagingDir, extStagingDir, legacyDataStagingDir]) {
      if (dir && fs.existsSync(dir)) {
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
      }
    }
    if (fs.existsSync(legacyBackupDir)) {
      try {
        if (fs.readdirSync(legacyBackupDir).length === 0) fs.rmdirSync(legacyBackupDir);
      } catch {}
    }
  }
}

// ---------------------------------------------------------------------------
// Uninstall
// ---------------------------------------------------------------------------

/**
 * Uninstall BYOK Bridge on Windows.
 *
 * @param {object} options
 * @param {string} [options.installRoot]  Override install root
 * @param {boolean} [options.purgeData]   Also delete the data directory
 * @param {boolean} [options.yes]         Skip confirmation for data purge
 */
export async function uninstallWindows(options = {}) {
  const testPathFile = getTestPathFile();

  const installRoot = options.installRoot
    ?? (process.env.BYOK_BRIDGE_INSTALL_ROOT
      ? path.resolve(process.env.BYOK_BRIDGE_INSTALL_ROOT)
      : path.join(process.env.LOCALAPPDATA || '', 'byok-bridge'));
  const targetDir = path.join(installRoot, 'app');

  assertSafePath('install root', installRoot);
  assertSafePath('application dir', targetDir);

  const manifestPath = path.join(targetDir, MANIFEST_NAME);
  const manifest = readAndValidateManifest(manifestPath);
  const manifestInstallDir = resolveManifestPath('installDir', manifest.installDir);
  if (manifestInstallDir.toLowerCase() !== path.resolve(targetDir).toLowerCase()) {
    fail('The install manifest does not own the requested application path.');
  }
  const dataDir = resolveManifestPath('dataDir', manifest.dataDir);
  const extensionDir = resolveManifestPath('extensionDir', manifest.extensionDir);
  assertSafePath('data dir', dataDir);
  assertSafePath('extension dir', extensionDir);
  assertNotOverlapping('application dir', targetDir, 'data dir', dataDir);
  assertNotOverlapping('application dir', targetDir, 'extension dir', extensionDir);
  assertNotOverlapping('data dir', dataDir, 'extension dir', extensionDir);

  // --- Remove from PATH -----------------------------------------------------
  removeFromUserPath(targetDir, testPathFile);

  // --- Remove extension ------------------------------------------------------
  if (manifest.withExtension && fs.existsSync(extensionDir)) {
    const marker = path.join(extensionDir, MANAGED_MARKER);
    if (fs.existsSync(marker)) {
      fs.rmSync(extensionDir, { recursive: true, force: true });
      console.log(`Removed managed extension: ${extensionDir}`);
    } else {
      console.warn(`Preserved unowned extension: ${extensionDir}`);
    }
  }

  // --- Remove application directory -----------------------------------------
  fs.rmSync(targetDir, { recursive: true, force: true });
  if (fs.existsSync(installRoot)) {
    try {
      if (fs.readdirSync(installRoot).length === 0) fs.rmdirSync(installRoot);
    } catch {}
  }
  console.log(`Removed application: ${targetDir}`);

  // --- Optional data purge --------------------------------------------------
  const purgeData = options.purgeData;
  if (purgeData && fs.existsSync(dataDir)) {
    if (!fs.existsSync(path.join(dataDir, DATA_MARKER))) {
      fail(`Data directory has no BYOK Bridge ownership marker; refusing purge: ${dataDir}`);
    }
    let confirmed = !!options.yes;
    if (!confirmed) {
      const { createInterface } = await import('node:readline');
      const rl = createInterface({ input: process.stdin, output: process.stdout });
      confirmed = await new Promise(resolve => {
        rl.question(`Type 'yes' to delete user data '${dataDir}': `, answer => {
          rl.close();
          resolve(answer === 'yes');
        });
      });
    }
    if (confirmed) {
      const protectedPaths = [
        process.env.USERPROFILE, process.env.WINDIR, process.env.ProgramFiles,
        process.env['ProgramFiles(x86)'], process.env.ProgramData
      ].filter(Boolean).map(p => path.resolve(p).toLowerCase() + path.sep);
      const candidate = path.resolve(dataDir).toLowerCase() + path.sep;
      for (const p of protectedPaths) {
        if (candidate === p || p.startsWith(candidate)) fail(`Refusing to purge protected path: ${dataDir}`);
      }
      fs.rmSync(dataDir, { recursive: true, force: true });
      console.log(`Purged user data: ${dataDir}`);
    } else {
      console.log(`Preserved user data: ${dataDir}`);
    }
  } else {
    console.log(`Preserved user data: ${dataDir}`);
  }
}
