#!/usr/bin/env bash
# BYOK_CLI_HUB_MANAGED_SHELL_INTEGRATION=1

# This file must be sourced. It defines a Bash function that asks the Node
# manager for a resolved launch plan, applies that plan to the current shell,
# and then launches the configured CLI without eval or secret-bearing files.

if [[ -z "${BASH_VERSION:-}" ]]; then
  printf '%s\n' 'Error: BYOK CLI Hub shell integration requires Bash.' >&2
  return 2 2>/dev/null || exit 2
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' "Error: This helper must be sourced: source \"${BASH_SOURCE[0]}\"" >&2
  exit 2
fi

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  printf '%s\n' "Error: BYOK CLI Hub shell integration requires Bash 4.2 or later (current: $BASH_VERSION)." >&2
  return 2
fi

_BYOK_CLI_HUB_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
if [[ -z "$_BYOK_CLI_HUB_SOURCE_DIR" || ! -x "$_BYOK_CLI_HUB_SOURCE_DIR/byok-cli-hub" ]]; then
  printf '%s\n' 'Error: Could not locate the real byok-cli-hub executable beside the shell integration helper.' >&2
  unset _BYOK_CLI_HUB_SOURCE_DIR
  return 2
fi

_BYOK_CLI_HUB_REAL_COMMAND="$_BYOK_CLI_HUB_SOURCE_DIR/byok-cli-hub"
_BYOK_CLI_HUB_OWNER_BASHPID="$BASHPID"
unset _BYOK_CLI_HUB_SOURCE_DIR

if ! declare -p _BYOK_CLI_HUB_ACTIVE_KEYS >/dev/null 2>&1; then
  declare -gA _BYOK_CLI_HUB_ACTIVE_KEYS=()
  declare -gA _BYOK_CLI_HUB_ORIGINAL_PRESENT=()
  declare -gA _BYOK_CLI_HUB_ORIGINAL_EXPORTED=()
  declare -gA _BYOK_CLI_HUB_ORIGINAL_VALUES=()
  declare -gA _BYOK_CLI_HUB_APPLIED_VALUES=()
fi

_byok_cli_hub_error() {
  printf 'Shell integration error: %s\n' "$1" >&2
}

