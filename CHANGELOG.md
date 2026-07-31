# Changelog

All notable changes to this project will be documented in this file.

The format is intentionally simple and follows a lightweight `Keep a Changelog` style.

## [0.1.0] - 2026-07-30

### Added

- Node.js-based Windows installer and uninstaller, with transactional application updates, managed-install compatibility, legacy-install detection, and user `PATH` management.
- A CMD execution-plan transport that lets the Windows launcher apply resolved provider, model, and runtime environment values to the calling CMD session before launching the selected CLI.
- OpenCode CLI support on Windows and Linux/WSL through the `opencode-config-v1` adapter.
- Atomic generation of `<data-dir>/opencode.json`, with deterministic runtime provider IDs, exact case-sensitive model maps, explicit model-selection provenance, and `OPENCODE_CONFIG` launch wiring.
- Cross-platform interactive wizard for selecting an AI coding CLI and BYOK provider, with shared theme and message resources.
- `--no-clear` and `BYOK_UI_HISTORY=true` options for retaining prior wizard screens.
- Node-manager, Windows-installer, dry-run, preflight-preservation, environment-scope, special-model-ID, and plaintext-secret regression coverage, including a documented behavior matrix.

### Changed

- Windows installation, uninstallation, and launch flows now use the Node.js manager; the previous PowerShell manager modules and entry-point scripts have been retired.
- Node.js 22 or later is now required on Windows as well as Linux and WSL2. Windows command shims validate this prerequisite and report a clear error when it is unavailable.
- The Windows launcher resolves the selected CLI executable before emitting its CMD execution plan, so the plan does not depend on later `PATH` changes in the caller session.
- Windows test commands now run the Node-based installer and behavior-matrix suites instead of the retired PowerShell test suites.
- Renamed the product from BYOK CLI Hub to BYOK Bridge. The public command is now `byok`, the package and repository slug are `byok-bridge`, environment variables use `BYOK_BRIDGE_*`, and default user data moves to `.byok-bridge`.
- A managed `0.0.3` installation is migrated once, transactionally, to the new application, data, command, Bash startup, extension, and Windows `PATH` names. No permanent old command or environment-variable alias is installed.
- The default and example provider configurations now include OpenCode alongside GitHub Copilot CLI.
- OpenCode templates now use `{api_key_ref}`, rendered as `{env:BYOK_BRIDGE_OPENCODE_API_KEY}`; the ambiguous `{api_key_env}` name is no longer accepted. The `{api_key}` placeholder remains reserved for assigning the plaintext key to runtime environment entries.
- Configured environment entries use the same semantics for every CLI: the selected CLI environment, provider-wide environment, selected provider CLI override, and configured API-key/model targets are all applied without filtering variable names.
- Runtime JSON writes reparse the flushed temporary file before atomic replacement. OpenCode generation is limited to 32 levels, 4096 unique models, and 8 MiB of UTF-8 JSON.
- Interactive startup now uses a clean two-step terminal UI; `NO_COLOR` and `BYOK_UI_COLOR=0` force plain-text output.

### Fixed

- During an interactive model refresh, an authentication failure without an API key now prompts for a key and retries once instead of immediately failing.
- The Windows installer now reports the exact existing `providers.json` path when strict JSON parsing or semantic validation fails, while preserving the invalid file unchanged.
- Restored the Windows `0.0.1` caller-CMD contract: resolved provider, model, API-key, and OpenCode runtime variables remain in the current console and can be reused by the next invocation.

### Security

- OpenCode config authentication uses `BYOK_BRIDGE_OPENCODE_API_KEY`; generated JSON contains an environment reference and never the plaintext key.
- Template validation rejects plaintext key placeholders, unknown Hub placeholders, misplaced typed placeholders, and rendered object-key collisions.

## [0.0.3] - 2026-07-29

### Added

- Linux/WSL Bash integration that applies the dynamically resolved Node launch environment to the current shell, launches the configured CLI, and retains the values until the next plan, deactivation, or terminal close.
- Versioned FD 3 shell-plan protocol, strict hex data parsing, caller-environment transaction/rollback, provider-switch cleanup, original-value restoration, and `byok-deactivate`/`byok-shell-unload` helpers.
- Managed installer ownership and rollback for the application-snapshot Bash library and automatic `~/.bashrc` startup block, plus Node, Bash session, xtrace, malformed-protocol, and installer regression coverage.

### Changed

