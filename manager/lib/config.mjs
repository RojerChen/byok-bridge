import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getByokDataDir, readJson, writeJsonAtomic } from './state.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export function getConfigPath(dataDir = getByokDataDir()) {
  return path.join(dataDir, 'providers.json');
}

/**
 * Finds bundled example config path in repo.
 */
export function getBundledExampleConfigPath() {
  const candidateDirs = [
    path.resolve(__dirname, '../../config'),
    path.resolve(__dirname, '../config')
  ];
  for (const dir of candidateDirs) {
    const p = path.join(dir, 'providers.example.json');
    if (fs.existsSync(p)) return p;
    const p2 = path.join(dir, 'providers.json');
    if (fs.existsSync(p2)) return p2;
  }
  return null;
}

export function getDefaultConfigStructure() {
  return {
    version: 1,
    clis: {
      copilot: {
        name: "GitHub Copilot CLI",
        command: "copilot",
        args: ["--experimental"],
        modelEnvName: "COPILOT_MODEL",
        defaultApiKeyEnv: ["COPILOT_PROVIDER_API_KEY"],
        defaultModelEnvNames: ["COPILOT_MODEL"],
        environment: {
          COPILOT_PROVIDER_BASE_URL: "{url}",
          COPILOT_PROVIDER_API_KEY: "{api_key}",
          COPILOT_PROVIDER_TYPE: "openai",
          COPILOT_MODEL: "{model}",
          BYOK_MODEL_PROVIDER_ID: "{provider_id}"
        }
      }
    },
    providers: {
      "openai-compatible": {
        name: "OpenAI-compatible provider (example)",
        enabled: true,
        type: "openai",
        baseUrl: "http://localhost:1234/v1",
        apiKeyRequired: false,
        modelCacheTtlSeconds: 3600,
        apiKeyEnv: ["COPILOT_PROVIDER_API_KEY", "OPENAI_API_KEY"],
        modelEnvNames: ["COPILOT_MODEL"],
        apiKeyHeader: "Authorization",
        apiKeyPrefix: "Bearer ",
        modelsApi: {
          path: "/models",
          itemsPath: "data",
          idPath: "id"
        },
        environment: {}
      }
    }
  };
}

/**
 * Normalizes raw config object into { configPath, rawConfig, clis: [...], providers: [...] }
 */
export function normalizeConfig(rawConfig, configPath) {
  const result = {
    configPath,
    version: rawConfig?.version || 1,
    clis: [],
    providers: []
  };

  if (rawConfig?.clis && typeof rawConfig.clis === 'object') {
    for (const [id, cliObj] of Object.entries(rawConfig.clis)) {
      if (!cliObj || typeof cliObj !== 'object') continue;
      const normalizedCli = {
        id,
        name: cliObj.name || id,
        command: cliObj.command || id,
        args: Array.isArray(cliObj.args) ? cliObj.args : [],
        modelEnvName: cliObj.modelEnvName || null,
        defaultApiKeyEnv: Array.isArray(cliObj.defaultApiKeyEnv) ? cliObj.defaultApiKeyEnv : (cliObj.defaultApiKeyEnv ? [cliObj.defaultApiKeyEnv] : []),
        defaultModelEnvNames: Array.isArray(cliObj.defaultModelEnvNames) ? cliObj.defaultModelEnvNames : (cliObj.defaultModelEnvNames ? [cliObj.defaultModelEnvNames] : []),
        environment: (cliObj.environment && typeof cliObj.environment === 'object') ? cliObj.environment : {},
        capabilities: cliObj.capabilities || { status: 'supported', providerEnv: true, apiKeyEnv: true, modelEnv: true }
      };
      result.clis.push(normalizedCli);
    }
  }

  if (rawConfig?.providers && typeof rawConfig.providers === 'object') {
    for (const [id, provObj] of Object.entries(rawConfig.providers)) {
      if (!provObj || typeof provObj !== 'object') continue;
      if (provObj.enabled === false) continue;

      const apiKeyEnvNames = [];
      if (Array.isArray(provObj.apiKeyEnvNames)) {
        apiKeyEnvNames.push(...provObj.apiKeyEnvNames);
      } else if (Array.isArray(provObj.apiKeyEnv)) {
        apiKeyEnvNames.push(...provObj.apiKeyEnv);
      } else if (typeof provObj.apiKeyEnv === 'string') {
        apiKeyEnvNames.push(provObj.apiKeyEnv);
      }

      const modelEnvNames = [];
      if (Array.isArray(provObj.modelEnvNames)) {
        modelEnvNames.push(...provObj.modelEnvNames);
      } else if (typeof provObj.modelEnvNames === 'string') {
        modelEnvNames.push(provObj.modelEnvNames);
      }

      const normalizedProvider = {
        id,
        name: provObj.name || id,
        enabled: provObj.enabled !== false,
        type: provObj.type || 'openai',
        baseUrl: provObj.baseUrl || '',
        apiKeyRequired: provObj.apiKeyRequired !== false,
        modelCacheTtlSeconds: typeof provObj.modelCacheTtlSeconds === 'number' ? provObj.modelCacheTtlSeconds : 3600,
        apiKeyEnvNames,
        apiKeyEnv: apiKeyEnvNames,
        modelEnvNames,
        apiKeyHeader: provObj.apiKeyHeader || 'Authorization',
        apiKeyPrefix: typeof provObj.apiKeyPrefix === 'string' ? provObj.apiKeyPrefix : 'Bearer ',
        modelsApi: provObj.modelsApi || { path: '/models', itemsPath: 'data', idPath: 'id' },
        models: Array.isArray(provObj.models) ? provObj.models : null,
        environment: (provObj.environment && typeof provObj.environment === 'object') ? provObj.environment : {},
        settings: (provObj.settings && typeof provObj.settings === 'object') ? provObj.settings : null
      };
      result.providers.push(normalizedProvider);
    }
  }

  return result;
}

