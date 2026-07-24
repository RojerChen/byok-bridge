# BYOK CLI Hub

BYOK CLI Hub selects a provider and model, builds a configuration-driven environment, and launches an AI CLI as a child process. Provider credentials are passed directly to that child process; they are not written to config/state/cache files or persisted in the caller's shell.

Current version: `0.0.1`

## Supported CLIs

| CLI | Status | Notes |
| --- | --- | --- |
| GitHub Copilot CLI | Supported (experimental) | Verified with Copilot CLI 1.0.73 |
| Gemini CLI | Not supported | Not included in the current integration scope |
| Codex CLI | Not supported | Not included in the current integration scope |

The optional Copilot extension uses an experimental API and may need updates when Copilot CLI changes.

## Prerequisites

Windows:

- Windows 10/11 and PowerShell 5.1 or later.
- GitHub Copilot CLI in `PATH`.

Linux / WSL2:

- Bash, `realpath`, and Node.js 22 or later.
- GitHub Copilot CLI in `PATH`.

Providers normally expose an OpenAI-compatible `/models` API. API keys should be supplied through environment variables or the secure interactive prompt, never stored in `providers.json`.

## Installation

### Windows

Run in CMD:

```bat
bin\win\install.cmd
```

The application and mutable user data are separate:

```text
Application: %LOCALAPPDATA%\byok-cli-hub\app\
User data:  %USERPROFILE%\.byok-cli-hub\
```

The installer stages and smoke-tests a complete application snapshot before switching it into place. An existing `providers.json` is preserved. The application directory is added to the user `PATH` unless `BYOK_CLI_HUB_SKIP_PATH_UPDATE=1` or `-SkipPathUpdate` is supplied.

The Copilot extension is opt-in:

```bat
bin\win\install.cmd -WithExtension
```

To adopt a recognizable extension from the pre-manifest installer, inspect it first and then run:

```bat
bin\win\install.cmd -WithExtension -AdoptLegacy
```

### Linux / WSL2

Run in Bash:

```bash
bash bin/linux/install.sh
# Optional Copilot extension:
bash bin/linux/install.sh --with-extension
```

Default locations:

| Item | Default path |
| --- | --- |
| Application snapshot | `${XDG_DATA_HOME:-$HOME/.local/share}/byok-cli-hub` |
| User data | `$HOME/.byok-cli-hub` |
| Command shim | `$HOME/.local/bin/byok-cli-hub` |
| Optional extension | `${COPILOT_HOME:-$HOME/.copilot}/extensions/byok-cli-hub-copilot` |

Custom paths must be absolute, safe, and non-overlapping:

```bash
bash bin/linux/install.sh \
  --install-dir /opt/byok-cli-hub \
  --data-dir "$HOME/.config/byok-cli-hub" \
  --bin-dir "$HOME/.local/bin"
```

The resolved data directory is recorded in the managed install manifest and exported by the generated shim as `BYOK_CLI_HUB_DATA_DIR`, so the Manager and extension read the same state/cache.

Use `--check` to validate prerequisites and paths without writing files. Upgrading a recognizable installation made before ownership manifests requires the explicit `--adopt-legacy` option.

## Provider configuration

Both platforms use this canonical user config path:

```text
<data-dir>/providers.json
```

Defaults are `%USERPROFILE%\.byok-cli-hub\providers.json` on Windows and `$HOME/.byok-cli-hub/providers.json` on Linux/WSL. A legacy Windows `config/providers.json` is migrated to the canonical location and preserved.

The installed example contains the full schema. A provider entry resembles:

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
      "environment": {}
    }
  }
}
```

Set the key outside the file:

```bat
set "MY_PROVIDER_API_KEY=your-api-key"
```

```bash
export MY_PROVIDER_API_KEY='your-api-key'
```

Invalid JSON, IDs, environment variable names, executable fragments, argument types, headers, or base URL schemes are rejected with a JSON path. `{api_key}` is forbidden in CLI arguments and may only be used in child environment templates. A damaged user config is not silently replaced.

## Launching

After installation:

```text
byok-cli-hub
```

Windows options use PowerShell syntax:

```bat
byok-cli-hub -Cli copilot -Provider my-provider -Model my-model
byok-cli-hub -Provider my-provider -DryRun
byok-cli-hub -Provider my-provider -Refresh
```

Linux / WSL options use GNU-style long names:

```bash
byok-cli-hub --cli copilot --provider my-provider --model my-model
byok-cli-hub --provider my-provider --dry-run
byok-cli-hub --provider my-provider --refresh
byok-cli-hub --provider my-provider -- --additional-cli-argument
```

`--dry-run` / `-DryRun` does not fetch models, update cache/state, or launch a child. It prints a redacted execution plan. Refresh updates cache/state and returns without launching the CLI.

There is intentionally no shell `eval`/`source` export mode. Secrets are passed directly through the child process environment and redacted as `[set]` in output.

## Switching models in Copilot

When the optional extension is installed, use:

```text
/model_byok
/model_byok info
```

The extension uses `BYOK_CLI_HUB_DATA_DIR` and locked atomic state updates. If the shared JSON is damaged, it reports the error instead of overwriting the file.

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

The uninstaller reads the managed manifest, removes only owned shim/extension paths, and preserves user data by default. A pre-manifest install requires `--force-legacy` and recognizable BYOK CLI Hub files.

Neither uninstaller removes GitHub Copilot CLI or any other separately installed AI CLI.

## Development and verification

```text
npm test
npm run smoke
```

The Node tests cover config validation, damaged-file preservation, state/cache writes, endpoint-scoped cache freshness, HTTP limits, strict arguments, redaction, dry-run side effects, and launching. The PowerShell smoke test exercises the canonical Windows data contract.
