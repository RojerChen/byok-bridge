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
    if (fs.existsSync(path.join(root, "doc", "plan.md")))
      throw new Error("Internal planning file was included in the application snapshot.");
  ' "$1"
}

bash -n \
  "$REPO_ROOT/bin/linux/install.sh" \
  "$REPO_ROOT/bin/linux/run.sh" \
  "$REPO_ROOT/bin/linux/uninstall.sh" \
  "$REPO_ROOT/shell/bash/byok-cli-hub.bash" \
  "$REPO_ROOT/bin/linux/byok-cli-hub"
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
printf '%s\n' 'preserve-shell-helper' > "$UNOWNED_ROOT/bin/byok-cli-hub-shell"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$UNOWNED_ROOT/app" \
  --data-dir "$UNOWNED_ROOT/data" \
  --bin-dir "$UNOWNED_ROOT/bin" >/dev/null
[[ "$(cat "$UNOWNED_ROOT/bin/byok-cli-hub-shell")" == 'preserve-shell-helper' ]]
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$UNOWNED_ROOT/app" >/dev/null
[[ "$(cat "$UNOWNED_ROOT/bin/byok-cli-hub-shell")" == 'preserve-shell-helper' ]]

APP_DIR="$TEST_ROOT/app"
DATA_DIR="$TEST_ROOT/data"
BIN_DIR="$TEST_ROOT/bin"

# A failed fresh install must not leave newly initialized data behind.
FRESH_APP_DIR="$TEST_ROOT/fresh-failure/app"
FRESH_DATA_DIR="$TEST_ROOT/fresh-failure/data"
FRESH_BIN_DIR="$TEST_ROOT/fresh-failure/bin"
if BYOK_CLI_HUB_TEST_FAIL_AT=after-app-backup bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$FRESH_APP_DIR" \
  --data-dir "$FRESH_DATA_DIR" \
  --bin-dir "$FRESH_BIN_DIR" >/dev/null 2>&1; then
  echo 'Injected fresh-install failure unexpectedly succeeded.' >&2
  exit 1
fi
[[ ! -e "$FRESH_APP_DIR" ]]
[[ ! -e "$FRESH_DATA_DIR" ]]
[[ ! -e "$FRESH_BIN_DIR/byok-cli-hub" ]]

# Creation flags must be registered before chmod so either failure restores an
# existing empty data directory byte-for-byte and leaves no application files.
for failure_point in data-marker-chmod data-config-chmod; do
  FAILURE_ROOT="$TEST_ROOT/$failure_point"
  FAILURE_APP_DIR="$FAILURE_ROOT/app"
  FAILURE_DATA_DIR="$FAILURE_ROOT/data"
  FAILURE_BIN_DIR="$FAILURE_ROOT/bin"
  mkdir -p "$FAILURE_DATA_DIR"
  DATA_BEFORE="$(snapshot_tree "$FAILURE_DATA_DIR")"
  if BYOK_CLI_HUB_TEST_FAIL_AT="$failure_point" bash "$REPO_ROOT/bin/linux/install.sh" \
    --install-dir "$FAILURE_APP_DIR" \
    --data-dir "$FAILURE_DATA_DIR" \
    --bin-dir "$FAILURE_BIN_DIR" >/dev/null 2>&1; then
    echo "Injected $failure_point failure unexpectedly succeeded." >&2
    exit 1
  fi
  [[ "$DATA_BEFORE" == "$(snapshot_tree "$FAILURE_DATA_DIR")" ]]
  [[ ! -e "$FAILURE_APP_DIR" ]]
  [[ ! -e "$FAILURE_BIN_DIR/byok-cli-hub" ]]
done

bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" \
  --with-extension

