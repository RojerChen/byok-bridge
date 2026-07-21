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

### Notes

- `providers.json` is intended to be a local, user-specific configuration file.
- Runtime files such as `state.json` and `models-cache.json` are ignored by git.

