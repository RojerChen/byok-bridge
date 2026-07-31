# Provider configuration

Both platforms use this canonical user config path:

```text
<data-dir>/providers.json
```

Defaults are `%USERPROFILE%\.byok-bridge\providers.json` on Windows and `$HOME/.byok-bridge/providers.json` on Linux/WSL. A legacy Windows `config/providers.json` is migrated to the canonical location and preserved.

[`config/providers.example.json`](../config/providers.example.json) is the canonical, complete starting configuration installed for users. The shortened JSON below illustrates the relevant structure; use the example file for the complete current schema and defaults.

```json
{
  "version": 1,
  "clis": {
    "copilot": {
      "name": "GitHub Copilot CLI",
      "command": "copilot",
      "args": ["--experimental"],
      "modelEnvName": "COPILOT_MODEL",
      "environment": {
        "COPILOT_PROVIDER_BASE_URL": "{url}",
        "COPILOT_PROVIDER_API_KEY": "{api_key}",
        "COPILOT_MODEL": "{model}"
      }
    },
    "opencode": {
      "name": "OpenCode CLI",
      "command": "opencode",
      "args": [],
      "adapter": "opencode-config-v1",
      "configEnvName": "OPENCODE_CONFIG",
      "configFileName": "opencode.json",
      "template": {
        "$schema": "https://opencode.ai/config.json",
        "provider": {
          "{opencode_provider_id}": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "{provider_name} (BYOK Bridge)",
            "options": {
              "baseURL": "{url}",
              "apiKey": "{api_key_ref}"
            },
            "models": "{models}"
          }
        },
        "model": "{opencode_provider_id}/{model}"
      },
      "environment": {}
    }
  },
  "providers": {
    "my-provider": {
      "name": "My Provider",
      "enabled": true,
      "type": "openai",
      "baseUrl": "https://api.example.com/v1",
      "apiKeyEnv": ["MY_PROVIDER_API_KEY"],
      "modelEnvNames": ["COPILOT_MODEL"],
      "modelsApi": {
        "path": "/models",
        "itemsPath": "data",
        "idPath": "id"
      },
      "environment": {
        "COPILOT_PROVIDER_API_KEY": "{api_key}"
      }
    }
  }
}
```

A provider's `environment` may contain provider-wide environment templates directly. It may also contain a CLI ID whose value is another environment map for CLI-specific overrides; CLI-specific values take precedence over provider-wide values.

In an OpenCode config template, `{api_key_ref}` is valid only as the complete `provider.*.options.apiKey` value. The Manager renders it as `{env:BYOK_BRIDGE_OPENCODE_API_KEY}` (or removes `options.apiKey` for an optional provider with no key); it never expands to the plaintext credential. Environment maps continue to use `{api_key}` when the resolved key itself must be assigned to a runtime environment variable.

When OpenCode is selected, the Manager writes the generated OpenCode config only to `<data-dir>/opencode.json` and launches OpenCode with `OPENCODE_CONFIG` pointing to that absolute path. The generated file contains the selected provider, all resolved model IDs, and an `{env:BYOK_BRIDGE_OPENCODE_API_KEY}` reference when a key is required or supplied; the plaintext key is passed in the launch environment and is never stored in the file. Existing user `providers.json` files are preserved during upgrades, so installations upgrading from an earlier release must add the `opencode` CLI entry shown above if they want to enable it. Do not run concurrent Hub sessions against the same data directory.

OpenCode merges higher-precedence project, inline, and managed configuration after `OPENCODE_CONFIG`, so those sources may override the generated provider or default model. Diagnose the final merged result with `opencode debug config` and `opencode models <runtime-provider-id>`; the Manager prints the runtime provider ID before launch.

Set the key outside the file:

```bat
set "MY_PROVIDER_API_KEY=your-api-key"
```

```bash
export MY_PROVIDER_API_KEY='your-api-key'
```

Invalid JSON, IDs, environment variable names, executable fragments, argument types, headers/prefixes, or base URL schemes are rejected with a JSON path. `version` must be the JSON number `1`; environment and settings templates accept only string, number, or boolean scalar values. On Windows, command paths may be a simple executable name, a fully qualified drive-rooted path, or a UNC path; drive-relative values such as `C:tools\cli.exe` are rejected.

`apiKeyPrefix`, `modelsApi.apiKeyPrefix`, and the final prefix-plus-key HTTP header value reject C0/DEL control characters, preventing header injection. Errors that could contain an API key are replaced with a generic message. `modelsApi.path` must not contain control characters, a query (`?`), or a fragment (`#`). Node and PowerShell apply and directly cross-check the same acceptance contract for validated fields. Unknown fields are currently preserved/ignored for forward compatibility. `{api_key}` is forbidden in CLI arguments and may only be used in child environment templates. A damaged user config is not silently replaced.
