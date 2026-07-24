#!/usr/bin/env bash
set -euo pipefail

# BYOK CLI Hub transactional installer for Linux & WSL2.

SHOW_CHECK=0
WITH_EXTENSION=0
ADOPT_LEGACY=0
INSTALL_DIR=""
DATA_DIR=""
BIN_DIR=""
STAGING_DIR=""
BACKUP_DIR=""
SHIM_TEMP=""
SHIM_BACKUP=""
EXT_STAGING_DIR=""
EXT_BACKUP_DIR=""
SWITCHED_INSTALL=0
SWITCHED_SHIM=0
SWITCHED_EXTENSION=0

die() {
  echo "Error: $*" >&2
  exit 1
}

print_help() {
  cat << 'EOF'
BYOK CLI Hub Installer (Linux / WSL2)

Usage:
  install.sh [options]

Options:
  --install-dir PATH   Absolute application snapshot path
                       (default: ${XDG_DATA_HOME:-$HOME/.local/share}/byok-cli-hub)
  --data-dir PATH      Absolute user configuration/state path
                       (default: $HOME/.byok-cli-hub)
  --bin-dir PATH       Absolute executable shim directory
                       (default: $HOME/.local/bin)
  --with-extension     Install/update the optional Copilot CLI extension
  --adopt-legacy       Explicitly replace a recognizable pre-manifest install
  --check              Validate prerequisites and resolved paths; write nothing
  --help, -h           Show this help message
EOF
}

require_option_value() {
  local option="$1"
  local value="${2-}"
  [[ -n "$value" && "$value" != --* ]] || die "Option '$option' requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir|--data-dir|--bin-dir)
      require_option_value "$1" "${2-}"
      case "$1" in
        --install-dir) INSTALL_DIR="$2" ;;
        --data-dir) DATA_DIR="$2" ;;
        --bin-dir) BIN_DIR="$2" ;;
      esac
      shift 2
      ;;
    --with-extension) WITH_EXTENSION=1; shift ;;
    --adopt-legacy) ADOPT_LEGACY=1; shift ;;
    --check) SHOW_CHECK=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) die "Unknown option '$1'. Use --help for usage." ;;
  esac
done

command -v node >/dev/null 2>&1 || die "Node.js 22 or later is required."
NODE_MAJOR="$(node -e "process.stdout.write(process.versions.node.split('.')[0])")"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ && "$NODE_MAJOR" -ge 22 ]] \
  || die "Node.js major version must be >= 22. Current: $(node --version 2>/dev/null || echo unknown)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
command -v realpath >/dev/null 2>&1 || die "The 'realpath' command is required."
HOME_CANON="$(realpath -m -- "$HOME")"

