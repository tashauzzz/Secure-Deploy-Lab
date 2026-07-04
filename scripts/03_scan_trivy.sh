#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"
source "$SCRIPT_DIR/_image_variants.sh"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

parse_image_variant "$@"

REPORT_DIR="$REPO_ROOT/reports"
REPORT_FILE_HOST="$TRIVY_REPORT_FILE"
REPORT_FILE_CONT="/work/reports/$(basename "$REPORT_FILE_HOST")"
CHECKS_FILE="$REPORT_DIR/trivy-${IMAGE_VARIANT}-checks.json"
CHECKS_TMP="${CHECKS_FILE}.tmp"

TRIVY_VERSION_FILE="$REPO_ROOT/security/trivy/VERSION"
CACHE_HOST="$REPO_ROOT/.cache/trivy"
CACHE_CONT="/cache/trivy"

# Project policy: scan the complete deployable image.
TRIVY_IMAGE_PKG_TYPES="os,library"
TRIVY_EOL_EXIT_CODE=30

cleanup_tmp() {
	rm -f "$CHECKS_TMP"
}

trap cleanup_tmp EXIT

need_cmd docker
need_cmd jq

cd "$REPO_ROOT" || die "Failed to cd into repo root: $REPO_ROOT"

mkdir -p "$REPORT_DIR" "$CACHE_HOST"
rm -f "$REPORT_FILE_HOST" "$CHECKS_FILE" "$CHECKS_TMP"

[[ -s "$TRIVY_VERSION_FILE" ]] \
	|| die "Trivy version file missing or empty: $TRIVY_VERSION_FILE"

TRIVY_VERSION="$(tr -d ' \t\r\n' < "$TRIVY_VERSION_FILE")"
[[ -n "$TRIVY_VERSION" ]] \
	|| die "Trivy version is empty in: $TRIVY_VERSION_FILE"

TRIVY_IMG="ghcr.io/aquasecurity/trivy:${TRIVY_VERSION}"

info "Running Trivy image scan"
info "Image variant: $IMAGE_VARIANT"
info "Target image: $AUTHLAB_IMAGE_REF"
info "Package scope: $TRIVY_IMAGE_PKG_TYPES"
info "Trivy runner image: $TRIVY_IMG"
info "Raw report: $REPORT_FILE_HOST"
info "Checks report: $CHECKS_FILE"

if ! docker image inspect "$AUTHLAB_IMAGE_REF" >/dev/null 2>&1; then
	die "Target image not found locally: $AUTHLAB_IMAGE_REF
Build it first:
  ./scripts/02_build_image.sh $IMAGE_VARIANT
or for validation flow:
  ./scripts/02_build_image.sh validation $IMAGE_VARIANT"
fi

TRIVY_VER_OUT="$(docker run --rm "$TRIVY_IMG" --version 2>/dev/null || true)"
[[ -n "$TRIVY_VER_OUT" ]] && info "$TRIVY_VER_OUT"

run_trivy_image() {
	docker run --rm \
		-v "$REPO_ROOT:/work" -w /work \
		-v "$CACHE_HOST:$CACHE_CONT" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		"$TRIVY_IMG" \
		--cache-dir "$CACHE_CONT" \
		image \
		--scanners vuln \
		--pkg-types "$TRIVY_IMAGE_PKG_TYPES" \
		--no-progress \
		"$@"
}

info "Generating full Trivy JSON report"

if ! run_trivy_image \
	--format json \
	--output "$REPORT_FILE_CONT" \
	--exit-code 0 \
	"$AUTHLAB_IMAGE_REF"
then
	rm -f "$REPORT_FILE_HOST"

	die "Trivy image scan failed for variant '$IMAGE_VARIANT'.
Check Docker socket access, image name, cache mount, and network."
fi

[[ -s "$REPORT_FILE_HOST" ]] \
	|| die "Trivy report missing or empty: $REPORT_FILE_HOST"

jq empty "$REPORT_FILE_HOST" >/dev/null 2>&1 \
	|| {
		rm -f "$REPORT_FILE_HOST"
		die "Trivy report is not valid JSON: $REPORT_FILE_HOST"
	}

jq -e '
	(.Results | type == "array")
	and (.Results | length > 0)
' "$REPORT_FILE_HOST" >/dev/null \
	|| {
		rm -f "$REPORT_FILE_HOST"
		die "Trivy report contains no evaluated result targets: $REPORT_FILE_HOST"
	}

info "Report size: $(wc -c < "$REPORT_FILE_HOST") bytes"

