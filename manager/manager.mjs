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
  buildAdapterRuntimeEnvMap,
  resolveEnvValue,
  getApiKeyEnvName,
  getCliSupportStatus,
  resolveChosenModel,
  resolveChosenModelSelection,
  getApiKeySource,
  getSensitiveEnvKeys
} from './lib/env.mjs';
import { parseArgs, UsageError } from './lib/args.mjs';
import { fetchModels, getSafeModelFetchErrorMessage, canUseStaleCacheForModelFetchError } from './lib/http.mjs';
import {
  InputCancelledError,
  NonInteractiveInputError,
  readMaskedPrompt,
  readInput,
  readNumberSelection
} from './lib/prompt.mjs';
import {
  loadUiResources,
  renderUiHeader,
  renderUiStep,
  renderUiChoices,
  renderUiProviderChoices,
  renderUiSelectionSummary,
  renderUiStatus,
  renderUiError,
  renderUiSummary,
  uiMessage
} from './lib/ui.mjs';
import { isExecutableInPath, launchCli } from './lib/launcher.mjs';
import { writeShellPlan } from './lib/shell-plan.mjs';
import {
  OPENCODE_ADAPTER,
  OPENCODE_API_KEY_ENV,
  OPENCODE_CONFIG_ENV,
  buildOpenCodeConfig,
  getOpenCodeConfigPath,
  getOpenCodeProviderId,
  writeOpenCodeConfig
} from './lib/opencode.mjs';

let uiForErrors = null;

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
  --no-clear        Keep prior screens instead of clearing an interactive terminal
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
    return 1;
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
    return 1;
  }

  console.log('[SELF-CHECK] All preflight checks passed.');
  return 0;
}

function emitShellPlan(options, plan) {
  if (options.internalShellPlanFd !== null) {
    writeShellPlan(Number(options.internalShellPlanFd), plan);
  }
}

function throwRenderedUiError(ui, messageId, values = {}) {
  renderUiError(ui, messageId, values);
  const error = new Error(uiMessage(ui, 'errors', messageId, values));
  error.uiRendered = true;
  throw error;
}

