#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/byok-linux-shell.XXXXXX")"

cleanup() {
  [[ -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

bash -n "$REPO_ROOT/shell/bash/byok-cli-hub.bash"

mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/fake-bin"
FAKE_CLI="$TEST_ROOT/fake-bin/fake-ai-cli"
CAPTURE_FILE="$TEST_ROOT/child-environment.txt"
cat > "$FAKE_CLI" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'url=%s\n' "${TEST_URL-}"
  printf 'key=%s\n' "${TEST_KEY-}"
  printf 'model=%s\n' "${TEST_MODEL-}"
  printf 'provider=%s\n' "${PROVIDER_VALUE-}"
  printf 'restore=%s\n' "${TEST_RESTORE-}"
  printf 'argc=%s\n' "$#"
  printf 'arg1=%s\n' "${1-}"
  printf 'arg2=%s\n' "${2-}"
  printf 'arg3=%s\n' "${3-}"
} > "$BYOK_TEST_CAPTURE"
EOF
chmod 755 "$FAKE_CLI"

node - "$TEST_ROOT/data/providers.json" "$FAKE_CLI" << 'NODE'
const fs = require('node:fs');
const [configPath, fakeCli] = process.argv.slice(2);
const config = {
  version: 1,
  clis: {
    test: {
      command: fakeCli,
      args: ['space value', '$(not-executed)', ''],
      environment: {
        TEST_URL: '{url}',
        TEST_KEY: '{api_key}',
        TEST_MODEL: '{model}',
        COMPLEX_VALUE: '繁體中文\nline\t$`"'
      }
    }
  },
  providers: {
    first: {
      baseUrl: 'https://first.example.test/v1',
      apiKeyEnv: ['TEST_KEY'],
      models: ['model-one'],
      environment: {
        FIRST_ONLY: 'first:{model}',
        PROVIDER_VALUE: 'first-wide',
        TEST_UNEXPORTED: 'managed-one',
        test: {
          PROVIDER_VALUE: 'first-cli',
          TEST_RESTORE: 'first-plan'
        }
      }
    },
    second: {
      baseUrl: 'https://second.example.test/v1',
      apiKeyEnv: ['TEST_KEY'],
      models: ['model-two'],
      environment: {
        SECOND_ONLY: 'second:{model}',
        PROVIDER_VALUE: 'second-wide',
        TEST_UNEXPORTED: 'managed-two',
        TEST_RESTORE: 'second-plan'
      }
    }
  }
};
fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
NODE

unset TEST_URL TEST_KEY TEST_MODEL COMPLEX_VALUE FIRST_ONLY SECOND_ONLY PROVIDER_VALUE BYOK_CLI_HUB_DATA_DIR || true
export TEST_RESTORE='original-value'
TEST_UNEXPORTED='unexported-original'
export BYOK_TEST_CAPTURE="$CAPTURE_FILE"
PATH="$REPO_ROOT/bin/linux:$PATH"
export PATH

# Executing the helper cannot affect the caller and must be rejected.
if bash "$REPO_ROOT/shell/bash/byok-cli-hub.bash" >/dev/null 2>&1; then
  echo 'Shell integration helper unexpectedly allowed direct execution.' >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi

# Sourcing only registers functions; it must not resolve or apply a plan.
source "$REPO_ROOT/shell/bash/byok-cli-hub.bash"
declare -F byok-cli-hub >/dev/null
declare -F byok-cli-hub-deactivate >/dev/null
[[ "$TEST_RESTORE" == 'original-value' ]]
[[ -z "${TEST_URL+x}" ]]

byok-cli-hub \
  --data-dir "$TEST_ROOT/data" \
  --cli test \
  --provider first \
  --model model-one \
  --api-key session-secret >/dev/null

[[ "$TEST_URL" == 'https://first.example.test/v1' ]]
[[ "$TEST_KEY" == 'session-secret' ]]
[[ "$TEST_MODEL" == 'model-one' ]]
[[ "$COMPLEX_VALUE" == $'繁體中文\nline\t$`"' ]]
[[ "$FIRST_ONLY" == 'first:model-one' ]]
[[ "$PROVIDER_VALUE" == 'first-cli' ]]
[[ "$TEST_RESTORE" == 'first-plan' ]]
[[ "$TEST_UNEXPORTED" == 'managed-one' ]]
[[ "$(declare -p TEST_UNEXPORTED)" == declare\ -x* ]]
[[ "$BYOK_CLI_HUB_DATA_DIR" == "$TEST_ROOT/data" ]]
grep -q '^key=session-secret$' "$CAPTURE_FILE"
grep -q '^arg1=space value$' "$CAPTURE_FILE"
grep -Fq 'arg2=$(not-executed)' "$CAPTURE_FILE"
grep -q '^arg3=$' "$CAPTURE_FILE"

# Re-sourcing is idempotent and keeps the active transaction bookkeeping.
source "$REPO_ROOT/shell/bash/byok-cli-hub.bash"
[[ "$FIRST_ONLY" == 'first:model-one' ]]
[[ "$TEST_RESTORE" == 'first-plan' ]]

# Non-launch actions must not alter the active parent-shell plan.
byok-cli-hub \
  --data-dir "$TEST_ROOT/data" \
  --cli test \
  --provider second \
  --model model-two \
  --dry-run >/dev/null
[[ "$FIRST_ONLY" == 'first:model-one' ]]
[[ -z "${SECOND_ONLY+x}" ]]

# A second launch replaces the complete plan and removes first-only values.
byok-cli-hub \
  --data-dir "$TEST_ROOT/data" \
  --cli test \
  --provider second \
  --model model-two \
  --api-key second-secret >/dev/null
[[ -z "${FIRST_ONLY+x}" ]]
[[ "$SECOND_ONLY" == 'second:model-two' ]]
[[ "$TEST_URL" == 'https://second.example.test/v1' ]]
[[ "$TEST_KEY" == 'second-secret' ]]
[[ "$PROVIDER_VALUE" == 'second-wide' ]]
[[ "$TEST_RESTORE" == 'second-plan' ]]
[[ "$TEST_UNEXPORTED" == 'managed-two' ]]

# Explicit user changes made while active are preserved by deactivate.
PROVIDER_VALUE='manual-override'
export PROVIDER_VALUE
byok-cli-hub-deactivate
[[ "$PROVIDER_VALUE" == 'manual-override' ]]
[[ "$TEST_RESTORE" == 'original-value' ]]
[[ "$TEST_UNEXPORTED" == 'unexported-original' ]]
[[ "$(declare -p TEST_UNEXPORTED)" == declare\ --* ]]
[[ -z "${TEST_URL+x}" ]]
[[ -z "${TEST_KEY+x}" ]]
[[ -z "${TEST_MODEL+x}" ]]
[[ -z "${COMPLEX_VALUE+x}" ]]
[[ -z "${SECOND_ONLY+x}" ]]
[[ -z "${BYOK_CLI_HUB_DATA_DIR+x}" ]]

# Malformed protocol and subshell use fail without partial mutation.
MALFORMED_SHIM="$TEST_ROOT/fake-bin/malformed-shim"
cat > "$MALFORMED_SHIM" << 'EOF'
#!/usr/bin/env bash
printf 'not-a-shell-plan\n' >&3
EOF
chmod 755 "$MALFORMED_SHIM"
REAL_COMMAND_BACKUP="$_BYOK_CLI_HUB_REAL_COMMAND"
_BYOK_CLI_HUB_REAL_COMMAND="$MALFORMED_SHIM"
if byok-cli-hub >/dev/null 2>&1; then
  echo 'Malformed shell plan unexpectedly succeeded.' >&2
  exit 1
fi
_BYOK_CLI_HUB_REAL_COMMAND="$REAL_COMMAND_BACKUP"
[[ "$PROVIDER_VALUE" == 'manual-override' ]]
if (byok-cli-hub --help >/dev/null 2>&1); then
  echo 'Subshell shell-integration invocation unexpectedly succeeded.' >&2
  exit 1
fi

# Xtrace must not reveal an environment-derived API key.
export TEST_KEY='xtrace-secret'
TRACE_FILE="$TEST_ROOT/xtrace.log"
{
  set -x
  byok-cli-hub \
    --data-dir "$TEST_ROOT/data" \
    --cli test \
    --provider first \
    --model model-one >/dev/null
  set +x
} 2> "$TRACE_FILE"
if grep -Fq 'xtrace-secret' "$TRACE_FILE"; then
  echo 'Shell xtrace leaked the API key.' >&2
  exit 1
fi
byok-cli-hub-deactivate
[[ "$TEST_KEY" == 'xtrace-secret' ]]
unset TEST_KEY

# The original executable remains available and cannot modify this Bash.
unset TEST_URL TEST_MODEL FIRST_ONLY SECOND_ONLY BYOK_CLI_HUB_DATA_DIR || true
command byok-cli-hub \
  --data-dir "$TEST_ROOT/data" \
  --cli test \
  --provider first \
  --model model-one \
  --api-key isolated-secret >/dev/null
[[ -z "${TEST_URL+x}" ]]
[[ -z "${TEST_MODEL+x}" ]]

byok-cli-hub-shell-unload
if declare -F byok-cli-hub >/dev/null; then
  echo 'Shell integration function remained after unload.' >&2
  exit 1
fi

echo 'Linux shell integration test passed.'
