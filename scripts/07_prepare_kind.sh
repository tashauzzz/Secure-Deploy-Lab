#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"

CLUSTER_NAME="secure-deploy-lab"
KIND_CONTEXT="kind-$CLUSTER_NAME"
K8S_IMAGE_REF="authlab-deploy:hardened"
KIND_VERSION_FILE="$REPO_ROOT/security/kind/VERSION"
KUBECTL_VERSION_FILE="$REPO_ROOT/security/kubectl/VERSION"
RECREATE=0

for arg in "$@"; do
case "$arg" in
--recreate)
RECREATE=1
;;
*)
die "Unknown arg: $arg (use: [--recreate])"
;;
esac
done

need_cmd() {
command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

read_pinned_version() {
	local file="$1"
	local tool="$2"
	local version

	[[ -s "$file" ]] || die "$tool version file missing or empty: $file"

	version="$(tr -d '[:space:]' < "$file")"

	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "Invalid $tool version in $file: $version"

	printf '%s' "$version"
}

verify_tool_versions() {
	local expected_kind
	local expected_kubectl
	local actual_kind
	local actual_kubectl
	local kind_output
	local kubectl_output

	expected_kind="$(read_pinned_version "$KIND_VERSION_FILE" kind)"
	expected_kubectl="$(read_pinned_version "$KUBECTL_VERSION_FILE" kubectl)"

	kind_output="$(kind version 2>&1)" \
		|| die "Failed to read kind version"

	actual_kind="$(
		awk 'NR == 1 { print $2; exit }' <<< "$kind_output"
	)"
	actual_kind="${actual_kind#v}"

	[[ -n "$actual_kind" ]] \
		|| die "Could not parse kind version from: $kind_output"

	[[ "$actual_kind" == "$expected_kind" ]] \
		|| die "Unsupported kind version: expected $expected_kind, got $actual_kind"

	info "kind version check passed: $actual_kind"

	kubectl_output="$(kubectl version --client --output=yaml 2>&1)" \
		|| die "Failed to read kubectl client version"

	actual_kubectl="$(
		awk '$1 == "gitVersion:" { print $2; exit }' <<< "$kubectl_output"
	)"
	actual_kubectl="${actual_kubectl#v}"

	[[ -n "$actual_kubectl" ]] \
		|| die "Could not parse kubectl version"

	[[ "$actual_kubectl" == "$expected_kubectl" ]] \
		|| die "Unsupported kubectl version: expected $expected_kubectl, got $actual_kubectl"

	info "kubectl version check passed: $actual_kubectl"
}

cluster_exists() {
kind get clusters 2>/dev/null | grep -Fx "$CLUSTER_NAME" >/dev/null 2>&1
}

ensure_tools() {
	need_cmd awk
	need_cmd docker
	need_cmd kind
	need_cmd kubectl
	need_cmd tr

	docker info >/dev/null 2>&1 \
		|| die "Docker daemon is not available"

	verify_tool_versions
}

require_local_image() {
	docker image inspect "$K8S_IMAGE_REF" >/dev/null 2>&1 \
		|| die "Missing local Docker image: $K8S_IMAGE_REF
Build the hardened image first:
./scripts/02_build_image.sh local hardened
or:
./scripts/02_build_image.sh validation hardened"
}
ensure_kind_cluster() {
if [[ "$RECREATE" -eq 1 ]]; then
if cluster_exists; then
info "Deleting existing kind cluster: $CLUSTER_NAME"
kind delete cluster --name "$CLUSTER_NAME" || die "Failed to delete kind cluster: $CLUSTER_NAME"
else
info "No existing kind cluster to recreate: $CLUSTER_NAME"
fi
fi

if cluster_exists; then
info "Using existing kind cluster: $CLUSTER_NAME"
else
info "Creating kind cluster: $CLUSTER_NAME"
kind create cluster --name "$CLUSTER_NAME" || die "Failed to create kind cluster: $CLUSTER_NAME"
fi

kubectl --context "$KIND_CONTEXT" get nodes >/dev/null 2>&1 \
	|| die "kind cluster is not reachable through kubectl context: $KIND_CONTEXT"

kubectl --context "$KIND_CONTEXT" wait \
	--for=condition=Ready \
	nodes \
	--all \
	--timeout=120s >/dev/null \
	|| die "kind cluster nodes did not become Ready: $KIND_CONTEXT"

info "kubectl context available: $KIND_CONTEXT"
info "kind cluster nodes are Ready"
}

load_image_into_kind() {
info "Loading image into kind cluster: $K8S_IMAGE_REF"
kind load docker-image "$K8S_IMAGE_REF" --name "$CLUSTER_NAME" \
  || die "Failed to load image into kind cluster: $K8S_IMAGE_REF"
}

verify_image_loaded() {
	local image_repo
	local image_tag
	local node
	local nodes_output
	local -a nodes=()

	image_repo="${K8S_IMAGE_REF%:*}"
	image_tag="${K8S_IMAGE_REF##*:}"

	nodes_output="$(kind get nodes --name "$CLUSTER_NAME")" \
		|| die "Failed to list kind nodes for cluster: $CLUSTER_NAME"

	mapfile -t nodes <<< "$nodes_output"

	[[ "${#nodes[@]}" -gt 0 ]] \
		|| die "No kind nodes found for cluster: $CLUSTER_NAME"

	for node in "${nodes[@]}"; do
		[[ -n "$node" ]] || continue

		if docker exec "$node" crictl images 2>/dev/null |
			awk -v repo="$image_repo" -v tag="$image_tag" '
				NR > 1 &&
				($1 == repo || $1 ~ "/" repo "$") &&
				$2 == tag {
					found=1
				}
				END {
					exit found ? 0 : 1
				}
			'
		then
			info "Verified image in kind node '$node': $K8S_IMAGE_REF"
		else
			die "Image was loaded but could not be verified in kind node '$node': $K8S_IMAGE_REF"
		fi
	done
}

info "Repo root: $REPO_ROOT"
info "kind cluster: $CLUSTER_NAME"
info "Kubernetes context: $KIND_CONTEXT"
info "Kubernetes image: $K8S_IMAGE_REF"

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

ensure_tools
require_local_image
ensure_kind_cluster
load_image_into_kind
verify_image_loaded

info "kind preparation complete"
exit 0
