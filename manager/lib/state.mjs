import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

/**
 * Gets the BYOK CLI Hub data directory root.
 * Priority: BYOK_CLI_HUB_DATA_DIR -> BYOK_MODEL_V3_DATA_DIR -> ~/.byok-cli-hub
 */
export function getByokDataDir(overrideDir = null) {
  if (overrideDir && typeof overrideDir === 'string' && overrideDir.trim()) {
    return path.resolve(overrideDir.trim());
  }
  let envDir = process.env.BYOK_CLI_HUB_DATA_DIR || process.env.BYOK_MODEL_V3_DATA_DIR;
  if (envDir && envDir.trim()) {
    envDir = envDir.trim();
    // On non-Windows platforms (e.g. WSL/Linux), ignore Windows-style paths (starts with drive letter or has backslashes)
    // inherited from Windows host environment variables.
    if (process.platform !== 'win32' && (/^[A-Za-z]:\\/.test(envDir) || envDir.includes('\\'))) {
      envDir = null;
    }
    if (envDir) {
      return path.resolve(envDir);
    }
  }
  return path.join(os.homedir(), '.byok-cli-hub');
}

/**
 * Safely reads a JSON file, returning defaultValue on failure or missing file.
 */
export function readJson(filePath, defaultValue = null) {
  try {
    if (!fs.existsSync(filePath)) {
      return defaultValue;
    }
    const content = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(content);
  } catch {
    return defaultValue;
  }
}

/**
 * Writes data as JSON atomically to filePath using a temporary file in the same directory.
 */
export function writeJsonAtomic(filePath, data) {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  const tmpPath = path.join(dir, `.tmp_${path.basename(filePath)}_${Date.now()}_${Math.random().toString(36).slice(2)}`);
  const jsonStr = JSON.stringify(data, null, 2) + '\n';

  try {
    fs.writeFileSync(tmpPath, jsonStr, { encoding: 'utf8', mode: 0o600 });
    fs.renameSync(tmpPath, filePath);
  } catch (err) {
    if (fs.existsSync(tmpPath)) {
      try { fs.unlinkSync(tmpPath); } catch {}
    }
    throw err;
  }
}

export function getStatePath(dataDir = getByokDataDir()) {
  return path.join(dataDir, 'state.json');
}

export function readState(dataDir = getByokDataDir()) {
  return readJson(getStatePath(dataDir), null);
}

export function writeState(state, dataDir = getByokDataDir()) {
  writeJsonAtomic(getStatePath(dataDir), state);
}

export function getCachePath(dataDir = getByokDataDir()) {
  return path.join(dataDir, 'models-cache.json');
}

export function readCache(dataDir = getByokDataDir()) {
  return readJson(getCachePath(dataDir), { version: 1, caches: {} });
}

export function writeCache(cache, dataDir = getByokDataDir()) {
  writeJsonAtomic(getCachePath(dataDir), cache);
}

export function updateCacheForProvider(providerId, baseUrl, apiPath, modelIds, dataDir = getByokDataDir()) {
  const cache = readCache(dataDir);
  if (!cache.caches) {
    cache.caches = {};
  }

  const now = new Date().toISOString();
  const existingModels = Array.isArray(cache.caches[providerId]?.models) ? cache.caches[providerId].models : [];
  const byId = new Map();
  let maxOrder = 0;

  for (const m of existingModels) {
    if (typeof m === 'string') {
      maxOrder += 1;
      byId.set(m, { id: m, order: maxOrder, available: false, firstSeen: now, lastSeen: now });
    } else if (m && typeof m === 'object' && m.id) {
      const ord = typeof m.order === 'number' ? m.order : 0;
      if (ord > maxOrder) maxOrder = ord;
      byId.set(m.id, {
        id: m.id,
        order: ord,
        available: false,
        firstSeen: m.firstSeen || now,
        lastSeen: m.lastSeen || now
      });
    }
  }

  const ids = Array.isArray(modelIds) ? modelIds : [];
  for (const id of ids) {
    if (!id || typeof id !== 'string') continue;
    if (byId.has(id)) {
      const item = byId.get(id);
      item.available = true;
      item.lastSeen = now;
    } else {
      maxOrder += 1;
      byId.set(id, {
        id,
        order: maxOrder,
        available: true,
        firstSeen: now,
        lastSeen: now
      });
    }
  }

  const modelsList = Array.from(byId.values()).sort((a, b) => a.order - b.order);
  modelsList.forEach((m, idx) => { m.order = idx + 1; });

  cache.caches[providerId] = {
    updatedAt: now,
    baseUrl: baseUrl || '',
    apiPath: apiPath || '/models',
    models: modelsList
  };
  writeCache(cache, dataDir);
  return modelsList;
}

export function getProviderCacheEntry(providerId, dataDir = getByokDataDir()) {
  const cache = readCache(dataDir);
  if (cache && cache.caches && cache.caches[providerId]) {
    return cache.caches[providerId];
  }
  return null;
}

export function getCachedModelIds(providerId, dataDir = getByokDataDir()) {
  const entry = getProviderCacheEntry(providerId, dataDir);
  if (entry && Array.isArray(entry.models)) {
    return entry.models
      .filter(m => (typeof m === 'string' ? true : m?.available !== false))
      .map(m => (typeof m === 'string' ? m : m.id));
  }
  return [];
}

export function testModelCacheFresh(providerId, providerConfig = null, dataDir = getByokDataDir()) {
  const entry = getProviderCacheEntry(providerId, dataDir);
  if (!entry || !entry.updatedAt || !Array.isArray(entry.models) || entry.models.length === 0) {
    return false;
  }

  let ttlSeconds = 3600;
  if (providerConfig && typeof providerConfig.modelCacheTtlSeconds === 'number') {
    ttlSeconds = providerConfig.modelCacheTtlSeconds;
  }
  if (ttlSeconds <= 0) {
    return false;
  }

  const updatedTime = new Date(entry.updatedAt).getTime();
  if (isNaN(updatedTime)) {
    return false;
  }
  const ageSeconds = (Date.now() - updatedTime) / 1000;
  return ageSeconds >= 0 && ageSeconds < ttlSeconds;
}
