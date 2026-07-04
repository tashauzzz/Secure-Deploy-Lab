# shellcheck shell=bash

AUTHLAB_PROFILE=""
AUTHLAB_ENV_TEMPLATE=""
AUTHLAB_ENV_FILE=""
AUTHLAB_STATE_DIR=""
AUTHLAB_READY_FILE=""
AUTHLAB_DEV_API_KEY_PREFIX=""

set_env_profile() {
	[[ "$#" -eq 1 ]] \
		|| die "set_env_profile requires exactly one profile"

	local profile="$1"

	AUTHLAB_STATE_DIR="$REPO_ROOT/.state"

	case "$profile" in
		local)
			AUTHLAB_PROFILE="local"
			AUTHLAB_ENV_TEMPLATE="$REPO_ROOT/.env.example"
			AUTHLAB_ENV_FILE="$REPO_ROOT/.env"
			AUTHLAB_READY_FILE="$AUTHLAB_STATE_DIR/db-ready.local"
			AUTHLAB_DEV_API_KEY_PREFIX="dev-local"
			;;
		validation)
			AUTHLAB_PROFILE="validation"
			AUTHLAB_ENV_TEMPLATE="$REPO_ROOT/.env.validation.example"
			AUTHLAB_ENV_FILE="$REPO_ROOT/.env.validation"
			AUTHLAB_READY_FILE="$AUTHLAB_STATE_DIR/db-ready.validation"
			AUTHLAB_DEV_API_KEY_PREFIX="dev-validation"
			;;
		*)
			die "Unsupported env profile: $profile (use: local|validation)"
			;;
	esac
}
