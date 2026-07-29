import crypto from 'node:crypto';
import path from 'node:path';
import { readJsonStrict, writeJsonAtomic } from './state.mjs';

export const OPENCODE_ADAPTER = 'opencode-config-v1';
export const OPENCODE_API_KEY_ENV = 'BYOK_CLI_HUB_OPENCODE_API_KEY';
export const OPENCODE_CONFIG_ENV = 'OPENCODE_CONFIG';
export const OPENCODE_CONFIG_FILE = 'opencode.json';
export const OPENCODE_MAX_DEPTH = 32;
export const OPENCODE_MAX_MODELS = 4096;
export const OPENCODE_MAX_JSON_BYTES = 8 * 1024 * 1024;

const OMIT = Symbol('omit');
const HUB_PLACEHOLDER_PATTERN = /\{[a-z][a-z0-9_]*\}/g;
const SCALAR_PLACEHOLDERS = new Set([
  '{url}',
  '{provider_id}',
  '{opencode_provider_id}',
  '{provider_name}',
  '{model}'
]);
const KNOWN_PLACEHOLDERS = new Set([
  ...SCALAR_PLACEHOLDERS,
  '{models}',
  '{api_key_ref}'
]);

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertSafeDepth(depth) {
  if (depth > OPENCODE_MAX_DEPTH) {
    throw new Error(`OpenCode template exceeds the maximum depth of ${OPENCODE_MAX_DEPTH}.`);
  }
}

function findHubPlaceholders(value) {
  return typeof value === 'string' ? (value.match(HUB_PLACEHOLDER_PATTERN) || []) : [];
}

function assertKnownPlaceholders(value, location) {
  if (String(value).includes('{api_key}')) {
    throw new Error(`OpenCode templates must not contain plaintext API key placeholder '{api_key}' at ${location}.`);
  }
  for (const placeholder of findHubPlaceholders(value)) {
    if (!KNOWN_PLACEHOLDERS.has(placeholder)) {
      throw new Error(`Unknown OpenCode template placeholder '${placeholder}' at ${location}.`);
    }
  }
}

function replaceScalarPlaceholders(value, substitutions) {
  let result = value;
  for (const placeholder of SCALAR_PLACEHOLDERS) {
    if (result.includes(placeholder)) {
      result = result.replaceAll(placeholder, String(substitutions[placeholder] ?? ''));
    }
  }
  return result;
}

function renderNode(value, substitutions, location, depth, propertyName = null, parentName = null) {
  assertSafeDepth(depth);

  if (typeof value === 'string') {
    assertKnownPlaceholders(value, location);
    const placeholders = findHubPlaceholders(value);

    if (placeholders.includes('{models}')) {
      if (value !== '{models}') {
        throw new Error(`'{models}' must be the complete template value at ${location}.`);
      }
      return substitutions['{models}'];
    }

    if (placeholders.includes('{api_key_ref}')) {
      if (value !== '{api_key_ref}' || propertyName !== 'apiKey' || parentName !== 'options') {
        throw new Error(`'{api_key_ref}' is only allowed as the complete provider options.apiKey value at ${location}.`);
      }
      return substitutions['{api_key_ref}'] ?? OMIT;
    }

    return replaceScalarPlaceholders(value, substitutions);
  }

  if (Array.isArray(value)) {
    return value.map((item, index) => {
      const rendered = renderNode(item, substitutions, `${location}[${index}]`, depth + 1);
      if (rendered === OMIT) throw new Error(`OpenCode template cannot omit an array item at ${location}[${index}].`);
      return rendered;
    });
  }

  if (isRecord(value)) {
    const result = Object.create(null);
    for (const [rawKey, child] of Object.entries(value)) {
      assertKnownPlaceholders(rawKey, `${location} key`);
      if (rawKey.includes('{models}') || rawKey.includes('{api_key_ref}')) {
        throw new Error(`Typed OpenCode placeholders are not allowed in object keys at ${location}.`);
      }
      const key = replaceScalarPlaceholders(rawKey, substitutions);
      if (Object.hasOwn(result, key)) {
        throw new Error(`OpenCode template produced duplicate object key '${key}' at ${location}.`);
      }
      const rendered = renderNode(child, substitutions, `${location}.${key}`, depth + 1, key, propertyName);
      if (rendered !== OMIT) Object.defineProperty(result, key, { value: rendered, enumerable: true, writable: true });
    }
    return result;
  }

  if (value === null || ['number', 'boolean'].includes(typeof value)) return value;
  throw new Error(`Unsupported OpenCode template value at ${location}.`);
}

