#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_kubescape.sh"
source "$SCRIPT_DIR/_networkpolicy_verify.sh"

CLUSTER_NAME="secure-deploy-lab"
KIND_CONTEXT="kind-$CLUSTER_NAME"
NAMESPACE="authlab"
DEPLOYMENT_NAME="authlab"
SERVICE_NAME="authlab"
SECRET_NAME="authlab-secret"
POD_SELECTOR="app.kubernetes.io/name=authlab,app.kubernetes.io/part-of=secure-deploy-lab,app.kubernetes.io/component=web"
APP_IMAGE="authlab-deploy:hardened"
APP_CONTAINER="authlab"
INIT_CONTAINER="db-bootstrap"
APP_PORT="5000"
PEER_PORT="18080"
ROLLOUT_TIMEOUT="120s"

REPORT_DIR="$REPO_ROOT/reports"
KUBESCAPE_REPORT="$REPORT_DIR/kubescape-live.json"
WORKLOAD_REPORT="$REPORT_DIR/k8s-workload-checks.json"
KUBECTL=(kubectl --context "$KIND_CONTEXT")

WORK_DIR=""
PORT_FORWARD_PID=""
CURRENT_PHASE="preflight"

[[ "$#" -eq 0 ]] || die "This script does not accept arguments"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

