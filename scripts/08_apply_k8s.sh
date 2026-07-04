#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_kubescape.sh"

CLUSTER_NAME="secure-deploy-lab"
KIND_CONTEXT="kind-$CLUSTER_NAME"

NAMESPACE="authlab"
DEPLOYMENT_NAME="authlab"

K8S_DIR="$REPO_ROOT/k8s"
REPORT_DIR="$REPO_ROOT/reports"

KUBESCAPE_MANIFEST_REPORT="$REPORT_DIR/kubescape-manifests.json"
K8S_MANIFEST_CHECKS_REPORT="$REPORT_DIR/k8s-manifest-checks.json"

NAMESPACE_MANIFEST="$K8S_DIR/namespace.yaml"
SERVICEACCOUNT_MANIFEST="$K8S_DIR/serviceaccount.yaml"
CONFIGMAP_MANIFEST="$K8S_DIR/configmap.yaml"
SECRET_MANIFEST="$K8S_DIR/secret.local.yaml"
NETWORKPOLICY_MANIFEST="$K8S_DIR/networkpolicy.yaml"
DEPLOYMENT_MANIFEST="$K8S_DIR/deployment.yaml"
SERVICE_MANIFEST="$K8S_DIR/service.yaml"

KUBESCAPE_STATIC_MANIFESTS=(
	"$NAMESPACE_MANIFEST"
	"$SERVICEACCOUNT_MANIFEST"
	"$CONFIGMAP_MANIFEST"
	"$NETWORKPOLICY_MANIFEST"
	"$DEPLOYMENT_MANIFEST"
	"$SERVICE_MANIFEST"
)

CURRENT_PHASE="preflight"

[[ "$#" -eq 0 ]] || die "This script does not accept arguments"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

require_manifest() {
	local file="$1"

	[[ -f "$file" ]] || die "Kubernetes manifest not found: $file"
	[[ -s "$file" ]] || die "Kubernetes manifest is empty: $file"
}

