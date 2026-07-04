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

need_cmd docker
docker compose version >/dev/null 2>&1 || die "docker compose not available"

[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE (run ./scripts/00_env_bootstrap.sh $PROFILE first)"

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

[[ -f "$AUTHLAB_DOCKERFILE" ]] || die "Dockerfile not found: $AUTHLAB_DOCKERFILE"

export_compose_image_env "$ENV_FILE"

info "Profile: $PROFILE"
info "Image variant: $IMAGE_VARIANT"
info "AUTHLAB_ENV_FILE=$AUTHLAB_ENV_FILE"
info "AUTHLAB_IMAGE_REF=$AUTHLAB_IMAGE_REF"
info "AUTHLAB_DOCKERFILE=$AUTHLAB_DOCKERFILE"
info "AUTHLAB_LOG_TO_STDOUT=$AUTHLAB_LOG_TO_STDOUT"
info "AUTHLAB_UID=$AUTHLAB_UID"
info "AUTHLAB_GID=$AUTHLAB_GID"

info "Building image: $AUTHLAB_IMAGE_REF"
docker compose --env-file /dev/null build authlab || die "docker compose build failed"

if docker image inspect "$AUTHLAB_IMAGE_REF" >/dev/null 2>&1; then
	info "Image ready: $AUTHLAB_IMAGE_REF"
else
	die "Build completed but target image not found locally: $AUTHLAB_IMAGE_REF"
fi

exit 0