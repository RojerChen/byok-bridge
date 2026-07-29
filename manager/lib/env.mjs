/**
 * Helper module for environment variable resolution, template expansion,
 * CLI args resolution, and runtime environment map building.
 */

export function expandTemplateValue(value, substitutions = {}) {
  if (value === null || value === undefined) return null;
  let text = String(value);
  for (const [key, subVal] of Object.entries(substitutions)) {
    if (subVal !== null && subVal !== undefined) {
      text = text.replaceAll(key, String(subVal));
    }
  }
  return text;
}

export function resolveCliArgs(cli, provider, baseUrl, model, apiKey, providerId) {
  if (!cli || !Array.isArray(cli.args) || cli.args.length === 0) {
    return [];
  }

  const providerName = provider?.name || '';
  const subs = {
    '{url}': baseUrl,
    '${url}': baseUrl,
    '{api_key}': apiKey,
    '${api_key}': apiKey,
    '{model}': model,
    '${model}': model,
    '{provider_id}': providerId,
    '${provider_id}': providerId,
    '{provider_name}': providerName,
    '${provider_name}': providerName
  };

  return cli.args.map(arg => expandTemplateValue(arg, subs));
}

export function buildRuntimeEnvMap(provider, baseUrl, model, apiKey, providerId, cli = null) {
  const map = {};
  const providerName = provider?.name || '';
  const subs = {
    '{url}': baseUrl,
    '${url}': baseUrl,
    '{api_key}': apiKey,
    '${api_key}': apiKey,
    '{model}': model,
    '${model}': model,
    '{provider_id}': providerId,
    '${provider_id}': providerId,
    '{provider_name}': providerName,
    '${provider_name}': providerName
  };

  // 1. CLI base environment (from cli.environment)
  const cliEnv = cli?.environment || cli?.settings;
  if (cliEnv && typeof cliEnv === 'object') {
    for (const [k, v] of Object.entries(cliEnv)) {
      map[k] = expandTemplateValue(v, subs);
    }
  }

  // 2. CLI model & API key environment variable names
  if (cli?.modelEnvName && typeof cli.modelEnvName === 'string' && cli.modelEnvName.trim()) {
    map[cli.modelEnvName.trim()] = model;
  }

  const cliApiKeyEnvs = [];
  if (Array.isArray(cli?.defaultApiKeyEnv)) cliApiKeyEnvs.push(...cli.defaultApiKeyEnv);
  if (Array.isArray(cli?.apiKeyEnv)) cliApiKeyEnvs.push(...cli.apiKeyEnv);
  for (const name of cliApiKeyEnvs) {
    if (typeof name === 'string' && name.trim()) {
      map[name.trim()] = apiKey;
    }
  }

  // 3. Provider-wide environment, followed by CLI-specific overrides
  if (provider?.environment && typeof provider.environment === 'object') {
    for (const [k, v] of Object.entries(provider.environment)) {
      if (v === null || typeof v === 'object') continue;
      map[k] = expandTemplateValue(v, subs);
    }
  }

  const cliOverrides = provider?.environment && cli?.id ? provider.environment[cli.id] : null;
  if (cliOverrides && typeof cliOverrides === 'object' && !Array.isArray(cliOverrides)) {
    for (const [k, v] of Object.entries(cliOverrides)) {
      if (k && typeof k === 'string') {
        map[k.trim()] = expandTemplateValue(v, subs);
      }
    }
  }

  // 4. Provider legacy settings / environment
  if (provider?.settings && typeof provider.settings === 'object') {
    for (const [k, v] of Object.entries(provider.settings)) {
      if (k && typeof k === 'string') {
        map[k.trim()] = expandTemplateValue(v, subs);
      }
    }
  }

  // 5. Provider API key & model environment variable names
  const keyTargets = Array.isArray(provider?.apiKeyEnvNames)
    ? provider.apiKeyEnvNames
    : (Array.isArray(provider?.apiKeyEnv) ? provider.apiKeyEnv : []);
  for (const t of keyTargets) {
    if (typeof t === 'string' && t.trim()) {
      map[t.trim()] = apiKey;
    }
  }

  const modelTargets = Array.isArray(provider?.modelEnvNames) ? provider.modelEnvNames : [];
  for (const t of modelTargets) {
    if (typeof t === 'string' && t.trim()) {
      map[t.trim()] = model;
    }
  }

  return map;
}

