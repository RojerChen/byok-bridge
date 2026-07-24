#!/usr/bin/env node

import process from 'node:process';
import {
  getByokDataDir,
  readState,
  writeState,
  readCache,
  updateCacheForProvider,
  testModelCacheFresh,
  cacheIdentityMatches
} from './lib/state.mjs';
import { loadProviderConfig, addProvider } from './lib/config.mjs';
import {
  resolveCliArgs,
  buildRuntimeEnvMap,
  resolveEnvValue,
  getApiKeyEnvName,
  getCliSupportStatus,
  resolveChosenModel,
  getApiKeySource,
  getSensitiveEnvKeys
} from './lib/env.mjs';
import { parseArgs, UsageError } from './lib/args.mjs';
import { fetchModels } from './lib/http.mjs';
import { readMaskedPrompt, readInput, selectMenuItem } from './lib/prompt.mjs';
import { launchCli } from './lib/launcher.mjs';

function printHelp() {
  console.log(`
BYOK CLI Hub Manager (Linux / Node.js)

Usage:
  byok-cli-hub [options] [-- [CLI_ARGS...]]

Options:
  --cli ID          Select CLI to launch (e.g. copilot)
  --provider ID     Select Provider ID (use '+' to add a new provider interactively)
  --base-url URL    Override Base URL
  --api-key KEY     Supply API key (Warning: visible in process list)
  --model ID        Select model ID
  --data-dir DIR    Override data directory
  --refresh         Refresh model cache from provider
  --dry-run         Display resolved parameters & env map without launching
  --self-check      Run environment preflight checks
  --help, -h        Display this help message
`);
}

async function runSelfCheck(dataDir) {
  console.log('[SELF-CHECK] Running BYOK CLI Hub preflight checks...');
  
  // Check Node.js version >= 22
  const majorVersion = parseInt(process.versions.node.split('.')[0], 10);
  if (majorVersion < 22) {
    console.error(`[SELF-CHECK] Error: Node.js version >= 22 is required. Current version: ${process.version}`);
    process.exit(1);
  }
  console.log(`[SELF-CHECK] Node.js version: ${process.version} (OK)`);

  // Check config
  try {
    const config = loadProviderConfig(dataDir);
    console.log(`[SELF-CHECK] Config loaded from: ${config.configPath}`);
    console.log(`[SELF-CHECK] Configured CLIs: ${config.clis.map(c => c.id).join(', ')}`);
    console.log(`[SELF-CHECK] Configured Providers: ${config.providers.map(p => p.id).join(', ')}`);
  } catch (err) {
    console.error(`[SELF-CHECK] Config Error: ${err.message}`);
    process.exit(1);
  }

  console.log('[SELF-CHECK] All preflight checks passed.');
  process.exit(0);
}

