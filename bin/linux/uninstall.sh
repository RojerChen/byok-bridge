#!/usr/bin/env bash
set -euo pipefail

# BYOK CLI Hub Uninstaller for Linux & WSL2

PURGE_DATA=0
INSTALL_DIR=""
BIN_DIR=""

function print_help() {
  cat << 'EOF'
BYOK CLI Hub Uninstaller (Linux / WSL2)

Usage:
  uninstall.sh [options]

Options:
  --install-dir PATH   Absolute path of installed application snapshot
                       (default: ${XDG_DATA_HOME:-$HOME/.local/share}/byok-cli-hub)
  --bin-dir PATH       Absolute path where executable shim was installed
                       (default: $HOME/.local/bin)
  --purge-data         Purge user data directory ($HOME/.byok-cli-hub)
                       (Warning: Destructive, removes all custom config and state!)
  --help, -h           Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --purge-data)
      PURGE_DATA=1
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      print_help
      exit 1
      ;;
  esac
done

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
TARGET_INSTALL_DIR="${INSTALL_DIR:-$XDG_DATA_HOME/byok-cli-hub}"
TARGET_BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
TARGET_DATA_DIR="$HOME/.byok-cli-hub"
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
TARGET_EXT_DIR="$COPILOT_HOME/extensions/byok-cli-hub-copilot"

echo "=== BYOK CLI Hub Uninstaller ==="

# Remove application snapshot
if [[ -d "$TARGET_INSTALL_DIR" ]]; then
  rm -rf "$TARGET_INSTALL_DIR"
  echo "[OK] Removed application snapshot at $TARGET_INSTALL_DIR"
fi

# Remove command shim
SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"
if [[ -f "$SHIM_PATH" ]]; then
  rm -f "$SHIM_PATH"
  echo "[OK] Removed command shim at $SHIM_PATH"
fi

# Remove Copilot extension if present
if [[ -d "$TARGET_EXT_DIR" ]]; then
  rm -rf "$TARGET_EXT_DIR"
  echo "[OK] Removed Copilot extension at $TARGET_EXT_DIR"
fi

# Purge data if requested
if [[ "$PURGE_DATA" -eq 1 ]]; then
  if [[ -d "$TARGET_DATA_DIR" ]]; then
    read -p "Are you SURE you want to delete user data directory '$TARGET_DATA_DIR'? (y/N) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf "$TARGET_DATA_DIR"
      echo "[OK] Purged data directory at $TARGET_DATA_DIR"
    else
      echo "[INFO] Data directory kept at $TARGET_DATA_DIR"
    fi
  fi
else
  echo "[INFO] User configuration and data kept intact at $TARGET_DATA_DIR"
fi

echo "BYOK CLI Hub uninstalled successfully."
