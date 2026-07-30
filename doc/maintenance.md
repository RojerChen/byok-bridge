# Removal and development

## Removal

### Windows

From the repository or installed application directory:

```bat
bin\win\uninstall.cmd
```

The default removes the managed application, PATH entry, and manifest-owned extension while preserving `%USERPROFILE%\.byok-cli-hub`. To delete user config/state/cache too:

```bat
bin\win\uninstall.cmd -PurgeData
```

Use `-Yes` only for an intentional non-interactive purge.

### Linux / WSL2

```bash
bash bin/linux/uninstall.sh
bash bin/linux/uninstall.sh --purge-data
# Non-interactive intentional purge:
bash bin/linux/uninstall.sh --purge-data --yes
```

The uninstaller reads the managed manifest, removes only the owned application snapshot (including its Bash library), executable shim, optional extension, and managed `.bashrc` block, and preserves unrelated `.bashrc` content and user data by default. It also removes a former `<bin-dir>/byok-cli-hub-shell` only when the old manifest and file marker both prove ownership. A pre-manifest install requires `--force-legacy` and recognizable BYOK CLI Hub files. Functions already loaded in the current terminal remain available until you run `byok-cli-hub-shell-unload` or close that terminal.

Neither uninstaller removes GitHub Copilot CLI or any other separately installed AI CLI.

## Development and verification

```text
# Run every test supported by the current OS:
npm test

# Cross-platform Node tests only:
npm run test:node

# Granular Windows suites:
npm run smoke
npm run test:powershell-http
npm run test:windows-installer
npm run test:all:windows

# Linux installer or aggregate suite:
npm run test:linux-shell
npm run test:linux-installer
npm run test:all:linux
```

`npm test` is platform-aware: Windows runs Node, PowerShell smoke/HTTP, caller-CMD, and Windows installer suites; Linux runs Node, caller-shell integration, and Linux installer suites. The Windows and Ubuntu jobs in `.github/workflows/test.yml` run this same entry point in CI.

The tests cover the shared Node/PowerShell config contract, OpenCode config generation and launch loading, damaged-file preservation, endpoint-scoped cache freshness, bounded HTTP reads and stalled-body deadlines, header-injection rejection and API-key-safe errors, strict arguments, redaction, side-effect-free dry-run, active and abandoned cross-runtime locks, caller-shell environment apply/switch/deactivate behavior, FD protocol validation, xtrace redaction, Windows `0.0.1` migration and rollback, managed-path relocation guards, and Windows/Linux data-aware installation transactions.