[[ -f "$APP_DIR/.byok-cli-hub-install.json" ]]
node -e 'const m=require(process.argv[1]); if(m.appVersion!==process.argv[2]||m.withExtension!==true) process.exit(1)' "$APP_DIR/.byok-cli-hub-install.json" "$APP_VERSION"
assert_installed_readme_documentation "$APP_DIR"
[[ -f "$APP_DIR/ui/theme.json" ]]
[[ -f "$APP_DIR/ui/messages/app.json" ]]
[[ -f "$DATA_DIR/providers.json" ]]
[[ -f "$DATA_DIR/.byok-cli-hub-data" ]]
grep -q '^# BYOK_CLI_HUB_MANAGED_SHIM=1$' "$BIN_DIR/byok-cli-hub"
grep -q '^# BYOK_CLI_HUB_MANAGED_SHELL_INTEGRATION=1$' "$APP_DIR/shell/bash/byok-cli-hub.bash"
[[ -f "$APP_DIR/libexec/linux/bash-profile-manager.mjs" ]]
[[ ! -e "$BIN_DIR/byok-cli-hub-shell" ]]
grep -q '^# BYOK_CLI_HUB_MANAGED_BASHRC=1$' "$HOME/.bashrc"
grep -Fq "source '$APP_DIR/shell/bash/byok-cli-hub.bash' --byok-cli-hub-managed-command '$BIN_DIR/byok-cli-hub'" "$HOME/.bashrc"
[[ "$(grep -c '^# >>> BYOK CLI Hub managed shell integration >>>$' "$HOME/.bashrc")" -eq 1 ]]
bash -c 'source "$1" --byok-cli-hub-managed-command "$2"; declare -F byok-cli-hub >/dev/null; declare -F byok-cli-hub-deactivate >/dev/null' _ "$APP_DIR/shell/bash/byok-cli-hub.bash" "$BIN_DIR/byok-cli-hub"
BYOK_TEST_EXPECTED_BASHRC="$HOME/.bashrc" node -e 'const m=require(process.argv[1]); if(m.managedFiles.length!==1||m.managedFiles[0]!=="byok-cli-hub"||m.shellStartupManaged!==true||m.bashrcPath!==process.env.BYOK_TEST_EXPECTED_BASHRC) process.exit(1)' "$APP_DIR/.byok-cli-hub-install.json"
bash --noprofile --rcfile "$HOME/.bashrc" -ic '[[ "$(type -t byok-cli-hub)" == function ]]' 2>/dev/null
# Keep this startup integration assertion fully offline.
node -e 'const fs=require("node:fs"),p=process.argv[1],c=JSON.parse(fs.readFileSync(p,"utf8"));c.providers["openai-compatible"].models=["gpt-4o"];fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n")' "$DATA_DIR/providers.json"
STARTUP_TEST_LOG="$TEST_ROOT/bash-startup-launch.log"
if ! bash --noprofile --rcfile "$HOME/.bashrc" -ic 'byok-cli-hub --cli copilot --provider openai-compatible --model gpt-4o --api-key startup-test-secret >/dev/null && [[ "$COPILOT_PROVIDER_TYPE" == openai && "$COPILOT_MODEL" == gpt-4o ]]' >"$STARTUP_TEST_LOG" 2>&1; then
  cat "$STARTUP_TEST_LOG" >&2
  echo 'Automatically loaded byok-cli-hub did not retain its environment.' >&2
  exit 1
fi
"$BIN_DIR/byok-cli-hub" --cli copilot --provider openai-compatible --dry-run

# A manifest from a newer application version must not be downgraded.
cp "$APP_DIR/.byok-cli-hub-install.json" "$TEST_ROOT/manifest-backup.json"
node -e 'const fs=require("node:fs"),p=process.argv[1],m=JSON.parse(fs.readFileSync(p,"utf8"));m.appVersion=process.argv[2];fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")' "$APP_DIR/.byok-cli-hub-install.json" "$NEWER_APP_VERSION"
if bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
  echo 'Installer accepted a managed manifest from a newer version.' >&2
  exit 1
fi
cp "$TEST_ROOT/manifest-backup.json" "$APP_DIR/.byok-cli-hub-install.json"

# Managed updates must not silently relocate the shim and orphan the old one.
if bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$TEST_ROOT/relocated-bin" >/dev/null 2>&1; then
  echo 'Managed update unexpectedly relocated bin-dir.' >&2
  exit 1
fi
[[ -f "$BIN_DIR/byok-cli-hub" ]]
[[ ! -e "$TEST_ROOT/relocated-bin/byok-cli-hub" ]]

# A failed copy into the example backup must not register an empty backup,
# alter any data byte, or leave the temporary backup file behind.
DATA_BEFORE="$(snapshot_tree "$DATA_DIR")"
if BYOK_CLI_HUB_TEST_FAIL_AT=data-example-backup-copy bash "$REPO_ROOT/bin/linux/install.sh" \
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