validate_kubescape_static_inventory() {
	local report_file="$1"
	local inventory

	inventory="$(
		jq '
			([
				{
					kind: "Namespace",
					namespace: "_cluster",
					name: "authlab"
				},
				{
					kind: "ServiceAccount",
					namespace: "authlab",
					name: "authlab"
				},
				{
					kind: "ConfigMap",
					namespace: "authlab",
					name: "authlab-config"
				},
				{
					kind: "NetworkPolicy",
					namespace: "authlab",
					name: "default-deny-all"
				},
				{
					kind: "Deployment",
					namespace: "authlab",
					name: "authlab"
				},
				{
					kind: "Service",
					namespace: "authlab",
					name: "authlab"
				}
			] | sort_by([.kind, .namespace, .name])) as $expected
			|
			([
				.resources[]?.object
				| select(type == "object")
				| {
					kind: (.kind // ""),
					namespace: (
						if ((.metadata.namespace // "") == "")
						then "_cluster"
						else .metadata.namespace
						end
					),
					name: (.metadata.name // "")
				}
			] | unique_by([.kind, .namespace, .name])
			  | sort_by([.kind, .namespace, .name])) as $actual
			|
			{
				expected_count: ($expected | length),
				actual_count: ($actual | length),
				missing_resources: ($expected - $actual),
				unexpected_resources: ($actual - $expected)
			}
		' "$report_file"
	)" || die "Failed to evaluate Kubescape static resource inventory"

	if ! jq -e '
		.expected_count == 6
		and .actual_count == 6
		and (.missing_resources | length) == 0
		and (.unexpected_resources | length) == 0
	' <<< "$inventory" >/dev/null
	then
		printf '[ERROR] Kubescape static resource inventory diagnostics:\n' >&2
		printf '%s\n' "$inventory" | jq . >&2

		die "Kubescape static report does not contain exactly the six expected resources"
	fi

	info "Kubescape static resource inventory passed: 6/6 resources"
}

write_k8s_manifest_checks_report() {
	local generated_at
	local controls_total
	local report_tmp

	generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	controls_total="$(
		jq -r '
			.summaryDetails.frameworks[0].controls
			| length
		' "$KUBESCAPE_MANIFEST_REPORT"
	)"

	[[ "$controls_total" =~ ^[0-9]+$ ]] \
		|| die "Could not determine Kubescape control count from: $KUBESCAPE_MANIFEST_REPORT"

	report_tmp="$K8S_MANIFEST_CHECKS_REPORT.tmp"

	jq -n \
		--arg generated_at "$generated_at" \
		--arg framework "$KUBESCAPE_FRAMEWORK" \
		--arg framework_version "$KUBESCAPE_FRAMEWORK_VERSION" \
		--arg kubescape_report "reports/$(basename "$KUBESCAPE_MANIFEST_REPORT")" \
		--argjson controls_total "$controls_total" '
		{
			schema_version: 1,
			stage: "kubernetes_manifest_deployment",
			generated_at: $generated_at,

			framework: {
				name: $framework,
				version: $framework_version
			},

			evidence: {
				kubescape_report: $kubescape_report
			},

			metrics: {
				controls_total: $controls_total,
				required_policy_resources: 6,
				evaluated_policy_resources: 6,
				required_manifests: 7,
				applied_manifests: 7
			},

			checks: [
				{
					name: "kubescape_static_policy",
					status: "pass",
					observed: "\($controls_total)/\($controls_total) controls passed"
				},
				{
					name: "kubescape_static_inventory",
					status: "pass",
					observed: "6/6 policy resources present"
				},
				{
					name: "kubernetes_manifest_apply",
					status: "pass",
					observed: "7/7 required manifests applied"
				}
			],

			summary: {
				total: 3,
				passed: 3,
				failed: 0,
				skipped: 0,
				overall: "pass"
			}
		}
	' > "$report_tmp" \
		|| die "Failed to create Kubernetes manifest deployment report"

	mv "$report_tmp" "$K8S_MANIFEST_CHECKS_REPORT" \
		|| die "Failed to finalize Kubernetes manifest deployment report"

	info "Kubernetes manifest deployment report written: $K8S_MANIFEST_CHECKS_REPORT"
}

write_k8s_manifest_failure_report() {
	local phase="$1"
	local report_tmp="$K8S_MANIFEST_CHECKS_REPORT.tmp"

	jq -n \
		--arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg phase "$phase" '
		{
			schema_version: 1,
			stage: "kubernetes_manifest_deployment",
			generated_at: $generated_at,
			failed_phase: $phase,
			checks: [
				{
					name: $phase,
					status: "fail"
				}
			],
			summary: {
				total: 1,
				passed: 0,
				failed: 1,
				skipped: 0,
				overall: "fail"
			}
		}
	' > "$report_tmp" || return 1

	mv "$report_tmp" "$K8S_MANIFEST_CHECKS_REPORT" || return 1

	info "Kubernetes manifest deployment failure report written: $K8S_MANIFEST_CHECKS_REPORT"
}

on_exit() {
	local rc=$?

	trap - EXIT

	if [[ "$rc" -ne 0 ]]; then
		rm -f "$K8S_MANIFEST_CHECKS_REPORT.tmp"
		write_k8s_manifest_failure_report "$CURRENT_PHASE" || true
	fi

	exit "$rc"
}

apply_manifest() {
	local resource_name="$1"
	local file="$2"

	info "Applying $resource_name manifest: $file"

	kubectl --context "$KIND_CONTEXT" apply -f "$file" \
		|| die "Failed to apply $resource_name manifest: $file"
}

info "Repo root: $REPO_ROOT"
info "kind cluster: $CLUSTER_NAME"
info "Kubernetes context: $KIND_CONTEXT"
info "Namespace: $NAMESPACE"

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

need_cmd kubectl
need_cmd jq

mkdir -p "$REPORT_DIR"

rm -f \
	"$K8S_MANIFEST_CHECKS_REPORT" \
	"$K8S_MANIFEST_CHECKS_REPORT.tmp" \
	"$KUBESCAPE_MANIFEST_REPORT"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kubectl --context "$KIND_CONTEXT" get nodes >/dev/null 2>&1 \
	|| die "kind cluster is not reachable through kubectl context: $KIND_CONTEXT
Run first:
./scripts/07_prepare_kind.sh"

require_manifest "$NAMESPACE_MANIFEST"
require_manifest "$SERVICEACCOUNT_MANIFEST"
require_manifest "$CONFIGMAP_MANIFEST"
require_manifest "$SECRET_MANIFEST"
require_manifest "$NETWORKPOLICY_MANIFEST"
require_manifest "$DEPLOYMENT_MANIFEST"
require_manifest "$SERVICE_MANIFEST"

CURRENT_PHASE="kubescape_static_policy"
kubescape_prepare
kubescape_scan_manifests_policy \
	"$KUBESCAPE_MANIFEST_REPORT" \
	"${KUBESCAPE_STATIC_MANIFESTS[@]}"

CURRENT_PHASE="kubescape_static_inventory"
validate_kubescape_static_inventory "$KUBESCAPE_MANIFEST_REPORT"

CURRENT_PHASE="kubernetes_manifest_apply"
DEPLOYMENT_EXISTED=0

if kubectl --context "$KIND_CONTEXT" get deployment "$DEPLOYMENT_NAME" \
	--namespace "$NAMESPACE" >/dev/null 2>&1
then
	DEPLOYMENT_EXISTED=1
fi

apply_manifest "Namespace" "$NAMESPACE_MANIFEST"
apply_manifest "ServiceAccount" "$SERVICEACCOUNT_MANIFEST"
apply_manifest "ConfigMap" "$CONFIGMAP_MANIFEST"
apply_manifest "generated Secret" "$SECRET_MANIFEST"
apply_manifest "NetworkPolicy" "$NETWORKPOLICY_MANIFEST"
apply_manifest "Deployment" "$DEPLOYMENT_MANIFEST"
apply_manifest "Service" "$SERVICE_MANIFEST"

if [[ "$DEPLOYMENT_EXISTED" -eq 1 ]]; then
	info "Restarting existing Deployment to use the current image and configuration"

	kubectl --context "$KIND_CONTEXT" rollout restart \
		"deployment/$DEPLOYMENT_NAME" \
		--namespace "$NAMESPACE" \
		|| die "Failed to restart Deployment: $DEPLOYMENT_NAME"
fi

CURRENT_PHASE="report_generation"
write_k8s_manifest_checks_report
info "Kubernetes manifests applied successfully"
exit 0