import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getByokDataDir, readJsonStrict, writeJsonAtomic } from './state.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const ENV_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const COMMAND_PATTERN = /^[A-Za-z0-9._+-]+$/;
const HEADER_NAME_PATTERN = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
const MODELS_API_PATH_FORBIDDEN_PATTERN = /[\u0000-\u001f\u007f?#]/;
const CONTROL_CHAR_PATTERN = /[\u0000-\u001f\u007f]/;

export class ConfigValidationError extends Error {
  constructor(jsonPath, message) {
    super(`Invalid provider config at ${jsonPath}: ${message}`);
    this.name = 'ConfigValidationError';
    this.jsonPath = jsonPath;
  }
}

function fail(jsonPath, message) {
  throw new ConfigValidationError(jsonPath, message);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validateId(value, jsonPath) {
  if (!ID_PATTERN.test(value)) fail(jsonPath, 'must match /^[A-Za-z0-9][A-Za-z0-9._-]*$/.');
}

function validateEnvName(value, jsonPath) {
  if (typeof value !== 'string' || !ENV_NAME_PATTERN.test(value)) {
    fail(jsonPath, 'must be a valid environment variable name.');
  }
}

function validateStringArray(value, jsonPath) {
  if (!Array.isArray(value) || value.some(item => typeof item !== 'string')) {
    fail(jsonPath, 'must be an array of strings.');
  }
}

function validateEnvMap(value, jsonPath) {
  if (!isRecord(value)) fail(jsonPath, 'must be an object.');
  for (const [name, template] of Object.entries(value)) {
    validateEnvName(name, `${jsonPath}.${name}`);
    if (!['string', 'number', 'boolean'].includes(typeof template)) {
      fail(`${jsonPath}.${name}`, 'must be a string, number, or boolean template value.');
    }
  }
}

function validateBaseUrl(value, jsonPath) {
  if (typeof value !== 'string' || !value.trim()) fail(jsonPath, 'must be a non-empty URL.');
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    fail(jsonPath, 'must be an absolute URL.');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) fail(jsonPath, 'must use http: or https:.');
  if (parsed.username || parsed.password) fail(jsonPath, 'must not contain embedded credentials.');
  if (parsed.search || parsed.hash) fail(jsonPath, 'must not contain a query string or fragment.');
}

function validateCli(cli, jsonPath) {
  if (!isRecord(cli)) fail(jsonPath, 'must be an object.');
  if (cli.command !== undefined) {
    if (typeof cli.command !== 'string' || !cli.command.trim()) fail(`${jsonPath}.command`, 'must be non-empty.');
    const command = cli.command.trim();
    if (!path.isAbsolute(command) && !COMMAND_PATTERN.test(command)) {
      fail(`${jsonPath}.command`, 'must be an executable name or an absolute path, not a shell fragment.');
    }
  }
  if (cli.args !== undefined) {
    validateStringArray(cli.args, `${jsonPath}.args`);
    if (cli.args.some(argument => argument.includes('{api_key}') || argument.includes('${api_key}'))) {
      fail(`${jsonPath}.args`, 'must not place API keys in process arguments; use child environment variables.');
    }
  }
  if (cli.modelEnvName !== undefined && cli.modelEnvName !== null) {
    validateEnvName(cli.modelEnvName, `${jsonPath}.modelEnvName`);
  }
  for (const property of ['defaultApiKeyEnv', 'defaultModelEnvNames', 'apiKeyEnv']) {
    if (cli[property] !== undefined) {
      const values = Array.isArray(cli[property]) ? cli[property] : [cli[property]];
      values.forEach((name, index) => validateEnvName(name, `${jsonPath}.${property}[${index}]`));
    }
  }
  if (cli.environment !== undefined) validateEnvMap(cli.environment, `${jsonPath}.environment`);
  if (cli.settings !== undefined) validateEnvMap(cli.settings, `${jsonPath}.settings`);
  if (cli.status !== undefined && !['supported', 'partial', 'unsupported'].includes(String(cli.status).toLowerCase())) {
    fail(`${jsonPath}.status`, 'must be supported, partial, or unsupported.');
  }
}

function validateProvider(provider, jsonPath) {
  if (!isRecord(provider)) fail(jsonPath, 'must be an object.');
  if (provider.baseUrl !== undefined && provider.baseUrl !== '') validateBaseUrl(provider.baseUrl, `${jsonPath}.baseUrl`);
  if (provider.modelCacheTtlSeconds !== undefined
      && (!Number.isFinite(provider.modelCacheTtlSeconds) || provider.modelCacheTtlSeconds < 0)) {
    fail(`${jsonPath}.modelCacheTtlSeconds`, 'must be a non-negative number.');
  }
  for (const property of ['apiKeyEnv', 'apiKeyEnvNames', 'modelEnvNames']) {
    if (provider[property] !== undefined) {
      const values = Array.isArray(provider[property]) ? provider[property] : [provider[property]];
      values.forEach((name, index) => validateEnvName(name, `${jsonPath}.${property}[${index}]`));
    }
  }
  if (provider.apiKeyHeader !== undefined
      && (typeof provider.apiKeyHeader !== 'string' || !HEADER_NAME_PATTERN.test(provider.apiKeyHeader))) {
    fail(`${jsonPath}.apiKeyHeader`, 'is not a valid HTTP header name.');
  }
  if (provider.apiKeyPrefix !== undefined) {
    if (typeof provider.apiKeyPrefix !== 'string') {
      fail(`${jsonPath}.apiKeyPrefix`, 'must be a string.');
    }
    if (CONTROL_CHAR_PATTERN.test(provider.apiKeyPrefix)) {
      fail(`${jsonPath}.apiKeyPrefix`, 'must not contain control characters.');
    }
  }
  if (provider.modelsApi !== undefined) {
    if (!isRecord(provider.modelsApi)) fail(`${jsonPath}.modelsApi`, 'must be an object.');
    for (const property of ['path', 'itemsPath', 'idPath']) {
      if (provider.modelsApi[property] !== undefined && typeof provider.modelsApi[property] !== 'string') {
        fail(`${jsonPath}.modelsApi.${property}`, 'must be a string.');
      }
    }
    if (provider.modelsApi.apiKeyPrefix !== undefined) {
      if (typeof provider.modelsApi.apiKeyPrefix !== 'string') {
        fail(`${jsonPath}.modelsApi.apiKeyPrefix`, 'must be a string.');
      }
      if (CONTROL_CHAR_PATTERN.test(provider.modelsApi.apiKeyPrefix)) {
        fail(`${jsonPath}.modelsApi.apiKeyPrefix`, 'must not contain control characters.');
      }
    }
    if (MODELS_API_PATH_FORBIDDEN_PATTERN.test(provider.modelsApi.path || '')) {
      fail(`${jsonPath}.modelsApi.path`, 'must not contain control characters, a query, or a fragment.');
    }
    if (provider.modelsApi.apiKeyHeader !== undefined
        && (typeof provider.modelsApi.apiKeyHeader !== 'string'
          || !HEADER_NAME_PATTERN.test(provider.modelsApi.apiKeyHeader))) {
      fail(`${jsonPath}.modelsApi.apiKeyHeader`, 'is not a valid HTTP header name.');
    }
  }
  if (provider.models !== undefined) {
    if (!Array.isArray(provider.models)) fail(`${jsonPath}.models`, 'must be an array.');
    provider.models.forEach((model, index) => {
      const id = typeof model === 'string' ? model : model?.id;
      if (typeof id !== 'string' || !id.trim() || /[\u0000-\u001f\u007f]/.test(id) || id.length > 512) {
        fail(`${jsonPath}.models[${index}]`, 'must contain a valid model ID string.');
      }
    });
  }
  if (provider.settings !== undefined) validateEnvMap(provider.settings, `${jsonPath}.settings`);
  if (provider.environment !== undefined) {
    if (!isRecord(provider.environment)) fail(`${jsonPath}.environment`, 'must be an object.');
    for (const [cliId, envMap] of Object.entries(provider.environment)) {
      validateId(cliId, `${jsonPath}.environment.${cliId}`);
      validateEnvMap(envMap, `${jsonPath}.environment.${cliId}`);
    }
  }
}

export function validateConfig(rawConfig) {
  if (!isRecord(rawConfig)) fail('$', 'must be a JSON object.');
  if (rawConfig.version !== 1) fail('$.version', 'must equal 1.');
  if (!isRecord(rawConfig.clis) || Object.keys(rawConfig.clis).length === 0) {
    fail('$.clis', 'must contain at least one CLI.');
  }
  if (!isRecord(rawConfig.providers)) fail('$.providers', 'must be an object.');

  for (const [id, cli] of Object.entries(rawConfig.clis)) {
    validateId(id, `$.clis.${id}`);
    validateCli(cli, `$.clis.${id}`);
  }
  for (const [id, provider] of Object.entries(rawConfig.providers)) {
    validateId(id, `$.providers.${id}`);
    validateProvider(provider, `$.providers.${id}`);
  }
  return rawConfig;
}

export function getConfigPath(dataDir = getByokDataDir()) {
  return path.join(dataDir, 'providers.json');
}

export function getBundledExampleConfigPath() {
  const candidateDirs = [path.resolve(__dirname, '../../config'), path.resolve(__dirname, '../config')];
  for (const dir of candidateDirs) {
    for (const name of ['providers.example.json', 'providers.json']) {
      const candidate = path.join(dir, name);
      if (fs.existsSync(candidate)) return candidate;
    }
  }
  return null;
}

export function getDefaultConfigStructure() {
  return {
    version: 1,
    clis: {
      copilot: {
        name: 'GitHub Copilot CLI',
        command: 'copilot',
        args: ['--experimental'],
        modelEnvName: 'COPILOT_MODEL',
        defaultApiKeyEnv: ['COPILOT_PROVIDER_API_KEY'],
        defaultModelEnvNames: ['COPILOT_MODEL'],
        environment: {
          COPILOT_PROVIDER_BASE_URL: '{url}',
          COPILOT_PROVIDER_API_KEY: '{api_key}',
          COPILOT_PROVIDER_TYPE: 'openai',
          COPILOT_MODEL: '{model}',
          BYOK_MODEL_PROVIDER_ID: '{provider_id}'
        }
      }
    },
    providers: {
      'openai-compatible': {
        name: 'OpenAI-compatible provider (example)',
        enabled: true,
        type: 'openai',
        baseUrl: 'http://localhost:1234/v1',
        apiKeyRequired: false,
        modelCacheTtlSeconds: 3600,
        apiKeyEnv: ['COPILOT_PROVIDER_API_KEY', 'OPENAI_API_KEY'],
        modelEnvNames: ['COPILOT_MODEL'],
        apiKeyHeader: 'Authorization',
        apiKeyPrefix: 'Bearer ',
        modelsApi: { path: '/models', itemsPath: 'data', idPath: 'id' },
        environment: {}
      }
    }
  };
}

export function normalizeConfig(rawConfig, configPath) {
  validateConfig(rawConfig);
  const result = { configPath, version: rawConfig.version, clis: [], providers: [] };

  for (const [id, cli] of Object.entries(rawConfig.clis)) {
    if (cli.enabled === false) continue;
    result.clis.push({
      id,
      name: cli.name || id,
      command: cli.command || id,
      args: cli.args || [],
      modelEnvName: cli.modelEnvName || null,
      defaultApiKeyEnv: Array.isArray(cli.defaultApiKeyEnv)
        ? cli.defaultApiKeyEnv
        : (cli.defaultApiKeyEnv ? [cli.defaultApiKeyEnv] : []),
      defaultModelEnvNames: Array.isArray(cli.defaultModelEnvNames)
        ? cli.defaultModelEnvNames
        : (cli.defaultModelEnvNames ? [cli.defaultModelEnvNames] : []),
      apiKeyEnv: Array.isArray(cli.apiKeyEnv) ? cli.apiKeyEnv : (cli.apiKeyEnv ? [cli.apiKeyEnv] : []),
      environment: cli.environment || cli.settings || {},
      capabilities: cli.capabilities || null,
      status: cli.status || cli.capabilities?.status || 'supported',
      order: typeof cli.order === 'number' ? cli.order : 0
    });
  }

  for (const [id, provider] of Object.entries(rawConfig.providers)) {
    if (provider.enabled === false) continue;
    const apiKeyEnvNames = Array.isArray(provider.apiKeyEnvNames)
      ? provider.apiKeyEnvNames
      : (Array.isArray(provider.apiKeyEnv) ? provider.apiKeyEnv : (provider.apiKeyEnv ? [provider.apiKeyEnv] : []));
    const modelEnvNames = Array.isArray(provider.modelEnvNames)
      ? provider.modelEnvNames
      : (provider.modelEnvNames ? [provider.modelEnvNames] : []);
    result.providers.push({
      id,
      name: provider.name || id,
      enabled: true,
      type: provider.type || 'openai',
      baseUrl: provider.baseUrl || '',
      apiKeyRequired: provider.apiKeyRequired !== false,
      modelCacheTtlSeconds: typeof provider.modelCacheTtlSeconds === 'number'
        ? provider.modelCacheTtlSeconds
        : 3600,
      apiKeyEnvNames,
      apiKeyEnv: apiKeyEnvNames,
      modelEnvNames,
      apiKeyHeader: provider.apiKeyHeader || 'Authorization',
      apiKeyPrefix: typeof provider.apiKeyPrefix === 'string' ? provider.apiKeyPrefix : 'Bearer ',
      modelsApi: provider.modelsApi || { path: '/models', itemsPath: 'data', idPath: 'id' },
      models: provider.models || null,
      environment: provider.environment || {},
      settings: provider.settings || null,
      order: typeof provider.order === 'number' ? provider.order : 0
    });
  }

  result.clis.sort((a, b) => a.order - b.order);
  result.providers.sort((a, b) => a.order - b.order);
  return result;
}

export function loadProviderConfig(dataDir = getByokDataDir(), options = {}) {
  const { initialize = true } = options;
  const userConfigPath = getConfigPath(dataDir);
  const legacyConfigPath = path.join(dataDir, 'config', 'providers.json');
  let raw;

  if (fs.existsSync(userConfigPath)) {
    raw = readJsonStrict(userConfigPath);
  } else if (fs.existsSync(legacyConfigPath)) {
    raw = readJsonStrict(legacyConfigPath);
    validateConfig(raw);
    if (initialize) writeJsonAtomic(userConfigPath, raw);
  } else {
    const bundledPath = getBundledExampleConfigPath();
    raw = bundledPath ? readJsonStrict(bundledPath) : getDefaultConfigStructure();
    validateConfig(raw);
    if (initialize) writeJsonAtomic(userConfigPath, raw);
  }

  return normalizeConfig(raw, userConfigPath);
}

export function addProvider(name, baseUrl, apiKey = '', cli = null, dataDir = getByokDataDir()) {
  const targetPath = getConfigPath(dataDir);
  let raw;
  if (fs.existsSync(targetPath)) {
    raw = readJsonStrict(targetPath);
  } else {
    const legacyPath = path.join(dataDir, 'config', 'providers.json');
    const bundledPath = getBundledExampleConfigPath();
    raw = fs.existsSync(legacyPath)
      ? readJsonStrict(legacyPath)
      : (bundledPath ? readJsonStrict(bundledPath) : getDefaultConfigStructure());
  }
  validateConfig(raw);

  const cleanName = String(name || '').trim();
  const cleanUrl = String(baseUrl || '').trim().replace(/\/+$/, '');
  if (!cleanName) fail('$.providers.<new>.name', 'is required.');
  validateBaseUrl(cleanUrl, '$.providers.<new>.baseUrl');

  let baseId = cleanName.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'custom-provider';
  let id = baseId;
  let counter = 1;
  while (raw.providers[id]) id = `${baseId}-${counter++}`;

  const cliKeyTargets = Array.isArray(cli?.defaultApiKeyEnv) && cli.defaultApiKeyEnv.length > 0
    ? cli.defaultApiKeyEnv
    : ['COPILOT_PROVIDER_API_KEY'];
  const cliModelTargets = Array.isArray(cli?.defaultModelEnvNames) && cli.defaultModelEnvNames.length > 0
    ? cli.defaultModelEnvNames
    : ['COPILOT_MODEL'];
  const generatedKeyName = `${id.toUpperCase().replace(/[^A-Z0-9_]/g, '_')}_API_KEY`;
  const apiKeyEnv = [...new Set([generatedKeyName, ...cliKeyTargets])];
  const apiKeyEnvName = apiKeyEnv[0];
  const newProvider = {
    name: cleanName,
    enabled: true,
    type: 'openai',
    baseUrl: cleanUrl,
    apiKeyRequired: true,
    modelCacheTtlSeconds: 3600,
    apiKeyEnv,
    modelEnvNames: [...new Set(cliModelTargets)],
    apiKeyHeader: 'Authorization',
    apiKeyPrefix: 'Bearer ',
    modelsApi: { path: '/models', itemsPath: 'data', idPath: 'id' },
    environment: {}
  };

  raw.providers[id] = newProvider;
  validateConfig(raw);
  writeJsonAtomic(targetPath, raw);
  return { id, configPath: targetPath, apiKeyEnvName, provider: newProvider, apiKeyProvided: Boolean(apiKey) };
}