_byok_cli_hub_is_reserved_name() {
  case "$1" in
    BASH_ENV|ENV|IFS|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE|PROMPT_COMMAND|PS0|PS1|PS2|PS3|PS4|PATH|PWD|OLDPWD|SHLVL|HOME|SHELL|LD_PRELOAD|LD_LIBRARY_PATH|NODE_OPTIONS|_BYOK_CLI_HUB_*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_byok_cli_hub_decode_hex() {
  local _BYOK_CLI_HUB_LOCAL_HEX="$1"
  local _BYOK_CLI_HUB_LOCAL_INDEX _BYOK_CLI_HUB_LOCAL_PAIR _BYOK_CLI_HUB_LOCAL_BYTE
  _BYOK_CLI_HUB_DECODED=''
  [[ "$_BYOK_CLI_HUB_LOCAL_HEX" =~ ^([0-9a-f][0-9a-f])*$ ]] || return 1
  for (( _BYOK_CLI_HUB_LOCAL_INDEX=0; _BYOK_CLI_HUB_LOCAL_INDEX<${#_BYOK_CLI_HUB_LOCAL_HEX}; _BYOK_CLI_HUB_LOCAL_INDEX+=2 )); do
    _BYOK_CLI_HUB_LOCAL_PAIR="${_BYOK_CLI_HUB_LOCAL_HEX:_BYOK_CLI_HUB_LOCAL_INDEX:2}"
    [[ "$_BYOK_CLI_HUB_LOCAL_PAIR" != '00' ]] || return 1
    printf -v _BYOK_CLI_HUB_LOCAL_BYTE '%b' "\\x$_BYOK_CLI_HUB_LOCAL_PAIR" || return 1
    _BYOK_CLI_HUB_DECODED+="$_BYOK_CLI_HUB_LOCAL_BYTE"
  done
}

_byok_cli_hub_declaration() {
  declare -p -- "$1" 2>/dev/null
}

_byok_cli_hub_is_exported() {
  local _BYOK_CLI_HUB_LOCAL_DECLARATION
  _BYOK_CLI_HUB_LOCAL_DECLARATION="$(_byok_cli_hub_declaration "$1")" || return 1
  [[ "$_BYOK_CLI_HUB_LOCAL_DECLARATION" =~ ^declare\ -[^[:space:]]*x ]]
}

_byok_cli_hub_has_unsafe_attributes() {
  local _BYOK_CLI_HUB_LOCAL_DECLARATION
  _BYOK_CLI_HUB_LOCAL_DECLARATION="$(_byok_cli_hub_declaration "$1")" || return 1
  case "$_BYOK_CLI_HUB_LOCAL_DECLARATION" in
    'declare -- '*|'declare -x '*) return 1 ;;
    *) return 0 ;;
  esac
}

_byok_cli_hub_set_global() {
  local _BYOK_CLI_HUB_LOCAL_NAME="$1" _BYOK_CLI_HUB_LOCAL_VALUE="$2" _BYOK_CLI_HUB_LOCAL_EXPORTED="$3"
  declare -g -- "$_BYOK_CLI_HUB_LOCAL_NAME=$_BYOK_CLI_HUB_LOCAL_VALUE" || return 1
  if [[ "$_BYOK_CLI_HUB_LOCAL_EXPORTED" == '1' ]]; then
    export -- "$_BYOK_CLI_HUB_LOCAL_NAME" || return 1
  else
    export -n -- "$_BYOK_CLI_HUB_LOCAL_NAME" 2>/dev/null || return 1
  fi
}

_byok_cli_hub_unset_global() {
  unset -v -- "$1"
}

_byok_cli_hub_drop_ownership() {
  local _BYOK_CLI_HUB_LOCAL_NAME="$1"
  unset "_BYOK_CLI_HUB_ACTIVE_KEYS[$_BYOK_CLI_HUB_LOCAL_NAME]"
  unset "_BYOK_CLI_HUB_ORIGINAL_PRESENT[$_BYOK_CLI_HUB_LOCAL_NAME]"
  unset "_BYOK_CLI_HUB_ORIGINAL_EXPORTED[$_BYOK_CLI_HUB_LOCAL_NAME]"
  unset "_BYOK_CLI_HUB_ORIGINAL_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]"
  unset "_BYOK_CLI_HUB_APPLIED_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]"
}

_byok_cli_hub_snapshot_baseline() {
  local _BYOK_CLI_HUB_LOCAL_NAME="$1"
  if [[ -v "$_BYOK_CLI_HUB_LOCAL_NAME" ]]; then
    _BYOK_CLI_HUB_ORIGINAL_PRESENT["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
    _BYOK_CLI_HUB_ORIGINAL_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${!_BYOK_CLI_HUB_LOCAL_NAME}"
    if _byok_cli_hub_is_exported "$_BYOK_CLI_HUB_LOCAL_NAME"; then
      _BYOK_CLI_HUB_ORIGINAL_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
    else
      _BYOK_CLI_HUB_ORIGINAL_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='0'
    fi
  else
    _BYOK_CLI_HUB_ORIGINAL_PRESENT["$_BYOK_CLI_HUB_LOCAL_NAME"]='0'
    _BYOK_CLI_HUB_ORIGINAL_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='0'
    _BYOK_CLI_HUB_ORIGINAL_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]=''
  fi
}

_byok_cli_hub_current_matches_applied() {
  local _BYOK_CLI_HUB_LOCAL_NAME="$1"
  [[ -v "$_BYOK_CLI_HUB_LOCAL_NAME" ]] || return 1
  [[ "${!_BYOK_CLI_HUB_LOCAL_NAME}" == "${_BYOK_CLI_HUB_APPLIED_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}" ]]
}

_byok_cli_hub_restore_owned_key() {
  local _BYOK_CLI_HUB_LOCAL_NAME="$1"
  if [[ "${_BYOK_CLI_HUB_ORIGINAL_PRESENT[$_BYOK_CLI_HUB_LOCAL_NAME]}" == '1' ]]; then
    _byok_cli_hub_set_global \
      "$_BYOK_CLI_HUB_LOCAL_NAME" \
      "${_BYOK_CLI_HUB_ORIGINAL_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}" \
      "${_BYOK_CLI_HUB_ORIGINAL_EXPORTED[$_BYOK_CLI_HUB_LOCAL_NAME]}"
  else
    _byok_cli_hub_unset_global "$_BYOK_CLI_HUB_LOCAL_NAME"
  fi
}

_byok_cli_hub_apply_plan() {
  local -A _BYOK_CLI_HUB_LOCAL_AFFECTED=()
  local -A _BYOK_CLI_HUB_LOCAL_ROLLBACK_PRESENT=()
  local -A _BYOK_CLI_HUB_LOCAL_ROLLBACK_EXPORTED=()
  local -A _BYOK_CLI_HUB_LOCAL_ROLLBACK_VALUES=()
  local -A _BYOK_CLI_HUB_LOCAL_SAVED_ACTIVE=()
  local -A _BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_PRESENT=()
  local -A _BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_EXPORTED=()
  local -A _BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_VALUES=()
  local -A _BYOK_CLI_HUB_LOCAL_SAVED_APPLIED_VALUES=()
  local _BYOK_CLI_HUB_LOCAL_NAME _BYOK_CLI_HUB_LOCAL_DECLARATION _BYOK_CLI_HUB_LOCAL_FAILED=0

  for _BYOK_CLI_HUB_LOCAL_NAME in "${!_BYOK_CLI_HUB_ACTIVE_KEYS[@]}" "${_BYOK_CLI_HUB_PLAN_NAMES[@]}"; do
    [[ -n "$_BYOK_CLI_HUB_LOCAL_NAME" ]] || continue
    _BYOK_CLI_HUB_LOCAL_AFFECTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
  done

  for _BYOK_CLI_HUB_LOCAL_NAME in "${!_BYOK_CLI_HUB_LOCAL_AFFECTED[@]}"; do
    if _byok_cli_hub_is_reserved_name "$_BYOK_CLI_HUB_LOCAL_NAME"; then
      _byok_cli_hub_error "Environment variable '$_BYOK_CLI_HUB_LOCAL_NAME' is reserved for the caller shell."
      return 1
    fi
    _BYOK_CLI_HUB_LOCAL_DECLARATION="$(_byok_cli_hub_declaration "$_BYOK_CLI_HUB_LOCAL_NAME")" || _BYOK_CLI_HUB_LOCAL_DECLARATION=''
    if [[ -n "$_BYOK_CLI_HUB_LOCAL_DECLARATION" ]] && _byok_cli_hub_has_unsafe_attributes "$_BYOK_CLI_HUB_LOCAL_NAME"; then
      _byok_cli_hub_error "Environment variable '$_BYOK_CLI_HUB_LOCAL_NAME' is readonly, an array, or has unsupported Bash attributes."
      return 1
    fi
    if [[ -v "$_BYOK_CLI_HUB_LOCAL_NAME" ]]; then
      _BYOK_CLI_HUB_LOCAL_ROLLBACK_PRESENT["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
      _BYOK_CLI_HUB_LOCAL_ROLLBACK_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${!_BYOK_CLI_HUB_LOCAL_NAME}"
      if _byok_cli_hub_is_exported "$_BYOK_CLI_HUB_LOCAL_NAME"; then
        _BYOK_CLI_HUB_LOCAL_ROLLBACK_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
      else
        _BYOK_CLI_HUB_LOCAL_ROLLBACK_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='0'
      fi
    else
      _BYOK_CLI_HUB_LOCAL_ROLLBACK_PRESENT["$_BYOK_CLI_HUB_LOCAL_NAME"]='0'
      _BYOK_CLI_HUB_LOCAL_ROLLBACK_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]='0'
      _BYOK_CLI_HUB_LOCAL_ROLLBACK_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]=''
    fi
  done

  for _BYOK_CLI_HUB_LOCAL_NAME in "${!_BYOK_CLI_HUB_ACTIVE_KEYS[@]}"; do
    _BYOK_CLI_HUB_LOCAL_SAVED_ACTIVE["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_ACTIVE_KEYS[$_BYOK_CLI_HUB_LOCAL_NAME]}"
    _BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_PRESENT["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_ORIGINAL_PRESENT[$_BYOK_CLI_HUB_LOCAL_NAME]}"
    _BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_ORIGINAL_EXPORTED[$_BYOK_CLI_HUB_LOCAL_NAME]}"
    _BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_ORIGINAL_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}"
    _BYOK_CLI_HUB_LOCAL_SAVED_APPLIED_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_APPLIED_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}"
  done

  for _BYOK_CLI_HUB_LOCAL_NAME in "${!_BYOK_CLI_HUB_ACTIVE_KEYS[@]}"; do
    if [[ -z "${_BYOK_CLI_HUB_PLAN_ENV[$_BYOK_CLI_HUB_LOCAL_NAME]+present}" ]]; then
      if _byok_cli_hub_current_matches_applied "$_BYOK_CLI_HUB_LOCAL_NAME"; then
        _byok_cli_hub_restore_owned_key "$_BYOK_CLI_HUB_LOCAL_NAME" || { _BYOK_CLI_HUB_LOCAL_FAILED=1; break; }
      fi
      _byok_cli_hub_drop_ownership "$_BYOK_CLI_HUB_LOCAL_NAME"
    fi
  done

  if [[ "$_BYOK_CLI_HUB_LOCAL_FAILED" == '0' ]]; then
    for _BYOK_CLI_HUB_LOCAL_NAME in "${_BYOK_CLI_HUB_PLAN_NAMES[@]}"; do
      if [[ -n "${_BYOK_CLI_HUB_ACTIVE_KEYS[$_BYOK_CLI_HUB_LOCAL_NAME]+present}" ]]; then
        if ! _byok_cli_hub_current_matches_applied "$_BYOK_CLI_HUB_LOCAL_NAME"; then
          _byok_cli_hub_drop_ownership "$_BYOK_CLI_HUB_LOCAL_NAME"
          _byok_cli_hub_snapshot_baseline "$_BYOK_CLI_HUB_LOCAL_NAME"
        fi
      else
        _byok_cli_hub_snapshot_baseline "$_BYOK_CLI_HUB_LOCAL_NAME"
      fi
      if ! _byok_cli_hub_set_global "$_BYOK_CLI_HUB_LOCAL_NAME" "${_BYOK_CLI_HUB_PLAN_ENV[$_BYOK_CLI_HUB_LOCAL_NAME]}" '1'; then
        _BYOK_CLI_HUB_LOCAL_FAILED=1
        break
      fi
      _BYOK_CLI_HUB_ACTIVE_KEYS["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
      _BYOK_CLI_HUB_APPLIED_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_PLAN_ENV[$_BYOK_CLI_HUB_LOCAL_NAME]}"
    done
  fi

  if [[ "$_BYOK_CLI_HUB_LOCAL_FAILED" == '1' ]]; then
    for _BYOK_CLI_HUB_LOCAL_NAME in "${!_BYOK_CLI_HUB_LOCAL_AFFECTED[@]}"; do
      if [[ "${_BYOK_CLI_HUB_LOCAL_ROLLBACK_PRESENT[$_BYOK_CLI_HUB_LOCAL_NAME]}" == '1' ]]; then
        _byok_cli_hub_set_global \
          "$_BYOK_CLI_HUB_LOCAL_NAME" \
          "${_BYOK_CLI_HUB_LOCAL_ROLLBACK_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}" \
          "${_BYOK_CLI_HUB_LOCAL_ROLLBACK_EXPORTED[$_BYOK_CLI_HUB_LOCAL_NAME]}" || true
      else
        _byok_cli_hub_unset_global "$_BYOK_CLI_HUB_LOCAL_NAME" || true
      fi
    done
    _BYOK_CLI_HUB_ACTIVE_KEYS=()
    _BYOK_CLI_HUB_ORIGINAL_PRESENT=()
    _BYOK_CLI_HUB_ORIGINAL_EXPORTED=()
    _BYOK_CLI_HUB_ORIGINAL_VALUES=()
    _BYOK_CLI_HUB_APPLIED_VALUES=()
    for _BYOK_CLI_HUB_LOCAL_NAME in "${!_BYOK_CLI_HUB_LOCAL_SAVED_ACTIVE[@]}"; do
      _BYOK_CLI_HUB_ACTIVE_KEYS["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_LOCAL_SAVED_ACTIVE[$_BYOK_CLI_HUB_LOCAL_NAME]}"
      _BYOK_CLI_HUB_ORIGINAL_PRESENT["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_PRESENT[$_BYOK_CLI_HUB_LOCAL_NAME]}"
      _BYOK_CLI_HUB_ORIGINAL_EXPORTED["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_EXPORTED[$_BYOK_CLI_HUB_LOCAL_NAME]}"
      _BYOK_CLI_HUB_ORIGINAL_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_LOCAL_SAVED_ORIGINAL_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}"
      _BYOK_CLI_HUB_APPLIED_VALUES["$_BYOK_CLI_HUB_LOCAL_NAME"]="${_BYOK_CLI_HUB_LOCAL_SAVED_APPLIED_VALUES[$_BYOK_CLI_HUB_LOCAL_NAME]}"
    done
    _byok_cli_hub_error 'Failed to apply the environment plan; the previous shell environment was restored.'
    return 1
  fi
}

_byok_cli_hub_resolve_executable() {
  local _BYOK_CLI_HUB_LOCAL_COMMAND="$1"
  _BYOK_CLI_HUB_RESOLVED_COMMAND=''
  if [[ "$_BYOK_CLI_HUB_LOCAL_COMMAND" == /* ]]; then
    [[ -f "$_BYOK_CLI_HUB_LOCAL_COMMAND" && -x "$_BYOK_CLI_HUB_LOCAL_COMMAND" ]] || return 1
    _BYOK_CLI_HUB_RESOLVED_COMMAND="$_BYOK_CLI_HUB_LOCAL_COMMAND"
  else
    _BYOK_CLI_HUB_RESOLVED_COMMAND="$(type -P -- "$_BYOK_CLI_HUB_LOCAL_COMMAND" 2>/dev/null)" || return 1
    [[ -n "$_BYOK_CLI_HUB_RESOLVED_COMMAND" ]]
  fi
}

_byok_cli_hub_invoke() {
  if [[ "$BASHPID" != "$_BYOK_CLI_HUB_OWNER_BASHPID" ]]; then
    _byok_cli_hub_error "Shell integration must run in the foreground Bash process that sourced it. Use 'command byok-cli-hub' for isolated execution."
    return 2
  fi
  if [[ ! -x "$_BYOK_CLI_HUB_REAL_COMMAND" ]]; then
    _byok_cli_hub_error "The real executable is missing or not executable: $_BYOK_CLI_HUB_REAL_COMMAND"
    return 5
  fi

  local _BYOK_CLI_HUB_LOCAL_UI_FD _BYOK_CLI_HUB_LOCAL_PAYLOAD _BYOK_CLI_HUB_LOCAL_STATUS
  local _BYOK_CLI_HUB_LOCAL_LINE _BYOK_CLI_HUB_LOCAL_KIND _BYOK_CLI_HUB_LOCAL_REST
  local _BYOK_CLI_HUB_LOCAL_NAME _BYOK_CLI_HUB_LOCAL_HEX _BYOK_CLI_HUB_LOCAL_END_COUNT
  local _BYOK_CLI_HUB_LOCAL_LINE_NUMBER=0 _BYOK_CLI_HUB_LOCAL_RECORD_COUNT=0 _BYOK_CLI_HUB_LOCAL_ENDED=0
  local _BYOK_CLI_HUB_LOCAL_ACTION='' _BYOK_CLI_HUB_LOCAL_COMMAND='' _BYOK_CLI_HUB_DECODED=''
  local _BYOK_CLI_HUB_RESOLVED_COMMAND=''
  local -A _BYOK_CLI_HUB_PLAN_ENV=()
  local -A _BYOK_CLI_HUB_LOCAL_SEEN_ENV=()
  local -a _BYOK_CLI_HUB_PLAN_NAMES=()
  local -a _BYOK_CLI_HUB_LOCAL_ARGS=()

  exec {_BYOK_CLI_HUB_LOCAL_UI_FD}>&1 || {
    _byok_cli_hub_error 'Could not duplicate stdout for the shell plan channel.'
    return 1
  }
  if _BYOK_CLI_HUB_LOCAL_PAYLOAD="$(
    "$_BYOK_CLI_HUB_REAL_COMMAND" --internal-shell-plan-fd 3 "$@" \
      3>&1 1>&"$_BYOK_CLI_HUB_LOCAL_UI_FD"
  )"; then
    _BYOK_CLI_HUB_LOCAL_STATUS=0
  else
    _BYOK_CLI_HUB_LOCAL_STATUS=$?
  fi
  exec {_BYOK_CLI_HUB_LOCAL_UI_FD}>&- || true

  if [[ "$_BYOK_CLI_HUB_LOCAL_STATUS" != '0' ]]; then
    _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
    return "$_BYOK_CLI_HUB_LOCAL_STATUS"
  fi
  if (( ${#_BYOK_CLI_HUB_LOCAL_PAYLOAD} > 1048576 )); then
    _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
    _byok_cli_hub_error 'The shell plan exceeded the 1 MiB limit.'
    return 1
  fi

  while IFS= read -r _BYOK_CLI_HUB_LOCAL_LINE || [[ -n "$_BYOK_CLI_HUB_LOCAL_LINE" ]]; do
    ((_BYOK_CLI_HUB_LOCAL_LINE_NUMBER += 1))
    if [[ "$_BYOK_CLI_HUB_LOCAL_LINE_NUMBER" == '1' ]]; then
      if [[ "$_BYOK_CLI_HUB_LOCAL_LINE" != $'BYOK_CLI_HUB_SHELL_PLAN\t1' ]]; then
        _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
        _byok_cli_hub_error 'The shell plan header or version was invalid.'
        return 1
      fi
      continue
    fi
    if [[ "$_BYOK_CLI_HUB_LOCAL_ENDED" == '1' ]]; then
      _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
      _byok_cli_hub_error 'The shell plan contained trailing data.'
      return 1
    fi
    if [[ "$_BYOK_CLI_HUB_LOCAL_LINE" != *$'\t'* ]]; then
      _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
      _byok_cli_hub_error 'The shell plan contained a malformed record.'
      return 1
    fi
    _BYOK_CLI_HUB_LOCAL_KIND="${_BYOK_CLI_HUB_LOCAL_LINE%%$'\t'*}"
    _BYOK_CLI_HUB_LOCAL_REST="${_BYOK_CLI_HUB_LOCAL_LINE#*$'\t'}"
    case "$_BYOK_CLI_HUB_LOCAL_KIND" in
      ACTION)
        if [[ -n "$_BYOK_CLI_HUB_LOCAL_ACTION" || "$_BYOK_CLI_HUB_LOCAL_REST" == *$'\t'* || "$_BYOK_CLI_HUB_LOCAL_REST" != 'launch' && "$_BYOK_CLI_HUB_LOCAL_REST" != 'none' ]]; then
          _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
          _byok_cli_hub_error 'The shell plan action was invalid or duplicated.'
          return 1
        fi
        _BYOK_CLI_HUB_LOCAL_ACTION="$_BYOK_CLI_HUB_LOCAL_REST"
        ((_BYOK_CLI_HUB_LOCAL_RECORD_COUNT += 1))
        ;;
      ENV)
        if [[ "$_BYOK_CLI_HUB_LOCAL_REST" != *$'\t'* ]]; then
          _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
          _byok_cli_hub_error 'The shell plan contained a malformed environment record.'
          return 1
        fi
        _BYOK_CLI_HUB_LOCAL_NAME="${_BYOK_CLI_HUB_LOCAL_REST%%$'\t'*}"
        _BYOK_CLI_HUB_LOCAL_HEX="${_BYOK_CLI_HUB_LOCAL_REST#*$'\t'}"
        if [[ "$_BYOK_CLI_HUB_LOCAL_HEX" == *$'\t'* || ! "$_BYOK_CLI_HUB_LOCAL_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
           _byok_cli_hub_is_reserved_name "$_BYOK_CLI_HUB_LOCAL_NAME" ||
           [[ -n "${_BYOK_CLI_HUB_LOCAL_SEEN_ENV[$_BYOK_CLI_HUB_LOCAL_NAME]+present}" ]] ||
           ! _byok_cli_hub_decode_hex "$_BYOK_CLI_HUB_LOCAL_HEX"; then
          _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
          _BYOK_CLI_HUB_DECODED=''
          _byok_cli_hub_error "The shell plan environment record for '$_BYOK_CLI_HUB_LOCAL_NAME' was invalid."
          return 1
        fi
        _BYOK_CLI_HUB_LOCAL_SEEN_ENV["$_BYOK_CLI_HUB_LOCAL_NAME"]='1'
        _BYOK_CLI_HUB_PLAN_NAMES+=("$_BYOK_CLI_HUB_LOCAL_NAME")
        _BYOK_CLI_HUB_PLAN_ENV["$_BYOK_CLI_HUB_LOCAL_NAME"]="$_BYOK_CLI_HUB_DECODED"
        _BYOK_CLI_HUB_DECODED=''
        ((_BYOK_CLI_HUB_LOCAL_RECORD_COUNT += 1))
        (( ${#_BYOK_CLI_HUB_PLAN_NAMES[@]} <= 1024 )) || {
          _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
          _byok_cli_hub_error 'The shell plan contained too many environment records.'
          return 1
        }
        ;;
      COMMAND|ARG)
        if [[ "$_BYOK_CLI_HUB_LOCAL_REST" == *$'\t'* ]] || ! _byok_cli_hub_decode_hex "$_BYOK_CLI_HUB_LOCAL_REST"; then
          _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
          _BYOK_CLI_HUB_DECODED=''
          _byok_cli_hub_error "The shell plan $_BYOK_CLI_HUB_LOCAL_KIND record was invalid."
          return 1
        fi
        if [[ "$_BYOK_CLI_HUB_LOCAL_KIND" == 'COMMAND' ]]; then
          if [[ -n "$_BYOK_CLI_HUB_LOCAL_COMMAND" || -z "$_BYOK_CLI_HUB_DECODED" ]]; then
            _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
            _BYOK_CLI_HUB_DECODED=''
            _byok_cli_hub_error 'The shell plan command was invalid or duplicated.'
            return 1
          fi
          _BYOK_CLI_HUB_LOCAL_COMMAND="$_BYOK_CLI_HUB_DECODED"
        else
          _BYOK_CLI_HUB_LOCAL_ARGS+=("$_BYOK_CLI_HUB_DECODED")
          (( ${#_BYOK_CLI_HUB_LOCAL_ARGS[@]} <= 4096 )) || {
            _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
            _BYOK_CLI_HUB_DECODED=''
            _byok_cli_hub_error 'The shell plan contained too many argument records.'
            return 1
          }
        fi
        _BYOK_CLI_HUB_DECODED=''
        ((_BYOK_CLI_HUB_LOCAL_RECORD_COUNT += 1))
        ;;
      END)
        if [[ ! "$_BYOK_CLI_HUB_LOCAL_REST" =~ ^[0-9]+$ ]]; then
          _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
          _byok_cli_hub_error 'The shell plan end record was invalid.'
          return 1
        fi
        _BYOK_CLI_HUB_LOCAL_END_COUNT="$_BYOK_CLI_HUB_LOCAL_REST"
        _BYOK_CLI_HUB_LOCAL_ENDED=1
        ;;
      *)
        _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
        _byok_cli_hub_error "The shell plan contained an unknown '$_BYOK_CLI_HUB_LOCAL_KIND' record."
        return 1
        ;;
    esac
  done <<< "$_BYOK_CLI_HUB_LOCAL_PAYLOAD"

  _BYOK_CLI_HUB_LOCAL_PAYLOAD=''
  if [[ "$_BYOK_CLI_HUB_LOCAL_LINE_NUMBER" -lt 3 || "$_BYOK_CLI_HUB_LOCAL_ENDED" != '1' ||
        -z "$_BYOK_CLI_HUB_LOCAL_ACTION" || "$_BYOK_CLI_HUB_LOCAL_END_COUNT" != "$_BYOK_CLI_HUB_LOCAL_RECORD_COUNT" ]]; then
    _byok_cli_hub_error 'The shell plan was incomplete or its record count did not match.'
    return 1
  fi

  if [[ "$_BYOK_CLI_HUB_LOCAL_ACTION" == 'none' ]]; then
    if [[ -n "$_BYOK_CLI_HUB_LOCAL_COMMAND" || "${#_BYOK_CLI_HUB_PLAN_NAMES[@]}" != '0' || "${#_BYOK_CLI_HUB_LOCAL_ARGS[@]}" != '0' ]]; then
      _byok_cli_hub_error 'A non-launch shell plan contained launch data.'
      return 1
    fi
    return 0
  fi
  if [[ -z "$_BYOK_CLI_HUB_LOCAL_COMMAND" ]]; then
    _byok_cli_hub_error 'The launch shell plan did not contain a command.'
    return 1
  fi
  if ! _byok_cli_hub_resolve_executable "$_BYOK_CLI_HUB_LOCAL_COMMAND"; then
    _byok_cli_hub_error "The resolved command is no longer executable: $_BYOK_CLI_HUB_LOCAL_COMMAND"
    return 5
  fi
  if ! _byok_cli_hub_apply_plan; then
    return 1
  fi

  _BYOK_CLI_HUB_LOCAL_COMMAND=''
  "$_BYOK_CLI_HUB_RESOLVED_COMMAND" "${_BYOK_CLI_HUB_LOCAL_ARGS[@]}"
}

byok-cli-hub() {
  local _BYOK_CLI_HUB_LOCAL_STATUS _BYOK_CLI_HUB_LOCAL_XTRACE=0
  case "$-" in *x*) _BYOK_CLI_HUB_LOCAL_XTRACE=1; set +x ;; esac
  if _byok_cli_hub_invoke "$@"; then
    _BYOK_CLI_HUB_LOCAL_STATUS=0
  else
    _BYOK_CLI_HUB_LOCAL_STATUS=$?
  fi
  [[ "$_BYOK_CLI_HUB_LOCAL_XTRACE" != '1' ]] || set -x
  return "$_BYOK_CLI_HUB_LOCAL_STATUS"
}

_byok_cli_hub_deactivate_internal() {
  local -A _BYOK_CLI_HUB_PLAN_ENV=()
  local -a _BYOK_CLI_HUB_PLAN_NAMES=()
  _byok_cli_hub_apply_plan
}

byok-cli-hub-deactivate() {
  local _BYOK_CLI_HUB_LOCAL_STATUS _BYOK_CLI_HUB_LOCAL_XTRACE=0
  case "$-" in *x*) _BYOK_CLI_HUB_LOCAL_XTRACE=1; set +x ;; esac
  if _byok_cli_hub_deactivate_internal; then
    _BYOK_CLI_HUB_LOCAL_STATUS=0
  else
    _BYOK_CLI_HUB_LOCAL_STATUS=$?
  fi
  [[ "$_BYOK_CLI_HUB_LOCAL_XTRACE" != '1' ]] || set -x
  return "$_BYOK_CLI_HUB_LOCAL_STATUS"
}

byok-cli-hub-shell-unload() {
  byok-cli-hub-deactivate || return $?
  unset -f byok-cli-hub byok-cli-hub-deactivate _byok_cli_hub_deactivate_internal
  unset -f _byok_cli_hub_error _byok_cli_hub_is_reserved_name _byok_cli_hub_decode_hex
  unset -f _byok_cli_hub_declaration _byok_cli_hub_is_exported _byok_cli_hub_has_unsafe_attributes
  unset -f _byok_cli_hub_set_global _byok_cli_hub_unset_global _byok_cli_hub_drop_ownership
  unset -f _byok_cli_hub_snapshot_baseline _byok_cli_hub_current_matches_applied
  unset -f _byok_cli_hub_restore_owned_key _byok_cli_hub_apply_plan _byok_cli_hub_resolve_executable
  unset -f _byok_cli_hub_invoke byok-cli-hub-shell-unload
  unset _BYOK_CLI_HUB_ACTIVE_KEYS _BYOK_CLI_HUB_ORIGINAL_PRESENT _BYOK_CLI_HUB_ORIGINAL_EXPORTED
  unset _BYOK_CLI_HUB_ORIGINAL_VALUES _BYOK_CLI_HUB_APPLIED_VALUES
  unset _BYOK_CLI_HUB_REAL_COMMAND _BYOK_CLI_HUB_OWNER_BASHPID
}
