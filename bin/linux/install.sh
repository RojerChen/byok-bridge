#!/usr/bin/env bash
set -euo pipefail

# BYOK CLI Hub Installer for Linux & WSL2

SHOW_CHECK=0
WITH_EXTENSION=0
INSTALL_DIR=""
DATA_DIR=""
BIN_DIR=""

function print_help() {
  cat << 'EOF'
BYOK CLI Hub Installer (Linux / WSL2)

Usage:
  install.sh [options]

Options:
  --install-dir PATH   Absolute path to install application snapshot
                       (default: ${XDG_DATA_HOME:-$HOME/.local/share}/byok-cli-hub)
  --data-dir PATH      Absolute path for user configuration and state
                       (default: $HOME/.byok-cli-hub)
  --bin-dir PATH       Absolute path to install executable shim/symlink
                       (default: $HOME/.local/bin)
  --with-extension     Install optional GitHub Copilot CLI extension
  --check              Run environment preflight checks without writing files
  --help, -h           Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --with-extension)
      WITH_EXTENSION=1
      shift
      ;;
    --check)
      SHOW_CHECK=1
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Resolve default directories
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
TARGET_INSTALL_DIR="${INSTALL_DIR:-$XDG_DATA_HOME/byok-cli-hub}"
TARGET_DATA_DIR="${DATA_DIR:-$HOME/.byok-cli-hub}"
TARGET_BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
TARGET_EXT_DIR="$COPILOT_HOME/extensions/byok-cli-hub-copilot"

echo "=== BYOK CLI Hub Installer ==="

# Preflight Check 1: Node.js version >= 22
if ! command -v node >/dev/null 2>&1; then
  echo "Error: 'node' command was not found in PATH." >&2
  echo "Please install Node.js 22 or later." >&2
  exit 1
fi

NODE_MAJOR=$(node -e "console.log(process.versions.node.split('.')[0])")
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  echo "Error: Node.js major version must be >= 22. Current: $(node --version)" >&2
  exit 1
fi
echo "[OK] Node.js version: $(node --version)"

# Preflight Check 2: Copilot CLI presence
COPILOT_STATUS=0
if command -v copilot >/dev/null 2>&1; then
  echo "[OK] GitHub Copilot CLI: $(copilot --version 2>/dev/null || echo 'found')"
else
  echo "[WARNING] GitHub Copilot CLI ('copilot') was not found in PATH."
  echo "          You can install it via: npm install -g @github/copilot"
  COPILOT_STATUS=1
fi

if [[ "$SHOW_CHECK" -eq 1 ]]; then
  echo "Preflight check complete."
  if [[ "$COPILOT_STATUS" -ne 0 ]]; then
    exit 2
  fi
  exit 0
fi

# Step 1: Create data directory with 0700 mode
umask 077
mkdir -p "$TARGET_DATA_DIR"
chmod 700 "$TARGET_DATA_DIR"

# Step 2: Copy example config if providers.json does not exist
if [[ ! -f "$TARGET_DATA_DIR/providers.json" ]]; then
  if [[ -f "$REPO_ROOT/config/providers.example.json" ]]; then
    cp "$REPO_ROOT/config/providers.example.json" "$TARGET_DATA_DIR/providers.json"
  elif [[ -f "$REPO_ROOT/config/providers.json" ]]; then
    cp "$REPO_ROOT/config/providers.json" "$TARGET_DATA_DIR/providers.json"
  fi
  echo "[OK] Initialized default configuration at $TARGET_DATA_DIR/providers.json"
else
  echo "[INFO] Existing configuration preserved at $TARGET_DATA_DIR/providers.json"
fi

# Always copy/update providers.example.json
if [[ -f "$REPO_ROOT/config/providers.example.json" ]]; then
  cp "$REPO_ROOT/config/providers.example.json" "$TARGET_DATA_DIR/providers.example.json"
fi

# Step 3: Stage application files into snapshot directory
PARENT_INSTALL_DIR="$(dirname "$TARGET_INSTALL_DIR")"
mkdir -p "$PARENT_INSTALL_DIR"

STAGING_DIR="${TARGET_INSTALL_DIR}.staging_$$"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -r "$REPO_ROOT/manager" "$STAGING_DIR/"
cp -r "$REPO_ROOT/config" "$STAGING_DIR/"
cp -r "$REPO_ROOT/bin" "$STAGING_DIR/"
if [[ -d "$REPO_ROOT/extension" ]]; then
  cp -r "$REPO_ROOT/extension" "$STAGING_DIR/"
fi
chmod -R 755 "$STAGING_DIR"

rm -rf "$TARGET_INSTALL_DIR"
mv "$STAGING_DIR" "$TARGET_INSTALL_DIR"
echo "[OK] Installed application snapshot to $TARGET_INSTALL_DIR"

# Step 4: Create command shim in bin dir
mkdir -p "$TARGET_BIN_DIR"
SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"

cat << EOF > "$SHIM_PATH"
#!/usr/bin/env bash
set -euo pipefail
exec "$TARGET_INSTALL_DIR/bin/linux/run.sh" "\$@"
EOF
chmod +x "$SHIM_PATH"
echo "[OK] Created command shim at $SHIM_PATH"

# Step 5: Optional Copilot extension installation
if [[ "$WITH_EXTENSION" -eq 1 ]]; then
  if [[ -d "$TARGET_INSTALL_DIR/extension" ]]; then
    mkdir -p "$(dirname "$TARGET_EXT_DIR")"
    rm -rf "$TARGET_EXT_DIR"
    cp -r "$TARGET_INSTALL_DIR/extension" "$TARGET_EXT_DIR"
    echo "[OK] Installed Copilot extension to $TARGET_EXT_DIR"
  else
    echo "[WARNING] Extension directory not found in repo."
  fi
fi

# Self-check installed app
node "$TARGET_INSTALL_DIR/manager/manager.mjs" --data-dir "$TARGET_DATA_DIR" --self-check

# Check PATH warning
if [[ ":$PATH:" != *":$TARGET_BIN_DIR:"* ]]; then
  echo ""
  echo "[NOTICE] '$TARGET_BIN_DIR' is not currently in your PATH."
  echo "         Add the following line to your shell profile (~/.bashrc or ~/.zshrc):"
  echo "         export PATH=\"$TARGET_BIN_DIR:\$PATH\""
fi

echo ""
echo "BYOK CLI Hub successfully installed!"
echo "Run 'byok-cli-hub --help' to get started."
