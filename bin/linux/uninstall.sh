#!/usr/bin/env bash
set -euo pipefail

PURGE_DATA=0
FORCE_LEGACY=0
ASSUME_YES=0
INSTALL_DIR=""
DATA_DIR=""
BIN_DIR=""

die() { echo "Error: $*" >&2; exit 1; }

print_help() {
  cat << 'EOF'
BYOK CLI Hub Uninstaller (Linux / WSL2)

Usage:
  uninstall.sh [options]

Options:
  --install-dir PATH   Absolute installed snapshot path
  --data-dir PATH      Absolute data path (normally read from manifest)
  --bin-dir PATH       Absolute shim directory (normally read from manifest)
  --purge-data         Also remove user config/state after confirmation
  --yes                Confirm --purge-data non-interactively
  --force-legacy       Remove a recognizable pre-manifest installation
  --help, -h           Show this help message
EOF
}

require_option_value() {
  [[ -n "${2-}" && "${2-}" != --* ]] || die "Option '$1' requires a value."
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
    --purge-data) PURGE_DATA=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --force-legacy) FORCE_LEGACY=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    *) die "Unknown option '$1'. Use --help for usage." ;;
  esac
done

command -v node >/dev/null 2>&1 || die "Node.js is required to validate install metadata."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
command -v realpath >/dev/null 2>&1 || die "The 'realpath' command is required."
HOME_CANON="$(realpath -m -- "$HOME")"

canonicalize_absolute() {
  local label="$1" value="$2"
  [[ -n "$value" && "$value" == /* ]] || die "$label must be an absolute non-empty path."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label must not contain newlines."
  realpath -m -- "$value"
}

is_same_or_parent() { [[ "$2" == "$1" || "$2" == "$1/"* ]]; }
assert_safe_target() {
  local label="$1" target="$2"
  case "$target" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "$label resolves to a protected system path: $target" ;;
  esac
  [[ "$target" != "$HOME_CANON" && "$target" != "$REPO_ROOT" ]] || die "$label resolves to a protected path: $target"
  is_same_or_parent "$target" "$HOME_CANON" && die "$label contains the home directory: $target"
  is_same_or_parent "$target" "$REPO_ROOT" && die "$label contains the repository: $target"
  return 0
}

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
TARGET_INSTALL_DIR="$(canonicalize_absolute 'install-dir' "${INSTALL_DIR:-$XDG_DATA_HOME/byok-cli-hub}")"
assert_safe_target 'install-dir' "$TARGET_INSTALL_DIR"
MANIFEST_PATH="$TARGET_INSTALL_DIR/.byok-cli-hub-install.json"

manifest_value() {
  node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]];
    if (typeof value === "boolean") process.stdout.write(value ? "1" : "0");
    else if (value !== undefined && value !== null) process.stdout.write(String(value));
  ' "$MANIFEST_PATH" "$1"
}

if [[ -f "$MANIFEST_PATH" ]]; then
  [[ "$(manifest_value product)" == "byok-cli-hub" ]] || die "Install manifest product marker is invalid."
  MANIFEST_INSTALL_DIR="$(canonicalize_absolute 'manifest installDir' "$(manifest_value installDir)")"
  [[ "$MANIFEST_INSTALL_DIR" == "$TARGET_INSTALL_DIR" ]] || die "Manifest installDir does not match the requested target."
  TARGET_DATA_DIR="$(canonicalize_absolute 'data-dir' "${DATA_DIR:-$(manifest_value dataDir)}")"
  TARGET_BIN_DIR="$(canonicalize_absolute 'bin-dir' "${BIN_DIR:-$(manifest_value binDir)}")"
  TARGET_EXT_DIR="$(canonicalize_absolute 'extension-dir' "$(manifest_value extensionDir)")"
  WITH_EXTENSION="$(manifest_value withExtension)"
else
  [[ "$FORCE_LEGACY" -eq 1 && -f "$TARGET_INSTALL_DIR/manager/manager.mjs" ]] \
    || die "No valid ownership manifest found. Refusing to remove '$TARGET_INSTALL_DIR'."
  TARGET_DATA_DIR="$(canonicalize_absolute 'data-dir' "${DATA_DIR:-$HOME/.byok-cli-hub}")"
  TARGET_BIN_DIR="$(canonicalize_absolute 'bin-dir' "${BIN_DIR:-$HOME/.local/bin}")"
  COPILOT_HOME_CANON="$(canonicalize_absolute 'COPILOT_HOME' "${COPILOT_HOME:-$HOME/.copilot}")"
  TARGET_EXT_DIR="$COPILOT_HOME_CANON/extensions/byok-cli-hub-copilot"
  WITH_EXTENSION=1
fi

assert_safe_target 'data-dir' "$TARGET_DATA_DIR"
assert_safe_target 'bin-dir' "$TARGET_BIN_DIR"
assert_safe_target 'extension-dir' "$TARGET_EXT_DIR"
SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"

echo "=== BYOK CLI Hub Uninstaller ==="
echo "Resolved install dir: $TARGET_INSTALL_DIR"
echo "Resolved data dir:    $TARGET_DATA_DIR"
echo "Resolved shim:        $SHIM_PATH"

if [[ -f "$SHIM_PATH" ]]; then
  if grep -q '^# BYOK_CLI_HUB_MANAGED_SHIM=1$' "$SHIM_PATH" 2>/dev/null || [[ "$FORCE_LEGACY" -eq 1 ]]; then
    rm -f -- "$SHIM_PATH"
    echo "[OK] Removed managed shim."
  else
    echo "[WARNING] Preserved unowned shim: $SHIM_PATH" >&2
  fi
fi

if [[ "$WITH_EXTENSION" -eq 1 && -d "$TARGET_EXT_DIR" ]]; then
  if [[ -f "$TARGET_EXT_DIR/.byok-cli-hub-managed" ]] || [[ "$FORCE_LEGACY" -eq 1 ]]; then
    rm -rf -- "$TARGET_EXT_DIR"
    echo "[OK] Removed managed extension."
  else
    echo "[WARNING] Preserved unowned extension: $TARGET_EXT_DIR" >&2
  fi
fi

rm -rf -- "$TARGET_INSTALL_DIR"
echo "[OK] Removed managed application snapshot."

if [[ "$PURGE_DATA" -eq 1 && -d "$TARGET_DATA_DIR" ]]; then
  if [[ ! -f "$TARGET_DATA_DIR/.byok-cli-hub-data" && "$FORCE_LEGACY" -ne 1 ]]; then
    die "Data directory has no ownership marker; refusing purge. Use --force-legacy only after verifying the path."
  fi
  confirmed=0
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    confirmed=1
  elif [[ -t 0 ]]; then
    read -r -p "Delete user data '$TARGET_DATA_DIR'? Type 'yes' to confirm: " reply
    [[ "$reply" == "yes" ]] && confirmed=1
  else
    die "--purge-data in a non-interactive shell also requires --yes."
  fi
  if [[ "$confirmed" -eq 1 ]]; then
    rm -rf -- "$TARGET_DATA_DIR"
    echo "[OK] Purged user data."
  else
    echo "[INFO] User data preserved."
  fi
else
  echo "[INFO] User data preserved at $TARGET_DATA_DIR"
fi

echo "BYOK CLI Hub uninstalled successfully."
