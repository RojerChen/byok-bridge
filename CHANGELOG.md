# Changelog

All notable changes to this project will be documented in this file.

The format is intentionally simple and follows a lightweight `Keep a Changelog` style.

## [0.0.2] - 2026-07-24

### Added

- First supported Linux/WSL2 release, using the Node.js 22 Manager and transactional Bash installer/uninstaller.
- Versioned ownership manifests, managed shim/extension markers, safe-path checks, overlap guards, and confirmed data purge on Windows and Linux.
- Windows uninstaller with data preservation by default.
- Isolated Windows `0.0.1` migration, rollback, unknown-owner, and malformed-config fixtures.
- PowerShell HTTP security tests and Node/PowerShell concurrent cache/stale-lock recovery tests.
- Platform-aware `npm test` orchestration, shared Node/PowerShell config contract fixtures, and Windows/Ubuntu CI jobs.

### Changed

- Windows application files now install to `%LOCALAPPDATA%\byok-cli-hub\app`; mutable data remains in `%USERPROFILE%\.byok-cli-hub`.
- Installed-mode upgrades are performed by rerunning the installer from newer release source. Repo-mode upgrades continue to use `git pull` or a release tag.
- Both installers stage and validate the new snapshot, then use backup/switch/rollback transactions for application and optional extension updates.
- Copilot extension installation is opt-in for fresh installs. Existing managed choices are preserved during update.
- Config, state, and cache now use the canonical `<data-dir>` root and compatible locked atomic storage across Node, PowerShell, and the extension.
- Dry-run is read-only: it cannot add providers, migrate config, fetch models, update state/cache, or launch a child process.

### Fixed

- Node and PowerShell now distinguish live, dead, and unreadable stale locks, honor lock deadlines under Windows exclusive sharing, and consistently clean up lock descriptors.
- PowerShell model discovery now applies one deadline to headers and the complete response body, uses structured domain-error tagging, and accepts valid empty root or nested model arrays.
- Windows and Linux installation rollback now restores installer-created or replaced data files. Windows also restores partially moved `0.0.1` files if migration fails in the middle of the move loop.
- Managed updates reject silent data/shim/extension path relocation that could leave orphaned managed files; relocation requires uninstalling and reinstalling.
- Node and PowerShell config validation now agree on command paths, header/prefix types, and `modelsApi.path` restrictions.

### Windows 0.0.1 upgrade

- Recognizable public `0.0.1` installations are migrated automatically after semantic config validation.
- The legacy `config\providers.json`, `state.json`, `models-cache.json`, and unknown user files are preserved.
- Legacy application files are removed by an explicit allowlist; the user `PATH` moves from the data directory to the new application directory.
- A recognizable `0.0.1` Copilot extension is adopted as enabled. Unknown extension content is preserved without ownership.
- A failed migration restores the legacy launcher/files, extension, canonical-config creation, and the exact previous user `PATH`.

### Security

- PowerShell model discovery now rejects credentials/query/fragment URLs and redirects, enforces status/content-type and a 2 MiB response limit, and validates/deduplicates model IDs.
- Manifest paths are revalidated before destructive operations; unknown application, shim, and extension owners are never silently overwritten or removed.
- Storage updates use a common lock contract, atomic replacement, damaged-file preservation, PID-aware stale-lock recovery, and locked read-modify-write transactions.
- Shell env export/temp-file secret flows were removed; credentials are passed only through the launched child environment and redacted in output.

### Notes

- Linux/WSL support begins at `0.0.2`; no public Linux `0.0.1` migration is claimed.

## [0.0.1] - 2026-07-21

Initial public baseline for BYOK CLI Hub.

### Added

- CLI launcher flow for selecting a provider and model at startup.
- Provider configuration support via `config/providers.json`.
- Example provider configuration in `config/providers.example.json`.
- PowerShell manager scripts for starting the hub and refreshing model data.
- Copilot extension entry point for switching models inside Copilot CLI.
- Local state and model cache handling for runtime data.
- `byok-cli-hub` command shim for launching from CMD or PowerShell after installation.
- Per-user `PATH` setup and removal helper, with `BYOK_CLI_HUB_SKIP_PATH_UPDATE=1` as an opt-out.

### Changed

- The installer now preserves an existing user `providers.json` during reinstall or upgrade.
- Installation failures now return a non-zero exit code instead of continuing with a success message.
- Installation output now distinguishes the local installed launcher from the repository development launcher.
- Documentation now identifies GitHub Copilot CLI 1.0.73 as the verified version and marks the extension integration as experimental.
- Required command and PowerShell module files under `bin/` and `manager/` are included in source control.

### Notes

- `providers.json` is intended to be a local, user-specific configuration file.
- Runtime files such as `state.json` and `models-cache.json` are ignored by git.
- Version `0.0.1` is distributed as a source-based Windows utility, not as an npm or NuGet package.