canonicalize_absolute() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || die "$label cannot be empty."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label must not contain newline characters."
  [[ "$value" == /* ]] || die "$label must be an absolute path: $value"
  realpath -m -- "$value"
}

is_same_or_parent() {
  local parent="$1"
  local child="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

assert_safe_target() {
  local label="$1"
  local target="$2"
  case "$target" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "$label resolves to a protected system path: $target"
      ;;
  esac
  [[ "$target" != "$HOME_CANON" ]] || die "$label must not be the home directory."
  [[ "$target" != "$REPO_ROOT" ]] || die "$label must not be the repository root."
  is_same_or_parent "$target" "$HOME_CANON" && die "$label must not contain the home directory: $target"
  is_same_or_parent "$target" "$REPO_ROOT" && die "$label must not contain the repository: $target"
  return 0
}

assert_not_overlapping() {
  local left_label="$1" left="$2" right_label="$3" right="$4"
  if is_same_or_parent "$left" "$right" || is_same_or_parent "$right" "$left"; then
    die "$left_label and $right_label must not overlap: '$left' / '$right'"
  fi
  return 0
}

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
TARGET_INSTALL_DIR="$(canonicalize_absolute 'install-dir' "${INSTALL_DIR:-$XDG_DATA_HOME/byok-cli-hub}")"
TARGET_DATA_DIR="$(canonicalize_absolute 'data-dir' "${DATA_DIR:-$HOME/.byok-cli-hub}")"
TARGET_BIN_DIR="$(canonicalize_absolute 'bin-dir' "${BIN_DIR:-$HOME/.local/bin}")"
COPILOT_HOME_VALUE="${COPILOT_HOME:-$HOME/.copilot}"
COPILOT_HOME_CANON="$(canonicalize_absolute 'COPILOT_HOME' "$COPILOT_HOME_VALUE")"
TARGET_EXT_DIR="$(canonicalize_absolute 'extension-dir' "$COPILOT_HOME_CANON/extensions/byok-cli-hub-copilot")"
SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"

assert_safe_target 'install-dir' "$TARGET_INSTALL_DIR"
assert_safe_target 'data-dir' "$TARGET_DATA_DIR"
assert_safe_target 'bin-dir' "$TARGET_BIN_DIR"
assert_safe_target 'extension-dir' "$TARGET_EXT_DIR"
assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'data-dir' "$TARGET_DATA_DIR"
assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'bin-dir' "$TARGET_BIN_DIR"
assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'bin-dir' "$TARGET_BIN_DIR"
assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'extension-dir' "$TARGET_EXT_DIR"
assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'extension-dir' "$TARGET_EXT_DIR"

echo "=== BYOK CLI Hub Installer ==="
echo "[OK] Node.js: $(node --version)"
echo "Resolved install dir: $TARGET_INSTALL_DIR"
echo "Resolved data dir:    $TARGET_DATA_DIR"
echo "Resolved bin dir:     $TARGET_BIN_DIR"
echo "Resolved extension:   $TARGET_EXT_DIR"

COPILOT_STATUS=0
if command -v copilot >/dev/null 2>&1; then
  echo "[OK] GitHub Copilot CLI: $(copilot --version 2>/dev/null || echo found)"
else
  echo "[WARNING] GitHub Copilot CLI was not found in PATH."
  COPILOT_STATUS=1
fi

if [[ "$SHOW_CHECK" -eq 1 ]]; then
  echo "Preflight check complete; no files were written."
  [[ "$COPILOT_STATUS" -eq 0 ]] || exit 2
  exit 0
fi

MANIFEST_NAME=".byok-cli-hub-install.json"
MANIFEST_PATH="$TARGET_INSTALL_DIR/$MANIFEST_NAME"
if [[ -f "$MANIFEST_PATH" ]]; then
  PREVIOUS_VALUES="$(node -e '
    const fs = require("node:fs");
    const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (m.product !== "byok-cli-hub" || m.schemaVersion !== 1) process.exit(2);
    for (const key of ["dataDir", "binDir", "extensionDir", "withExtension"])
      process.stdout.write(String(m[key] ?? "") + "\n");
  ' "$MANIFEST_PATH")" || die "Existing install manifest is invalid."
  mapfile -t PREVIOUS_FIELDS <<< "$PREVIOUS_VALUES"
  [[ -n "$DATA_DIR" ]] || TARGET_DATA_DIR="$(canonicalize_absolute 'manifest dataDir' "${PREVIOUS_FIELDS[0]}")"
  [[ -n "$BIN_DIR" ]] || TARGET_BIN_DIR="$(canonicalize_absolute 'manifest binDir' "${PREVIOUS_FIELDS[1]}")"
  TARGET_EXT_DIR="$(canonicalize_absolute 'manifest extensionDir' "${PREVIOUS_FIELDS[2]}")"
  [[ "${PREVIOUS_FIELDS[3]}" != "true" ]] || WITH_EXTENSION=1
  SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"
  assert_safe_target 'data-dir' "$TARGET_DATA_DIR"
  assert_safe_target 'bin-dir' "$TARGET_BIN_DIR"
  assert_safe_target 'extension-dir' "$TARGET_EXT_DIR"
  assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'data-dir' "$TARGET_DATA_DIR"
  assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'bin-dir' "$TARGET_BIN_DIR"
  assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'bin-dir' "$TARGET_BIN_DIR"
fi
if [[ -e "$TARGET_INSTALL_DIR" && ! -f "$MANIFEST_PATH" ]]; then
  if [[ "$ADOPT_LEGACY" -ne 1 || ! -f "$TARGET_INSTALL_DIR/manager/manager.mjs" ]]; then
    die "Existing install-dir is not owned by this installer. Use --adopt-legacy only after verifying it is a legacy BYOK CLI Hub install."
  fi
fi
if [[ -e "$SHIM_PATH" ]] && ! grep -q '^# BYOK_CLI_HUB_MANAGED_SHIM=1$' "$SHIM_PATH" 2>/dev/null; then
  if [[ "$ADOPT_LEGACY" -ne 1 ]] || ! grep -q 'byok-cli-hub' "$SHIM_PATH" 2>/dev/null; then
    die "Refusing to overwrite unowned shim: $SHIM_PATH"
  fi
fi
if [[ "$WITH_EXTENSION" -eq 1 && -e "$TARGET_EXT_DIR" && ! -f "$TARGET_EXT_DIR/.byok-cli-hub-managed" ]]; then
  if [[ "$ADOPT_LEGACY" -ne 1 || ! -f "$TARGET_EXT_DIR/extension.mjs" ]]; then
    die "Refusing to overwrite unowned extension: $TARGET_EXT_DIR"
  fi
fi

umask 077
mkdir -p "$TARGET_DATA_DIR"
chmod 700 "$TARGET_DATA_DIR"
: > "$TARGET_DATA_DIR/.byok-cli-hub-data"
chmod 600 "$TARGET_DATA_DIR/.byok-cli-hub-data"
if [[ ! -f "$TARGET_DATA_DIR/providers.json" ]]; then
  CONFIG_SOURCE="$REPO_ROOT/config/providers.example.json"
  [[ -f "$CONFIG_SOURCE" ]] || CONFIG_SOURCE="$REPO_ROOT/config/providers.json"
  [[ -f "$CONFIG_SOURCE" ]] || die "Bundled provider configuration is missing."
  cp "$CONFIG_SOURCE" "$TARGET_DATA_DIR/providers.json"
  chmod 600 "$TARGET_DATA_DIR/providers.json"
  echo "[OK] Initialized $TARGET_DATA_DIR/providers.json"
else
  echo "[INFO] Preserved $TARGET_DATA_DIR/providers.json"
fi
if [[ -f "$REPO_ROOT/config/providers.example.json" ]]; then
  cp "$REPO_ROOT/config/providers.example.json" "$TARGET_DATA_DIR/providers.example.json"
  chmod 600 "$TARGET_DATA_DIR/providers.example.json"
fi

PARENT_INSTALL_DIR="$(dirname "$TARGET_INSTALL_DIR")"
mkdir -p "$PARENT_INSTALL_DIR" "$TARGET_BIN_DIR"
STAGING_DIR="$(mktemp -d "$PARENT_INSTALL_DIR/.byok-cli-hub.staging.XXXXXX")"
BACKUP_DIR="${TARGET_INSTALL_DIR}.backup.$$"
SHIM_TEMP="$(mktemp "$TARGET_BIN_DIR/.byok-cli-hub.shim.XXXXXX")"
SHIM_BACKUP="${SHIM_PATH}.backup.$$"

rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$status" -ne 0 ]]; then
    echo "[ERROR] Installation failed; restoring the previous installation." >&2
    if [[ "$SWITCHED_EXTENSION" -eq 1 ]]; then
      rm -rf -- "$TARGET_EXT_DIR"
      [[ -d "$EXT_BACKUP_DIR" ]] && mv -- "$EXT_BACKUP_DIR" "$TARGET_EXT_DIR"
    fi
    if [[ "$SWITCHED_SHIM" -eq 1 ]]; then
      rm -f -- "$SHIM_PATH"
      [[ -f "$SHIM_BACKUP" ]] && mv -- "$SHIM_BACKUP" "$SHIM_PATH"
    fi
    if [[ "$SWITCHED_INSTALL" -eq 1 ]]; then
      rm -rf -- "$TARGET_INSTALL_DIR"
      [[ -d "$BACKUP_DIR" ]] && mv -- "$BACKUP_DIR" "$TARGET_INSTALL_DIR"
    fi
  fi
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf -- "$STAGING_DIR"
  [[ -n "$SHIM_TEMP" && -f "$SHIM_TEMP" ]] && rm -f -- "$SHIM_TEMP"
  [[ -n "$EXT_STAGING_DIR" && -d "$EXT_STAGING_DIR" ]] && rm -rf -- "$EXT_STAGING_DIR"
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "$REPO_ROOT/manager" "$STAGING_DIR/"
cp -R "$REPO_ROOT/config" "$STAGING_DIR/"
cp -R "$REPO_ROOT/bin" "$STAGING_DIR/"
[[ ! -d "$REPO_ROOT/extension" ]] || cp -R "$REPO_ROOT/extension" "$STAGING_DIR/"
find "$STAGING_DIR" -type d -exec chmod 755 {} +
find "$STAGING_DIR" -type f -exec chmod 644 {} +
chmod 755 "$STAGING_DIR/manager/manager.mjs" "$STAGING_DIR/bin/linux/"*.sh "$STAGING_DIR/bin/linux/byok-cli-hub"

node --check "$STAGING_DIR/manager/manager.mjs"
node "$STAGING_DIR/manager/manager.mjs" --data-dir "$TARGET_DATA_DIR" --self-check

INSTALL_Q="$(printf '%q' "$TARGET_INSTALL_DIR")"
DATA_Q="$(printf '%q' "$TARGET_DATA_DIR")"
cat > "$SHIM_TEMP" << EOF
#!/usr/bin/env bash
# BYOK_CLI_HUB_MANAGED_SHIM=1
set -euo pipefail
export BYOK_CLI_HUB_DATA_DIR=$DATA_Q
exec $INSTALL_Q/bin/linux/run.sh "\$@"
EOF
chmod 755 "$SHIM_TEMP"

node -e '
  const fs = require("node:fs");
  const [file, installDir, dataDir, binDir, extensionDir, withExtension] = process.argv.slice(1);
  fs.writeFileSync(file, JSON.stringify({
    schemaVersion: 1,
    product: "byok-cli-hub",
    installedAt: new Date().toISOString(),
    installDir, dataDir, binDir, extensionDir,
    withExtension: withExtension === "1",
    managedFiles: ["byok-cli-hub"]
  }, null, 2) + "\n", { mode: 0o644 });
' "$STAGING_DIR/$MANIFEST_NAME" "$TARGET_INSTALL_DIR" "$TARGET_DATA_DIR" "$TARGET_BIN_DIR" "$TARGET_EXT_DIR" "$WITH_EXTENSION"

if [[ "$WITH_EXTENSION" -eq 1 ]]; then
  [[ -d "$STAGING_DIR/extension" ]] || die "Bundled extension directory is missing."
  mkdir -p "$(dirname "$TARGET_EXT_DIR")"
  EXT_STAGING_DIR="$(mktemp -d "$(dirname "$TARGET_EXT_DIR")/.byok-cli-hub.extension.XXXXXX")"
  cp -R "$STAGING_DIR/extension/." "$EXT_STAGING_DIR/"
  : > "$EXT_STAGING_DIR/.byok-cli-hub-managed"
  EXT_BACKUP_DIR="${TARGET_EXT_DIR}.backup.$$"
fi

[[ ! -e "$BACKUP_DIR" ]] || die "Backup path already exists: $BACKUP_DIR"
if [[ -d "$TARGET_INSTALL_DIR" ]]; then mv -- "$TARGET_INSTALL_DIR" "$BACKUP_DIR"; fi
mv -- "$STAGING_DIR" "$TARGET_INSTALL_DIR"
STAGING_DIR=""
SWITCHED_INSTALL=1

[[ ! -e "$SHIM_BACKUP" ]] || die "Shim backup path already exists: $SHIM_BACKUP"
if [[ -f "$SHIM_PATH" ]]; then mv -- "$SHIM_PATH" "$SHIM_BACKUP"; fi
mv -- "$SHIM_TEMP" "$SHIM_PATH"
SHIM_TEMP=""
SWITCHED_SHIM=1

if [[ "$WITH_EXTENSION" -eq 1 ]]; then
  [[ ! -e "$EXT_BACKUP_DIR" ]] || die "Extension backup path already exists: $EXT_BACKUP_DIR"
  if [[ -d "$TARGET_EXT_DIR" ]]; then mv -- "$TARGET_EXT_DIR" "$EXT_BACKUP_DIR"; fi
  mv -- "$EXT_STAGING_DIR" "$TARGET_EXT_DIR"
  EXT_STAGING_DIR=""
  SWITCHED_EXTENSION=1
fi

node "$TARGET_INSTALL_DIR/manager/manager.mjs" --data-dir "$TARGET_DATA_DIR" --self-check

[[ ! -d "$BACKUP_DIR" ]] || rm -rf -- "$BACKUP_DIR"
[[ ! -f "$SHIM_BACKUP" ]] || rm -f -- "$SHIM_BACKUP"
[[ -z "$EXT_BACKUP_DIR" || ! -d "$EXT_BACKUP_DIR" ]] || rm -rf -- "$EXT_BACKUP_DIR"
SWITCHED_INSTALL=0
SWITCHED_SHIM=0
SWITCHED_EXTENSION=0
trap - EXIT INT TERM

echo "[OK] Installed application snapshot to $TARGET_INSTALL_DIR"
echo "[OK] Installed managed shim at $SHIM_PATH"
[[ "$WITH_EXTENSION" -ne 1 ]] || echo "[OK] Installed managed extension at $TARGET_EXT_DIR"
if [[ ":$PATH:" != *":$TARGET_BIN_DIR:"* ]]; then
  echo "[NOTICE] '$TARGET_BIN_DIR' is not in PATH. Add: export PATH=\"$TARGET_BIN_DIR:\$PATH\""
fi
echo "BYOK CLI Hub successfully installed."