export function validateOpenCodeTemplate(template) {
  if (!isRecord(template)) throw new Error('OpenCode template must be a JSON object.');
  const visit = (value, location, depth, propertyName = null, parentName = null) => {
    assertSafeDepth(depth);
    if (typeof value === 'string') {
      assertKnownPlaceholders(value, location);
      if (value.includes('{models}') && value !== '{models}') {
        throw new Error(`'{models}' must be the complete template value at ${location}.`);
      }
      if (value.includes('{api_key_ref}')
          && (value !== '{api_key_ref}' || propertyName !== 'apiKey' || parentName !== 'options')) {
        throw new Error(`'{api_key_ref}' is only allowed as the complete provider options.apiKey value at ${location}.`);
      }
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((item, index) => visit(item, `${location}[${index}]`, depth + 1));
      return;
    }
    if (isRecord(value)) {
      for (const [key, child] of Object.entries(value)) {
        assertKnownPlaceholders(key, `${location} key`);
        if (key.includes('{models}') || key.includes('{api_key_ref}')) {
          throw new Error(`Typed OpenCode placeholders are not allowed in object keys at ${location}.`);
        }
        visit(child, `${location}.${key}`, depth + 1, key, propertyName);
      }
      return;
    }
    if (value !== null && !['number', 'boolean'].includes(typeof value)) {
      throw new Error(`Unsupported OpenCode template value at ${location}.`);
    }
  };
  visit(template, '$', 0);
  return template;
}

export function getOpenCodeProviderId(providerId) {
  const original = String(providerId ?? '');
  let slug = original
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  if (!slug) slug = 'provider';
  slug = slug.slice(0, 48).replace(/-+$/g, '') || 'provider';

  const suffix = original === slug
    ? ''
    : `-${crypto.createHash('sha256').update(original, 'utf8').digest('hex').slice(0, 8)}`;
  return `byok-cli-hub-${slug}${suffix}`;
}

export function normalizeOpenCodeModels(availableModels, chosenModel, chosenModelSource = 'first-available') {
  const models = [];
  const seen = new Set();
  for (const rawModel of Array.isArray(availableModels) ? availableModels : []) {
    const id = typeof rawModel === 'string' ? rawModel.trim() : String(rawModel?.id ?? '').trim();
    if (!id || seen.has(id)) continue;
    if (/\p{Cc}/u.test(id) || id.length > 512) throw new Error(`Invalid OpenCode model ID '${id}'.`);
    seen.add(id);
    models.push(id);
    if (models.length > OPENCODE_MAX_MODELS) {
      throw new Error(`OpenCode model list exceeds the maximum of ${OPENCODE_MAX_MODELS}.`);
    }
  }

  const selected = String(chosenModel ?? '').trim();
  if (chosenModelSource === 'option' && selected && !seen.has(selected)) {
    if (models.length >= OPENCODE_MAX_MODELS) {
      throw new Error(`OpenCode model list exceeds the maximum of ${OPENCODE_MAX_MODELS}.`);
    }
    models.push(selected);
    seen.add(selected);
  }
  if (!selected) throw new Error('OpenCode requires a selected model.');
  if (!seen.has(selected)) throw new Error(`Selected OpenCode model '${selected}' is not available.`);
  return models;
}

