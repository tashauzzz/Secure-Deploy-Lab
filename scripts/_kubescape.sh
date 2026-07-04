# shellcheck shell=bash

KUBESCAPE_VERSION_FILE="$REPO_ROOT/security/kubescape/VERSION"
KUBESCAPE_FRAMEWORK_FILE="$REPO_ROOT/security/kubescape/authlab-kubernetes-hardening.json"

KUBESCAPE_FRAMEWORK="AuthLabKubernetesHardening"
KUBESCAPE_FRAMEWORK_VERSION="1.0.0"

KUBESCAPE_CACHE_DIR="$REPO_ROOT/.cache/kubescape"

KUBESCAPE_VERSION=""

kubescape_prepare() {
	local version_output
	local actual_version

	command -v kubescape >/dev/null 2>&1 \
		|| die "kubescape not found"

	command -v jq >/dev/null 2>&1 \
		|| die "jq not found"

	[[ -s "$KUBESCAPE_VERSION_FILE" ]] \
		|| die "Kubescape version file missing or empty: $KUBESCAPE_VERSION_FILE"

	[[ -s "$KUBESCAPE_FRAMEWORK_FILE" ]] \
		|| die "Kubescape framework missing or empty: $KUBESCAPE_FRAMEWORK_FILE"

	jq empty "$KUBESCAPE_FRAMEWORK_FILE" >/dev/null 2>&1 \
		|| die "Kubescape framework is not valid JSON: $KUBESCAPE_FRAMEWORK_FILE"

	jq -e \
		--arg expected_name "$KUBESCAPE_FRAMEWORK" \
		--arg expected_version "$KUBESCAPE_FRAMEWORK_VERSION" '
		.name == $expected_name
		and .version == $expected_version
	' "$KUBESCAPE_FRAMEWORK_FILE" >/dev/null \
		|| die "Unexpected Kubescape framework identity or version: $KUBESCAPE_FRAMEWORK_FILE"

	KUBESCAPE_VERSION="$(
		tr -d '[:space:]' < "$KUBESCAPE_VERSION_FILE"
	)"

	[[ "$KUBESCAPE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| die "Invalid Kubescape version in $KUBESCAPE_VERSION_FILE: $KUBESCAPE_VERSION"

	version_output="$(kubescape version 2>&1)" \
		|| die "Failed to read Kubescape version"

	actual_version="$(
		printf '%s\n' "$version_output" \
			| grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' \
			| head -n 1 \
			| sed 's/^v//' \
			|| true
	)"

	[[ -n "$actual_version" ]] \
		|| die "Could not parse Kubescape version from:
$version_output"

	[[ "$actual_version" == "$KUBESCAPE_VERSION" ]] \
		|| die "Kubescape version mismatch: installed=$actual_version expected=$KUBESCAPE_VERSION"

	mkdir -p "$KUBESCAPE_CACHE_DIR"

	info "Kubescape version check passed: $actual_version"
	info "Kubescape framework: $KUBESCAPE_FRAMEWORK"
	info "Kubescape framework version: $KUBESCAPE_FRAMEWORK_VERSION"
	info "Kubescape framework file: $KUBESCAPE_FRAMEWORK_FILE"
}

