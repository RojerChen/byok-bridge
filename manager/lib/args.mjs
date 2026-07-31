export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = 'UsageError';
    this.exitCode = 2;
  }
}

const VALUE_OPTIONS = new Map([
  ['--cli', 'cli'],
  ['--provider', 'provider'],
  ['--base-url', 'baseUrl'],
  ['--api-key', 'apiKey'],
  ['--model', 'model'],
  ['--data-dir', 'dataDir'],
  ['--internal-shell-plan-fd', 'internalShellPlanFd'],
  ['--internal-cmd-plan-file', 'internalCmdPlanFile']
]);

const FLAG_OPTIONS = new Map([
  ['--refresh', 'refresh'],
  ['--dry-run', 'dryRun'],
  ['--self-check', 'selfCheck'],
  ['--no-clear', 'noClear']
]);

export function parseArgs(argv) {
  const options = {
    cli: null,
    provider: null,
    baseUrl: null,
    apiKey: null,
    model: null,
    refresh: false,
    dryRun: false,
    selfCheck: false,
    noClear: false,
    help: false,
    dataDir: null,
    internalShellPlanFd: null,
    internalCmdPlanFile: null,
    passthroughArgs: []
  };
  const seen = new Set();
  let passthrough = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (passthrough) {
      options.passthroughArgs.push(arg);
      continue;
    }
    if (arg === '--') {
      passthrough = true;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      if (seen.has('help')) throw new UsageError(`Option '${arg}' was provided more than once.`);
      seen.add('help');
      options.help = true;
      continue;
    }
    if (VALUE_OPTIONS.has(arg)) {
      const property = VALUE_OPTIONS.get(arg);
      if (seen.has(property)) throw new UsageError(`Option '${arg}' was provided more than once.`);
      const value = argv[index + 1];
      if (value === undefined || value === '' || value.startsWith('--')) {
        throw new UsageError(`Option '${arg}' requires a value.`);
      }
      seen.add(property);
      options[property] = value;
      index += 1;
      continue;
    }
    if (FLAG_OPTIONS.has(arg)) {
      const property = FLAG_OPTIONS.get(arg);
      if (seen.has(property)) throw new UsageError(`Option '${arg}' was provided more than once.`);
      seen.add(property);
      options[property] = true;
      continue;
    }
    throw new UsageError(`Unknown option '${arg}'. Use --help for usage.`);
  }

  if (options.internalShellPlanFd !== null && options.internalShellPlanFd !== '3') {
    throw new UsageError("Option '--internal-shell-plan-fd' only accepts the internal descriptor 3.");
  }
  if (options.internalCmdPlanFile !== null) {
    if (typeof options.internalCmdPlanFile !== 'string' || !options.internalCmdPlanFile.trim()) {
      throw new UsageError("Option '--internal-cmd-plan-file' requires a non-empty absolute path.");
    }
  }
  const semanticSeen = [...seen].filter(option => !['internalShellPlanFd', 'internalCmdPlanFile'].includes(option));
  if (options.help && semanticSeen.length > 1) throw new UsageError('--help cannot be combined with other options.');
  if (options.selfCheck) {
    const selfCheckOptions = new Set(['selfCheck', 'dataDir']);
    const hasLaunchOption = semanticSeen.some((option) => !selfCheckOptions.has(option));
    if (hasLaunchOption || options.passthroughArgs.length > 0) {
      throw new UsageError('--self-check cannot be combined with launch options.');
    }
  }
  if (options.refresh && options.dryRun) throw new UsageError('--refresh and --dry-run cannot be combined.');
  if (options.dryRun && options.provider === '+') {
    throw new UsageError("--dry-run cannot be combined with '--provider +', because adding a provider is a persistent change.");
  }
  return options;
}
