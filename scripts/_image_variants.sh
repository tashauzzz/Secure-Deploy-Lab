# shellcheck shell=bash

IMAGE_VARIANT=""
AUTHLAB_IMAGE_REF=""
AUTHLAB_DOCKERFILE=""
TRIVY_REPORT_FILE=""

parse_image_variant() {
	local seen=0

	IMAGE_VARIANT=""
	AUTHLAB_IMAGE_REF=""
	AUTHLAB_DOCKERFILE=""
	TRIVY_REPORT_FILE=""

	for arg in "$@"; do
		case "$arg" in
			baseline|hardened)
				if [[ "$seen" -eq 1 && "$IMAGE_VARIANT" != "$arg" ]]; then
					die "Conflicting variants: '$IMAGE_VARIANT' and '$arg' (use only one: baseline|hardened)"
				fi

				IMAGE_VARIANT="$arg"
				seen=1
				;;
			*)
				die "Unknown arg: $arg (use: baseline|hardened)"
				;;
		esac
	done

	[[ -n "$IMAGE_VARIANT" ]] \
		|| die "Missing image variant (use: baseline|hardened)"

	case "$IMAGE_VARIANT" in
		baseline)
			AUTHLAB_IMAGE_REF="authlab-deploy:baseline"
			AUTHLAB_DOCKERFILE="dockerfile.baseline"
			TRIVY_REPORT_FILE="$REPO_ROOT/reports/trivy-baseline.json"
			;;
		hardened)
			AUTHLAB_IMAGE_REF="authlab-deploy:hardened"
			AUTHLAB_DOCKERFILE="dockerfile.hardened"
			TRIVY_REPORT_FILE="$REPO_ROOT/reports/trivy-hardened.json"
			;;
	esac
}

export_compose_image_env() {
	local env_file="${1:-.env}"

	export AUTHLAB_ENV_FILE="$env_file"
	export AUTHLAB_IMAGE_REF
	export AUTHLAB_DOCKERFILE

	case "$IMAGE_VARIANT" in
		baseline)
			AUTHLAB_LOG_TO_STDOUT="false"
			;;
		hardened)
			AUTHLAB_LOG_TO_STDOUT="true"
			;;
		*)
			die "Unsupported image variant for compose env: $IMAGE_VARIANT"
			;;
	esac

	AUTHLAB_UID="${AUTHLAB_UID:-$(id -u)}"
	AUTHLAB_GID="${AUTHLAB_GID:-$(id -g)}"

	export AUTHLAB_LOG_TO_STDOUT
	export AUTHLAB_UID
	export AUTHLAB_GID
}