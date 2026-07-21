# Changelog

All notable changes to this project will be documented in this file.

The format is intentionally simple and follows a lightweight `Keep a Changelog` style.

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
