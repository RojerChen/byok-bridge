# BYOK CLI Hub

BYOK CLI Hub selects a provider and model, builds a configuration-driven environment, and launches an AI CLI as a child process. Provider credentials are passed directly to that child process; they are not written to config/state/cache files or persisted in the caller's shell.

Current version: `0.0.2`

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

The installer stages and smoke-tests a complete application snapshot before switching it into place. An existing `providers.json` is preserved. If installation fails, the previous application, extension, user `PATH`, and any data files created or replaced by that attempt are restored. The application directory is added to the user `PATH` unless `BYOK_CLI_HUB_SKIP_PATH_UPDATE=1` or `-SkipPathUpdate` is supplied.

The Copilot extension is opt-in:

```bat
bin\win\install.cmd -WithExtension
```

The public Windows `0.0.1` layout is detected and migrated automatically. Its existing Copilot extension is treated as the user's enabled choice and becomes managed by `0.0.2`. For any other recognizable pre-manifest extension, inspect it first and explicitly opt in to adoption:

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

The resolved data directory is recorded in the managed install manifest and exported by the generated shim as `BYOK_CLI_HUB_DATA_DIR`, so the Manager and extension read the same state/cache. Application, shim, extension, and installer-created data changes are rolled back together if a later validation or switch step fails.

Use `--check` to validate prerequisites and paths without writing files. Upgrading a recognizable installation made before ownership manifests requires the explicit `--adopt-legacy` option.

## Distribution and upgrades

This project is distributed as source; `0.0.2` does not introduce an MSI, DEB/RPM, global npm package, or automatic updater.

Repo mode means running `bin\win\run.cmd` or `bin/linux/run.sh` directly from a clone. Upgrade by running `git pull` or checking out a newer release tag. Repo mode does not copy an application snapshot or modify `PATH`, so it has no separate uninstall step.

Installed mode means running the installer from downloaded or cloned release source. Upgrade by obtaining the newer source and rerunning that version's installer. The installer replaces only its managed application snapshot, shim/`PATH` entry, manifest, and optional managed extension; user config, state, and cache remain in the data directory. Use the installed uninstaller for removal.

A managed update must keep the data, shim, and extension paths recorded by the existing manifest. Windows rejects a different `BYOK_CLI_HUB_DATA_DIR` or `COPILOT_HOME`; Linux rejects different `--data-dir` or `--bin-dir` values. To relocate these paths without leaving orphaned managed files, uninstall first and then reinstall with the new locations.

For a Windows `0.0.1` upgrade, run the `0.0.2` Windows installer normally. It validates the legacy config before creating `%USERPROFILE%\.byok-cli-hub\providers.json`, moves the application to `%LOCALAPPDATA%\byok-cli-hub\app`, migrates the user `PATH`, preserves state/cache and the original legacy config, and adopts a recognizable legacy extension. Unknown extension content is preserved without taking ownership. If validation or any switch step fails, the old launcher, extension, files, and original `PATH` are restored.

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
npm run test:linux-installer
npm run test:all:linux
```

`npm test` is platform-aware: Windows runs Node, PowerShell smoke/HTTP, and Windows installer suites; Linux runs Node and Linux installer suites. A current Windows run contains 20 Node/cross-runtime assertions in addition to the PowerShell and installer suites. The Windows and Ubuntu jobs in `.github/workflows/test.yml` run this same entry point in CI.

The tests cover the shared Node/PowerShell config contract (including strict scalar types and Windows command-path variants), damaged-file preservation, endpoint-scoped cache freshness, bounded HTTP reads and stalled-body deadlines, empty model arrays, header-injection rejection and API-key-safe errors, strict arguments, redaction, side-effect-free dry-run, active and abandoned cross-runtime locks, Windows `0.0.1` migration and rollback, managed-path relocation guards, and Windows/Linux data-aware installation transactions. Linux failure injection explicitly verifies example-backup copy failure plus marker/config `chmod` failure using byte-level SHA-256 data-tree snapshots.

The completed `0.0.2` review and remediation record is in [`doc/improve_0.0.2.md`](doc/improve_0.0.2.md).
