# Installation and upgrades

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

The application snapshot includes `README.md` and its linked guides under `doc/`, so the installed README can be read locally.

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

This project is distributed as source; it does not provide an MSI, DEB/RPM, global npm package, or automatic updater.

Repo mode means running `bin\win\run.cmd` or `bin/linux/run.sh` directly from a clone. Upgrade by running `git pull` or checking out a newer release tag. Repo mode does not copy an application snapshot or modify `PATH`, so it has no separate uninstall step.

Installed mode means running the installer from downloaded or cloned release source. Upgrade by obtaining the newer source and rerunning that version's installer. The installer replaces only its managed application snapshot, executable shim, `.bashrc` block, manifest, and optional managed extension; user config, state, and cache remain in the data directory. An upgrade from the former layout safely removes an owned `<bin-dir>/byok-cli-hub-shell` only after the new snapshot and startup block have switched successfully; an unknown file at that path is preserved. Use the installed uninstaller for removal.

A managed update must keep the data, shim, and extension paths recorded by the existing manifest. Windows rejects a different `BYOK_CLI_HUB_DATA_DIR` or `COPILOT_HOME`; Linux rejects different `--data-dir` or `--bin-dir` values. To relocate these paths without leaving orphaned managed files, uninstall first and then reinstall with the new locations.

For a Windows `0.0.1` upgrade, run the current Windows installer normally. It validates the legacy config before creating `%USERPROFILE%\.byok-cli-hub\providers.json`, moves the application to `%LOCALAPPDATA%\byok-cli-hub\app`, migrates the user `PATH`, preserves state/cache and the original legacy config, and adopts a recognizable legacy extension. Unknown extension content is preserved without taking ownership. If validation or any switch step fails, the old launcher, extension, files, and original `PATH` are restored.

Linux/WSL support is first released in `0.0.2`; there is no public Linux `0.0.1` migration contract. Windows and each Linux/WSL distro are independent installations with separate default data directories.
