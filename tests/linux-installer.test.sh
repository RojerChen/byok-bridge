#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
APP_VERSION="$(node -e 'const p=require(process.argv[1]); process.stdout.write(p.version)' "$REPO_ROOT/package.json")"
NEWER_APP_VERSION="$(node -e 'const [major]=require(process.argv[1]).version.split("."); process.stdout.write(`${Number(major)+1}.0.0`)' "$REPO_ROOT/package.json")"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/byok-linux-installer.XXXXXX")"

cleanup() {
  [[ -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
printf '%s' 'export BYOK_TEST_BASHRC_SENTINEL=present' > "$HOME/.bashrc"
BASHRC_ORIGINAL_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")"

snapshot_tree() {
  node -e '
    const crypto = require("node:crypto");
    const fs = require("node:fs");
    const path = require("node:path");
    const root = process.argv[1];
    const rows = [];
    function walk(dir, relative) {
      for (const name of fs.readdirSync(dir).sort()) {
        const absolute = path.join(dir, name);
        const childRelative = relative ? `${relative}/${name}` : name;
        const stat = fs.lstatSync(absolute);
        if (stat.isDirectory()) {
          rows.push(`D ${childRelative}`);
          walk(absolute, childRelative);
        } else if (stat.isFile()) {
          const hash = crypto.createHash("sha256").update(fs.readFileSync(absolute)).digest("hex");
          rows.push(`F ${childRelative} ${hash}`);
        } else if (stat.isSymbolicLink()) {
          rows.push(`L ${childRelative} ${fs.readlinkSync(absolute)}`);
        } else {
          rows.push(`O ${childRelative}`);
        }
      }
    }
    if (fs.existsSync(root)) walk(root, "");
    process.stdout.write(rows.join("\n"));
  ' "$1"
}

assert_installed_readme_documentation() {
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const root = process.argv[1];
    const readmePath = path.join(root, "README.md");
    if (!fs.existsSync(readmePath)) throw new Error("Installed README is missing.");
    const readme = fs.readFileSync(readmePath, "utf8");
    const links = [...readme.matchAll(/\]\((doc\/[^)#]+)(?:#[^)]+)?\)/g)];
    if (links.length === 0) throw new Error("Installed README has no relative documentation links.");
    for (const [, relativePath] of links) {
      if (!fs.existsSync(path.join(root, relativePath)))
        throw new Error(`Installed README link does not resolve: ${relativePath}`);
    }
    const documentationDir = path.join(root, "doc");
    if (!fs.existsSync(documentationDir))
      throw new Error("Installed documentation directory is missing.");
    const markdownPaths = [
      readmePath,
      ...fs.readdirSync(documentationDir)
        .filter((name) => name.endsWith(".md"))
        .map((name) => path.join(documentationDir, name))
    ];
    for (const markdownPath of markdownPaths) {
      const markdown = fs.readFileSync(markdownPath, "utf8");
      for (const match of markdown.matchAll(/!?\[[^\]]*\]\(([^)\s]+)/g)) {
        const target = match[1].split("#", 1)[0];
        if (!target || /^[a-z][a-z0-9+.-]*:/i.test(target)) continue;
        const resolvedPath = path.resolve(path.dirname(markdownPath), target);
        if (!fs.existsSync(resolvedPath))
          throw new Error(`Installed Markdown link does not resolve: ${target} (from ${markdownPath})`);
      }
    }
    if (fs.existsSync(path.join(root, "doc", "plan.md")))
      throw new Error("Internal planning file was included in the application snapshot.");
  ' "$1"
}

bash -n \
  "$REPO_ROOT/bin/linux/install.sh" \
  "$REPO_ROOT/bin/linux/run.sh" \
  "$REPO_ROOT/bin/linux/uninstall.sh" \
  "$REPO_ROOT/shell/bash/byok-bridge.bash" \
  "$REPO_ROOT/bin/linux/byok"
node --check "$REPO_ROOT/libexec/linux/bash-profile-manager.mjs"

mkdir -p "$TEST_ROOT/fake-bin"
cat > "$TEST_ROOT/fake-bin/copilot" << 'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "--version" ]]; then echo 'copilot-test'; exit 0; fi
exit 0
EOF
chmod 755 "$TEST_ROOT/fake-bin/copilot"
export PATH="$TEST_ROOT/fake-bin:$PATH"
export COPILOT_HOME="$TEST_ROOT/copilot-home"

if bash "$REPO_ROOT/bin/linux/install.sh" --check --install-dir / >/dev/null 2>&1; then
  echo 'Root path guard did not reject /.' >&2
  exit 1
fi
if bash "$REPO_ROOT/bin/linux/install.sh" --check \
  --install-dir "$TEST_ROOT/overlap" \
  --data-dir "$TEST_ROOT/overlap/data" >/dev/null 2>&1; then
  echo 'Overlap guard did not reject nested data.' >&2
  exit 1
fi

# An obsolete, unowned shell integration helper is outside the new installer's
# ownership and must survive installation and uninstallation unchanged.
UNOWNED_ROOT="$TEST_ROOT/unowned-shell-helper"
mkdir -p "$UNOWNED_ROOT/bin"
printf '%s\n' 'preserve-shell-helper' > "$UNOWNED_ROOT/bin/byok-shell"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$UNOWNED_ROOT/app" \
  --data-dir "$UNOWNED_ROOT/data" \
  --bin-dir "$UNOWNED_ROOT/bin" >/dev/null
[[ "$(cat "$UNOWNED_ROOT/bin/byok-shell")" == 'preserve-shell-helper' ]]
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$UNOWNED_ROOT/app" >/dev/null
[[ "$(cat "$UNOWNED_ROOT/bin/byok-shell")" == 'preserve-shell-helper' ]]

APP_DIR="$TEST_ROOT/app"
DATA_DIR="$TEST_ROOT/data"
BIN_DIR="$TEST_ROOT/bin"

# A failed fresh install must not leave newly initialized data behind.
FRESH_APP_DIR="$TEST_ROOT/fresh-failure/app"
FRESH_DATA_DIR="$TEST_ROOT/fresh-failure/data"
FRESH_BIN_DIR="$TEST_ROOT/fresh-failure/bin"
if BYOK_BRIDGE_TEST_FAIL_AT=after-app-backup bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$FRESH_APP_DIR" \
  --data-dir "$FRESH_DATA_DIR" \
  --bin-dir "$FRESH_BIN_DIR" >/dev/null 2>&1; then
  echo 'Injected fresh-install failure unexpectedly succeeded.' >&2
  exit 1
fi
[[ ! -e "$FRESH_APP_DIR" ]]
[[ ! -e "$FRESH_DATA_DIR" ]]
[[ ! -e "$FRESH_BIN_DIR/byok" ]]

# Creation flags must be registered before chmod so either failure restores an
# existing empty data directory byte-for-byte and leaves no application files.
for failure_point in data-marker-chmod data-config-chmod; do
  FAILURE_ROOT="$TEST_ROOT/$failure_point"
  FAILURE_APP_DIR="$FAILURE_ROOT/app"
  FAILURE_DATA_DIR="$FAILURE_ROOT/data"
  FAILURE_BIN_DIR="$FAILURE_ROOT/bin"
  mkdir -p "$FAILURE_DATA_DIR"
  DATA_BEFORE="$(snapshot_tree "$FAILURE_DATA_DIR")"
  if BYOK_BRIDGE_TEST_FAIL_AT="$failure_point" bash "$REPO_ROOT/bin/linux/install.sh" \
    --install-dir "$FAILURE_APP_DIR" \
    --data-dir "$FAILURE_DATA_DIR" \
    --bin-dir "$FAILURE_BIN_DIR" >/dev/null 2>&1; then
    echo "Injected $failure_point failure unexpectedly succeeded." >&2
    exit 1
  fi
  [[ "$DATA_BEFORE" == "$(snapshot_tree "$FAILURE_DATA_DIR")" ]]
  [[ ! -e "$FAILURE_APP_DIR" ]]
  [[ ! -e "$FAILURE_BIN_DIR/byok" ]]
done

bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" \
  --with-extension

[[ -f "$APP_DIR/.byok-bridge-install.json" ]]
node -e 'const m=require(process.argv[1]); if(m.appVersion!==process.argv[2]||m.withExtension!==true) process.exit(1)' "$APP_DIR/.byok-bridge-install.json" "$APP_VERSION"
assert_installed_readme_documentation "$APP_DIR"
[[ -f "$APP_DIR/ui/theme.json" ]]
[[ -f "$APP_DIR/ui/messages/app.json" ]]
[[ -f "$DATA_DIR/providers.json" ]]
[[ -f "$DATA_DIR/.byok-bridge-data" ]]
grep -q '^# BYOK_BRIDGE_MANAGED_SHIM=1$' "$BIN_DIR/byok"
grep -q '^# BYOK_BRIDGE_MANAGED_SHELL_INTEGRATION=1$' "$APP_DIR/shell/bash/byok-bridge.bash"
[[ -f "$APP_DIR/libexec/linux/bash-profile-manager.mjs" ]]
true
grep -q '^# BYOK_BRIDGE_MANAGED_BASHRC=1$' "$HOME/.bashrc"
grep -Fq "source '$APP_DIR/shell/bash/byok-bridge.bash' --byok-managed-command '$BIN_DIR/byok'" "$HOME/.bashrc"
[[ "$(grep -c '^# >>> BYOK Bridge managed shell integration >>>$' "$HOME/.bashrc")" -eq 1 ]]
bash -c 'source "$1" --byok-managed-command "$2"; declare -F byok >/dev/null; declare -F byok-deactivate >/dev/null' _ "$APP_DIR/shell/bash/byok-bridge.bash" "$BIN_DIR/byok"
BYOK_TEST_EXPECTED_BASHRC="$HOME/.bashrc" node -e 'const m=require(process.argv[1]); if(m.managedFiles.length!==1||m.managedFiles[0]!=="byok"||m.shellStartupManaged!==true||m.bashrcPath!==process.env.BYOK_TEST_EXPECTED_BASHRC) process.exit(1)' "$APP_DIR/.byok-bridge-install.json"
bash --noprofile --rcfile "$HOME/.bashrc" -ic '[[ "$(type -t byok)" == function ]]' 2>/dev/null
# Keep this startup integration assertion fully offline.
node -e 'const fs=require("node:fs"),p=process.argv[1],c=JSON.parse(fs.readFileSync(p,"utf8"));c.providers["openai-compatible"].models=["gpt-4o"];fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$DATA_DIR/providers.json"
STARTUP_TEST_LOG="$TEST_ROOT/bash-startup-launch.log"
if ! bash --noprofile --rcfile "$HOME/.bashrc" -ic 'byok --cli copilot --provider openai-compatible --model gpt-4o --api-key startup-test-secret >/dev/null && [[ "$COPILOT_PROVIDER_TYPE" == openai && "$COPILOT_MODEL" == gpt-4o ]]' >"$STARTUP_TEST_LOG" 2>&1; then
  cat "$STARTUP_TEST_LOG" >&2
  echo 'Automatically loaded byok did not retain its environment.' >&2
  exit 1
fi
"$BIN_DIR/byok" --cli copilot --provider openai-compatible --dry-run

# A manifest from a newer application version must not be downgraded.
cp "$APP_DIR/.byok-bridge-install.json" "$TEST_ROOT/manifest-backup.json"
node -e 'const fs=require("node:fs"),p=process.argv[1],m=JSON.parse(fs.readFileSync(p,"utf8"));m.appVersion=process.argv[2];fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")' "$APP_DIR/.byok-bridge-install.json" "$NEWER_APP_VERSION"
if bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
  echo 'Installer accepted a managed manifest from a newer version.' >&2
  exit 1
fi
cp "$TEST_ROOT/manifest-backup.json" "$APP_DIR/.byok-bridge-install.json"

# Managed updates must not silently relocate the shim and orphan the old one.
if bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$TEST_ROOT/relocated-bin" >/dev/null 2>&1; then
  echo 'Managed update unexpectedly relocated bin-dir.' >&2
  exit 1
fi
[[ -f "$BIN_DIR/byok" ]]
[[ ! -e "$TEST_ROOT/relocated-bin/byok" ]]

# A failed copy into the example backup must not register an empty backup,
# alter any data byte, or leave the temporary backup file behind.
DATA_BEFORE="$(snapshot_tree "$DATA_DIR")"
if BYOK_BRIDGE_TEST_FAIL_AT=data-example-backup-copy bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
  echo 'Injected data example backup-copy failure unexpectedly succeeded.' >&2
  exit 1
fi
[[ "$DATA_BEFORE" == "$(snapshot_tree "$DATA_DIR")" ]]
if compgen -G "$DATA_DIR/.providers.example.backup.*" >/dev/null; then
  echo 'Failed data example backup left a temporary file behind.' >&2
  exit 1
fi

# Every switch boundary in an old-to-new update must restore the previous app,
# shim, Bash startup file, legacy helper, extension, and user data.
CONFIG_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")"
EXT_DIR="$COPILOT_HOME/extensions/byok-bridge-copilot"
for failure_point in after-app-backup after-shim-backup after-bashrc-backup after-extension-backup before-backup-cleanup; do
  printf '%s\n' "$failure_point" > "$APP_DIR/rollback-sentinel.txt"
  printf '# rollback=%s\n' "$failure_point" >> "$BIN_DIR/byok"
  printf '%s\n' "$failure_point" > "$EXT_DIR/rollback-sentinel.txt"
  printf 'example=%s\n' "$failure_point" > "$DATA_DIR/providers.example.json"
  BASHRC_BEFORE_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")"
  if BYOK_BRIDGE_TEST_FAIL_AT="$failure_point" bash "$REPO_ROOT/bin/linux/install.sh" \
    --install-dir "$APP_DIR" \
    --data-dir "$DATA_DIR" \
    --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
    echo "Failure injection did not fail at $failure_point." >&2
    exit 1
  fi
  [[ "$(cat "$APP_DIR/rollback-sentinel.txt")" == "$failure_point" ]]
  grep -q "^# rollback=$failure_point$" "$BIN_DIR/byok"
  [[ "$(cat "$EXT_DIR/rollback-sentinel.txt")" == "$failure_point" ]]
  [[ "$(cat "$DATA_DIR/providers.example.json")" == "example=$failure_point" ]]
  [[ "$BASHRC_BEFORE_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]
done

# A successful update moves the source library into the application snapshot,
# removes the old owned helper, and retains config plus startup ownership.
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
assert_installed_readme_documentation "$APP_DIR"
[[ "$CONFIG_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")" ]]
[[ "$(grep -c '^# >>> BYOK Bridge managed shell integration >>>$' "$HOME/.bashrc")" -eq 1 ]]
true
node -e 'const m=require(process.argv[1]);if(m.shellStartupManaged!==true||!m.bashrcPath||m.managedFiles.includes("byok-cli-hub-shell"))process.exit(1)' "$APP_DIR/.byok-bridge-install.json"

# Even a legacy manifest claim is insufficient to delete a same-name file
# whose ownership marker is missing.
printf '%s\n' 'preserve-unowned-legacy-helper' > "$BIN_DIR/byok-cli-hub-shell"
node -e 'const fs=require("node:fs"),p=process.argv[1],m=JSON.parse(fs.readFileSync(p,"utf8"));m.managedFiles=["byok","byok-shell"];fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")' "$APP_DIR/.byok-bridge-install.json"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" >/dev/null
[[ "$(cat "$BIN_DIR/byok-cli-hub-shell")" == 'preserve-unowned-legacy-helper' ]]

bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR"
[[ ! -e "$APP_DIR" ]]
[[ ! -e "$BIN_DIR/byok" ]]
[[ "$(cat "$BIN_DIR/byok-cli-hub-shell")" == 'preserve-unowned-legacy-helper' ]]
[[ ! -e "$EXT_DIR" ]]
[[ -f "$DATA_DIR/providers.json" ]]
[[ "$BASHRC_ORIGINAL_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]
rm -f -- "$BIN_DIR/byok-cli-hub-shell"

bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR" --purge-data --yes
[[ ! -e "$DATA_DIR" ]]
true
[[ "$BASHRC_ORIGINAL_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]

# An unowned extension must survive install and uninstall when extension support is not requested.
mkdir -p "$EXT_DIR"
printf '%s\n' 'preserve-me' > "$EXT_DIR/unknown-owner.txt"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
[[ -f "$EXT_DIR/unknown-owner.txt" ]]
[[ ! -f "$EXT_DIR/.byok-bridge-managed" ]]
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR"
[[ -f "$EXT_DIR/unknown-owner.txt" ]]
[[ "$BASHRC_ORIGINAL_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]

# A managed 0.0.3 layout must move to the new data, shim and extension paths
# only after the staged copy can be switched and rolled back safely.
rm -rf -- "$EXT_DIR"
LEGACY_INSTALL_DIR="$HOME/.local/share/byok-cli-hub"
LEGACY_DATA_DIR="$HOME/.byok-cli-hub"
LEGACY_BIN_DIR="$HOME/.local/bin"
LEGACY_SHIM="$LEGACY_BIN_DIR/byok-cli-hub"
LEGACY_EXT_DIR="$COPILOT_HOME/extensions/byok-cli-hub-copilot"
NEW_DEFAULT_INSTALL_DIR="$HOME/.local/share/byok-bridge"
NEW_DEFAULT_DATA_DIR="$HOME/.byok-bridge"
NEW_DEFAULT_SHIM="$LEGACY_BIN_DIR/byok"
NEW_DEFAULT_EXT_DIR="$COPILOT_HOME/extensions/byok-bridge-copilot"
mkdir -p "$LEGACY_INSTALL_DIR" "$LEGACY_DATA_DIR" "$LEGACY_BIN_DIR" "$LEGACY_EXT_DIR"
printf '%s\n' '#!/usr/bin/env bash' '# BYOK_CLI_HUB_MANAGED_SHIM=1' > "$LEGACY_SHIM"
chmod 755 "$LEGACY_SHIM"
: > "$LEGACY_DATA_DIR/.byok-cli-hub-data"
cp "$REPO_ROOT/config/providers.example.json" "$LEGACY_DATA_DIR/providers.json"
printf '%s\n' '{"providerId":"legacy","model":"legacy-model"}' > "$LEGACY_DATA_DIR/state.json"
printf '%s\n' '{"version":1,"caches":{}}' > "$LEGACY_DATA_DIR/models-cache.json"
printf '%s\n' 'preserve-me' > "$LEGACY_DATA_DIR/user-file.txt"
: > "$LEGACY_EXT_DIR/.byok-cli-hub-managed"
printf '\n' >> "$HOME/.bashrc"
cat >> "$HOME/.bashrc" << EOF
# >>> BYOK CLI Hub managed shell integration >>>
# BYOK_CLI_HUB_MANAGED_BASHRC=1
# BYOK_CLI_HUB_BASHRC_ORIGINAL_FILE_PRESENT=1
# BYOK_CLI_HUB_BASHRC_PREFIX_NEWLINE_ADDED=0
if [[ -r '/legacy/helper' ]]; then
  source '/legacy/helper' --byok-cli-hub-managed-command '$LEGACY_SHIM'
fi
# <<< BYOK CLI Hub managed shell integration <<<
EOF
node -e '
  const fs=require("node:fs"), p=process.argv[1];
  fs.writeFileSync(p, JSON.stringify({schemaVersion:1,product:"byok-cli-hub",appVersion:"0.0.3",installedAt:new Date().toISOString(),installDir:process.argv[2],dataDir:process.argv[3],binDir:process.argv[4],extensionDir:process.argv[5],withExtension:true,bashrcPath:process.argv[6],shellStartupManaged:true,managedFiles:["byok-cli-hub"]},null,2)+"\n");
' "$LEGACY_INSTALL_DIR/.byok-cli-hub-install.json" "$LEGACY_INSTALL_DIR" "$LEGACY_DATA_DIR" "$LEGACY_BIN_DIR" "$LEGACY_EXT_DIR" "$HOME/.bashrc"
LEGACY_SNAPSHOT="$(snapshot_tree "$HOME")"
if BYOK_BRIDGE_TEST_FAIL_AT=legacy-data-copy bash "$REPO_ROOT/bin/linux/install.sh" >/dev/null 2>&1; then
  echo 'Legacy data-copy failure unexpectedly succeeded.' >&2
  exit 1
fi
[[ "$LEGACY_SNAPSHOT" == "$(snapshot_tree "$HOME")" ]]
bash "$REPO_ROOT/bin/linux/install.sh" >/dev/null
[[ -f "$NEW_DEFAULT_INSTALL_DIR/.byok-bridge-install.json" ]]
node -e 'const m=require(process.argv[1]);if(m.migratedFrom!=="0.0.3"||m.managedFiles.length!==1||m.managedFiles[0]!=="byok")process.exit(1)' "$NEW_DEFAULT_INSTALL_DIR/.byok-bridge-install.json"
[[ -x "$NEW_DEFAULT_SHIM" ]]
[[ -f "$NEW_DEFAULT_DATA_DIR/providers.json" ]]
[[ -f "$NEW_DEFAULT_DATA_DIR/state.json" ]]
[[ -f "$NEW_DEFAULT_DATA_DIR/models-cache.json" ]]
[[ "$(cat "$NEW_DEFAULT_DATA_DIR/user-file.txt")" == 'preserve-me' ]]
[[ ! -e "$NEW_DEFAULT_DATA_DIR/.byok-cli-hub-data" ]]
[[ -f "$NEW_DEFAULT_EXT_DIR/.byok-bridge-managed" ]]
[[ ! -e "$LEGACY_INSTALL_DIR" && ! -e "$LEGACY_DATA_DIR" && ! -e "$LEGACY_SHIM" && ! -e "$LEGACY_EXT_DIR" ]]
grep -q '^# >>> BYOK Bridge managed shell integration >>>$' "$HOME/.bashrc"
! grep -q 'BYOK_CLI_HUB' "$HOME/.bashrc"
bash --noprofile --rcfile "$HOME/.bashrc" -ic '[[ "$(type -t byok)" == function ]]' 2>/dev/null

echo 'Linux installer/update/uninstaller test passed.'
