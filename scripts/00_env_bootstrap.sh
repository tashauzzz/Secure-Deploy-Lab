#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_env_profiles.sh"

# New files created here should be private by default (.env/.env.validation contain secrets).
umask 077

PROFILE="local"   # local | validation
FORCE=0
SEEN_PROFILE=0
PY=""

VENV_DIR="$REPO_ROOT/.venv"
APP_REQ="$REPO_ROOT/requirements.txt"

STATE_DIR="$REPO_ROOT/.state"

for arg in "$@"; do
  case "$arg" in
    --force)
      FORCE=1
      ;;
    local|validation)
      if [[ "$SEEN_PROFILE" -eq 1 && "$PROFILE" != "$arg" ]]; then
        die "Conflicting profiles: '$PROFILE' and '$arg' (use only one: local|validation)"
      fi
      PROFILE="$arg"
      SEEN_PROFILE=1
      ;;
    *)
      die "Unknown arg: $arg (use: [--force] [local|validation])"
      ;;
  esac
done

set_env_profile "$PROFILE"

SRC="$AUTHLAB_ENV_TEMPLATE"
FINAL_DST="$AUTHLAB_ENV_FILE"
STATE_DIR="$AUTHLAB_STATE_DIR"
READY_FILE="$AUTHLAB_READY_FILE"
DEV_API_KEY_PREFIX="$AUTHLAB_DEV_API_KEY_PREFIX"

WORK_DST="${FINAL_DST}.tmp"

cleanup_tmp() {
  local status=$?
  if [[ "$status" -ne 0 && -f "$WORK_DST" ]]; then
    rm -f "$WORK_DST" || true
    info "Removed incomplete temp file: $WORK_DST"
  fi
}
trap cleanup_tmp EXIT

info "Repo root: $REPO_ROOT"
info "Profile: $PROFILE"
info "Virtual env: $VENV_DIR"
info "Env template: $SRC"
info "Env output: $FINAL_DST"

ensure_host_venv() {
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    info "Using existing .venv"
  else
    command -v python3 >/dev/null 2>&1 || die "python3 not found (required to create .venv)"
    info "Creating .venv"
    python3 -m venv "$VENV_DIR" || die "Failed to create .venv"
  fi

  PY="$VENV_DIR/bin/python"
  [[ -x "$PY" ]] || die "Python not found in .venv: $PY"

  info "Python selected: $PY"
  info "Python version: $("$PY" -V 2>&1)"

  info "Upgrading pip in .venv"
  "$PY" -m pip install --upgrade pip || die "Failed to upgrade pip in .venv"

  info "pip version: $("$PY" -m pip --version 2>&1)"
}

install_app_requirements() {
  [[ -s "$APP_REQ" ]] || die "Requirements file missing or empty: $APP_REQ"

  info "Installing $(basename "$APP_REQ") into .venv"
  "$PY" -m pip install -r "$APP_REQ" || die "Failed to install: $APP_REQ"
}

set_kv() {
  local file="$1" key="$2" val="$3"
  local tmp="${file}.tmp"

  awk -v k="$key" -v v="$val" '
    BEGIN { found=0 }
    $0 ~ ("^" k "=") { print k "=" v; found=1; next }
    { print }
    END { if (found==0) print k "=" v }
  ' "$file" > "$tmp" || return 1

  mv "$tmp" "$file" || return 1
  return 0
}

get_kv() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | head -n 1 | cut -d= -f2-
}

rand_hex() {
  od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

is_false() {
  local v
  v="$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "false" ]]
}

MIN_ADMIN_PASS_LEN=12

password_is_forbidden() {
  local pwd="$1"
  local lowered

  lowered="$(printf "%s" "$pwd" | tr '[:upper:]' '[:lower:]')"

  case "$lowered" in
    admin|password|adminadmin|passwordpassword|qwerty|letmein|1|11111111|12345678|123456789|1234567890)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_admin_password() {
  local pwd="$1"

  [[ -n "$pwd" ]] || die "Admin password must not be empty"

  [[ -n "${pwd//[[:space:]]/}" ]] || die "Admin password must not be blank or whitespace-only"

  if [[ "${#pwd}" -lt "$MIN_ADMIN_PASS_LEN" ]]; then
    die "Admin password must be at least $MIN_ADMIN_PASS_LEN characters long"
  fi

  if password_is_forbidden "$pwd"; then
    die "Admin password is too weak or too common"
  fi
}

generate_validation_password() {
  local pwd

  pwd="validation-$(rand_hex 24)"
  validate_admin_password "$pwd"

  printf "%s" "$pwd"
}

prompt_admin_password() {
  local pwd1="" pwd2=""

  while true; do
    read -r -s -p "Admin password (hidden): " pwd1
    printf "\n" >&2
    read -r -s -p "Repeat admin password: " pwd2
    printf "\n" >&2

    [[ "$pwd1" == "$pwd2" ]] || {
      printf "[ERROR] Passwords do not match. Try again.\n" >&2
      continue
    }

    validate_admin_password "$pwd1"
    printf "%s" "$pwd1"
    return 0
  done
}

require_kv_ready() {
  local file="$1" key="$2" val
  val="$(get_kv "$file" "$key")"

  [[ -n "${val// }" ]] || die "Required key '$key' is empty or missing in: $file"

  case "$val" in
    CHANGE_ME|*EXAMPLE*|*example*|*PLACEHOLDER*)
      die "Key '$key' still looks like a placeholder in: $file"
      ;;
  esac
}

