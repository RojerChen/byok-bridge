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
SHELL_HELPER_PATH=""
LEGACY_SHELL_HELPER_PATH=""
LEGACY_SHELL_HELPER_BACKUP=""
LEGACY_SHELL_HELPER_OWNED=0
BASH_RC_TARGET=""
BASH_RC_TEMP=""
BASH_RC_BACKUP=""
EXT_STAGING_DIR=""
EXT_BACKUP_DIR=""
SWITCHED_INSTALL=0
SWITCHED_SHIM=0
SWITCHED_BASH_RC=0
SWITCHED_EXTENSION=0
APP_VERSION=""
DATA_DIR_CREATED=0
DATA_MARKER_CREATED=0
DATA_CONFIG_CREATED=0
DATA_EXAMPLE_CREATED=0
DATA_EXAMPLE_BACKUP=""

die() {
  echo "Error: $*" >&2
  exit 1
}

failure_point() {
  [[ "${BYOK_CLI_HUB_TEST_FAIL_AT:-}" != "$1" ]] || die "Injected installer failure at '$1'."
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
APP_VERSION="$(node -e 'const p=require(process.argv[1]); if(typeof p.version!=="string"||!/^\d+\.\d+\.\d+$/.test(p.version)) process.exit(1); process.stdout.write(p.version)' "$REPO_ROOT/package.json")" \
  || die "Source package version is missing."
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

assert_bashrc_target() {
  local target="$1"
  case "$target" in
    "$HOME_CANON"/*) ;;
    *) die "Bash startup file must resolve inside the current home directory: $target" ;;
  esac
  [[ ! -e "$target" || -f "$target" ]] || die "Bash startup path is not a regular file: $target"
  [[ -d "$(dirname "$target")" ]] || die "Bash startup parent directory does not exist: $(dirname "$target")"
}

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
TARGET_INSTALL_DIR="$(canonicalize_absolute 'install-dir' "${INSTALL_DIR:-$XDG_DATA_HOME/byok-cli-hub}")"
TARGET_DATA_DIR="$(canonicalize_absolute 'data-dir' "${DATA_DIR:-$HOME/.byok-cli-hub}")"
TARGET_BIN_DIR="$(canonicalize_absolute 'bin-dir' "${BIN_DIR:-$HOME/.local/bin}")"
COPILOT_HOME_VALUE="${COPILOT_HOME:-$HOME/.copilot}"
COPILOT_HOME_CANON="$(canonicalize_absolute 'COPILOT_HOME' "$COPILOT_HOME_VALUE")"
TARGET_EXT_DIR="$(canonicalize_absolute 'extension-dir' "$COPILOT_HOME_CANON/extensions/byok-cli-hub-copilot")"
SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"
SHELL_HELPER_PATH="$TARGET_INSTALL_DIR/shell/bash/byok-cli-hub.bash"
LEGACY_SHELL_HELPER_PATH="$TARGET_BIN_DIR/byok-cli-hub-shell"
BASH_RC_TARGET="$(realpath -m -- "$HOME/.bashrc")"
assert_bashrc_target "$BASH_RC_TARGET"

assert_safe_target 'install-dir' "$TARGET_INSTALL_DIR"
assert_safe_target 'data-dir' "$TARGET_DATA_DIR"
assert_safe_target 'bin-dir' "$TARGET_BIN_DIR"
assert_safe_target 'extension-dir' "$TARGET_EXT_DIR"
assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'data-dir' "$TARGET_DATA_DIR"
assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'bin-dir' "$TARGET_BIN_DIR"
assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'bin-dir' "$TARGET_BIN_DIR"
assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'extension-dir' "$TARGET_EXT_DIR"
assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'extension-dir' "$TARGET_EXT_DIR"
assert_not_overlapping 'bin-dir' "$TARGET_BIN_DIR" 'extension-dir' "$TARGET_EXT_DIR"

echo "=== BYOK CLI Hub Installer ==="
echo "[OK] Node.js: $(node --version)"
echo "Resolved install dir: $TARGET_INSTALL_DIR"
echo "Resolved data dir:    $TARGET_DATA_DIR"
echo "Resolved bin dir:     $TARGET_BIN_DIR"
echo "Resolved extension:   $TARGET_EXT_DIR"
echo "Resolved Bash startup: $BASH_RC_TARGET"

COPILOT_STATUS=0
if command -v copilot >/dev/null 2>&1; then
  echo "[OK] GitHub Copilot CLI: $(copilot --version 2>/dev/null || echo found)"
else
  echo "[WARNING] GitHub Copilot CLI was not found in PATH."
  COPILOT_STATUS=1
fi

if [[ "$SHOW_CHECK" -eq 1 ]]; then
  BASH_RC_INPUT="$BASH_RC_TARGET"
  [[ -f "$BASH_RC_INPUT" ]] || BASH_RC_INPUT='-'
  node "$REPO_ROOT/libexec/linux/bash-profile-manager.mjs" check-install "$BASH_RC_INPUT" "$SHELL_HELPER_PATH" "$SHIM_PATH"
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
    const parseVersion = value => {
      const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(value);
      return match && match.slice(1).map(Number);
    };
    const previousVersion = parseVersion(m.appVersion);
    const sourceVersion = parseVersion(process.argv[2]);
    if (m.product !== "byok-cli-hub" || m.schemaVersion !== 1 || !previousVersion || !sourceVersion || typeof m.withExtension !== "boolean") process.exit(2);
    for (let index = 0; index < 3; index += 1) {
      if (previousVersion[index] > sourceVersion[index]) process.exit(3);
      if (previousVersion[index] < sourceVersion[index]) break;
    }
    for (const key of ["installDir", "dataDir", "binDir", "extensionDir", "withExtension", "bashrcPath", "shellStartupManaged"])
      process.stdout.write(String(m[key] ?? "") + "\n");
    process.stdout.write(Array.isArray(m.managedFiles) && m.managedFiles.includes("byok-cli-hub-shell") ? "1\n" : "0\n");
  ' "$MANIFEST_PATH" "$APP_VERSION")" || die "Existing install manifest is invalid or belongs to a newer application version."
  mapfile -t PREVIOUS_FIELDS <<< "$PREVIOUS_VALUES"
  MANIFEST_INSTALL_DIR="$(canonicalize_absolute 'manifest installDir' "${PREVIOUS_FIELDS[0]}")"
  MANIFEST_DATA_DIR="$(canonicalize_absolute 'manifest dataDir' "${PREVIOUS_FIELDS[1]}")"
  MANIFEST_BIN_DIR="$(canonicalize_absolute 'manifest binDir' "${PREVIOUS_FIELDS[2]}")"
  MANIFEST_EXT_DIR="$(canonicalize_absolute 'manifest extensionDir' "${PREVIOUS_FIELDS[3]}")"
  [[ "$MANIFEST_INSTALL_DIR" == "$TARGET_INSTALL_DIR" ]] || die "Manifest installDir does not match the requested target."
  assert_safe_target 'manifest data-dir' "$MANIFEST_DATA_DIR"
  assert_safe_target 'manifest bin-dir' "$MANIFEST_BIN_DIR"
  assert_safe_target 'manifest extension-dir' "$MANIFEST_EXT_DIR"
  assert_not_overlapping 'manifest install-dir' "$TARGET_INSTALL_DIR" 'manifest data-dir' "$MANIFEST_DATA_DIR"
  assert_not_overlapping 'manifest install-dir' "$TARGET_INSTALL_DIR" 'manifest bin-dir' "$MANIFEST_BIN_DIR"
  assert_not_overlapping 'manifest data-dir' "$MANIFEST_DATA_DIR" 'manifest bin-dir' "$MANIFEST_BIN_DIR"
  assert_not_overlapping 'manifest install-dir' "$TARGET_INSTALL_DIR" 'manifest extension-dir' "$MANIFEST_EXT_DIR"
  assert_not_overlapping 'manifest data-dir' "$MANIFEST_DATA_DIR" 'manifest extension-dir' "$MANIFEST_EXT_DIR"
  assert_not_overlapping 'manifest bin-dir' "$MANIFEST_BIN_DIR" 'manifest extension-dir' "$MANIFEST_EXT_DIR"
  [[ -z "$DATA_DIR" || "$TARGET_DATA_DIR" == "$MANIFEST_DATA_DIR" ]] \
    || die "A managed update cannot relocate data-dir. Uninstall and reinstall to choose a new path."
  [[ -z "$BIN_DIR" || "$TARGET_BIN_DIR" == "$MANIFEST_BIN_DIR" ]] \
    || die "A managed update cannot relocate bin-dir. Uninstall and reinstall to choose a new path."
  TARGET_DATA_DIR="$MANIFEST_DATA_DIR"
  TARGET_BIN_DIR="$MANIFEST_BIN_DIR"
  TARGET_EXT_DIR="$MANIFEST_EXT_DIR"
  [[ "${PREVIOUS_FIELDS[4]}" != "true" ]] || WITH_EXTENSION=1
  if [[ -n "${PREVIOUS_FIELDS[5]-}" || -n "${PREVIOUS_FIELDS[6]-}" ]]; then
    [[ "${PREVIOUS_FIELDS[6]-}" == "true" && -n "${PREVIOUS_FIELDS[5]-}" ]] \
      || die "Existing install manifest has invalid Bash startup ownership metadata."
    BASH_RC_TARGET="$(canonicalize_absolute 'manifest bashrcPath' "${PREVIOUS_FIELDS[5]}")"
    assert_bashrc_target "$BASH_RC_TARGET"
  fi
  SHIM_PATH="$TARGET_BIN_DIR/byok-cli-hub"
  SHELL_HELPER_PATH="$TARGET_INSTALL_DIR/shell/bash/byok-cli-hub.bash"
  LEGACY_SHELL_HELPER_PATH="$TARGET_BIN_DIR/byok-cli-hub-shell"
  if [[ "${PREVIOUS_FIELDS[7]-}" == "1" ]]; then
    if [[ -f "$LEGACY_SHELL_HELPER_PATH" ]] && grep -q '^# BYOK_CLI_HUB_MANAGED_SHELL_INTEGRATION=1$' "$LEGACY_SHELL_HELPER_PATH" 2>/dev/null; then
      LEGACY_SHELL_HELPER_OWNED=1
    elif [[ -e "$LEGACY_SHELL_HELPER_PATH" ]]; then
      echo "[WARNING] Preserving unowned legacy shell integration helper: $LEGACY_SHELL_HELPER_PATH" >&2
    fi
  fi
  assert_safe_target 'data-dir' "$TARGET_DATA_DIR"
  assert_safe_target 'bin-dir' "$TARGET_BIN_DIR"
  assert_safe_target 'extension-dir' "$TARGET_EXT_DIR"
  assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'data-dir' "$TARGET_DATA_DIR"
  assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'bin-dir' "$TARGET_BIN_DIR"
  assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'bin-dir' "$TARGET_BIN_DIR"
  assert_not_overlapping 'install-dir' "$TARGET_INSTALL_DIR" 'extension-dir' "$TARGET_EXT_DIR"
  assert_not_overlapping 'data-dir' "$TARGET_DATA_DIR" 'extension-dir' "$TARGET_EXT_DIR"
  assert_not_overlapping 'bin-dir' "$TARGET_BIN_DIR" 'extension-dir' "$TARGET_EXT_DIR"
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
if [[ "$ADOPT_LEGACY" -eq 1 && "$LEGACY_SHELL_HELPER_OWNED" -eq 0 && -f "$LEGACY_SHELL_HELPER_PATH" ]] \
  && grep -q '^# BYOK_CLI_HUB_MANAGED_SHELL_INTEGRATION=1$' "$LEGACY_SHELL_HELPER_PATH" 2>/dev/null; then
  LEGACY_SHELL_HELPER_OWNED=1
fi
BASH_RC_INPUT="$BASH_RC_TARGET"
[[ -f "$BASH_RC_INPUT" ]] || BASH_RC_INPUT='-'
node "$REPO_ROOT/libexec/linux/bash-profile-manager.mjs" check-install "$BASH_RC_INPUT" "$SHELL_HELPER_PATH" "$SHIM_PATH"
if [[ "$WITH_EXTENSION" -eq 1 && -e "$TARGET_EXT_DIR" && ! -f "$TARGET_EXT_DIR/.byok-cli-hub-managed" ]]; then
  if [[ "$ADOPT_LEGACY" -ne 1 || ! -f "$TARGET_EXT_DIR/extension.mjs" ]]; then
    die "Refusing to overwrite unowned extension: $TARGET_EXT_DIR"
  fi
elif [[ "$WITH_EXTENSION" -eq 0 && -e "$TARGET_EXT_DIR" && ! -f "$TARGET_EXT_DIR/.byok-cli-hub-managed" ]]; then
  echo "[WARNING] Preserving unowned extension: $TARGET_EXT_DIR" >&2
fi

rollback() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ "$status" -ne 0 ]]; then
    echo "[ERROR] Installation failed; restoring the previous installation." >&2
    if [[ -n "$BASH_RC_BACKUP" && -f "$BASH_RC_BACKUP" ]]; then
      rm -f -- "$BASH_RC_TARGET"
      mv -- "$BASH_RC_BACKUP" "$BASH_RC_TARGET"
    elif [[ "$SWITCHED_BASH_RC" -eq 1 ]]; then
      rm -f -- "$BASH_RC_TARGET"
    fi
    if [[ -n "$EXT_BACKUP_DIR" && -d "$EXT_BACKUP_DIR" ]]; then
      rm -rf -- "$TARGET_EXT_DIR"
      mv -- "$EXT_BACKUP_DIR" "$TARGET_EXT_DIR"
    elif [[ "$SWITCHED_EXTENSION" -eq 1 ]]; then
      rm -rf -- "$TARGET_EXT_DIR"
    fi
    if [[ -n "$SHIM_BACKUP" && -f "$SHIM_BACKUP" ]]; then
      rm -f -- "$SHIM_PATH"
      mv -- "$SHIM_BACKUP" "$SHIM_PATH"
    elif [[ "$SWITCHED_SHIM" -eq 1 ]]; then
      rm -f -- "$SHIM_PATH"
    fi
    if [[ -n "$LEGACY_SHELL_HELPER_BACKUP" && -f "$LEGACY_SHELL_HELPER_BACKUP" ]]; then
      rm -f -- "$LEGACY_SHELL_HELPER_PATH"
      mv -- "$LEGACY_SHELL_HELPER_BACKUP" "$LEGACY_SHELL_HELPER_PATH"
    fi
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
      rm -rf -- "$TARGET_INSTALL_DIR"
      mv -- "$BACKUP_DIR" "$TARGET_INSTALL_DIR"
    elif [[ "$SWITCHED_INSTALL" -eq 1 ]]; then
      rm -rf -- "$TARGET_INSTALL_DIR"
    fi

    if [[ -n "$DATA_EXAMPLE_BACKUP" && -f "$DATA_EXAMPLE_BACKUP" ]]; then
      mv -f -- "$DATA_EXAMPLE_BACKUP" "$TARGET_DATA_DIR/providers.example.json"
      DATA_EXAMPLE_BACKUP=""
    elif [[ "$DATA_EXAMPLE_CREATED" -eq 1 ]]; then
      rm -f -- "$TARGET_DATA_DIR/providers.example.json"
    fi
    [[ "$DATA_CONFIG_CREATED" -ne 1 ]] || rm -f -- "$TARGET_DATA_DIR/providers.json"
    [[ "$DATA_MARKER_CREATED" -ne 1 ]] || rm -f -- "$TARGET_DATA_DIR/.byok-cli-hub-data"
    if [[ "$DATA_DIR_CREATED" -eq 1 && -d "$TARGET_DATA_DIR" ]]; then
      rmdir -- "$TARGET_DATA_DIR" 2>/dev/null || true
    fi
  fi
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf -- "$STAGING_DIR"
  [[ -n "$SHIM_TEMP" && -f "$SHIM_TEMP" ]] && rm -f -- "$SHIM_TEMP"
  [[ -n "$BASH_RC_TEMP" && -f "$BASH_RC_TEMP" ]] && rm -f -- "$BASH_RC_TEMP"
  [[ -n "$EXT_STAGING_DIR" && -d "$EXT_STAGING_DIR" ]] && rm -rf -- "$EXT_STAGING_DIR"
  [[ -n "$DATA_EXAMPLE_BACKUP" && -f "$DATA_EXAMPLE_BACKUP" ]] && rm -f -- "$DATA_EXAMPLE_BACKUP"
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
[[ -d "$TARGET_DATA_DIR" ]] || DATA_DIR_CREATED=1
mkdir -p "$TARGET_DATA_DIR"
[[ "$DATA_DIR_CREATED" -ne 1 ]] || chmod 700 "$TARGET_DATA_DIR"
if [[ ! -e "$TARGET_DATA_DIR/.byok-cli-hub-data" ]]; then
  : > "$TARGET_DATA_DIR/.byok-cli-hub-data"
  DATA_MARKER_CREATED=1
  failure_point 'data-marker-chmod'
  chmod 600 "$TARGET_DATA_DIR/.byok-cli-hub-data"
fi
if [[ ! -f "$TARGET_DATA_DIR/providers.json" ]]; then
  CONFIG_SOURCE="$REPO_ROOT/config/providers.example.json"
  [[ -f "$CONFIG_SOURCE" ]] || CONFIG_SOURCE="$REPO_ROOT/config/providers.json"
  [[ -f "$CONFIG_SOURCE" ]] || die "Bundled provider configuration is missing."
  cp "$CONFIG_SOURCE" "$TARGET_DATA_DIR/providers.json"
  DATA_CONFIG_CREATED=1
  failure_point 'data-config-chmod'
  chmod 600 "$TARGET_DATA_DIR/providers.json"
  echo "[OK] Initialized $TARGET_DATA_DIR/providers.json"
else
  echo "[INFO] Preserved $TARGET_DATA_DIR/providers.json"
fi
if [[ -f "$REPO_ROOT/config/providers.example.json" ]]; then
  if [[ -e "$TARGET_DATA_DIR/providers.example.json" && ! -f "$TARGET_DATA_DIR/providers.example.json" ]]; then
    die "Provider example path is not a regular file: $TARGET_DATA_DIR/providers.example.json"
  fi
  if [[ -f "$TARGET_DATA_DIR/providers.example.json" ]]; then
    DATA_EXAMPLE_BACKUP_TEMP="$(mktemp "$TARGET_DATA_DIR/.providers.example.backup.XXXXXX")"
    if ! (
      failure_point 'data-example-backup-copy'
      cp -p -- "$TARGET_DATA_DIR/providers.example.json" "$DATA_EXAMPLE_BACKUP_TEMP"
    ); then
      rm -f -- "$DATA_EXAMPLE_BACKUP_TEMP"
      die "Failed to backup existing providers.example.json"
    fi
    DATA_EXAMPLE_BACKUP="$DATA_EXAMPLE_BACKUP_TEMP"
  else
    DATA_EXAMPLE_CREATED=1
  fi
  cp "$REPO_ROOT/config/providers.example.json" "$TARGET_DATA_DIR/providers.example.json"
  chmod 600 "$TARGET_DATA_DIR/providers.example.json"
fi

PARENT_INSTALL_DIR="$(dirname "$TARGET_INSTALL_DIR")"
mkdir -p "$PARENT_INSTALL_DIR" "$TARGET_BIN_DIR"
STAGING_DIR="$(mktemp -d "$PARENT_INSTALL_DIR/.byok-cli-hub.staging.XXXXXX")"
BACKUP_DIR="${TARGET_INSTALL_DIR}.backup.$$"
SHIM_TEMP="$(mktemp "$TARGET_BIN_DIR/.byok-cli-hub.shim.XXXXXX")"
SHIM_BACKUP="${SHIM_PATH}.backup.$$"
LEGACY_SHELL_HELPER_BACKUP="${LEGACY_SHELL_HELPER_PATH}.backup.$$"
BASH_RC_TEMP="$(mktemp "$(dirname "$BASH_RC_TARGET")/.byok-cli-hub.bashrc.XXXXXX")"
BASH_RC_BACKUP="${BASH_RC_TARGET}.byok-backup.$$"

cp -R "$REPO_ROOT/manager" "$STAGING_DIR/"
cp -R "$REPO_ROOT/config" "$STAGING_DIR/"
cp -R "$REPO_ROOT/ui" "$STAGING_DIR/"
cp -R "$REPO_ROOT/bin" "$STAGING_DIR/"
cp -R "$REPO_ROOT/shell" "$STAGING_DIR/"
cp -R "$REPO_ROOT/libexec" "$STAGING_DIR/"
cp "$REPO_ROOT/README.md" "$STAGING_DIR/README.md"
mkdir -p "$STAGING_DIR/doc"
for documentation_name in quick-start.md installation.md provider-configuration.md usage.md maintenance.md; do
  cp "$REPO_ROOT/doc/$documentation_name" "$STAGING_DIR/doc/$documentation_name"
done
cp -R "$REPO_ROOT/images" "$STAGING_DIR/"
cp "$REPO_ROOT/CHANGELOG.md" "$STAGING_DIR/CHANGELOG.md"
[[ ! -d "$REPO_ROOT/extension" ]] || cp -R "$REPO_ROOT/extension" "$STAGING_DIR/"
find "$STAGING_DIR" -type d -exec chmod 755 {} +
find "$STAGING_DIR" -type f -exec chmod 644 {} +
chmod 755 "$STAGING_DIR/manager/manager.mjs" "$STAGING_DIR/bin/linux/"*.sh "$STAGING_DIR/bin/linux/byok-cli-hub"

node --check "$STAGING_DIR/manager/manager.mjs"
node --check "$STAGING_DIR/libexec/linux/bash-profile-manager.mjs"
bash -n "$STAGING_DIR/shell/bash/byok-cli-hub.bash"
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

BASH_RC_INPUT="$BASH_RC_TARGET"
if [[ -f "$BASH_RC_INPUT" ]]; then
  node "$REPO_ROOT/libexec/linux/bash-profile-manager.mjs" install "$BASH_RC_INPUT" "$BASH_RC_TEMP" "$SHELL_HELPER_PATH" "$SHIM_PATH" >/dev/null
  chmod --reference="$BASH_RC_INPUT" "$BASH_RC_TEMP"
else
  node "$REPO_ROOT/libexec/linux/bash-profile-manager.mjs" install - "$BASH_RC_TEMP" "$SHELL_HELPER_PATH" "$SHIM_PATH" >/dev/null
  chmod 644 "$BASH_RC_TEMP"
fi

BYOK_MANIFEST_APP_VERSION="$APP_VERSION" \
BYOK_MANIFEST_INSTALL_DIR="$TARGET_INSTALL_DIR" \
BYOK_MANIFEST_DATA_DIR="$TARGET_DATA_DIR" \
BYOK_MANIFEST_BIN_DIR="$TARGET_BIN_DIR" \
BYOK_MANIFEST_EXTENSION_DIR="$TARGET_EXT_DIR" \
BYOK_MANIFEST_WITH_EXTENSION="$WITH_EXTENSION" \
BYOK_MANIFEST_BASHRC_PATH="$BASH_RC_TARGET" \
MSYS2_ARG_CONV_EXCL='*' \
MSYS_NO_PATHCONV=1 \
node -e '
  const env = process.env;
  process.stdout.write(JSON.stringify({
    schemaVersion: 1,
    product: "byok-cli-hub",
    appVersion: env.BYOK_MANIFEST_APP_VERSION,
    installedAt: new Date().toISOString(),
    installDir: env.BYOK_MANIFEST_INSTALL_DIR,
    dataDir: env.BYOK_MANIFEST_DATA_DIR,
    binDir: env.BYOK_MANIFEST_BIN_DIR,
    extensionDir: env.BYOK_MANIFEST_EXTENSION_DIR,
    withExtension: env.BYOK_MANIFEST_WITH_EXTENSION === "1",
    bashrcPath: env.BYOK_MANIFEST_BASHRC_PATH,
    shellStartupManaged: true,
    managedFiles: ["byok-cli-hub"]
  }, null, 2) + "\n");
' > "$STAGING_DIR/$MANIFEST_NAME"
chmod 644 "$STAGING_DIR/$MANIFEST_NAME"

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
failure_point 'after-app-backup'
mv -- "$STAGING_DIR" "$TARGET_INSTALL_DIR"
STAGING_DIR=""
SWITCHED_INSTALL=1

[[ ! -e "$SHIM_BACKUP" ]] || die "Shim backup path already exists: $SHIM_BACKUP"
if [[ -f "$SHIM_PATH" ]]; then mv -- "$SHIM_PATH" "$SHIM_BACKUP"; fi
failure_point 'after-shim-backup'
mv -- "$SHIM_TEMP" "$SHIM_PATH"
SHIM_TEMP=""
SWITCHED_SHIM=1

[[ ! -e "$BASH_RC_BACKUP" ]] || die "Bash startup backup path already exists: $BASH_RC_BACKUP"
if [[ -f "$BASH_RC_TARGET" ]]; then mv -- "$BASH_RC_TARGET" "$BASH_RC_BACKUP"; fi
failure_point 'after-bashrc-backup'
mv -- "$BASH_RC_TEMP" "$BASH_RC_TARGET"
BASH_RC_TEMP=""
SWITCHED_BASH_RC=1

if [[ "$LEGACY_SHELL_HELPER_OWNED" -eq 1 && -f "$LEGACY_SHELL_HELPER_PATH" ]]; then
  [[ ! -e "$LEGACY_SHELL_HELPER_BACKUP" ]] || die "Legacy shell integration backup path already exists: $LEGACY_SHELL_HELPER_BACKUP"
  mv -- "$LEGACY_SHELL_HELPER_PATH" "$LEGACY_SHELL_HELPER_BACKUP"
  failure_point 'after-legacy-shell-helper-backup'
fi

if [[ "$WITH_EXTENSION" -eq 1 ]]; then
  [[ ! -e "$EXT_BACKUP_DIR" ]] || die "Extension backup path already exists: $EXT_BACKUP_DIR"
  if [[ -d "$TARGET_EXT_DIR" ]]; then mv -- "$TARGET_EXT_DIR" "$EXT_BACKUP_DIR"; fi
  failure_point 'after-extension-backup'
  mv -- "$EXT_STAGING_DIR" "$TARGET_EXT_DIR"
  EXT_STAGING_DIR=""
  SWITCHED_EXTENSION=1
fi

node "$TARGET_INSTALL_DIR/manager/manager.mjs" --data-dir "$TARGET_DATA_DIR" --self-check

failure_point 'before-backup-cleanup'
# Backup cleanup is best effort. A cleanup error must never trigger rollback
# after part of the previous installation has already been discarded.
[[ ! -d "$BACKUP_DIR" ]] || rm -rf -- "$BACKUP_DIR" || echo "[WARNING] Could not remove backup: $BACKUP_DIR" >&2
[[ ! -f "$SHIM_BACKUP" ]] || rm -f -- "$SHIM_BACKUP" || echo "[WARNING] Could not remove shim backup: $SHIM_BACKUP" >&2
[[ ! -f "$LEGACY_SHELL_HELPER_BACKUP" ]] || rm -f -- "$LEGACY_SHELL_HELPER_BACKUP" || echo "[WARNING] Could not remove legacy shell integration backup: $LEGACY_SHELL_HELPER_BACKUP" >&2
[[ ! -f "$BASH_RC_BACKUP" ]] || rm -f -- "$BASH_RC_BACKUP" || echo "[WARNING] Could not remove Bash startup backup: $BASH_RC_BACKUP" >&2
[[ -z "$EXT_BACKUP_DIR" || ! -d "$EXT_BACKUP_DIR" ]] || rm -rf -- "$EXT_BACKUP_DIR" || echo "[WARNING] Could not remove extension backup: $EXT_BACKUP_DIR" >&2
[[ -z "$DATA_EXAMPLE_BACKUP" || ! -f "$DATA_EXAMPLE_BACKUP" ]] || rm -f -- "$DATA_EXAMPLE_BACKUP" || echo "[WARNING] Could not remove data backup: $DATA_EXAMPLE_BACKUP" >&2
SWITCHED_INSTALL=0
SWITCHED_SHIM=0
SWITCHED_BASH_RC=0
SWITCHED_EXTENSION=0
DATA_DIR_CREATED=0
DATA_MARKER_CREATED=0
DATA_CONFIG_CREATED=0
DATA_EXAMPLE_CREATED=0
DATA_EXAMPLE_BACKUP=""
trap - EXIT INT TERM

echo "[OK] Installed application snapshot to $TARGET_INSTALL_DIR"
echo "[OK] Installed managed shim at $SHIM_PATH"
echo "[OK] Installed sourceable shell integration in the application snapshot at $SHELL_HELPER_PATH"
echo "[OK] Enabled automatic Bash startup integration in $BASH_RC_TARGET"
[[ "$WITH_EXTENSION" -ne 1 ]] || echo "[OK] Installed managed extension at $TARGET_EXT_DIR"
if [[ ":$PATH:" != *":$TARGET_BIN_DIR:"* ]]; then
  echo "[NOTICE] '$TARGET_BIN_DIR' is not in PATH. Add: export PATH=\"$TARGET_BIN_DIR:\$PATH\""
fi
echo "[INFO] Open a new Bash terminal or run 'exec bash' once; then use: byok-cli-hub"
echo "BYOK CLI Hub successfully installed."