cleanup() {
	set +e

	if [[ -n "$PORT_FORWARD_PID" ]]; then
		kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
		wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
	fi

	networkpolicy_cleanup

	[[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

write_report() {
	local overall="$1"
	local phase="${2:-}"
	local tmp="$WORKLOAD_REPORT.tmp"

	jq -n \
		--arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg context "$KIND_CONTEXT" \
		--arg namespace "$NAMESPACE" \
		--arg image "$APP_IMAGE" \
		--arg kubescape "reports/$(basename "$KUBESCAPE_REPORT")" \
		--arg overall "$overall" \
		--arg phase "$phase" '
		($overall == "pass") as $passed
		| {
			schema_version: 1,
			stage: "kubernetes_workload_verification",
			generated_at: $generated_at,
			context: $context,
			namespace: $namespace,
			image: $image,
			failed_phase: (if $passed then null else $phase end),
			evidence: (if $passed then {kubescape_report: $kubescape} else {} end),
			checks: (if $passed then [
				{name: "workload_runtime", status: "pass"},
				{name: "secret_contract", status: "pass"},
				{name: "kubescape_live_policy", status: "pass"},
				{name: "service_health", status: "pass"},
				{name: "networkpolicy_enforcement", status: "pass"}
			] else [{name: $phase, status: "fail"}] end),
			summary: (if $passed
				then {total: 5, passed: 5, failed: 0, skipped: 0, overall: "pass"}
				else {total: 1, passed: 0, failed: 1, skipped: 0, overall: "fail"}
			end)
		}
		| if $passed then del(.failed_phase) else . end
	' > "$tmp"

	mv "$tmp" "$WORKLOAD_REPORT"
	info "Kubernetes workload report written: $WORKLOAD_REPORT"
}

on_exit() {
	local rc=$?

	trap - EXIT
	cleanup

	if [[ "$rc" -ne 0 ]]; then
		write_report fail "$CURRENT_PHASE" || true
	fi

	exit "$rc"
}

require_http_200() {
	local port="$1" path="$2" code

	code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
		"http://127.0.0.1:$port$path")" || die "$path request failed"

	[[ "$code" == "200" ]] || die "$path returned HTTP $code (expected 200)"
}

validate_live_inventory() {
	jq -e '
		([ ["Namespace", "_cluster", "authlab"],
		   ["ServiceAccount", "authlab", "authlab"],
		   ["ConfigMap", "authlab", "authlab-config"],
		   ["NetworkPolicy", "authlab", "default-deny-all"],
		   ["Deployment", "authlab", "authlab"],
		   ["Service", "authlab", "authlab"] ]) as $required
		| ([.resources[]?.object | select(type == "object")
			| [.kind, (.metadata.namespace // "_cluster"), .metadata.name]] | unique) as $actual
		| (($required - $actual) | length) == 0
	' "$KUBESCAPE_REPORT" >/dev/null \
		|| die "Kubescape live report does not cover all 6 required project resources"
}

need_cmd jq
mkdir -p "$REPORT_DIR"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rm -f "$WORKLOAD_REPORT" "$WORKLOAD_REPORT.tmp" "$KUBESCAPE_REPORT"

for cmd in kubectl curl python3; do
	need_cmd "$cmd"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/secure-deploy-k8s-verify.XXXXXX")" \
	|| die "Failed to create verification work directory"

info "Kubernetes context: $KIND_CONTEXT"
info "Namespace: $NAMESPACE"

CURRENT_PHASE="preflight"
"${KUBECTL[@]}" get nodes >/dev/null 2>&1 \
	|| die "Kubernetes context is not reachable: $KIND_CONTEXT"

CURRENT_PHASE="workload_runtime"
"${KUBECTL[@]}" rollout status "deployment/$DEPLOYMENT_NAME" \
	--namespace "$NAMESPACE" --timeout "$ROLLOUT_TIMEOUT" \
	|| die "Deployment rollout failed or timed out: $DEPLOYMENT_NAME"

PODS_JSON="$WORK_DIR/pods.json"
SECRET_JSON="$WORK_DIR/secret.json"

"${KUBECTL[@]}" get pods --namespace "$NAMESPACE" \
	--selector "$POD_SELECTOR" --output json > "$PODS_JSON"

POD_NAME="$(jq -r \
	--arg app "$APP_CONTAINER" --arg init "$INIT_CONTAINER" --arg image "$APP_IMAGE" '
	[.items[]
	 | select(.metadata.deletionTimestamp == null)
	 | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
	 | select(any(.spec.containers[]?; .name == $app and .image == $image))
	 | select(any(.spec.initContainers[]?; .name == $init and .image == $image))
	][0].metadata.name // empty
' "$PODS_JSON")"

POD_IP="$(jq -r --arg pod "$POD_NAME" '
	.items[] | select(.metadata.name == $pod) | .status.podIP // empty
' "$PODS_JSON")"

[[ -n "$POD_NAME" && -n "$POD_IP" ]] \
	|| die "No Ready AuthLab Pod using $APP_IMAGE for app and init containers was found"

info "Workload runtime passed: Pod=$POD_NAME image=$APP_IMAGE"

CURRENT_PHASE="secret_contract"
"${KUBECTL[@]}" get secret "$SECRET_NAME" --namespace "$NAMESPACE" \
	--output json > "$SECRET_JSON"

jq -e -n \
	--arg pod "$POD_NAME" \
	--arg app "$APP_CONTAINER" \
	--arg init "$INIT_CONTAINER" \
	--arg secret "$SECRET_NAME" \
	--slurpfile pods "$PODS_JSON" \
	--slurpfile secret_json "$SECRET_JSON" '
	($secret_json[0].type == "Opaque")
	and (($secret_json[0].data | keys | sort) ==
		["ADMIN_MFA_SECRET", "ADMIN_PWHASH", "DEV_API_KEY", "SECRET_KEY"])
	and any(
		$pods[0].items[] | select(.metadata.name == $pod);
		any(
			.spec.containers[]?;
			.name == $app
			and any(.envFrom[]?; .secretRef.name == $secret)
		)
		and any(
			.spec.initContainers[]?;
			.name == $init
			and any(.envFrom[]?; .secretRef.name == $secret)
		)
	)
' >/dev/null || die "Live Secret contract is unexpected"

info "Live Secret contract passed"

CURRENT_PHASE="kubescape_live_policy"
kubescape_prepare
kubescape_scan_live_policy "$KUBESCAPE_REPORT" "$KIND_CONTEXT" "$NAMESPACE"
validate_live_inventory

info "Kubescape live policy and required inventory passed"

CURRENT_PHASE="service_health"
LOCAL_PORT="$(python3 -c \
	'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

PORT_FORWARD_LOG="$WORK_DIR/port-forward.log"

"${KUBECTL[@]}" port-forward "service/$SERVICE_NAME" \
	--namespace "$NAMESPACE" \
	"$LOCAL_PORT:$APP_PORT" > "$PORT_FORWARD_LOG" 2>&1 &

PORT_FORWARD_PID=$!
PORT_FORWARD_READY=0

for _ in {1..20}; do
	if curl -sS --max-time 1 \
		"http://127.0.0.1:$LOCAL_PORT/ready" >/dev/null 2>&1
	then
		PORT_FORWARD_READY=1
		break
	fi

	kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1 || break
	sleep 1
done

if [[ "$PORT_FORWARD_READY" -ne 1 ]]; then
	tail -n 20 "$PORT_FORWARD_LOG" >&2 2>/dev/null || true
	die "Service port-forward did not become ready"
fi

require_http_200 "$LOCAL_PORT" /health
require_http_200 "$LOCAL_PORT" /ready

info "Service health checks passed"

CURRENT_PHASE="networkpolicy_enforcement"
verify_networkpolicy_enforcement "$POD_NAME" "$POD_IP"

info "NetworkPolicy ingress and egress enforcement passed"

CURRENT_PHASE="report_generation"
write_report pass

info "Kubernetes workload verification passed"