- Moved the Bash source-only integration from `bin/linux/shell-integration.sh` to `shell/bash/byok.bash`, and the installer-internal profile tool from `bin/linux/bashrc-integration.mjs` to `libexec/linux/bash-profile-manager.mjs`.
- Linux installs now keep only the executable `byok` shim in `bin-dir`; the source library and profile manager are owned as part of the application snapshot.
- The Linux install manifest now lists only the external executable shim in `managedFiles`. Managed upgrades transactionally replace the `.bashrc` source path and remove the former owned `byok-shell`, while rollback restores the old application, startup block, shim, and helper.
- Unknown or unmarked files named `<bin-dir>/byok-shell` are preserved during update and uninstall. Windows launcher and installer paths are unchanged.

### Security

- The managed `.bashrc` block contains only fixed, shell-quoted library/shim paths and restoration metadata—never provider/model/API-key values. Shell integration uses no `eval` or secret-bearing regular temp file, rejects unsafe parent-shell variables, and keeps unredacted plan data off stdout/stderr. Explicit executable mode remains child-only.

## [0.0.2] - 2026-07-24

### Added

- First supported Linux/WSL2 release, using the Node.js 22 Manager and transactional Bash installer/uninstaller.
- Versioned ownership manifests, managed shim/extension markers, safe-path checks, overlap guards, and confirmed data purge on Windows and Linux.
- Windows uninstaller with data preservation by default.
- Isolated Windows `0.0.1` migration, rollback, unknown-owner, and malformed-config fixtures.
- PowerShell HTTP security tests and Node/PowerShell concurrent cache/stale-lock recovery tests.
- Platform-aware `npm test` orchestration, shared Node/PowerShell config contract fixtures, and Windows/Ubuntu CI jobs.
- Comprehensive cross-runtime config fixtures for strict scalar types, header/prefix controls, URL/path rules, unknown-field policy, and Windows executable/drive-rooted/UNC/drive-relative command paths.
- Node and PowerShell regression coverage for provider/model API prefix injection, API-key control characters, and secret-safe model-fetch errors.
- Linux installer failure injection for example-backup copy and marker/config permission failures, with SHA-256 snapshots proving that failed transactions preserve the data tree byte-for-byte.

### Changed

- Windows application files now install to `%LOCALAPPDATA%\byok-bridge\app`; mutable data remains in `%USERPROFILE%\.byok-bridge`.
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
- Node and PowerShell config validation now agree on strict `version` and template scalar types, command paths, header/prefix types and control characters, URL rules, and `modelsApi.path` restrictions.
- PowerShell rejects drive-relative commands such as `C:tools\cli.exe` while accepting fully qualified drive-rooted and UNC paths.
- Linux registers example backups only after a successful copy, records marker/config creation before permission changes, and removes incomplete backup temporaries on failure.
- Model-fetch header values are validated before dispatch, and Node manager errors that contain a non-empty API key are replaced with a generic safe message.

### Windows 0.0.1 upgrade

- Recognizable public `0.0.1` installations are migrated automatically after semantic config validation.
- The legacy `config\providers.json`, `state.json`, `models-cache.json`, and unknown user files are preserved.
- Legacy application files are removed by an explicit allowlist; the user `PATH` moves from the data directory to the new application directory.
- A recognizable `0.0.1` Copilot extension is adopted as enabled. Unknown extension content is preserved without ownership.
- A failed migration restores the legacy launcher/files, extension, canonical-config creation, and the exact previous user `PATH`.

### Security

- PowerShell model discovery now rejects credentials/query/fragment URLs and redirects, enforces status/content-type and a 2 MiB response limit, and validates/deduplicates model IDs.
- Provider prefixes, models API prefixes, and API keys cannot inject HTTP headers through C0 or DEL control characters; related validation errors do not echo secret values.
- Manifest paths are revalidated before destructive operations; unknown application, shim, and extension owners are never silently overwritten or removed.
- Storage updates use a common lock contract, atomic replacement, damaged-file preservation, PID-aware stale-lock recovery, and locked read-modify-write transactions.
- Shell env export/temp-file secret flows were removed; credentials are passed only through the launched child environment and redacted in output.

### Notes

- Linux/WSL support begins at `0.0.2`; no public Linux `0.0.1` migration is claimed.

## [0.0.1] - 2026-07-21

Initial public baseline for BYOK Bridge.

### Added

- CLI launcher flow for selecting a provider and model at startup.
- Provider configuration support via `config/providers.json`.
- Example provider configuration in `config/providers.example.json`.
- PowerShell manager scripts for starting the hub and refreshing model data.
- Copilot extension entry point for switching models inside Copilot CLI.
- Local state and model cache handling for runtime data.
- `byok` command shim for launching from CMD or PowerShell after installation.
- Per-user `PATH` setup and removal helper, with `BYOK_BRIDGE_SKIP_PATH_UPDATE=1` as an opt-out.

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
