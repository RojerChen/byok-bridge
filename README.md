# BYOK CLI Hub

BYOK CLI Hub selects a provider and model, builds a configuration-driven environment, and launches an AI CLI. The Windows CMD launcher and installed Linux/WSL Bash function retain the resolved BYOK environment in the current shell session, so the same provider credential can be reused until that terminal closes. Credentials are never written to config/state/cache or shell startup files.

Current version: `0.0.4`

## Supported CLIs

| CLI | Status | Notes |
| --- | --- | --- |
| GitHub Copilot CLI | Supported (experimental) | Verified with Copilot CLI 1.0.73 |
| OpenCode CLI | Experimental | Generated config loading verified with OpenCode 1.18.9; real-provider conversation validation is still required |
| Gemini CLI | Not supported | Not included in the current integration scope |
| Codex CLI | Not supported | Not included in the current integration scope |

The optional Copilot extension uses an experimental API and may need updates when Copilot CLI changes.

## Prerequisites

Windows:

- Windows 10/11 and PowerShell 5.1 or later.
- At least one integrated CLI (`copilot` or `opencode`) in `PATH`.

Linux / WSL2:

- Bash, `realpath`, and Node.js 22 or later.
- At least one integrated CLI (`copilot` or `opencode`) in `PATH`.
- The managed caller-shell integration requires Bash 4.2 or later.

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

The installer stages and smoke-tests a complete application snapshot before switching it into place. An existing `providers.json` is preserved. If installation fails, the previous application, extension, user `PATH`, and any data files created or replaced by that attempt are restored. The application directory is added to the user `PATH` unless `BYOK_CLI_HUB_SKIP_PATH_UPDATE=1` or `-SkipPathUpdate` is supplied.

The `byok-cli-hub` CMD launcher applies every resolved `environment` entry for the selected CLI and provider to the current CMD console. These values remain available after the launched CLI exits and are inherited by the next invocation. A short-lived environment plan is created under `%TEMP%`, called by the launcher, and deleted before the CLI starts; because it can contain the API key, an interrupted launcher may require manual removal of an abandoned `byok-cli-hub-env-*.cmd` file.

The Copilot extension is opt-in:

```bat
bin\win\install.cmd -WithExtension
```

The public Windows `0.0.1` layout is detected and migrated automatically. Its existing Copilot extension is treated as the user's enabled choice and becomes managed by the current installer. For any other recognizable pre-manifest extension, inspect it first and explicitly opt in to adoption:

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
| Sourceable Bash library | `${XDG_DATA_HOME:-$HOME/.local/share}/byok-cli-hub/shell/bash/byok-cli-hub.bash` |
| Installer-internal profile manager | `${XDG_DATA_HOME:-$HOME/.local/share}/byok-cli-hub/libexec/linux/bash-profile-manager.mjs` |
| Managed Bash startup block | `$HOME/.bashrc` |
| Optional extension | `${COPILOT_HOME:-$HOME/.copilot}/extensions/byok-cli-hub-copilot` |

Custom paths must be absolute, safe, and non-overlapping:

```bash
bash bin/linux/install.sh \
  --install-dir /opt/byok-cli-hub \
  --data-dir "$HOME/.config/byok-cli-hub" \
  --bin-dir "$HOME/.local/bin"
```

The resolved data directory is recorded in the managed install manifest and exported by the generated shim as `BYOK_CLI_HUB_DATA_DIR`, so the Manager and extension read the same state/cache. The sourceable Bash library is part of the application snapshot; the external bin directory contains only the executable `byok-cli-hub` shim. Application, shim, managed `.bashrc` block, extension, and installer-created data changes are rolled back together if a later validation or switch step fails.

Linux files are grouped by how they are invoked: `bin/linux` contains directly executable launch/install commands, `shell/bash` contains the source-only caller-shell library, and `libexec/linux` contains installer-internal tools. Windows entry points remain under `bin/win`.

The installer adds an owned, non-secret block to `~/.bashrc`. Open a new WSL/Bash terminal after installation, or replace the current shell once:

```bash
exec bash
byok-cli-hub

# Later, restore/unset variables managed by the active BYOK plan:
byok-cli-hub-deactivate
```

The startup block only loads fixed Bash functions and passes the canonical managed shim path; it does not store or resolve provider/model/API-key values. Provider selection and prompting still happen each time `byok-cli-hub` is called. The final values are returned by Node over a private anonymous file descriptor, validated as data, exported by the function, and then used to launch the CLI. No `eval` or secret-bearing temporary file is used. Run `command byok-cli-hub` or the shim's absolute path to bypass the function and use isolated child-only mode.

From a repository checkout, choose the invocation contract explicitly:

```bash
# Direct executable; environment changes remain child-only.
./bin/linux/byok-cli-hub

# Source library; successful launch plans remain in the current Bash.
source shell/bash/byok-cli-hub.bash
byok-cli-hub
```

