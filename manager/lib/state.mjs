import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { withFileLock } from '../../extension/lib/file-lock.mjs';


/**
 * Gets the BYOK Bridge data directory root.
 * Priority: explicit override -> BYOK_BRIDGE_DATA_DIR -> default.
 */
export function getByokDataDir(overrideDir = null) {
  if (overrideDir && typeof overrideDir === 'string' && overrideDir.trim()) {
    return path.resolve(overrideDir.trim());
  }

  let envDir = process.env.BYOK_BRIDGE_DATA_DIR;
  if (envDir && envDir.trim()) {
    envDir = envDir.trim();
    if (process.platform !== 'win32' && (/^[A-Za-z]:\\/.test(envDir) || envDir.includes('\\'))) {
      envDir = null;
    }
    if (envDir) return path.resolve(envDir);
  }

  return path.join(os.homedir(), '.byok-bridge');
}

export function readJson(filePath, defaultValue = null) {
  try {
    return readJsonStrict(filePath, defaultValue);
  } catch {
    return defaultValue;
  }
}

/** Reads JSON while distinguishing a missing file from a damaged file. */
export function readJsonStrict(filePath, defaultValue = null) {
  if (!fs.existsSync(filePath)) return defaultValue;

  let content;
  try {
    content = fs.readFileSync(filePath, 'utf8');
  } catch (error) {
    throw new Error(`Unable to read JSON file '${filePath}': ${error.message}`, { cause: error });
  }

  try {
    return JSON.parse(content);
  } catch (error) {
    throw new Error(`Invalid JSON in '${filePath}': ${error.message}`, { cause: error });
  }
}

function ensurePrivateDirectory(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (process.platform !== 'win32') fs.chmodSync(dir, 0o700);
}