# Build an old-layout fixture: its manifest owns an external source helper and
# predates automatic Bash startup metadata.
BASHRC_REMOVE_TEMP="$(mktemp "$HOME/.bashrc.remove.XXXXXX")"
node "$REPO_ROOT/libexec/linux/bash-profile-manager.mjs" remove "$HOME/.bashrc" "$BASHRC_REMOVE_TEMP" >/dev/null
chmod --reference="$HOME/.bashrc" "$BASHRC_REMOVE_TEMP"
mv -f -- "$BASHRC_REMOVE_TEMP" "$HOME/.bashrc"
cp "$APP_DIR/shell/bash/byok-cli-hub.bash" "$BIN_DIR/byok-cli-hub-shell"
node -e 'const fs=require("node:fs"),p=process.argv[1],m=JSON.parse(fs.readFileSync(p,"utf8"));delete m.bashrcPath;delete m.shellStartupManaged;m.managedFiles=["byok-cli-hub","byok-cli-hub-shell"];fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")' "$APP_DIR/.byok-cli-hub-install.json"
[[ "$BASHRC_ORIGINAL_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]

# Every switch boundary in an old-to-new update must restore the previous app,
# shim, Bash startup file, legacy helper, extension, and user data.
CONFIG_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")"
EXT_DIR="$COPILOT_HOME/extensions/byok-cli-hub-copilot"
for failure_point in after-app-backup after-shim-backup after-bashrc-backup after-legacy-shell-helper-backup after-extension-backup before-backup-cleanup; do
  printf '%s\n' "$failure_point" > "$APP_DIR/rollback-sentinel.txt"
  printf '# rollback=%s\n' "$failure_point" >> "$BIN_DIR/byok-cli-hub"
  printf '# rollback=%s\n' "$failure_point" >> "$BIN_DIR/byok-cli-hub-shell"
  printf '%s\n' "$failure_point" > "$EXT_DIR/rollback-sentinel.txt"
  printf 'example=%s\n' "$failure_point" > "$DATA_DIR/providers.example.json"
  BASHRC_BEFORE_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")"
  if BYOK_CLI_HUB_TEST_FAIL_AT="$failure_point" bash "$REPO_ROOT/bin/linux/install.sh" \
    --install-dir "$APP_DIR" \
    --data-dir "$DATA_DIR" \
    --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
    echo "Failure injection did not fail at $failure_point." >&2
    exit 1
  fi
  [[ "$(cat "$APP_DIR/rollback-sentinel.txt")" == "$failure_point" ]]
  grep -q "^# rollback=$failure_point$" "$BIN_DIR/byok-cli-hub"
  grep -q "^# rollback=$failure_point$" "$BIN_DIR/byok-cli-hub-shell"
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
[[ "$(grep -c '^# >>> BYOK CLI Hub managed shell integration >>>$' "$HOME/.bashrc")" -eq 1 ]]
[[ ! -e "$BIN_DIR/byok-cli-hub-shell" ]]
node -e 'const m=require(process.argv[1]);if(m.shellStartupManaged!==true||!m.bashrcPath||m.managedFiles.includes("byok-cli-hub-shell"))process.exit(1)' "$APP_DIR/.byok-cli-hub-install.json"

# Even a legacy manifest claim is insufficient to delete a same-name file
# whose ownership marker is missing.
printf '%s\n' 'preserve-unowned-legacy-helper' > "$BIN_DIR/byok-cli-hub-shell"
node -e 'const fs=require("node:fs"),p=process.argv[1],m=JSON.parse(fs.readFileSync(p,"utf8"));m.managedFiles=["byok-cli-hub","byok-cli-hub-shell"];fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")' "$APP_DIR/.byok-cli-hub-install.json"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" >/dev/null
[[ "$(cat "$BIN_DIR/byok-cli-hub-shell")" == 'preserve-unowned-legacy-helper' ]]

bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR"
[[ ! -e "$APP_DIR" ]]
[[ ! -e "$BIN_DIR/byok-cli-hub" ]]
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
[[ ! -e "$BIN_DIR/byok-cli-hub-shell" ]]
[[ "$BASHRC_ORIGINAL_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]

# An unowned extension must survive install and uninstall when extension support is not requested.
mkdir -p "$EXT_DIR"
printf '%s\n' 'preserve-me' > "$EXT_DIR/unknown-owner.txt"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
[[ -f "$EXT_DIR/unknown-owner.txt" ]]
[[ ! -f "$EXT_DIR/.byok-cli-hub-managed" ]]
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR"
[[ -f "$EXT_DIR/unknown-owner.txt" ]]
[[ "$BASHRC_ORIGINAL_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.bashrc")" ]]

echo 'Linux installer/update/uninstaller test passed.'
