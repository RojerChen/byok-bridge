# Using BYOK CLI Hub

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
