# Using BYOK Bridge

## Launching

After installation:

```text
byok
```

Windows options use PowerShell syntax:

```bat
byok -Cli copilot -Provider my-provider -Model my-model
byok -Cli opencode -Provider my-provider -Model my-model
byok -Provider my-provider -DryRun
byok -Provider my-provider -Refresh
byok -NoClear
```

Linux / WSL options use GNU-style long names:

```bash
byok --cli copilot --provider my-provider --model my-model
byok --cli opencode --provider my-provider --model my-model
byok --provider my-provider --dry-run
byok --provider my-provider --refresh
byok --no-clear
byok --provider my-provider -- --additional-cli-argument
```

`--dry-run` / `-DryRun` does not fetch models, update cache/state, apply a caller environment, or launch a child. It prints a redacted execution plan. Refresh updates cache/state and returns without launching the CLI.

Interactive terminals use a clean wizard screen by default. Use `--no-clear` on Linux/WSL, `-NoClear` on Windows, or set `BYOK_UI_HISTORY=true` to keep every screen in the terminal for debugging or transcript capture.

Colors are enabled only for interactive terminals. Set `NO_COLOR` or `BYOK_UI_COLOR=0` to force the plain-text layout.

On Windows, the public CMD launcher applies the environment in the caller console; invoking the PowerShell Manager script directly remains child-only. On Linux/WSL, the installed Bash integration sources fixed, version-controlled function code and applies a strictly parsed plan received over a private file descriptor; invoking the executable directly remains child-only. Secrets are redacted as `[set]` in human-readable output.

## Switching models in Copilot

`/model_byok` is a command added by BYOK Bridge's optional extension for GitHub Copilot CLI; it is not a built-in Copilot CLI command. With the extension installed, start GitHub Copilot CLI through BYOK Bridge and use:

```text
/model_byok
/model_byok info
```

`/model_byok` opens a picker for the models that the Hub has preloaded for the selected provider. Model names and availability vary by provider. It changes the current Copilot session; it is not part of the Hub's initial CLI/provider selection flow.

![Copilot CLI /model_byok model selection](../images/copilot-model-byok-selection.png)

The extension uses `BYOK_BRIDGE_DATA_DIR` and locked atomic state updates. If the shared JSON is damaged, it reports the error instead of overwriting the file.