require_mfa_disabled() {
  local file="$1" mfa_enabled mfa_secret

  mfa_enabled="$(get_kv "$file" "ADMIN_MFA_ENABLED")"
  mfa_secret="$(get_kv "$file" "ADMIN_MFA_SECRET")"

  if ! is_false "$mfa_enabled"; then
    die "ADMIN_MFA_ENABLED must be false for Project 3 profile '$PROFILE'. MFA behavior is covered in AuthLab; this project focuses on container/workload hardening."
  fi

  if [[ -n "${mfa_secret// }" ]]; then
    die "ADMIN_MFA_SECRET must be empty when ADMIN_MFA_ENABLED=false for Project 3 profile '$PROFILE'."
  fi
}

validate_final_env() {
  local file="$1"
  [[ -f "$file" ]] || die "Env file not found: $file"

  require_kv_ready "$file" "SECRET_KEY"
  require_kv_ready "$file" "DEV_API_KEY"
  require_kv_ready "$file" "DB_PATH"
  require_kv_ready "$file" "ADMIN_PWHASH"

  require_mfa_disabled "$file"
}

[[ -f "$SRC" ]] || die "Template not found: $SRC"

ensure_host_venv
install_app_requirements

if [[ -f "$FINAL_DST" && "$FORCE" -ne 1 ]]; then
  info "File already exists, not touching: $FINAL_DST (use --force to overwrite)"
  validate_final_env "$FINAL_DST"

  info "Validated existing env file: $FINAL_DST"
  info "$PROFILE env bootstrap complete"

  if [[ "$PROFILE" == "local" ]]; then
    info "To activate .venv in current shell, run: source .venv/bin/activate"
  fi

  exit 0
fi

mkdir -p "$STATE_DIR"
rm -f "$READY_FILE"
info "Cleared stale DB ready marker: $READY_FILE"

cp -f "$SRC" "$WORK_DST" || die "Failed to copy template to temp file: $WORK_DST"
info "Created temp file: $WORK_DST"

sed -i 's/\r$//' "$WORK_DST" 2>/dev/null || true
sed -i '/^[[:space:]]*$/d' "$WORK_DST" 2>/dev/null || true
chmod 600 "$WORK_DST" 2>/dev/null || true

set_kv "$WORK_DST" "ADMIN_MFA_SECRET" "" || die "Failed to clear ADMIN_MFA_SECRET"
require_mfa_disabled "$WORK_DST"
info "MFA disabled for profile '$PROFILE' -> ADMIN_MFA_SECRET cleared"

SECRET_KEY="$(rand_hex 32)"
DEV_API_KEY="$DEV_API_KEY_PREFIX-$(rand_hex 12)"

set_kv "$WORK_DST" "SECRET_KEY" "$SECRET_KEY" || die "Failed to set SECRET_KEY"
set_kv "$WORK_DST" "DEV_API_KEY" "$DEV_API_KEY" || die "Failed to set DEV_API_KEY"
info "Generated: SECRET_KEY, DEV_API_KEY"

"$PY" -c 'import werkzeug.security' >/dev/null 2>&1 || die "Missing Python module: werkzeug"

if [[ "$PROFILE" == "local" ]]; then
  ADMIN_PASSWORD="$(prompt_admin_password)"
else
  ADMIN_PASSWORD="$(generate_validation_password)"
fi

ADMIN_PWHASH="$(
  ADMIN_PASSWORD="$ADMIN_PASSWORD" "$PY" -c '
from werkzeug.security import generate_password_hash
import os
print(generate_password_hash(os.environ["ADMIN_PASSWORD"], method="scrypt"))
'
)"

set_kv "$WORK_DST" "ADMIN_PWHASH" "'$ADMIN_PWHASH'" || die "Failed to set ADMIN_PWHASH"
info "Generated: ADMIN_PWHASH"

unset ADMIN_PASSWORD

chmod 600 "$WORK_DST" 2>/dev/null || true
mv -f "$WORK_DST" "$FINAL_DST" || die "Failed to move temp file into place: $FINAL_DST"

validate_final_env "$FINAL_DST"

info "Validated env file: $FINAL_DST"
info "$PROFILE env bootstrap complete"

if [[ "$PROFILE" == "local" ]]; then
  info "To activate .venv in current shell, run: source .venv/bin/activate"
fi

exit 0