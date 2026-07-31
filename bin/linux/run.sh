#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "Error: Node.js is required but was not found in PATH." >&2
  echo "Please install Node.js (version 22 or later) to run BYOK Bridge." >&2
  exit 1
fi

exec node "${APP_DIR}/manager/manager.mjs" "$@"