export function buildOpenCodeModelMap(models) {
  const result = Object.create(null);
  for (const id of models) {
    Object.defineProperty(result, id, {
      value: { name: id },
      enumerable: true,
      writable: true
    });
  }
  return result;
}

export function validateOpenCodeConfig(config, context) {
  const {
    runtimeProviderId,
    chosenModel,
    models,
    includeApiKeyReference,
    apiKey = ''
  } = context;

  if (!isRecord(config)) throw new Error('Generated OpenCode config must be a JSON object.');
  if (typeof config.$schema !== 'string' || !config.$schema.trim()) {
    throw new Error('Generated OpenCode config must contain a non-empty $schema string.');
  }
  if (config.model !== `${runtimeProviderId}/${chosenModel}`) {
    throw new Error('Generated OpenCode config has an invalid default model reference.');
  }
  const runtimeProvider = config.provider?.[runtimeProviderId];
  if (!isRecord(runtimeProvider) || !isRecord(runtimeProvider.models)) {
    throw new Error(`Generated OpenCode config is missing provider '${runtimeProviderId}'.`);
  }
  for (const model of models) {
    if (!Object.hasOwn(runtimeProvider.models, model)) {
      throw new Error(`Generated OpenCode config is missing model '${model}'.`);
    }
  }

  const hasApiKey = Object.hasOwn(runtimeProvider.options || {}, 'apiKey');
  if (includeApiKeyReference) {
    if (!hasApiKey || runtimeProvider.options.apiKey !== `{env:${OPENCODE_API_KEY_ENV}}`) {
      throw new Error('Generated OpenCode config has an invalid API key environment reference.');
    }
  } else if (hasApiKey) {
    throw new Error('Generated OpenCode config must omit options.apiKey when no optional API key is present.');
  }

  const json = JSON.stringify(config);
  if (apiKey.length >= 8 && json.includes(apiKey)) throw new Error('Generated OpenCode config contains the plaintext API key.');
  if (Buffer.byteLength(json, 'utf8') > OPENCODE_MAX_JSON_BYTES) {
    throw new Error(`Generated OpenCode config exceeds ${OPENCODE_MAX_JSON_BYTES} UTF-8 bytes.`);
  }
  JSON.parse(json);
  return config;
}

export function buildOpenCodeConfig(template, context) {
  const runtimeProviderId = getOpenCodeProviderId(context.providerId);
  const models = normalizeOpenCodeModels(context.availableModels, context.chosenModel, context.chosenModelSource);
  const includeApiKeyReference = context.apiKeyRequired !== false || Boolean(context.apiKey);
  const substitutions = {
    '{url}': context.baseUrl,
    '{provider_id}': context.providerId,
    '{opencode_provider_id}': runtimeProviderId,
    '{provider_name}': context.providerName,
    '{model}': context.chosenModel,
    '{models}': buildOpenCodeModelMap(models),
    '{api_key_ref}': includeApiKeyReference ? `{env:${OPENCODE_API_KEY_ENV}}` : null
  };
  const config = renderNode(template, substitutions, '$', 0);
  validateOpenCodeConfig(config, {
    runtimeProviderId,
    chosenModel: context.chosenModel,
    models,
    includeApiKeyReference,
    apiKey: context.apiKey
  });
  return { config, runtimeProviderId, models };
}

export function getOpenCodeConfigPath(dataDir, fileName = OPENCODE_CONFIG_FILE) {
  if (fileName !== OPENCODE_CONFIG_FILE) {
    throw new Error(`OpenCode configFileName must be '${OPENCODE_CONFIG_FILE}'.`);
  }
  return path.resolve(dataDir, fileName);
}

export function writeOpenCodeConfig(filePath, config) {
  writeJsonAtomic(filePath, config);
  return readJsonStrict(filePath);
}
