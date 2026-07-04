#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_env_profiles.sh"

PROFILE="local"   # local | validation
SEEN_PROFILE=0

for arg in "$@"; do
  case "$arg" in
    local|validation)
      if [[ "$SEEN_PROFILE" -eq 1 && "$PROFILE" != "$arg" ]]; then
        die "Conflicting profiles: '$PROFILE' and '$arg' (use only one: local|validation)"
      fi
      PROFILE="$arg"
      SEEN_PROFILE=1
      ;;
    *)
      die "Unknown arg: $arg (use: [local|validation])"
      ;;
  esac
done

set_env_profile "$PROFILE"

ENV_FILE="$AUTHLAB_ENV_FILE"
DB_INIT="$REPO_ROOT/scripts/db/db_init.py"
PY="$REPO_ROOT/.venv/bin/python"

STATE_DIR="$AUTHLAB_STATE_DIR"
READY_FILE="$AUTHLAB_READY_FILE"

[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE (run ./scripts/00_env_bootstrap.sh $PROFILE first)"
[[ -f "$DB_INIT" ]] || die "DB init script not found: $DB_INIT"
[[ -x "$PY" ]] || die "Python not found in .venv: $PY (run ./scripts/00_env_bootstrap.sh $PROFILE first)"

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

info "Profile: $PROFILE"
info "Env file: $ENV_FILE"
info "Python: $PY"
info "DB init script: $DB_INIT"
info "Ready marker: $READY_FILE"

mkdir -p "$STATE_DIR"
rm -f "$READY_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ -n "${DB_PATH:-}" ]] || die "DB_PATH is empty or missing after loading: $ENV_FILE"
info "DB_PATH=$DB_PATH"

info "Initializing database (existing DB will be recreated)..."
"$PY" "$DB_INIT" init || die "DB init failed"

info "Verifying database..."
"$PY" "$DB_INIT" verify || die "DB verify failed"

cat > "$READY_FILE" <<EOF
PROFILE=$PROFILE
ENV_FILE=$ENV_FILE
DB_PATH=$DB_PATH
STATUS=ready
EOF

info "DB init + verify complete"
info "Ready marker written: $READY_FILE"
exit 0