async function invokeAddProviderFlow(selectedCli, dataDir) {
  console.log('\x1b[36m--- Add a new provider ---\x1b[0m');
  const name = await readInput('Provider display name');
  if (!name) {
    console.error('Provider name is required.');
    process.exit(1);
  }

  const url = await readInput('Base URL (e.g. https://api.example.com/v1)');
  if (!url) {
    console.error('Base URL is required.');
    process.exit(1);
  }

  let key = '';
  if (process.stdin.isTTY) {
    key = await readMaskedPrompt('API key (optional, press Enter to skip): ');
  }

  const result = addProvider(name, url, key, selectedCli, dataDir);
  console.log(`\x1b[32mProvider '${name}' added with id '${result.id}'.\x1b[0m`);
  console.log(`Config file: ${result.configPath}`);
  console.log('Edit that file to customize advanced settings (type, headers, modelsApi, environment, etc.).\n');

  if (key) {
    process.env[result.apiKeyEnvName] = key;
  }

  const freshConfig = loadProviderConfig(dataDir);
  const newProv = freshConfig.providers.find(p => p.id === result.id);
  if (!newProv) {
    console.error('Failed to reload newly added provider.');
    process.exit(1);
  }
  return newProv;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    return;
  }
  const dataDir = getByokDataDir(options.dataDir);

  if (options.selfCheck) {
    await runSelfCheck(dataDir);
    return;
  }

  const config = loadProviderConfig(dataDir, { initialize: !options.dryRun });
  const state = readState(dataDir) || {};

  const rememberedCliId = state.cliId || null;
  const rememberedProviderId = state.providerId || null;
  const rememberedModel = state.model || null;

  if (config.providers.length === 0) {
    console.error('Error: No enabled providers were found in providers.json.');
    process.exit(1);
  }

  // --- 1. CLI Selection ---------------------------------------------------
  let clis = config.clis.filter(c => getCliSupportStatus(c) !== 'unsupported');
  if (clis.length === 0) {
    console.error('Error: No supported or partial CLIs were found.');
    process.exit(1);
  }

  let selectedCli = null;
  if (options.cli) {
    selectedCli = config.clis.find(c => c.id === options.cli);
    if (!selectedCli) {
      console.error(`Error: Unknown CLI '${options.cli}'.`);
      process.exit(1);
    }
    if (getCliSupportStatus(selectedCli) === 'unsupported') {
      console.error(`Error: CLI '${options.cli}' is marked unsupported.`);
      process.exit(1);
    }
  } else if (clis.length === 1) {
    selectedCli = clis[0];
  } else {
    let defaultIdx = clis.findIndex(c => c.id === rememberedCliId);
    if (defaultIdx === -1) defaultIdx = 0;

    const selection = await selectMenuItem(
      'Available CLIs:',
      clis,
      defaultIdx,
      (cli) => {
        const status = getCliSupportStatus(cli);
        const suffix = status === 'partial' ? ' [partial]' : '';
        return `${cli.name} (${cli.id})${suffix}`;
      }
    );
    selectedCli = selection.item;
  }

  console.log(`Selected CLI: ${selectedCli.name} (${selectedCli.id})`);

  // --- 2. Provider Selection ----------------------------------------------
  let selectedProvider = null;
  if (options.provider === '+') {
    selectedProvider = await invokeAddProviderFlow(selectedCli, dataDir);
  } else if (options.provider) {
    selectedProvider = config.providers.find(p => p.id === options.provider);
    if (!selectedProvider) {
      console.error(`Error: Unknown provider '${options.provider}'.`);
      process.exit(1);
    }
  } else {
    let defaultIdx = config.providers.findIndex(p => p.id === rememberedProviderId);
    if (defaultIdx === -1) defaultIdx = 0;

    const menuItems = options.dryRun
      ? [...config.providers]
      : [...config.providers, { id: '+', name: 'Add a new provider...' }];
    const selection = await selectMenuItem(
      'Available providers:',
      menuItems,
      defaultIdx,
      (item) => item.id === '+' ? `\x1b[36m${item.name}\x1b[0m` : `${item.name} (${item.id})`
    );

    if (selection.item.id === '+') {
      selectedProvider = await invokeAddProviderFlow(selectedCli, dataDir);
    } else {
      selectedProvider = selection.item;
    }
  }

  // --- 3. Base URL & API Key Resolution ----------------------------------
  let baseUrl = options.baseUrl || selectedProvider.baseUrl || '';
  if (!baseUrl) {
    baseUrl = await readInput('Base URL', selectedProvider.baseUrl || '');
  }
  baseUrl = baseUrl.trim().replace(/\/+$/, '');
  if (!baseUrl) {
    console.error('Error: No base URL could be determined.');
    process.exit(1);
  }

  const keyEnvName = getApiKeyEnvName(selectedProvider);
  let envApiKey = resolveEnvValue(selectedProvider.apiKeyEnvNames || selectedProvider.apiKeyEnv);
  let apiKey = options.apiKey || envApiKey || '';
  let fromPrompt = false;

  // A dry run reports key presence but never prompts or performs network I/O.
  if (!options.dryRun && !apiKey && selectedProvider.apiKeyRequired !== false) {
    if (process.stdin.isTTY) {
      apiKey = await readMaskedPrompt(`API key for '${selectedProvider.name}': `);
      if (apiKey) {
        fromPrompt = true;
      } else {
        console.error(`Error: API key is required for provider '${selectedProvider.name}'.`);
        process.exit(1);
      }
    } else {
      console.error(`Error: Provider '${selectedProvider.name}' requires an API key, but none was provided via --api-key or environment variable.`);
      process.exit(1);
    }
  }

  // --- 4. Model Fetch & Cache Update --------------------------------------
  let availableModels = [];
  const ttl = selectedProvider.modelCacheTtlSeconds ?? 3600;

  const apiPath = selectedProvider.modelsApi?.path || '/models';
  if (Array.isArray(selectedProvider.models) && selectedProvider.models.length > 0) {
    availableModels = selectedProvider.models
      .filter(model => typeof model === 'string' || model?.available !== false)
      .map(model => typeof model === 'string' ? model.trim() : String(model.id || '').trim())
      .filter(Boolean);
  } else {
    const cacheEntry = readCache(dataDir)?.caches?.[selectedProvider.id];
    const identityMatches = cacheIdentityMatches(cacheEntry, baseUrl, apiPath);
    const cachedModels = identityMatches && Array.isArray(cacheEntry?.models)
      ? cacheEntry.models.filter(model => model.available !== false).map(model => model.id)
      : [];
    const isFresh = testModelCacheFresh(
      selectedProvider.id,
      selectedProvider,
      dataDir,
      { baseUrl, apiPath }
    );

    if (options.dryRun) {
      availableModels = cachedModels;
      if (availableModels.length > 0) console.log('Dry run: using the matching cached model list without refreshing it.');
    } else if (isFresh && !options.refresh && cachedModels.length > 0) {
      availableModels = cachedModels;
      console.log(`Using cached models for ${selectedProvider.id} (ttl=${ttl}s)`);
    } else {
      console.log(`Fetching models from ${baseUrl}...`);
      let fetchedModelIds = [];
      try {
        fetchedModelIds = await fetchModels(selectedProvider, baseUrl, apiKey);
      } catch (err) {
        if (!options.refresh && cachedModels.length > 0) {
          availableModels = cachedModels;
          console.warn(`Warning: model refresh failed; using stale cache for '${selectedProvider.id}': ${err.message}`);
        } else {
          console.error(`Error fetching models: ${err.message}`);
          process.exit(1);
        }
      }

      if (availableModels.length === 0 && fetchedModelIds.length === 0) {
        console.error('Error: No models were returned by the provider.');
        process.exit(1);
      }

      if (fetchedModelIds.length > 0) {
        const updatedList = updateCacheForProvider(selectedProvider.id, baseUrl, apiPath, fetchedModelIds, dataDir);
        availableModels = updatedList.filter(model => model.available !== false).map(model => model.id);
        console.log(`Saved ${availableModels.length} models to models-cache.json`);
      }
    }
  }

  // --- 5. Model Selection & Dynamic Map Building --------------------------
  const envModel = resolveEnvValue(selectedCli.modelEnvName);
  const providerChanged = rememberedProviderId && selectedProvider.id !== rememberedProviderId;
  const chosenModel = resolveChosenModel(options.model, envModel, rememberedModel, availableModels, providerChanged);

  const resolvedCliArgs = resolveCliArgs(selectedCli, selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id);
  const resolvedLaunchArgs = [...resolvedCliArgs, ...options.passthroughArgs];

  const envMap = buildRuntimeEnvMap(selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id, selectedCli);
  envMap.BYOK_CLI_HUB_DATA_DIR = dataDir;
  const sensitiveKeys = getSensitiveEnvKeys(envMap, apiKey);

  // --- 6. Save State ------------------------------------------------------
  const newState = {
    cliId: selectedCli.id,
    cliName: selectedCli.name,
    providerId: selectedProvider.id,
    providerName: selectedProvider.name,
    providerType: selectedProvider.type || 'openai',
    baseUrl,
    model: chosenModel,
    apiKeySource: getApiKeySource(keyEnvName, fromPrompt, Boolean(options.apiKey), apiKey),
    updatedAt: new Date().toISOString()
  };
  if (!options.dryRun) writeState(newState, dataDir);

  // --- 7. Display a redacted environment plan -----------------------------
  console.log(`\n\x1b[36mBYOK Environment Variables:\x1b[0m`);
  for (const [k, v] of Object.entries(envMap)) {
    if (sensitiveKeys.has(k)) {
      console.log(`  ${k}=${v ? '[set]' : '[not set]'}`);
    } else {
      console.log(`  ${k}=${v}`);
    }
  }
  console.log('');

  if (options.refresh) {
    console.log('Model cache refresh complete.');
    return;
  }

  // --- 8. Launch CLI ------------------------------------------------------
  const command = selectedCli.command || 'copilot';
  const exitCode = await launchCli(command, resolvedLaunchArgs, envMap, {
    dryRun: options.dryRun,
    sensitiveKeys
  });

  process.exit(exitCode);
}

main().catch(err => {
  console.error(`${err instanceof UsageError ? 'Usage error' : 'Manager error'}: ${err.message}`);
  process.exit(err.exitCode || 1);
});