/**
 * Config-file adapters use the same configured environment contract as every
 * other CLI.  An `environment` entry is an instruction to set that variable;
 * the adapter must not discard it based on the variable name.  CLI-specific
 * provider overrides still apply only to the selected CLI.
 */
export function buildAdapterRuntimeEnvMap(provider, baseUrl, model, apiKey, providerId, cli) {
  return buildRuntimeEnvMap(provider, baseUrl, model, apiKey, providerId, cli);
}

/**
 * Marks values derived from the API key as sensitive. Redaction must follow the
 * value source, not guesses based on environment variable names.
 */
export function getSensitiveEnvKeys(envMap, apiKey) {
  const sensitive = new Set();
  const secret = typeof apiKey === 'string' ? apiKey : '';
  if (!secret) return sensitive;
  for (const [name, value] of Object.entries(envMap || {})) {
    if (String(value ?? '').includes(secret)) sensitive.add(name);
  }
  return sensitive;
}

export function resolveEnvValue(envNames) {
  if (!envNames) return '';
  const list = Array.isArray(envNames) ? envNames : [envNames];
  for (const name of list) {
    if (name && typeof name === 'string') {
      const val = process.env[name.trim()];
      if (val !== undefined && val !== null && String(val).trim() !== '') {
        return String(val).trim();
      }
    }
  }
  return '';
}

export function getApiKeyEnvName(provider) {
  if (!provider) return 'COPILOT_PROVIDER_API_KEY';
  const names = Array.isArray(provider.apiKeyEnvNames) && provider.apiKeyEnvNames.length > 0
    ? provider.apiKeyEnvNames
    : (Array.isArray(provider.apiKeyEnv) ? provider.apiKeyEnv : []);
  for (const name of names) {
    if (typeof name === 'string' && process.env[name]?.trim()) return name;
  }
  if (names.length > 0) return names[0];
  return 'COPILOT_PROVIDER_API_KEY';
}

export function getCliSupportStatus(cli) {
  if (!cli) return 'unsupported';
  if (cli.status && typeof cli.status === 'string') {
    return cli.status.trim().toLowerCase();
  }
  if (cli.capabilities && cli.capabilities.status && typeof cli.capabilities.status === 'string') {
    return cli.capabilities.status.trim().toLowerCase();
  }
  return 'supported';
}

export function resolveChosenModelSelection(requestedModel, environmentModel, rememberedModel, availableModels = [], providerChanged = false) {
  const req = (requestedModel || '').trim();
  if (req) return { model: req, source: 'option' };

  const env = (environmentModel || '').trim();
  const rem = (rememberedModel || '').trim();
  const available = Array.isArray(availableModels) ? availableModels : [];

  if (env && available.includes(env)) return { model: env, source: 'environment' };

  if (!providerChanged && rem && available.includes(rem)) {
    return { model: rem, source: 'state' };
  }

  if (available.length > 0) {
    return { model: available[0], source: 'first-available' };
  }

  return { model: '', source: 'first-available' };
}

export function resolveChosenModel(requestedModel, environmentModel, rememberedModel, availableModels = [], providerChanged = false) {
  const req = (requestedModel || '').trim();
  if (req) return req;
  const env = (environmentModel || '').trim();
  if (env) return env;
  const rem = (rememberedModel || '').trim();
  const available = Array.isArray(availableModels) ? availableModels : [];
  if (!providerChanged && rem && (available.length === 0 || available.includes(rem))) return rem;
  return available[0] || 'gpt-4o';
}

export function getApiKeySource(keyEnvName, fromPrompt = false, fromArgument = false, apiKey = '') {
  if (fromPrompt) return 'prompt';
  if (fromArgument) return 'argument';
  if (apiKey && keyEnvName && process.env[keyEnvName]) return `env:${keyEnvName}`;
  return 'none';
}
