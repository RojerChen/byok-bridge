#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/byok-linux-installer.XXXXXX")"

cleanup() {
  [[ -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

bash -n \
  "$REPO_ROOT/bin/linux/install.sh" \
  "$REPO_ROOT/bin/linux/run.sh" \
  "$REPO_ROOT/bin/linux/uninstall.sh" \
  "$REPO_ROOT/bin/linux/byok-cli-hub"

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

APP_DIR="$TEST_ROOT/app"
DATA_DIR="$TEST_ROOT/data"
BIN_DIR="$TEST_ROOT/bin"

bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" \
  --with-extension

[[ -f "$APP_DIR/.byok-cli-hub-install.json" ]]
node -e 'const m=require(process.argv[1]); if(m.appVersion!=="0.0.2"||m.withExtension!==true) process.exit(1)' "$APP_DIR/.byok-cli-hub-install.json"
[[ -f "$DATA_DIR/providers.json" ]]
[[ -f "$DATA_DIR/.byok-cli-hub-data" ]]
grep -q '^# BYOK_CLI_HUB_MANAGED_SHIM=1$' "$BIN_DIR/byok-cli-hub"
"$BIN_DIR/byok-cli-hub" --cli copilot --provider openai-compatible --dry-run

# A manifest from a newer application version must not be downgraded.
cp "$APP_DIR/.byok-cli-hub-install.json" "$TEST_ROOT/manifest-backup.json"
node -e 'const fs=require("node:fs"),p=process.argv[1],m=JSON.parse(fs.readFileSync(p,"utf8"));m.appVersion="0.0.3";fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n")' "$APP_DIR/.byok-cli-hub-install.json"
if bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
  echo 'Installer accepted a managed manifest from a newer version.' >&2
  exit 1
fi
cp "$TEST_ROOT/manifest-backup.json" "$APP_DIR/.byok-cli-hub-install.json"

# Update must preserve config and replace the snapshot transactionally.
CONFIG_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
[[ "$CONFIG_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")" ]]

# Every switch boundary must restore the previous app, shim, and extension.
EXT_DIR="$COPILOT_HOME/extensions/byok-cli-hub-copilot"
for failure_point in after-app-backup after-shim-backup after-extension-backup before-backup-cleanup; do
  printf '%s\n' "$failure_point" > "$APP_DIR/rollback-sentinel.txt"
  printf '# rollback=%s\n' "$failure_point" >> "$BIN_DIR/byok-cli-hub"
  printf '%s\n' "$failure_point" > "$EXT_DIR/rollback-sentinel.txt"
  if BYOK_CLI_HUB_TEST_FAIL_AT="$failure_point" bash "$REPO_ROOT/bin/linux/install.sh" \
    --install-dir "$APP_DIR" \
    --data-dir "$DATA_DIR" \
    --bin-dir "$BIN_DIR" >/dev/null 2>&1; then
    echo "Failure injection did not fail at $failure_point." >&2
    exit 1
  fi
  [[ "$(cat "$APP_DIR/rollback-sentinel.txt")" == "$failure_point" ]]
  grep -q "^# rollback=$failure_point$" "$BIN_DIR/byok-cli-hub"
  [[ "$(cat "$EXT_DIR/rollback-sentinel.txt")" == "$failure_point" ]]
done

bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR"
[[ ! -e "$APP_DIR" ]]
[[ ! -e "$BIN_DIR/byok-cli-hub" ]]
[[ ! -e "$EXT_DIR" ]]
[[ -f "$DATA_DIR/providers.json" ]]

bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR" --purge-data --yes
[[ ! -e "$DATA_DIR" ]]

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

echo 'Linux installer/update/uninstaller test passed.'
