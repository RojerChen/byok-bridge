#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/byok-linux-installer.XXXXXX")"

cleanup() {
  [[ -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

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
  printf 'example=%s\n' "$failure_point" > "$DATA_DIR/providers.example.json"
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
  [[ "$(cat "$DATA_DIR/providers.example.json")" == "example=$failure_point" ]]
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