kubescape_report_gate() {
	local report_file="$1"
	local report_name="$2"
	local summary
	local controls_total

	summary="$(
		jq \
			--slurpfile policy "$KUBESCAPE_FRAMEWORK_FILE" \
			--arg expected_name "$KUBESCAPE_FRAMEWORK" '
			(($policy[0].ControlsIDs // []) | sort) as $expected_ids
			|
			(.summaryDetails.frameworks // []) as $frameworks
			|
			($frameworks[0] // {}) as $framework
			|
			($framework.controls // {}) as $controls
			|
			($controls | keys | sort) as $actual_ids
			|
			($controls | to_entries) as $entries
			|
			{
				framework_count:
					($frameworks | length),

				framework_name:
					($framework.name // ""),

				expected_framework:
					$expected_name,

				framework_status:
					($framework.status // ""),

				controls_total:
					($entries | length),

				expected_controls_total:
					($expected_ids | length),

				missing_controls:
					($expected_ids - $actual_ids),

				unexpected_controls:
					($actual_ids - $expected_ids),

				non_passed_controls: [
					$entries[]
					| select(
						(.value.statusInfo.status // "")
						!= "passed"
					)
					| .key
				],

				irrelevant_controls: [
					$entries[]
					| select(
						(.value.statusInfo.subStatus // "")
						== "irrelevant"
					)
					| .key
				],

				controls_without_evaluated_resources: [
					$entries[]
					| select(
						(
							(.value.ResourceCounters.passedResources // 0)
							+
							(.value.ResourceCounters.failedResources // 0)
						) == 0
					)
					| .key
				],

				controls_with_incomplete_coverage: [
					$entries[]
					| select(
						(.value.ResourceCounters.skippedResources // 0) > 0
						or
						(.value.ResourceCounters.excludedResources // 0) > 0
						or
						(.value.subStatusCounters.ignoredResources // 0) > 0
					)
					| .key
				]
			}
		' "$report_file"
	)" || die "Failed to evaluate $report_name"

	if ! jq -e '
		.framework_count == 1
		and .framework_name == .expected_framework
		and .framework_status == "passed"

		and .expected_controls_total > 0
		and .controls_total == .expected_controls_total

		and (.missing_controls | length) == 0
		and (.unexpected_controls | length) == 0
		and (.non_passed_controls | length) == 0
		and (.irrelevant_controls | length) == 0

		and (
			.controls_without_evaluated_resources
			| length
		) == 0

		and (
			.controls_with_incomplete_coverage
			| length
		) == 0
	' <<< "$summary" >/dev/null
	then
		printf '[ERROR] %s policy diagnostics:\n' "$report_name" >&2
		printf '%s\n' "$summary" | jq . >&2

		die "$report_name failed Kubescape policy or coverage validation"
	fi

	controls_total="$(
		printf '%s\n' "$summary" \
			| jq -r '.controls_total'
	)"

	info "$report_name policy gate passed: $controls_total controls"
}

_kubescape_run() {
	local report_file="$1"
	local report_name="$2"
	shift 2

	local rc
	local -a scan_cmd

	mkdir -p "$(dirname "$report_file")"
	rm -f "$report_file"

	scan_cmd=(
		kubescape
		scan
		framework
		"$KUBESCAPE_FRAMEWORK"
		"$@"
		--use-from
		"$KUBESCAPE_FRAMEWORK_FILE"
		--cache-dir
		"$KUBESCAPE_CACHE_DIR"
		--format
		json
		--format-version
		v2
		--output
		"$report_file"
		--keep-local
	)

	if "${scan_cmd[@]}"; then
		rc=0
	else
		rc=$?
	fi

	[[ "$rc" -eq 0 ]] \
		|| die "$report_name scan execution failed (exit=$rc)"

	[[ -s "$report_file" ]] \
		|| die "$report_name missing or empty: $report_file"

	jq empty "$report_file" >/dev/null 2>&1 \
		|| die "$report_name is not valid JSON: $report_file"

	kubescape_report_gate "$report_file" "$report_name"

	info "$report_name written: $report_file"
}

kubescape_scan_manifests_policy() (
	local report_file="$1"
	shift

	local bundle
	local manifest

	[[ "$#" -gt 0 ]] \
		|| die "No Kubernetes manifests provided to Kubescape"

	for manifest in "$@"; do
		[[ -f "$manifest" ]] \
			|| die "Kubescape manifest not found: $manifest"

		[[ -s "$manifest" ]] \
			|| die "Kubescape manifest is empty: $manifest"
	done

	bundle="$(
		mktemp "${TMPDIR:-/tmp}/secure-deploy-kubescape.XXXXXX.yaml"
	)" || die "Failed to create temporary Kubescape manifest bundle"

	trap 'rm -f -- "$bundle"' EXIT

	: > "$bundle"

	for manifest in "$@"; do
		{
			printf '%s\n' '---'
			cat "$manifest"
			printf '\n'
		} >> "$bundle"
	done

	info "Running Kubescape static manifest policy scan"
	info "Framework: $KUBESCAPE_FRAMEWORK"
	info "Manifest count: $#"
	info "Report: $report_file"

	_kubescape_run \
		"$report_file" \
		"Kubescape manifest report" \
		"$bundle"

	info "Kubescape static manifest policy scan completed"
)

kubescape_scan_live_policy() {
	local report_file="$1"
	local kube_context="$2"
	local namespace="$3"

	[[ -n "$kube_context" ]] \
		|| die "Kubescape live scan context is empty"

	[[ -n "$namespace" ]] \
		|| die "Kubescape live scan namespace is empty"

	info "Running Kubescape live-cluster policy scan"
	info "Framework: $KUBESCAPE_FRAMEWORK"
	info "Kubernetes context: $kube_context"
	info "Included namespace: $namespace"
	info "Report: $report_file"

	_kubescape_run \
		"$report_file" \
		"Kubescape live report" \
		--kube-context "$kube_context" \
		--include-namespaces "$namespace"

	info "Kubescape live-cluster policy scan completed"
}