METRICS_JSON="$(
	jq '
		. as $report
		| reduce ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"][] as $severity
			({};
				[
					$report.Results[]?
					| (.Vulnerabilities // [])[]
					| select(.Severity == $severity)
				] as $all
				| ($all | map(select((.FixedVersion // "") != ""))) as $fixable
				| . + {
					($severity | ascii_downcase): {
						total: ($all | length),
						fixable: ($fixable | length),
						unfixed: (($all | length) - ($fixable | length))
					}
				}
			)
	' "$REPORT_FILE_HOST"
)" || die "Failed to summarize Trivy report: $REPORT_FILE_HOST"

FIXABLE_CRITICAL="$(jq -r '.critical.fixable' <<< "$METRICS_JSON")"
FIXABLE_HIGH="$(jq -r '.high.fixable' <<< "$METRICS_JSON")"

info "Running Trivy EOL check"

if run_trivy_image \
	--exit-code 0 \
	--exit-on-eol "$TRIVY_EOL_EXIT_CODE" \
	"$AUTHLAB_IMAGE_REF" >/dev/null
then
	EOL_STATUS="pass"
else
	EOL_RC=$?

	if [[ "$EOL_RC" -eq "$TRIVY_EOL_EXIT_CODE" ]]; then
		EOL_STATUS="fail"
	else
		die "Trivy EOL check failed unexpectedly for variant '$IMAGE_VARIANT' (exit=$EOL_RC)"
	fi
fi

[[ "$FIXABLE_CRITICAL" -eq 0 ]] \
	&& CRITICAL_STATUS="pass" \
	|| CRITICAL_STATUS="fail"

[[ "$FIXABLE_HIGH" -eq 0 ]] \
	&& HIGH_STATUS="pass" \
	|| HIGH_STATUS="fail"

if [[ "$IMAGE_VARIANT" == "hardened" ]]; then
	POLICY_MODE="enforced"
	POLICY_ENFORCED=true
else
	POLICY_MODE="evidence_only"
	POLICY_ENFORCED=false
fi

OVERALL_STATUS="pass"

if [[ "$POLICY_ENFORCED" == true ]] \
	&& { [[ "$EOL_STATUS" == "fail" ]] \
		|| [[ "$CRITICAL_STATUS" == "fail" ]] \
		|| [[ "$HIGH_STATUS" == "fail" ]]; }
then
	OVERALL_STATUS="fail"
fi

jq -n \
	--arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg variant "$IMAGE_VARIANT" \
	--arg image_ref "$AUTHLAB_IMAGE_REF" \
	--arg trivy_version "$TRIVY_VERSION" \
	--arg package_scope "$TRIVY_IMAGE_PKG_TYPES" \
	--arg policy_mode "$POLICY_MODE" \
	--arg raw_report "reports/$(basename "$REPORT_FILE_HOST")" \
	--arg eol_status "$EOL_STATUS" \
	--arg critical_status "$CRITICAL_STATUS" \
	--arg high_status "$HIGH_STATUS" \
	--arg overall "$OVERALL_STATUS" \
	--argjson enforced "$POLICY_ENFORCED" \
	--argjson metrics "$METRICS_JSON" '
	{
		schema_version: 1,
		stage: "image_vulnerability_scan",
		generated_at: $generated_at,
		variant: $variant,
		image_ref: $image_ref,
		trivy_version: $trivy_version,
		package_scope: $package_scope,
		policy_mode: $policy_mode,
		evidence: {
			raw_report: $raw_report
		},
		metrics: $metrics,
		checks: {
			base_image_not_eol: {
				status: $eol_status,
				enforced: $enforced
			},
			fixable_critical: {
				status: $critical_status,
				enforced: $enforced,
				threshold: 0,
				observed: $metrics.critical.fixable
			},
			fixable_high: {
				status: $high_status,
				enforced: $enforced,
				threshold: 0,
				observed: $metrics.high.fixable
			}
		},
		summary: {
			overall: $overall
		}
	}
' > "$CHECKS_TMP" \
	|| die "Failed to create Trivy checks report: $CHECKS_FILE"

mv "$CHECKS_TMP" "$CHECKS_FILE" \
	|| die "Failed to finalize Trivy checks report: $CHECKS_FILE"

info "Trivy image summary for variant '$IMAGE_VARIANT':"

jq -r '
	.metrics
	| to_entries[]
	| "  \(.key | ascii_upcase): total=\(.value.total) fixable=\(.value.fixable) unfixed=\(.value.unfixed)"
' "$CHECKS_FILE" |
	while IFS= read -r line; do
		info "$line"
	done

info "  EOL:      $EOL_STATUS"
info "Checks report written: $CHECKS_FILE"

if [[ "$POLICY_ENFORCED" == true ]]; then
	[[ "$OVERALL_STATUS" == "pass" ]] \
		|| die "Trivy hardened-image gate failed: EOL=$EOL_STATUS fixable_CRITICAL=$FIXABLE_CRITICAL fixable_HIGH=$FIXABLE_HIGH"

	info "Trivy hardened-image gate passed"
else
	info "Baseline policy results recorded as evidence and are not enforced"
fi

info "Trivy scan complete for variant: $IMAGE_VARIANT"
