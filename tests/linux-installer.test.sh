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
  --bin-dir "$BIN_DIR"

[[ -f "$APP_DIR/.byok-cli-hub-install.json" ]]
[[ -f "$DATA_DIR/providers.json" ]]
[[ -f "$DATA_DIR/.byok-cli-hub-data" ]]
grep -q '^# BYOK_CLI_HUB_MANAGED_SHIM=1$' "$BIN_DIR/byok-cli-hub"
"$BIN_DIR/byok-cli-hub" --cli copilot --provider openai-compatible --dry-run

# Update must preserve config and replace the snapshot transactionally.
CONFIG_HASH="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")"
bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
[[ "$CONFIG_HASH" == "$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$DATA_DIR/providers.json")" ]]

bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR"
[[ ! -e "$APP_DIR" ]]
[[ ! -e "$BIN_DIR/byok-cli-hub" ]]
[[ -f "$DATA_DIR/providers.json" ]]

bash "$REPO_ROOT/bin/linux/install.sh" \
  --install-dir "$APP_DIR" \
  --data-dir "$DATA_DIR" \
  --bin-dir "$BIN_DIR"
bash "$REPO_ROOT/bin/linux/uninstall.sh" --install-dir "$APP_DIR" --purge-data --yes
[[ ! -e "$DATA_DIR" ]]

echo 'Linux installer/update/uninstaller test passed.'