async function invokeAddProviderFlow(ui, selectedCli, dataDir) {
  console.log('');
  console.log(`--- ${uiMessage(ui, 'prompts', 'addProvider')} ---`);
  const name = await readInput(uiMessage(ui, 'prompts', 'providerName'));
  if (!name) throwRenderedUiError(ui, 'providerNameRequired');

  const url = await readInput(uiMessage(ui, 'prompts', 'baseUrl'));
  if (!url) throwRenderedUiError(ui, 'baseUrlRequired');

  const key = await readMaskedPrompt(`${uiMessage(ui, 'prompts', 'optionalApiKey')}: `);
  const result = addProvider(name, url, key, selectedCli, dataDir);
  console.log(`${ui.theme.symbols.success} Provider '${name}' added.`);

  if (key) {
    process.env[result.apiKeyEnvName] = key;
  }

  const freshConfig = loadProviderConfig(dataDir);
  const newProv = freshConfig.providers.find(p => p.id === result.id);
  if (!newProv) throw new Error('Failed to reload newly added provider.');
  return newProv;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    printHelp();
    emitShellPlan(options, { action: 'none' });
    return 0;
  }
  const dataDir = getByokDataDir(options.dataDir);

  if (options.selfCheck) {
    const exitCode = await runSelfCheck(dataDir);
    if (exitCode === 0) emitShellPlan(options, { action: 'none' });
    return exitCode;
  }

  // The shared UI files are loaded before any renderer-owned output or
  // interactive prompt. Their location is anchored to the installed app root.
  const ui = loadUiResources();
  uiForErrors = ui;
  const interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY);
  const transcriptMode = options.noClear || /^(1|true|yes)$/i.test(process.env.BYOK_UI_HISTORY || '');
  let headerRendered = false;
  let showedInteractiveScreen = false;
  const beginInteractive = ({ cli = null, provider = null } = {}) => {
    if (!interactive) throw new NonInteractiveInputError();
    showedInteractiveScreen = true;
    if (!transcriptMode) {
      console.clear();
      renderUiHeader(ui);
      headerRendered = true;
      if (cli || provider) console.log('');
      renderUiSelectionSummary(ui, { cli, provider });
    } else if (!headerRendered) {
      renderUiHeader(ui);
      headerRendered = true;
    }
  };

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

  const selectCliInteractively = async () => {
    beginInteractive();
    const defaultIndex = Math.max(0, clis.findIndex(cli => cli.id === rememberedCliId));
    renderUiStep(ui, 1, ui.messages.app.steps.selectCli);
    renderUiChoices(ui, clis.map((cli) => {
      const suffix = getCliSupportStatus(cli) === 'partial' ? ' [partial]' : '';
      return `${cli.name}${suffix}`;
    }), defaultIndex, { includeExit: true });
    const selectedNumber = await readNumberSelection(
      uiMessage(ui, 'prompts', 'selectCli', { min: 1, max: clis.length, default: defaultIndex + 1 }),
      0,
      clis.length,
      defaultIndex + 1,
      { onInvalid: () => renderUiError(ui, 'invalidSelection') }
    );
    console.log('');
    if (selectedNumber === 0) return { exit: true };
    return clis[selectedNumber - 1];
  };

  const selectProviderInteractively = async () => {
    beginInteractive({ cli: selectedCli.name });
    const defaultIndex = Math.max(0, config.providers.findIndex(provider => provider.id === rememberedProviderId));
    const items = [
      ...config.providers,
      ...(options.dryRun ? [] : [{ id: '+', name: uiMessage(ui, 'prompts', 'addProvider') }]),
      { id: '__exit', name: uiMessage(ui, 'prompts', 'exit') }
    ];
    renderUiStep(ui, 2, ui.messages.app.steps.selectProvider);
    renderUiProviderChoices(ui, config.providers.map(provider => provider.name), defaultIndex, {
      includeAdd: !options.dryRun,
      includeExit: true
    });
    const selectedNumber = await readNumberSelection(
      uiMessage(ui, 'prompts', 'selectProvider', { min: 1, max: items.length, default: defaultIndex + 1 }),
      0,
      items.length,
      defaultIndex + 1,
      { onInvalid: () => renderUiError(ui, 'invalidSelection') }
    );
    console.log('');
    if (selectedNumber === 0) return { back: true };
    return { item: items[selectedNumber - 1] };
  };

  let selectedCli = null;
  let selectedProvider = null;
  let cliStatusReported = false;
  const reportSelectedCli = () => {
    if (!cliStatusReported) {
      renderUiStatus(ui, 'selectedCli', { cli: selectedCli.name });
      cliStatusReported = true;
    }
  };
  if (options.cli) {
    selectedCli = config.clis.find(c => c.id === options.cli);
    if (!selectedCli) throw new Error(`Unknown CLI '${options.cli}'.`);
    if (getCliSupportStatus(selectedCli) === 'unsupported') throw new Error(`CLI '${options.cli}' is marked unsupported.`);
  }

  // Back renders the preceding CLI step below the current provider block.
  // An explicitly supplied CLI cannot be changed, so Back repeats its compact
  // status before allowing the provider to be selected again.
  while (!selectedProvider) {
    if (!selectedCli) {
      if (clis.length === 1) {
        selectedCli = clis[0];
      } else {
        const result = await selectCliInteractively();
        if (result.exit) {
          renderUiStatus(ui, 'exited');
          emitShellPlan(options, { action: 'none' });
          return 0;
        }
        selectedCli = result;
      }
      cliStatusReported = false;
    }

    reportSelectedCli();

    if (options.provider === '+') {
      beginInteractive({ cli: selectedCli.name });
      selectedProvider = await invokeAddProviderFlow(ui, selectedCli, dataDir);
    } else if (options.provider) {
      selectedProvider = config.providers.find(p => p.id === options.provider);
      if (!selectedProvider) throw new Error(`Unknown provider '${options.provider}'.`);
    } else {
      const result = await selectProviderInteractively();
      if (result.back) {
        if (options.cli) {
          renderUiStatus(ui, 'selectedCli', { cli: selectedCli.name });
        } else {
          selectedCli = null;
          cliStatusReported = false;
        }
        continue;
      }
      if (result.item.id === '__exit') {
        renderUiStatus(ui, 'exited');
        emitShellPlan(options, { action: 'none' });
        return 0;
      }
      selectedProvider = result.item.id === '+'
        ? await invokeAddProviderFlow(ui, selectedCli, dataDir)
        : result.item;
    }
    renderUiStatus(ui, 'selectedProvider', { provider: selectedProvider.name });
  }

  // --- 3. Base URL & API Key Resolution ----------------------------------
  let baseUrl = options.baseUrl || selectedProvider.baseUrl || '';
  if (!baseUrl) {
    beginInteractive({ cli: selectedCli.name, provider: selectedProvider.name });
    baseUrl = await readInput(uiMessage(ui, 'prompts', 'baseUrl'), selectedProvider.baseUrl || '');
  }
  baseUrl = baseUrl.trim().replace(/\/+$/, '');
  if (!baseUrl) {
    throwRenderedUiError(ui, 'baseUrlRequired');
  }

  const keyEnvName = getApiKeyEnvName(selectedProvider);
  let envApiKey = resolveEnvValue(selectedProvider.apiKeyEnvNames || selectedProvider.apiKeyEnv);
  let apiKey = options.apiKey || envApiKey || '';
  let fromPrompt = false;

  // A dry run reports key presence but never prompts or performs network I/O.
  if (!options.dryRun && !apiKey && selectedProvider.apiKeyRequired !== false) {
    if (interactive) {
      beginInteractive({ cli: selectedCli.name, provider: selectedProvider.name });
      apiKey = await readMaskedPrompt(`${uiMessage(ui, 'prompts', 'apiKey', { provider: selectedProvider.name })}: `);
      if (apiKey) {
        fromPrompt = true;
      } else {
        throwRenderedUiError(ui, 'apiKeyRequired', { provider: selectedProvider.name });
      }
    } else {
      throw new NonInteractiveInputError();
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
        const safeMessage = getSafeModelFetchErrorMessage(err, apiKey);
        if (!options.refresh && cachedModels.length > 0 && canUseStaleCacheForModelFetchError(err)) {
          availableModels = cachedModels;
          console.warn(`Warning: model refresh failed; using stale cache for '${selectedProvider.id}': ${safeMessage}`);
        } else {
          console.error(`Error fetching models: ${safeMessage}`);
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
  const isOpenCode = selectedCli.adapter === OPENCODE_ADAPTER;
  const modelSelection = isOpenCode
    ? resolveChosenModelSelection(options.model, envModel, rememberedModel, availableModels, providerChanged)
    : {
        model: resolveChosenModel(options.model, envModel, rememberedModel, availableModels, providerChanged),
        source: options.model ? 'option' : (envModel ? 'environment' : 'state-or-fallback')
      };
  const chosenModel = modelSelection.model;
  if (!chosenModel) {
    console.error('Error: No model is available. Run again with --refresh or specify --model explicitly.');
    process.exit(1);
  }

  const resolvedCliArgs = resolveCliArgs(selectedCli, selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id);
  const resolvedLaunchArgs = [...resolvedCliArgs, ...options.passthroughArgs];

  const envMap = isOpenCode
    ? buildAdapterRuntimeEnvMap(selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id, selectedCli)
    : buildRuntimeEnvMap(selectedProvider, baseUrl, chosenModel, apiKey, selectedProvider.id, selectedCli);
  envMap.BYOK_CLI_HUB_DATA_DIR = dataDir;
  let openCodeOutput = null;
  let openCodeConfigPath = null;
  if (isOpenCode && !options.refresh) {
    openCodeConfigPath = getOpenCodeConfigPath(dataDir, selectedCli.configFileName);
    openCodeOutput = buildOpenCodeConfig(selectedCli.template, {
      providerId: selectedProvider.id,
      providerName: selectedProvider.name,
      baseUrl,
      apiKey,
      apiKeyRequired: selectedProvider.apiKeyRequired,
      availableModels,
      chosenModel,
      chosenModelSource: modelSelection.source
    });
    envMap[OPENCODE_CONFIG_ENV] = openCodeConfigPath;
    if (apiKey) envMap[OPENCODE_API_KEY_ENV] = apiKey;
  }
  const sensitiveKeys = getSensitiveEnvKeys(envMap, apiKey);
  if (isOpenCode && Object.hasOwn(envMap, OPENCODE_API_KEY_ENV)) sensitiveKeys.add(OPENCODE_API_KEY_ENV);

  // --- 6. Save State ------------------------------------------------------
  const newState = {
    cliId: selectedCli.id,
    cliName: selectedCli.name,
    providerId: selectedProvider.id,
    providerName: selectedProvider.name,
    providerType: selectedProvider.type || 'openai',
    baseUrl,
    model: chosenModel,
    modelSource: modelSelection.source,
    ...(isOpenCode ? {
      runtimeProviderId: openCodeOutput?.runtimeProviderId || getOpenCodeProviderId(selectedProvider.id),
      runtimeConfigType: OPENCODE_ADAPTER
    } : {}),
    apiKeySource: getApiKeySource(keyEnvName, fromPrompt, Boolean(options.apiKey), apiKey),
    updatedAt: new Date().toISOString()
  };

  const command = selectedCli.command || 'copilot';
  const shouldLaunch = !options.dryRun && !options.refresh;
  if (shouldLaunch && !isExecutableInPath(command)) {
    console.error(`Error: The command '${command}' was not found in PATH.`);
    console.error(`Please ensure '${command}' is installed and accessible in your environment.`);
    return 5;
  }
  if (shouldLaunch && isOpenCode) {
    writeOpenCodeConfig(openCodeConfigPath, openCodeOutput.config);
    console.log(`Generated OpenCode config: ${openCodeConfigPath}`);
    console.log(`OpenCode runtime provider: ${openCodeOutput.runtimeProviderId} (${openCodeOutput.models.length} models)`);
  }
  if (!options.dryRun) {
    writeState(newState, dataDir);
    if (!transcriptMode && showedInteractiveScreen) {
      beginInteractive({ cli: selectedCli.name, provider: selectedProvider.name });
    }
    renderUiStatus(ui, 'configurationApplied');
  }

  // --- 7. Display a redacted environment plan -----------------------------
  renderUiSummary(ui, selectedProvider.name, chosenModel, apiKey, selectedProvider.apiKeyRequired);
  if (isOpenCode) {
    const keyStatus = apiKey ? '[set]' : (selectedProvider.apiKeyRequired === false ? '[not required]' : '[missing]');
    console.log(`OpenCode API key: ${keyStatus}`);
  }
  console.log('\nBYOK Environment Variables:');
  for (const [k, v] of Object.entries(envMap)) {
    if (sensitiveKeys.has(k)) {
      const missingRequiredOpenCodeKey = isOpenCode
        && k === OPENCODE_API_KEY_ENV
        && !v
        && selectedProvider.apiKeyRequired !== false;
      console.log(`  ${k}=${missingRequiredOpenCodeKey ? '[missing]' : (v ? '[set]' : '[not set]')}`);
    } else {
      console.log(`  ${k}=${v}`);
    }
  }
  console.log('');

  if (options.refresh) {
    console.log('Model cache refresh complete.');
    emitShellPlan(options, { action: 'none' });
    return 0;
  }

  // --- 8. Launch CLI ------------------------------------------------------
  if (options.dryRun) {
    const exitCode = await launchCli(command, resolvedLaunchArgs, envMap, {
      dryRun: true,
      sensitiveKeys
    });
    emitShellPlan(options, { action: 'none' });
    return exitCode;
  }

  if (options.internalShellPlanFd !== null) {
    renderUiStatus(ui, 'launching', { cli: selectedCli.name });
    emitShellPlan(options, {
      action: 'launch',
      command,
      args: resolvedLaunchArgs,
      environment: envMap
    });
    return 0;
  }

  renderUiStatus(ui, 'launching', { cli: selectedCli.name });
  const exitCode = await launchCli(command, resolvedLaunchArgs, envMap, {
    dryRun: false,
    sensitiveKeys
  });
  if (isOpenCode && exitCode !== 0) {
    console.error(`OpenCode exited with code ${exitCode}. Generated config: ${openCodeConfigPath}`);
    console.error('Check the merged configuration with: opencode debug config');
    console.error(`Check provider models with: opencode models ${openCodeOutput.runtimeProviderId}`);
  }
  return exitCode;
}

main().then(exitCode => {
  process.exitCode = exitCode ?? 0;
}).catch(err => {
  if (err instanceof InputCancelledError) {
    if (uiForErrors) renderUiError(uiForErrors, 'cancelled');
    else console.error('Operation cancelled.');
  } else if (!err?.uiRendered) {
    if (err instanceof NonInteractiveInputError) {
      console.error('Interactive selection is unavailable: provide --cli, --provider, --base-url, and any required API key through supported non-interactive inputs.');
    } else {
      console.error(`${err instanceof UsageError ? 'Usage error' : 'Manager error'}: ${err.message}`);
    }
  }
  process.exitCode = err.exitCode || 1;
});
