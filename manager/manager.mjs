#!/usr/bin/env node

import process from 'node:process';
import path from 'node:path';
import { getByokDataDir, readState, writeState, readCache } from './lib/state.mjs';
import { loadProviderConfig, addProvider } from './lib/config.mjs';
import {
  resolveCliArgs,
  buildRuntimeEnvMap,
  resolveEnvValue,
  getApiKeyEnvName,
  getCliSupportStatus,
  resolveChosenModel,
  getApiKeySource
} from './lib/env.mjs';
import { fetchModels } from './lib/http.mjs';
import { readMaskedPrompt, readInput, selectMenuItem } from './lib/prompt.mjs';
import { launchCli } from './lib/launcher.mjs';

function parseArgs(argv) {
  const options = {
    cli: null,
    provider: null,
    baseUrl: null,
    apiKey: null,
    model: null,
    refresh: false,
    dryRun: false,
    emitEnv: false,
    selfCheck: false,
    dataDir: null,
    passthroughArgs: []
  };

  const passthroughIdx = argv.indexOf('--');
  let mainArgs = argv;
  if (passthroughIdx !== -1) {
    mainArgs = argv.slice(0, passthroughIdx);
    options.passthroughArgs = argv.slice(passthroughIdx + 1);
  }

  for (let i = 0; i < mainArgs.length; i++) {
    const arg = mainArgs[i];
    if (arg === '--cli' && i + 1 < mainArgs.length) {
      options.cli = mainArgs[++i];
    } else if (arg === '--provider' && i + 1 < mainArgs.length) {
      options.provider = mainArgs[++i];
    } else if (arg === '--base-url' && i + 1 < mainArgs.length) {
      options.baseUrl = mainArgs[++i];
    } else if (arg === '--api-key' && i + 1 < mainArgs.length) {
      options.apiKey = mainArgs[++i];
    } else if (arg === '--model' && i + 1 < mainArgs.length) {
      options.model = mainArgs[++i];
    } else if (arg === '--data-dir' && i + 1 < mainArgs.length) {
      options.dataDir = mainArgs[++i];
    } else if (arg === '--refresh') {
      options.refresh = true;
    } else if (arg === '--dry-run') {
      options.dryRun = true;
    } else if (arg === '--emit-env' || arg === '--export') {
      options.emitEnv = true;
    } else if (arg === '--self-check') {
      options.selfCheck = true;
    } else if (arg === '--help' || arg === '-h') {
      printHelp();
      process.exit(0);
    }
  }

  return options;
}

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
  --emit-env        Output export KEY="VALUE" lines for shell without launching
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
  const dataDir = getByokDataDir(options.dataDir);

  if (options.selfCheck) {
    await runSelfCheck(dataDir);
    return;
  }

  const config = loadProviderConfig(dataDir);
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

    const menuItems = [...config.providers, { id: '+', name: 'Add a new provider...' }];
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

  // Strict API key enforcement for providers requiring a key
  if (!apiKey && selectedProvider.apiKeyRequired !== false) {
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

  if (Array.isArray(selectedProvider.models) && selectedProvider.models.length > 0) {
    availableModels = selectedProvider.models;
  } else {
    const cacheEntry = readCache(dataDir)?.caches?.[selectedProvider.id];
    const isFresh = cacheEntry && cacheEntry.updatedAt && (Date.now() - new Date(cacheEntry.updatedAt).getTime()) < (ttl * 1000);

    if (isFresh && !options.refresh && Array.isArray(cacheEntry.models) && cacheEntry.models.length > 0) {
      availableModels = cacheEntry.models
        .filter(m => (typeof m === 'string' ? true : m?.available !== false))
        .map(m => (typeof m === 'string' ? m : m.id));
      console.log(`Using cached models for ${selectedProvider.id} (ttl=${ttl}s)`);
    } else {
      console.log(`Fetching models from ${baseUrl}...`);
      let fetchedModelIds = [];
      try {
        fetchedModelIds = await fetchModels(selectedProvider, baseUrl, apiKey);
      } catch (err) {
        console.error(`Error fetching models from ${baseUrl}: ${err.message}`);
        process.exit(1);
      }

      if (fetchedModelIds.length === 0) {
        console.error('Error: No models were returned by the provider.');
        process.exit(1);
      }

      const { updateCacheForProvider } = await import('./lib/state.mjs');
      const updatedList = updateCacheForProvider(selectedProvider.id, baseUrl, selectedProvider.modelsApi?.path || '/models', fetchedModelIds, dataDir);
      availableModels = updatedList.map(m => m.id);
      console.log(`Saved ${availableModels.length} models to models-cache.json`);
    }
  }

  // --- 5. Model Selection & Dynamic Map Building --------------------------
  const envModel = resolveEnvValue(selectedCli.modelEnvName);
  const providerChanged = rememberedProviderId && selectedProvider.id !== rememberedProviderId;
  const chosenModel = resolveChosenModel(options.model, envModel, rememberedModel, availableModels, providerChanged);

  const resolvedCliArgs = resolveCliArgs(selectedCli, selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id);
  const resolvedLaunchArgs = [...resolvedCliArgs, ...options.passthroughArgs];

  const envMap = buildRuntimeEnvMap(selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id, selectedCli);

  // --- 6. Save State ------------------------------------------------------
  const newState = {
    cliId: selectedCli.id,
    cliName: selectedCli.name,
    providerId: selectedProvider.id,
    providerName: selectedProvider.name,
    providerType: selectedProvider.type || 'openai',
    baseUrl,
    model: chosenModel,
    apiKeySource: getApiKeySource(keyEnvName, fromPrompt),
    updatedAt: new Date().toISOString()
  };
  writeState(newState, dataDir);

  // --- 7. Handle --emit-env mode or Log Environment Map ------------------
  if (options.emitEnv) {
    for (const [k, v] of Object.entries(envMap)) {
      const escaped = String(v).replace(/"/g, '\\"');
      console.log(`export ${k}="${escaped}"`);
    }
    process.exit(0);
  }

  console.log(`\n\x1b[36mApplied BYOK Environment Variables:\x1b[0m`);
  for (const [k, v] of Object.entries(envMap)) {
    if (k.includes('KEY') || k.includes('TOKEN') || k.includes('SECRET')) {
      console.log(`  export ${k}="${apiKey ? '*'.repeat(Math.max(8, apiKey.length)) : '[not set]'}"`);
    } else {
      console.log(`  export ${k}="${v}"`);
    }
  }
  console.log('');

  // --- 8. Launch CLI ------------------------------------------------------
  const command = selectedCli.command || 'copilot';
  const exitCode = await launchCli(command, resolvedLaunchArgs, envMap, {
    dryRun: options.dryRun,
    refresh: options.refresh
  });

  process.exit(exitCode);
}

main().catch(err => {
  console.error('Unhandled Manager Error:', err.message);
  process.exit(1);
});