The managed startup block contains original-file restoration metadata, while its path and ownership are recorded in the install manifest. Both are updated transactionally, and the uninstaller removes the block without removing unrelated `.bashrc` content. It does not preserve provider/model/API-key values across terminals. API keys retained in a caller shell can be inherited by other programs subsequently launched from that shell; use child-only mode when that wider session scope is not desired.

Use `--check` to validate prerequisites and paths without writing files. Upgrading a recognizable installation made before ownership manifests requires the explicit `--adopt-legacy` option.

## Distribution and upgrades

This project continues to be distributed as source in `0.0.4`; it does not provide an MSI, DEB/RPM, global npm package, or automatic updater.

Repo mode means running `bin\win\run.cmd` or `bin/linux/run.sh` directly from a clone. Upgrade by running `git pull` or checking out a newer release tag. Repo mode does not copy an application snapshot or modify `PATH`, so it has no separate uninstall step.

Installed mode means running the installer from downloaded or cloned release source. Upgrade by obtaining the newer source and rerunning that version's installer. The installer replaces only its managed application snapshot, executable shim, `.bashrc` block, manifest, and optional managed extension; user config, state, and cache remain in the data directory. An upgrade from the former layout safely removes an owned `<bin-dir>/byok-cli-hub-shell` only after the new snapshot and startup block have switched successfully; an unknown file at that path is preserved. Use the installed uninstaller for removal.

A managed update must keep the data, shim, and extension paths recorded by the existing manifest. Windows rejects a different `BYOK_CLI_HUB_DATA_DIR` or `COPILOT_HOME`; Linux rejects different `--data-dir` or `--bin-dir` values. To relocate these paths without leaving orphaned managed files, uninstall first and then reinstall with the new locations.

For a Windows `0.0.1` upgrade, run the current Windows installer normally. It validates the legacy config before creating `%USERPROFILE%\.byok-cli-hub\providers.json`, moves the application to `%LOCALAPPDATA%\byok-cli-hub\app`, migrates the user `PATH`, preserves state/cache and the original legacy config, and adopts a recognizable legacy extension. Unknown extension content is preserved without taking ownership. If validation or any switch step fails, the old launcher, extension, files, and original `PATH` are restored.

Linux/WSL support is first released in `0.0.2`; there is no public Linux `0.0.1` migration contract. Windows and each Linux/WSL distro are independent installations with separate default data directories.

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
            "name": "{provider_name} (BYOK CLI Hub)",
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

In an OpenCode config template, `{api_key_ref}` is valid only as the complete `provider.*.options.apiKey` value. The Manager renders it as `{env:BYOK_CLI_HUB_OPENCODE_API_KEY}` (or removes `options.apiKey` for an optional provider with no key); it never expands to the plaintext credential. Environment maps continue to use `{api_key}` when the resolved key itself must be assigned to a runtime environment variable.

When OpenCode is selected, the Manager writes the generated OpenCode config only to `<data-dir>/opencode.json` and launches OpenCode with `OPENCODE_CONFIG` pointing to that absolute path. The generated file contains the selected provider, all resolved model IDs, and an `{env:BYOK_CLI_HUB_OPENCODE_API_KEY}` reference when a key is required or supplied; the plaintext key is passed in the launch environment and is never stored in the file. Existing user `providers.json` files are preserved during upgrades, so installations upgrading from an earlier release must add the `opencode` CLI entry shown above if they want to enable it. Do not run concurrent Hub sessions against the same data directory.

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

## Launching

After installation:

```text
byok-cli-hub
```

Windows options use PowerShell syntax:

```bat
byok-cli-hub -Cli copilot -Provider my-provider -Model my-model
byok-cli-hub -Cli opencode -Provider my-provider -Model my-model
byok-cli-hub -Provider my-provider -DryRun
byok-cli-hub -Provider my-provider -Refresh
```

Linux / WSL options use GNU-style long names:

```bash
byok-cli-hub --cli copilot --provider my-provider --model my-model
byok-cli-hub --cli opencode --provider my-provider --model my-model
byok-cli-hub --provider my-provider --dry-run
byok-cli-hub --provider my-provider --refresh
byok-cli-hub --provider my-provider -- --additional-cli-argument
```

`--dry-run` / `-DryRun` does not fetch models, update cache/state, apply a caller environment, or launch a child. It prints a redacted execution plan. Refresh updates cache/state and returns without launching the CLI.

On Windows, the public CMD launcher applies the environment in the caller console; invoking the PowerShell Manager script directly remains child-only. On Linux/WSL, the installed Bash integration sources fixed, version-controlled function code and applies a strictly parsed plan received over a private file descriptor; invoking the executable directly remains child-only. Secrets are redacted as `[set]` in human-readable output.

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

The completed `0.0.2` review and remediation record is in [`doc/improve_0.0.2.md`](doc/improve_0.0.2.md).
