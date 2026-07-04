#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

source "$SCRIPT_DIR/_common.sh"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

PROFILE="${1:-local}"

case "$PROFILE" in
	local|validation)
		;;
	*)
		die "Unknown profile: $PROFILE (use: [local|validation])"
		;;
esac

[[ "$#" -le 1 ]] || die "Usage: ./scripts/10_security_summary.sh [local|validation]"

REPORT_DIR="$REPO_ROOT/reports"
OUT_FILE="$REPORT_DIR/security-summary.md"
PYTHON_SCRIPT="$SCRIPT_DIR/summary/security_summary.py"

need_cmd python3

[[ -f "$PYTHON_SCRIPT" ]] || die "Security summary renderer not found: $PYTHON_SCRIPT"
[[ -s "$PYTHON_SCRIPT" ]] || die "Security summary renderer is empty: $PYTHON_SCRIPT"

mkdir -p "$REPORT_DIR"
rm -f "$OUT_FILE" "$OUT_FILE.tmp"

info "Generating security summary"
info "Profile: $PROFILE"

python3 "$PYTHON_SCRIPT" "$PROFILE" "$REPORT_DIR" "$OUT_FILE"

info "Security summary written: $OUT_FILE"
info "Summary size: $(wc -c < "$OUT_FILE") bytes"
exit 0
