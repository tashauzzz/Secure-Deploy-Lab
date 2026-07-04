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
VARIANT_ARGS=()

for arg in "$@"; do
	case "$arg" in
		local|validation)
			if [[ "$SEEN_PROFILE" -eq 1 && "$PROFILE" != "$arg" ]]; then
				die "Conflicting profiles: '$PROFILE' and '$arg' (use only one: local|validation)"
			fi
			PROFILE="$arg"
			SEEN_PROFILE=1
			;;
		baseline|hardened)
			VARIANT_ARGS+=("$arg")
			;;
		*)
			die "Unknown arg: $arg (use: [local|validation] baseline|hardened)"
			;;
	esac
done

set_env_profile "$PROFILE"
parse_image_variant "${VARIANT_ARGS[@]}"

ENV_FILE="$AUTHLAB_ENV_FILE"
READY_FILE="$AUTHLAB_READY_FILE"

REPORT_DIR="$REPO_ROOT/reports"
RUN_REPORT="$REPORT_DIR/run-${IMAGE_VARIANT}.json"

mkdir -p "$REPORT_DIR"
rm -f "$RUN_REPORT"

need_cmd docker
docker compose version >/dev/null 2>&1 || die "docker compose not available"
need_cmd curl

[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE
Run setup first:
  ./scripts/00_env_bootstrap.sh $PROFILE
  ./scripts/01_app_db_bootstrap.sh $PROFILE"

[[ -f "$AUTHLAB_DOCKERFILE" ]] || die "Dockerfile not found: $AUTHLAB_DOCKERFILE"

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

export_compose_image_env "$ENV_FILE"

info "Profile: $PROFILE"
info "Image variant: $IMAGE_VARIANT"
info "AUTHLAB_ENV_FILE=$AUTHLAB_ENV_FILE"
info "AUTHLAB_IMAGE_REF=$AUTHLAB_IMAGE_REF"
info "AUTHLAB_DOCKERFILE=$AUTHLAB_DOCKERFILE"
info "AUTHLAB_LOG_TO_STDOUT=$AUTHLAB_LOG_TO_STDOUT"
info "AUTHLAB_UID=$AUTHLAB_UID"
info "AUTHLAB_GID=$AUTHLAB_GID"

[[ -f "$READY_FILE" ]] || die "Missing DB ready marker: $READY_FILE
Run setup first:
  ./scripts/00_env_bootstrap.sh $PROFILE
  ./scripts/01_app_db_bootstrap.sh $PROFILE"

grep -qx "PROFILE=$PROFILE" "$READY_FILE" || die "DB ready marker does not match profile '$PROFILE': $READY_FILE
Run:
  ./scripts/01_app_db_bootstrap.sh $PROFILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ -n "${DB_PATH:-}" ]] || die "DB_PATH is empty or missing in: $ENV_FILE"

DB_FILE="$DB_PATH"
if [[ "$DB_FILE" != /* ]]; then
	DB_FILE="$REPO_ROOT/$DB_FILE"
fi

[[ -s "$DB_FILE" ]] || die "Database file missing or empty: $DB_FILE
Run setup first:
  ./scripts/00_env_bootstrap.sh $PROFILE
  ./scripts/01_app_db_bootstrap.sh $PROFILE"

info "DB ready marker found: $READY_FILE"
info "Database file: $DB_FILE"

docker image inspect "$AUTHLAB_IMAGE_REF" >/dev/null 2>&1 || die \
  "Required image not found locally: $AUTHLAB_IMAGE_REF
Run build first:
  ./scripts/02_build_image.sh $PROFILE $IMAGE_VARIANT"

info "Starting service from existing image"
docker compose --env-file /dev/null up -d --no-build authlab || die "docker compose up failed"

CONTAINER_ID="$(docker compose --env-file /dev/null ps -q authlab)"
[[ -n "$CONTAINER_ID" ]] || die "Container started but container id was not found"
info "Container ID: $CONTAINER_ID"

URL_HEALTH="http://127.0.0.1:5000/health"
URL_READY="http://127.0.0.1:5000/ready"
URL_WEB="http://127.0.0.1:5000/login"
URL_API="http://127.0.0.1:5000/api/v1/auth/session"

TRIES=60
SLEEP_SEC=0.25

HEALTH_CODE="000"
READY_CODE="000"
WEB_CODE="000"
API_CODE="000"

for _ in $(seq 1 "$TRIES"); do
	HEALTH_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "$URL_HEALTH" 2>/dev/null || true)"
	READY_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "$URL_READY" 2>/dev/null || true)"
  WEB_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "$URL_WEB" 2>/dev/null || true)"
	API_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "$URL_API" 2>/dev/null || true)"

	if [[ "$HEALTH_CODE" == "200" && "$READY_CODE" == "200" && "$WEB_CODE" == "200" && ( "$API_CODE" == "401" || "$API_CODE" == "409" ) ]]; then
		info "Ready:"
		info "  HEALTH: $URL_HEALTH (http=$HEALTH_CODE)"
    info "  READY: $URL_READY (http=$READY_CODE)"
		info "  WEB: $URL_WEB (http=$WEB_CODE)"
		info "  API: $URL_API (http=$API_CODE)"

		cat > "$RUN_REPORT" <<EOF
{
  "profile": "$PROFILE",
  "variant": "$IMAGE_VARIANT",
  "image": "$AUTHLAB_IMAGE_REF",
  "dockerfile": "$AUTHLAB_DOCKERFILE",
  "env_file": "$ENV_FILE",
  "ready_file": "$READY_FILE",
  "container_id": "$CONTAINER_ID",
  "db_file": "$DB_FILE",
  "runtime": {
    "log_to_stdout": "$AUTHLAB_LOG_TO_STDOUT",
    "uid": "$AUTHLAB_UID",
    "gid": "$AUTHLAB_GID"
  },
  "checks": {
    "health": {
      "url": "$URL_HEALTH",
      "http": "$HEALTH_CODE",
      "expected": "200",
      "status": "pass"
    },
    "ready": {
      "url": "$URL_READY",
      "http": "$READY_CODE",
      "expected": "200",
      "status": "pass"
    },
    "web_login": {
      "url": "$URL_WEB",
      "http": "$WEB_CODE",
      "expected": "200",
      "status": "pass"
    },
    "api_session": {
      "url": "$URL_API",
      "http": "$API_CODE",
      "expected": "401 or 409",
      "status": "pass"
    }
  },
  "status": "pass"
}
EOF

		info "Runtime smoke report written: $RUN_REPORT"
		exit 0
	fi

	sleep "$SLEEP_SEC"
done

die "Not ready after ${TRIES} tries:
  HEALTH: $URL_HEALTH (last_http=$HEALTH_CODE, expected 200)
  READY: $URL_READY (last_http=$READY_CODE, expected 200)
  WEB: $URL_WEB (last_http=$WEB_CODE, expected 200)
  API: $URL_API (last_http=$API_CODE, expected 401 or 409)

Verify setup order:
  ./scripts/00_env_bootstrap.sh $PROFILE
  ./scripts/01_app_db_bootstrap.sh $PROFILE
  ./scripts/02_build_image.sh $PROFILE $IMAGE_VARIANT

Check logs:
  docker compose logs --tail=200 authlab"