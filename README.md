# BYOK CLI Hub

A cross-platform BYOK provider and model manager for AI coding CLIs.

Manage local or remote LLM providers without repeatedly editing environment variables, remembering model names, or switching configuration files manually.

> Configure once. Discover models automatically. Launch any supported AI coding CLI.

BYOK CLI Hub provides one consistent path from provider to prompt:

**Provider → Model discovery → Model selection → CLI configuration → Launch**

## Why BYOK CLI Hub?

Using multiple AI coding CLIs often means repeatedly editing environment variables, configuration files, and model names.

BYOK CLI Hub provides one consistent workflow across supported AI coding CLIs.

### Provider Management

- Manage multiple BYOK providers.
- Support local and remote OpenAI-compatible endpoints.

### Model Discovery

- Automatically retrieve available models.
- No manual model-name configuration.

### CLI Integration

- Generate CLI-specific configuration.
- Launch supported AI coding CLIs.
- Optional `/model_byok` support for GitHub Copilot CLI.

## Supported platforms

- Windows
- WSL2
- Linux

## Supported CLIs

| CLI | Status |
| --- | --- |
| GitHub Copilot CLI | ✅ Experimental |
| OpenCode CLI | ✅ Experimental |

## Documentation

- [Install and upgrade](doc/installation.md)
- [Configure providers](doc/provider-configuration.md)
- [Launch a CLI and switch models](doc/usage.md)
- [Remove or contribute](doc/maintenance.md)

## Security by design

- API keys are never stored in configuration or cache.
- Generated OpenCode configuration references environment variables instead of plaintext credentials.
- See the [Provider Configuration guide](doc/provider-configuration.md) for implementation details.