function syncDirectory(dir) {
  let fd;
  try {
    fd = fs.openSync(dir, 'r');
    fs.fsyncSync(fd);
  } catch {
    // Some platforms/filesystems do not support fsync on a directory.
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function writeJsonUnlocked(filePath, data) {
  const dir = path.dirname(filePath);
  ensurePrivateDirectory(dir);

  const tmpPath = path.join(
    dir,
    `.tmp_${path.basename(filePath)}_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2)}`
  );
  const json = `${JSON.stringify(data, null, 2)}\n`;
  let fd;

  try {
    fd = fs.openSync(tmpPath, 'wx', 0o600);
    fs.writeFileSync(fd, json, 'utf8');
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    JSON.parse(fs.readFileSync(tmpPath, 'utf8'));
    if (process.platform !== 'win32') fs.chmodSync(tmpPath, 0o600);
    fs.renameSync(tmpPath, filePath);
    if (process.platform !== 'win32') fs.chmodSync(filePath, 0o600);
    syncDirectory(dir);
  } catch (error) {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch {}
    }
    try { fs.unlinkSync(tmpPath); } catch {}
    throw error;
  }
}

/** Writes JSON using a same-directory temp file, flush, lock, and atomic rename. */
export function writeJsonAtomic(filePath, data) {
  return withFileLock(filePath, () => writeJsonUnlocked(filePath, data));
}

/** Performs a locked read-modify-write operation. */
export function updateJsonAtomic(filePath, defaultValue, updater) {
  return withFileLock(filePath, () => {
    const current = readJsonStrict(filePath, defaultValue);
    const updated = updater(current);
    writeJsonUnlocked(filePath, updated);
    return updated;
  });
}

export function getStatePath(dataDir = getByokDataDir()) {
  return path.join(dataDir, 'state.json');
}

export function readState(dataDir = getByokDataDir()) {
  return readJsonStrict(getStatePath(dataDir), null);
}

export function writeState(state, dataDir = getByokDataDir()) {
  writeJsonAtomic(getStatePath(dataDir), state);
}

export function updateState(updater, dataDir = getByokDataDir()) {
  return updateJsonAtomic(getStatePath(dataDir), null, updater);
}

export function getCachePath(dataDir = getByokDataDir()) {
  return path.join(dataDir, 'models-cache.json');
}

function normalizeModelEntry(model, index) {
  if (typeof model === 'string') {
    return { id: model, order: index + 1, available: true };
  }
  if (!model || typeof model !== 'object' || typeof model.id !== 'string') return null;
  return {
    ...model,
    id: model.id,
    order: typeof model.order === 'number' ? model.order : index + 1,
    available: model.available !== false
  };
}

export function normalizeCache(cache) {
  const source = cache && typeof cache === 'object' ? cache : {};
  const normalized = { version: 1, caches: {} };
  const sourceCaches = source.caches && typeof source.caches === 'object' ? source.caches : {};

  for (const [providerId, entryValue] of Object.entries(sourceCaches)) {
    if (!entryValue || typeof entryValue !== 'object') continue;
    const models = Array.isArray(entryValue.models)
      ? entryValue.models.map(normalizeModelEntry).filter(Boolean)
      : [];
    normalized.caches[providerId] = {
      providerId,
      updatedAt: entryValue.updatedAt || entryValue.lastQueried || null,
      baseUrl: entryValue.baseUrl || '',
      apiPath: entryValue.apiPath || entryValue.modelsApiPath || '/models',
      models
    };
  }

  return normalized;
}

export function readCache(dataDir = getByokDataDir()) {
  return normalizeCache(readJsonStrict(getCachePath(dataDir), { version: 1, caches: {} }));
}

export function writeCache(cache, dataDir = getByokDataDir()) {
  writeJsonAtomic(getCachePath(dataDir), normalizeCache(cache));
}

function normalizeIdentityValue(value) {
  return String(value || '').trim().replace(/\/+$/, '');
}

export function cacheIdentityMatches(entry, baseUrl, apiPath = '/models') {
  if (!entry) return false;
  return normalizeIdentityValue(entry.baseUrl) === normalizeIdentityValue(baseUrl)
    && String(entry.apiPath || '/models') === String(apiPath || '/models');
}

export function updateCacheForProvider(providerId, baseUrl, apiPath, modelIds, dataDir = getByokDataDir()) {
  const cachePath = getCachePath(dataDir);
  let modelsList = [];

  updateJsonAtomic(cachePath, { version: 1, caches: {} }, (rawCache) => {
    const cache = normalizeCache(rawCache);
    const now = new Date().toISOString();
    const previous = cache.caches[providerId];
    const existingModels = cacheIdentityMatches(previous, baseUrl, apiPath) ? previous.models : [];
    const byId = new Map();
    let maxOrder = 0;

    for (const model of existingModels) {
      const order = typeof model.order === 'number' ? model.order : 0;
      maxOrder = Math.max(maxOrder, order);
      byId.set(model.id, {
        ...model,
        order,
        available: false,
        firstSeen: model.firstSeen || now,
        lastSeen: model.lastSeen || now
      });
    }

    const seen = new Set();
    for (const rawId of Array.isArray(modelIds) ? modelIds : []) {
      if (typeof rawId !== 'string') continue;
      const id = rawId.trim();
      if (!id || seen.has(id)) continue;
      seen.add(id);
      if (byId.has(id)) {
        const item = byId.get(id);
        item.available = true;
        item.lastSeen = now;
      } else {
        maxOrder += 1;
        byId.set(id, { id, order: maxOrder, available: true, firstSeen: now, lastSeen: now });
      }
    }

    modelsList = Array.from(byId.values()).sort((a, b) => a.order - b.order);
    modelsList.forEach((model, index) => { model.order = index + 1; });
    cache.caches[providerId] = {
      providerId,
      updatedAt: now,
      baseUrl: normalizeIdentityValue(baseUrl),
      apiPath: apiPath || '/models',
      models: modelsList
    };
    return cache;
  });

  return modelsList;
}

export function getProviderCacheEntry(providerId, dataDir = getByokDataDir()) {
  return readCache(dataDir).caches[providerId] || null;
}

export function getCachedModelIds(providerId, dataDir = getByokDataDir()) {
  const entry = getProviderCacheEntry(providerId, dataDir);
  if (!entry) return [];
  return entry.models.filter(model => model.available !== false).map(model => model.id);
}

export function testModelCacheFresh(
  providerId,
  providerConfig = null,
  dataDir = getByokDataDir(),
  expectedIdentity = null
) {
  const entry = getProviderCacheEntry(providerId, dataDir);
  if (!entry?.updatedAt || entry.models.length === 0) return false;
  if (expectedIdentity && !cacheIdentityMatches(entry, expectedIdentity.baseUrl, expectedIdentity.apiPath)) return false;

  const ttlSeconds = typeof providerConfig?.modelCacheTtlSeconds === 'number'
    ? providerConfig.modelCacheTtlSeconds
    : 3600;
  if (ttlSeconds <= 0) return false;

  const updatedTime = new Date(entry.updatedAt).getTime();
  if (!Number.isFinite(updatedTime)) return false;
  const ageSeconds = (Date.now() - updatedTime) / 1000;
  return ageSeconds >= 0 && ageSeconds < ttlSeconds;
}
