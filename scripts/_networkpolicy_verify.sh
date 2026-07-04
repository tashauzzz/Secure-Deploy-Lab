#!/usr/bin/env bash

# Requires: KUBECTL, NAMESPACE, APP_CONTAINER, APP_IMAGE, APP_PORT, PEER_PORT.

NP_NAMESPACE=""
NP_NAMESPACE_CREATED=0

networkpolicy_cleanup() {
	if [[ "$NP_NAMESPACE_CREATED" -eq 1 ]]; then
		"${KUBECTL[@]}" delete namespace "$NP_NAMESPACE" \
			--wait=false >/dev/null 2>&1 || true
	fi
}

_np_connect() {
	local pod="$1" namespace="$2" container="$3" host="$4" port="$5"
	local -a cmd=("${KUBECTL[@]}" exec "$pod" --namespace "$namespace")

	[[ -z "$container" ]] || cmd+=(--container "$container")
	cmd+=(-- python -c \
		'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 3).close()' \
		"$host" "$port")

	"${cmd[@]}" >/dev/null 2>&1
}

_np_expect_blocked() {
	local pod="$1" namespace="$2" container="$3" host="$4" port="$5"
	local -a cmd=("${KUBECTL[@]}" exec "$pod" --namespace "$namespace")

	[[ -z "$container" ]] || cmd+=(--container "$container")
	cmd+=(-- python -c \
		'import socket,sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), 3).close()
except OSError:
    sys.exit(0)
sys.exit(1)' "$host" "$port")

	"${cmd[@]}" >/dev/null 2>&1
}

verify_networkpolicy_enforcement() {
	local workload_pod="$1" workload_ip="$2"
	local server="network-server" client="network-client"
	local server_ip cross_pod_ready=0

	NP_NAMESPACE="authlab-verify-$$"

	"${KUBECTL[@]}" create namespace "$NP_NAMESPACE" >/dev/null \
		|| die "Failed to create NetworkPolicy verification namespace"

	NP_NAMESPACE_CREATED=1

	"${KUBECTL[@]}" run "$server" --namespace "$NP_NAMESPACE" \
		--image "$APP_IMAGE" --image-pull-policy Never --restart Never \
		--env PYTHONDONTWRITEBYTECODE=1 --command -- \
		python -m http.server "$PEER_PORT" --bind 0.0.0.0 >/dev/null \
		|| die "Failed to create NetworkPolicy verification server"

	"${KUBECTL[@]}" run "$client" --namespace "$NP_NAMESPACE" \
		--image "$APP_IMAGE" --image-pull-policy Never --restart Never \
		--env PYTHONDONTWRITEBYTECODE=1 --command -- \
		python -c 'import time; time.sleep(300)' >/dev/null \
		|| die "Failed to create NetworkPolicy verification client"

	"${KUBECTL[@]}" wait --namespace "$NP_NAMESPACE" \
		--for=condition=Ready "pod/$server" "pod/$client" \
		--timeout=60s >/dev/null \
		|| die "NetworkPolicy verification Pods did not become Ready"

	server_ip="$(
		"${KUBECTL[@]}" get pod "$server" \
			--namespace "$NP_NAMESPACE" \
			--output jsonpath='{.status.podIP}'
	)"

	[[ -n "$server_ip" ]] \
		|| die "Could not resolve NetworkPolicy verification server IP"

	for _ in {1..10}; do
		if _np_connect "$client" "$NP_NAMESPACE" "" "$server_ip" "$PEER_PORT"; then
			cross_pod_ready=1
			break
		fi

		sleep 1
	done

	[[ "$cross_pod_ready" -eq 1 ]] \
		|| die "Cross-Pod positive control failed: verification server did not become reachable"

	_np_expect_blocked "$client" "$NP_NAMESPACE" "" "$workload_ip" "$APP_PORT" \
		|| die "Default-deny ingress is not enforced"

	_np_expect_blocked "$workload_pod" "$NAMESPACE" "$APP_CONTAINER" \
		"$server_ip" "$PEER_PORT" \
		|| die "Default-deny egress is not enforced"
}
