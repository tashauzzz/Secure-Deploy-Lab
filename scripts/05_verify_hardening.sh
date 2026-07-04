#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_env_profiles.sh"
source "$SCRIPT_DIR/_image_variants.sh"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

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
parse_image_variant hardened

ENV_FILE="$AUTHLAB_ENV_FILE"

REPORT_DIR="$REPO_ROOT/reports"
RUNTIME_REPORT="$REPORT_DIR/hardened-runtime-checks.json"

mkdir -p "$REPORT_DIR"
rm -f "$RUNTIME_REPORT"

need_cmd docker

docker compose version >/dev/null 2>&1 \
	|| die "docker compose not available"

[[ -f "$ENV_FILE" ]] \
	|| die "Missing env file: $ENV_FILE (run ./scripts/00_env_bootstrap.sh $PROFILE first)"

cd "$REPO_ROOT" \
	|| die "Failed to cd into repo root: $REPO_ROOT"

export_compose_image_env "$ENV_FILE"

info "Verifying hardened runtime"
info "Profile: $PROFILE"
info "IMAGE_VARIANT=$IMAGE_VARIANT"
info "AUTHLAB_ENV_FILE=$AUTHLAB_ENV_FILE"
info "AUTHLAB_IMAGE_REF=$AUTHLAB_IMAGE_REF"
info "AUTHLAB_DOCKERFILE=$AUTHLAB_DOCKERFILE"
info "AUTHLAB_LOG_TO_STDOUT=$AUTHLAB_LOG_TO_STDOUT"
info "AUTHLAB_UID=$AUTHLAB_UID"
info "AUTHLAB_GID=$AUTHLAB_GID"

CONTAINER_ID="$(
	docker compose --env-file /dev/null ps -q authlab
)"

[[ -n "$CONTAINER_ID" ]] \
	|| die "authlab container is not running
Run first:
  ./scripts/02_build_image.sh $PROFILE hardened
  ./scripts/04_run_image.sh $PROFILE hardened"

RUNNING_STATE="$(
	docker inspect \
		-f '{{.State.Running}}' \
		"$CONTAINER_ID" 2>/dev/null \
		|| true
)"

[[ "$RUNNING_STATE" == "true" ]] \
	|| die "authlab container exists but is not running"

info "Container ID: $CONTAINER_ID"

CONTAINER_IMAGE="$(
	docker inspect \
		-f '{{.Config.Image}}' \
		"$CONTAINER_ID" 2>/dev/null \
		|| true
)"

if [[ "$CONTAINER_IMAGE" != "$AUTHLAB_IMAGE_REF" ]]; then
	die "Hardened runtime check failed: running container image is '$CONTAINER_IMAGE', expected '$AUTHLAB_IMAGE_REF'
Run first:
  ./scripts/99_cleanup.sh compose
  ./scripts/02_build_image.sh $PROFILE hardened
  ./scripts/04_run_image.sh $PROFILE hardened"
fi

info "Container image check passed: $CONTAINER_IMAGE"

USER_ID="$(
	docker compose --env-file /dev/null exec -T authlab id -u \
		| tr -d ' \r\n'
)"

USER_NAME="$(
	docker compose --env-file /dev/null exec -T authlab id -un \
		| tr -d ' \r\n'
)"

if [[ "$USER_ID" == "0" ]]; then
	die "Hardened runtime check failed: container process runs as root"
fi

info "Non-root user check passed: uid=$USER_ID user=$USER_NAME"

docker compose --env-file /dev/null exec -T authlab \
	sh -c 'test -r /app/app.py' \
	|| die "Application code is not readable: /app/app.py"

docker compose --env-file /dev/null exec -T authlab \
	sh -c 'test -r /app/authlab' \
	|| die "Application package is not readable: /app/authlab"

info "Application code read check passed"

docker compose --env-file /dev/null exec -T authlab \
	sh -c 'test ! -w /app/app.py' \
	|| die "Hardened runtime check failed: /app/app.py is writable by runtime user"

docker compose --env-file /dev/null exec -T authlab \
	sh -c 'test ! -w /app/authlab' \
	|| die "Hardened runtime check failed: /app/authlab is writable by runtime user"

info "Application code non-writable check passed"

docker compose --env-file /dev/null exec -T authlab \
	sh -c 'test -d /app/data && test -w /app/data' \
	|| die "Hardened runtime check failed: /app/data is not writable"

info "Runtime data directory writable check passed: /app/data"

LOG_TO_STDOUT_VALUE="$(
	docker compose --env-file /dev/null exec -T authlab \
		sh -c 'printf "%s" "${LOG_TO_STDOUT:-}"' \
		| tr -d ' \r\n'
)"

if [[ "$LOG_TO_STDOUT_VALUE" != "true" ]]; then
	die "Hardened runtime check failed: LOG_TO_STDOUT must be true, got '${LOG_TO_STDOUT_VALUE:-<empty>}'"
fi

info "Stdout logging mode check passed: LOG_TO_STDOUT=true"

docker compose --env-file /dev/null exec -T authlab \
	sh -c 'test ! -d /app/logs || test ! -w /app/logs' \
	|| die "Hardened runtime check failed: /app/logs should not be writable in stdout logging mode"

info "Logs writable-surface check passed"

HEALTH_TRIES=45
HEALTH_SLEEP_SEC=1
HEALTH_STATUS="unknown"

for _ in $(seq 1 "$HEALTH_TRIES"); do
	HEALTH_STATUS="$(
		docker inspect \
			-f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
			"$CONTAINER_ID" 2>/dev/null \
			|| true
	)"

	if [[ "$HEALTH_STATUS" == "healthy" ]]; then
		break
	fi

	sleep "$HEALTH_SLEEP_SEC"
done

if [[ "$HEALTH_STATUS" != "healthy" ]]; then
	die "Hardened runtime check failed: Docker health status is '$HEALTH_STATUS' (expected healthy)"
fi

info "Docker healthcheck status passed: $HEALTH_STATUS"

cat > "$RUNTIME_REPORT" <<EOF
{
  "schema_version": 1,
  "stage": "hardened_runtime_verification",
  "profile": "$PROFILE",
  "variant": "$IMAGE_VARIANT",
  "image": "$AUTHLAB_IMAGE_REF",
  "dockerfile": "$AUTHLAB_DOCKERFILE",
  "env_file": "$ENV_FILE",
  "container_id": "$CONTAINER_ID",
  "checks": {
    "non_root": {
      "status": "pass",
      "uid": "$USER_ID",
      "user": "$USER_NAME"
    },
    "app_code_readable": {
      "status": "pass"
    },
    "app_code_not_writable": {
      "status": "pass"
    },
    "data_writable": {
      "status": "pass",
      "path": "/app/data"
    },
    "stdout_logging": {
      "status": "pass",
      "LOG_TO_STDOUT": "$LOG_TO_STDOUT_VALUE"
    },
    "logs_not_writable": {
      "status": "pass",
      "path": "/app/logs"
    },
    "docker_healthcheck": {
      "status": "pass",
      "docker_health_status": "$HEALTH_STATUS"
    }
  },
  "summary": {
    "overall": "pass"
  }
}
EOF

info "Hardened runtime report written: $RUNTIME_REPORT"
info "Hardened runtime verification passed"
exit 0
