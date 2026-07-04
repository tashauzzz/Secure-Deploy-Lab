#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_env_profiles.sh"

# Generated Kubernetes Secret manifests contain sensitive values.
umask 077

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
K8S_DIR="$REPO_ROOT/k8s"
FINAL_DST="$K8S_DIR/secret.local.yaml"
WORK_DST="${FINAL_DST}.tmp"
PY="$REPO_ROOT/.venv/bin/python"

cleanup_tmp() {
  local status=$?
  if [[ "$status" -ne 0 && -f "$WORK_DST" ]]; then
    rm -f "$WORK_DST" || true
    info "Removed incomplete temp file: $WORK_DST"
  fi
}
trap cleanup_tmp EXIT

require_env_ready() {
	local key="$1"
	local val="${!key:-}"

	[[ -n "${val//[[:space:]]/}" ]] || die "Required env key '$key' is empty or missing in: $ENV_FILE"

	case "$val" in
		CHANGE_ME|*EXAMPLE*|*example*|*PLACEHOLDER*)
			die "Env key '$key' still looks like a placeholder in: $ENV_FILE"
			;;
	esac
}

yaml_quote() {
	local value="$1"

	VALUE="$value" "$PY" - <<'PY'
import json
import os

print(json.dumps(os.environ["VALUE"]))
PY
}

[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE
Run first:
  ./scripts/00_env_bootstrap.sh $PROFILE"

[[ -x "$PY" ]] || die "Python not found in .venv: $PY
Run first:
  ./scripts/00_env_bootstrap.sh $PROFILE"

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

info "Preparing Kubernetes Secret manifest"
info "Profile: $PROFILE"
info "Env file: $ENV_FILE"
info "Secret output: $FINAL_DST"

# Prevent inherited shell values from masking missing keys in the selected env file.
unset DEV_API_KEY SECRET_KEY ADMIN_PWHASH ADMIN_MFA_ENABLED ADMIN_MFA_SECRET

# shellcheck disable=SC1090
source "$ENV_FILE"

require_env_ready "DEV_API_KEY"
require_env_ready "SECRET_KEY"
require_env_ready "ADMIN_PWHASH"

MFA_ENABLED_VALUE="$(printf "%s" "${ADMIN_MFA_ENABLED:-}" | tr '[:upper:]' '[:lower:]')"

if [[ "$MFA_ENABLED_VALUE" != "false" ]]; then
	die "ADMIN_MFA_ENABLED must be false for Project 3 Kubernetes profile '$PROFILE'. Got: ${ADMIN_MFA_ENABLED:-<empty>}"
fi

if [[ -n "${ADMIN_MFA_SECRET:-}" && -n "${ADMIN_MFA_SECRET//[[:space:]]/}" ]]; then
	die "ADMIN_MFA_SECRET must be empty when ADMIN_MFA_ENABLED=false for Project 3 Kubernetes profile '$PROFILE'"
fi

mkdir -p "$K8S_DIR"

PROFILE_Q="$(yaml_quote "$PROFILE")"
DEV_API_KEY_Q="$(yaml_quote "$DEV_API_KEY")"
SECRET_KEY_Q="$(yaml_quote "$SECRET_KEY")"
ADMIN_PWHASH_Q="$(yaml_quote "$ADMIN_PWHASH")"
ADMIN_MFA_SECRET_Q="$(yaml_quote "${ADMIN_MFA_SECRET:-}")"

cat > "$WORK_DST" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: authlab-secret
  namespace: authlab
  labels:
    app.kubernetes.io/name: authlab
    app.kubernetes.io/part-of: secure-deploy-lab
    app.kubernetes.io/component: secret
    app.kubernetes.io/managed-by: kubectl
  annotations:
    secure-deploy-lab/profile: $PROFILE_Q
    secure-deploy-lab/generated-by: "scripts/06_prepare_k8s_secret.sh"
type: Opaque
stringData:
  DEV_API_KEY: $DEV_API_KEY_Q
  SECRET_KEY: $SECRET_KEY_Q
  ADMIN_PWHASH: $ADMIN_PWHASH_Q
  ADMIN_MFA_SECRET: $ADMIN_MFA_SECRET_Q
EOF

chmod 600 "$WORK_DST" \
	|| die "Failed to set private permissions on: $WORK_DST"

mv -f "$WORK_DST" "$FINAL_DST" \
	|| die "Failed to move temp file into place: $FINAL_DST"

info "Generated Kubernetes Secret manifest: $FINAL_DST"
exit 0