/**
 * Loads provider config from dataDir/providers.json or bundled example.
 */
export function loadProviderConfig(dataDir = getByokDataDir()) {
  const userConfigPath = getConfigPath(dataDir);
  let raw = readJson(userConfigPath, null);
  let targetPath = userConfigPath;

  if (!raw) {
    const bundledPath = getBundledExampleConfigPath();
    if (bundledPath) {
      raw = readJson(bundledPath, null);
    }
    if (!raw) {
      raw = getDefaultConfigStructure();
    }
    // Automatically initialize user config file if it didn't exist
    try {
      writeJsonAtomic(userConfigPath, raw);
    } catch {}
  }

  return normalizeConfig(raw, targetPath);
}

/**
 * Interactively / programmatically adds a new provider to providers.json.
 */
export function addProvider(name, baseUrl, apiKey = '', cli = null, dataDir = getByokDataDir()) {
  const targetPath = getConfigPath(dataDir);
  let raw = readJson(targetPath, null);
  if (!raw) {
    const bundledPath = getBundledExampleConfigPath();
    raw = readJson(bundledPath, null) || getDefaultConfigStructure();
  }

  if (!raw.providers || typeof raw.providers !== 'object') {
    raw.providers = {};
  }

  const cleanName = (name || '').trim();
  const cleanUrl = (baseUrl || '').trim().replace(/\/+$/, '');
  
  // Generate a clean provider id
  let baseId = cleanName.toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'custom-provider';
  let id = baseId;
  let counter = 1;
  while (raw.providers[id]) {
    id = `${baseId}-${counter++}`;
  }

  const apiKeyEnvName = 'COPILOT_PROVIDER_API_KEY';
  const newProviderConfig = {
    name: cleanName,
    enabled: true,
    type: 'openai',
    baseUrl: cleanUrl,
    apiKeyRequired: !!apiKey,
    modelCacheTtlSeconds: 3600,
    apiKeyEnv: [apiKeyEnvName, 'OPENAI_API_KEY'],
    modelEnvNames: ['COPILOT_MODEL'],
    apiKeyHeader: 'Authorization',
    apiKeyPrefix: 'Bearer ',
    modelsApi: {
      path: '/models',
      itemsPath: 'data',
      idPath: 'id'
    },
    environment: {}
  };

  raw.providers[id] = newProviderConfig;
  writeJsonAtomic(targetPath, raw);

  return {
    id,
    configPath: targetPath,
    apiKeyEnvName,
    provider: newProviderConfig
  };
}
