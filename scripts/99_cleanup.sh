#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"

# Tear down runtime environments without deleting images, reports, or project data.
#
# Usage:
#   ./scripts/99_cleanup.sh compose
#   ./scripts/99_cleanup.sh all

CLUSTER_NAME="secure-deploy-lab"

[[ "$#" -eq 1 ]] \
	|| die "Usage: ./scripts/99_cleanup.sh compose|all"

MODE="$1"

case "$MODE" in
	compose|all)
		;;
	*)
		die "Unknown cleanup mode: $MODE (use: compose|all)"
		;;
esac

cleanup_compose() {
	command -v docker >/dev/null 2>&1 \
		|| {
			printf '[ERROR] docker not found\n' >&2
			return 1
		}

	docker compose version >/dev/null 2>&1 \
		|| {
			printf '[ERROR] docker compose not available\n' >&2
			return 1
		}

	# Compose still interpolates service fields during teardown.
	export AUTHLAB_ENV_FILE="/dev/null"
	export AUTHLAB_IMAGE_REF="authlab-deploy:baseline"
	export AUTHLAB_DOCKERFILE="dockerfile.baseline"
	export AUTHLAB_LOG_TO_STDOUT="false"
	export AUTHLAB_UID="${AUTHLAB_UID:-$(id -u)}"
	export AUTHLAB_GID="${AUTHLAB_GID:-$(id -g)}"

	info "Cleaning up Compose runtime"

	docker compose --env-file /dev/null down --remove-orphans \
		|| {
			printf '[ERROR] Compose cleanup failed\n' >&2
			return 1
		}

	info "Compose cleanup complete: containers and network removed"
}

cleanup_kind() {
	local clusters

	command -v kind >/dev/null 2>&1 \
		|| {
			printf '[ERROR] kind not found\n' >&2
			return 1
		}

	clusters="$(kind get clusters 2>/dev/null)" \
		|| {
			printf '[ERROR] Failed to list kind clusters\n' >&2
			return 1
		}

	if ! grep -Fx "$CLUSTER_NAME" <<< "$clusters" >/dev/null 2>&1; then
		info "No kind cluster to remove: $CLUSTER_NAME"
		return 0
	fi

	info "Deleting kind cluster: $CLUSTER_NAME"

	kind delete cluster --name "$CLUSTER_NAME" \
		|| {
			printf '[ERROR] Failed to delete kind cluster: %s\n' "$CLUSTER_NAME" >&2
			return 1
		}

	info "kind cleanup complete: $CLUSTER_NAME removed"
}

cd "$REPO_ROOT" \
	|| die "Failed to cd into repo root: $REPO_ROOT"

case "$MODE" in
	compose)
		cleanup_compose
		;;
	all)
		rc=0

		cleanup_compose || rc=1
		cleanup_kind || rc=1

		if [[ "$rc" -ne 0 ]]; then
			die "Cleanup completed with errors"
		fi
		;;
esac

info "Cleanup mode completed: $MODE"
exit 0
