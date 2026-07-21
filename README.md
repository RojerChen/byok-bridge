# BYOK CLI Hub

BYOK CLI Hub lets you choose a provider and model when launching an AI CLI, and applies the matching environment variables to the current CMD window.

## Supported CLIs

Current support status:

| CLI | Status | Notes |
| --- | --- | --- |
| Copilot CLI | Supported | Primary target for now |
| Gemini CLI | Not supported | Not included in the integration scope |
| Codex CLI | Not supported | Limited by the current execution environment |

If the environment or integration targets change later, this list will be updated.

## Prerequisites

Install the following first:

- Windows 10/11
- PowerShell 5.1 or later
- The CLI you want to use, such as GitHub Copilot CLI, Aider, or any other CLI listed in the configuration file
- The CLI command must be available in the `PATH` for CMD

The provider must expose an OpenAI-compatible `/models` API. The API key can come from an environment variable or be entered at startup.

## Installation

Run this in the project directory:

```bat
srcV3\bin\install.cmd
```

The installer copies files to:

```text
%USERPROFILE%\.byok-cli-hub\
```

That directory includes:

- `run.cmd`: launch entry point
- `manager\`: startup and provider management scripts
- `config\providers.example.json`: example configuration
- `state.json`, `models-cache.json`: runtime state and model cache generated after execution

If the Copilot extension is installed, it will be placed here:

```text
%USERPROFILE%\.copilot\extensions\byok-cli-hub-copilot\
```

## Provider setup

Copy the example configuration:

```bat
copy "%USERPROFILE%\.byok-cli-hub\config\providers.example.json" "%USERPROFILE%\.byok-cli-hub\config\providers.json"
```

Then edit:

```text
%USERPROFILE%\.byok-cli-hub\config\providers.json
```

The minimal provider configuration looks like this:

```json
{
  "version": 1,
  "providers": {
    "my-provider": {
      "name": "My Provider",
      "enabled": true,
      "type": "openai",
      "baseUrl": "https://api.example.com/v1",
      "apiKeyEnv": ["MY_PROVIDER_API_KEY"],
      "modelEnvNames": ["COPILOT_MODEL"],
      "apiKeyHeader": "Authorization",
      "apiKeyPrefix": "Bearer ",
      "modelsApi": {
        "path": "/models",
        "itemsPath": "data",
        "idPath": "id"
      },
      "environment": {}
    }
  }
}
```

Do not put real API keys into `providers.json`. Set them through an environment variable instead:

```bat
set "MY_PROVIDER_API_KEY=your-api-key"
```

If no API key is found, you will be prompted to enter one at startup.

## Launching

Run this in CMD:

```bat
call "%USERPROFILE%\.byok-cli-hub\run.cmd"
```

The startup flow will ask you to choose:

1. CLI
2. Provider
3. Model
4. API key, if it is not already present in environment variables

You can also pass options directly:

```bat
call "%USERPROFILE%\.byok-cli-hub\run.cmd" -Cli copilot -Provider my-provider -Model my-model
```

The first launch will call the provider's `/models` API and cache the result in `models-cache.json`.

## Switching models in Copilot

After installing the extension, run this inside Copilot CLI:

```text
/model_byok
```

To view the current provider and model:

```text
/model_byok info
```

## Refreshing models

To update the model cache without launching the CLI:

```powershell
& "$env:USERPROFILE\.byok-cli-hub\manager\refresh-byok-models-v3.ps1" -All
```

## Removal

Delete the following directories to remove BYOK CLI Hub data and settings:

```text
%USERPROFILE%\.byok-cli-hub\
%USERPROFILE%\.copilot\extensions\byok-cli-hub-copilot\
```

This does not remove any separately installed Copilot CLI, Aider, or other AI CLIs.
