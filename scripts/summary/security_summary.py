#!/usr/bin/env python3
"""
Generate the AuthLab secure deployment summary from existing JSON reports.

Usage:
  python scripts/summary/security_summary.py PROFILE REPORT_DIR OUTPUT_FILE
"""

import json
import sys
from pathlib import Path

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")
ARTIFACTS = (
    "run-baseline.json",
    "run-hardened.json",
    "trivy-baseline-checks.json",
    "trivy-hardened-checks.json",
    "trivy-baseline.json",
    "trivy-hardened.json",
    "hardened-runtime-checks.json",
    "k8s-manifest-checks.json",
    "kubescape-manifests.json",
    "k8s-workload-checks.json",
    "kubescape-live.json",
)
STATE_LABELS = {
    "valid": "present",
    "missing": "missing",
    "empty": "empty",
    "invalid_json": "invalid JSON",
    "invalid_report": "invalid report",
    "profile_mismatch": "profile mismatch",
}
MANIFEST_ROWS = (
    ("kubescape_static_policy", "Kubescape static policy", "all applicable controls pass"),
    ("kubescape_static_inventory", "Static resource inventory", "6 required policy resources"),
    ("kubernetes_manifest_apply", "Manifest application", "7 required manifests"),
)
WORKLOAD_ROWS = (
    ("workload_runtime", "Workload runtime", "hardened workload ready", "hardened Pod ready"),
    ("secret_contract", "Secret contract", "required live Secret contract", "live Secret contract verified"),
    ("kubescape_live_policy", "Kubescape live policy", "all applicable controls pass", "live policy passed"),
    ("service_health", "Service health", "/health and /ready pass", "service health checks passed"),
    ("networkpolicy_enforcement", "NetworkPolicy enforcement", "ingress and egress blocked", "ingress and egress blocking verified"),
)

def die(msg):
    raise SystemExit(msg)

def get_args():
    if len(sys.argv) != 4:
        die(
            "Usage: python scripts/summary/security_summary.py "
            "PROFILE REPORT_DIR OUTPUT_FILE"
        )

    profile = sys.argv[1].strip().lower()
    if profile not in ("local", "validation"):
        die("Unsupported profile. Use: local or validation")

    return profile, Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve()

def load_report(path):
    report = {"path": path, "state": "valid", "data": None, "detail": ""}

    if not path.exists():
        report["state"] = "missing"
        return report
    if path.stat().st_size <= 0:
        report["state"] = "empty"
        return report

    try:
        with path.open("r", encoding="utf-8") as handle:
            report["data"] = json.load(handle)
    except (json.JSONDecodeError, UnicodeDecodeError):
        report["state"] = "invalid_json"
    except OSError as exc:
        report["state"] = "invalid_report"
        report["detail"] = str(exc)

    return report

def validate_reports(reports, profile):

    for variant in ("baseline", "hardened"):
        report = reports[f"run-{variant}.json"]
        if report["state"] != "valid":
            continue

        data = report["data"]
        if not isinstance(data, dict):
            report["state"] = "invalid_report"
        elif data.get("profile") != profile:
            report["state"] = "profile_mismatch"
        elif data.get("variant") != variant:
            report["state"] = "invalid_report"
        elif data.get("status") not in ("pass", "fail"):
            report["state"] = "invalid_report"
        elif not isinstance(data.get("checks"), dict):
            report["state"] = "invalid_report"

    contracts = {
        "trivy-baseline-checks.json": ("image_vulnerability_scan", dict),
        "trivy-hardened-checks.json": ("image_vulnerability_scan", dict),
        "hardened-runtime-checks.json": ("hardened_runtime_verification", dict),
        "k8s-manifest-checks.json": ("kubernetes_manifest_deployment", list),
        "k8s-workload-checks.json": ("kubernetes_workload_verification", list),
    }

    for filename, (stage, checks_type) in contracts.items():
        report = reports[filename]
        if report["state"] != "valid":
            continue

        data = report["data"]
        summary = data.get("summary") if isinstance(data, dict) else None
        if not isinstance(data, dict):
            report["state"] = "invalid_report"
        elif data.get("schema_version") != 1 or data.get("stage") != stage:
            report["state"] = "invalid_report"
        elif not isinstance(summary, dict) or summary.get("overall") not in ("pass", "fail"):
            report["state"] = "invalid_report"
        elif not isinstance(data.get("checks"), checks_type):
            report["state"] = "invalid_report"

    runtime = reports["hardened-runtime-checks.json"]
    if runtime["state"] == "valid" and runtime["data"].get("profile") != profile:
        runtime["state"] = "profile_mismatch"

    baseline = reports["trivy-baseline-checks.json"]
    hardened = reports["trivy-hardened-checks.json"]
    if baseline["state"] == "valid":
        if baseline["data"].get("variant") != "baseline" or baseline["data"].get("policy_mode") != "evidence_only":
            baseline["state"] = "invalid_report"
    if hardened["state"] == "valid":
        if hardened["data"].get("variant") != "hardened" or hardened["data"].get("policy_mode") != "enforced":
            hardened["state"] = "invalid_report"

def load_reports(report_dir, profile):
    reports = {name: load_report(report_dir / name) for name in ARTIFACTS}
    validate_reports(reports, profile)
    return reports

def value(item):
    return "N/A" if item is None or item == "" else str(item)

def code(item):
    if item is None or item == "":
        return "N/A"
    return "`" + str(item).replace("`", "'") + "`"

def cell(item):
    return value(item).replace("|", "\\|").replace("\n", " ")

def add_table(lines, headers, rows, separators=None):
    separators = separators or ["---"] * len(headers)
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join(separators) + "|")
    for row in rows:
        lines.append("| " + " | ".join(cell(item) for item in row) + " |")
    lines.append("")

def check_status(check):
    if not isinstance(check, dict):
        return "N/A"
    if check.get("status") == "pass":
        return "PASS"
    if check.get("status") == "fail":
        return "FAIL"
    return "N/A"

def find_check(report, name):
    if report["state"] != "valid":
        return {}

    checks = report["data"].get("checks", {})
    if isinstance(checks, dict):
        return checks.get(name, {})
    for check in checks:
        if isinstance(check, dict) and check.get("name") == name:
            return check
    return {}

def stage_status(report, top_level=False):
    if report["state"] != "valid":
        return "N/A"

    if top_level:
        status = report["data"].get("status")
    else:
        status = report["data"].get("summary", {}).get("overall")

    return "PASS" if status == "pass" else "FAIL" if status == "fail" else "N/A"

def report_detail(report):
    label = STATE_LABELS.get(report["state"], report["state"])
    return f"{label}: {report['detail']}" if report["detail"] else label

def stage_detail(report, status):
    if status == "N/A":
        return report_detail(report)

    failed_phase = report["data"].get("failed_phase")
    if status == "FAIL" and failed_phase:
        return f"failed phase: `{failed_phase}`"

    checks = report["data"].get("checks", {})
    checks = list(checks.values()) if isinstance(checks, dict) else checks
    passed = sum(check.get("status") == "pass" for check in checks if isinstance(check, dict))
    return f"{passed}/{len(checks)} checks passed"

def overall_status(stage_rows):
    statuses = [row[2] for row in stage_rows]
    if "FAIL" in statuses:
        return "FAIL"
    if "N/A" in statuses:
        return "INCOMPLETE"
    return "PASS"

def runtime_result(report, name):
    check = find_check(report, name)
    return f"{value(check.get('http'))} ({check_status(check)})" if check else "N/A"

def trivy_metric(report, severity, field):
    if report["state"] != "valid":
        return "N/A"

    metrics = report["data"].get("metrics")
    if not isinstance(metrics, dict):
        return "N/A"

    severity_metrics = metrics.get(severity.lower())
    if not isinstance(severity_metrics, dict):
        return "N/A"

    return value(severity_metrics.get(field))

def trivy_policy_value(report, name):
    check = find_check(report, name)
    if not check:
        return "N/A"
    if check.get("observed") is not None and check.get("threshold") is not None:
        if check.get("enforced") is False:
            return f"{check['observed']} (not enforced)"
        return f"{check['observed']} (threshold {check['threshold']}, {check_status(check)})"
    return check_status(check)

def trivy_findings(report):
    if report["state"] != "valid":
        return None

    data = report["data"]
    if not isinstance(data, dict):
        return None

    results = data.get("Results")
    if not isinstance(results, list):
        return None

    findings = set()

    for result in results:
        if not isinstance(result, dict):
            continue

        vulnerabilities = result.get("Vulnerabilities") or []
        if not isinstance(vulnerabilities, list):
            continue

        for vuln in vulnerabilities:
            if not isinstance(vuln, dict):
                continue

            severity = vuln.get("Severity")
            fixed = vuln.get("FixedVersion") or ""

            if severity in ("CRITICAL", "HIGH") and fixed:
                findings.add(
                    (
                        severity,
                        value(vuln.get("PkgName")),
                        value(vuln.get("InstalledVersion")),
                        fixed,
                        value(vuln.get("VulnerabilityID")),
                    )
                )

    order = {"CRITICAL": 0, "HIGH": 1}

    return sorted(
        findings,
        key=lambda row: (order[row[0]], row[1], row[4]),
    )[:10]

def build_stage_rows(profile, reports):
    stages = (
        ("Baseline runtime smoke", f"profile: {profile}", "run-baseline.json", True),
        ("Baseline vulnerability evidence", "policy: evidence_only", "trivy-baseline-checks.json", False),
        ("Hardened runtime smoke", f"profile: {profile}", "run-hardened.json", True),
        ("Hardened runtime verification", f"profile: {profile}", "hardened-runtime-checks.json", False),
        ("Hardened vulnerability gate", "policy: enforced", "trivy-hardened-checks.json", False),
        ("Kubernetes manifest deployment", "hardened image only; static policy + apply", "k8s-manifest-checks.json", False),
        ("Kubernetes workload verification", "hardened image only; live workload", "k8s-workload-checks.json", False),
    )

    rows = []
    for name, context, filename, top_level in stages:
        report = reports[filename]
        status = stage_status(report, top_level)
        rows.append((name, context, status, stage_detail(report, status)))
    return rows

def build_summary(profile, reports):
    stage_rows = build_stage_rows(profile, reports)
    baseline_run = reports["run-baseline.json"]
    hardened_run = reports["run-hardened.json"]
    runtime = reports["hardened-runtime-checks.json"]
    manifest = reports["k8s-manifest-checks.json"]
    workload = reports["k8s-workload-checks.json"]

    lines = [
        "# Secure Deployment Security Summary",
        "",
        f"Validation profile: `{profile}`",
        f"Overall validation status: **{overall_status(stage_rows)}**",
        "",
        "## Stage results",
        "",
    ]
    add_table(lines, ("Stage", "Context", "Status", "Check summary"), stage_rows)

    lines.extend(("## Generated evidence", ""))
    evidence_rows = []
    for filename in ARTIFACTS:
        report = reports[filename]
        size = "N/A"
        if report["path"].exists():
            try:
                size = f"{report['path'].stat().st_size} bytes"
            except OSError:
                pass
        evidence_rows.append((code(f"reports/{filename}"), STATE_LABELS[report["state"]], size))
    add_table(lines, ("Artifact", "Status", "Size"), evidence_rows, ("---", "---", "---:"))

    lines.extend(("## Image variants", ""))
    image_rows = []
    for variant, report in (("baseline", baseline_run), ("hardened", hardened_run)):
        data = report["data"] if report["state"] == "valid" else {}
        image_rows.append(
            (variant, value(data.get("profile")), code(data.get("image")), code(data.get("dockerfile")), stage_status(report, True))
        )
    add_table(lines, ("Variant", "Profile", "Image", "Dockerfile", "Runtime smoke result"), image_rows)

    lines.extend(("## Runtime smoke checks", ""))
    smoke_rows = []
    for variant, report in (("baseline", baseline_run), ("hardened", hardened_run)):
        smoke_rows.append(
            (
                variant,
                runtime_result(report, "health"),
                runtime_result(report, "ready"),
                runtime_result(report, "web_login"),
                runtime_result(report, "api_session"),
                stage_status(report, True),
            )
        )
    add_table(lines, ("Variant", "/health", "/ready", "/login", "/api/v1/auth/session", "Result"), smoke_rows)

    lines.extend(("## Hardened runtime checks", ""))
    non_root = find_check(runtime, "non_root")
    readable = find_check(runtime, "app_code_readable")
    not_writable = find_check(runtime, "app_code_not_writable")
    data_writable = find_check(runtime, "data_writable")
    stdout = find_check(runtime, "stdout_logging")
    logs = find_check(runtime, "logs_not_writable")
    health = find_check(runtime, "docker_healthcheck")
    runtime_rows = (
        ("Runtime user", "non-root", f"uid={value(non_root.get('uid'))} user={value(non_root.get('user'))}" if non_root else "N/A", check_status(non_root)),
        ("Application code readable", "yes", "/app/app.py and /app/authlab readable" if readable else "N/A", check_status(readable)),
        ("Application code writable", "no", "/app/app.py and /app/authlab not writable" if not_writable else "N/A", check_status(not_writable)),
        ("Runtime data directory writable", "yes", f"{value(data_writable.get('path'))} writable" if data_writable else "N/A", check_status(data_writable)),
        ("Logging mode", "stdout", f"LOG_TO_STDOUT={value(stdout.get('LOG_TO_STDOUT'))}" if stdout else "N/A", check_status(stdout)),
        ("Logs directory writable surface", "not required", f"{value(logs.get('path'))} absent or not writable" if logs else "N/A", check_status(logs)),
        ("Docker healthcheck", "healthy", value(health.get("docker_health_status")) if health else "N/A", check_status(health)),
    )
    add_table(lines, ("Check", "Expected", "Actual", "Result"), runtime_rows)

    lines.extend(("## Trivy validation", ""))
    policy_rows = []
    for variant in ("baseline", "hardened"):
        report = reports[f"trivy-{variant}-checks.json"]
        mode = value(report["data"].get("policy_mode")) if report["state"] == "valid" else "N/A"
        policy_rows.append(
            (
                variant,
                mode,
                check_status(find_check(report, "base_image_not_eol")),
                trivy_policy_value(report, "fixable_critical"),
                trivy_policy_value(report, "fixable_high"),
                stage_status(report),
            )
        )
    add_table(lines, ("Variant", "Mode", "Base image not EOL", "Fixable CRITICAL", "Fixable HIGH", "Result"), policy_rows)

    lines.extend(("## Trivy image evidence", ""))
    severity_rows = []
    for variant in ("baseline", "hardened"):
        report = reports[f"trivy-{variant}-checks.json"]
        for severity in SEVERITIES:
            severity_rows.append(
                (variant, severity, trivy_metric(report, severity, "total"), trivy_metric(report, severity, "fixable"), trivy_metric(report, severity, "unfixed"))
            )
    add_table(lines, ("Variant", "Severity", "Total", "Fixable", "Unfixed"), severity_rows, ("---", "---", "---:", "---:", "---:"))

    lines.extend(("### Trivy actionable CRITICAL/HIGH findings", ""))
    finding_rows = []
    raw_unavailable = False
    for variant in ("baseline", "hardened"):
        report = reports[f"trivy-{variant}.json"]

        if report["state"] != "valid":
            raw_unavailable = True
            finding_rows.append(
                (
                    variant,
                    "-",
                    "-",
                    "-",
                    "-",
                    f"N/A — raw report {report_detail(report)}",
                )
            )
            continue

        findings = trivy_findings(report)

        if findings is None:
            raw_unavailable = True
            finding_rows.append(
                (
                    variant,
                    "-",
                    "-",
                    "-",
                    "-",
                    "N/A — unsupported raw report structure",
                )
            )
            continue

        for severity, package, installed, fixed, vulnerability in findings:
            finding_rows.append(
                (
                    variant,
                    severity,
                    code(package),
                    code(installed),
                    code(fixed),
                    vulnerability,
                )
            )
    if not finding_rows and not raw_unavailable:
        finding_rows.append(("-", "-", "-", "-", "-", "No fixable CRITICAL/HIGH findings"))
    add_table(lines, ("Variant", "Severity", "Package", "Installed", "Fixed", "Vulnerability"), finding_rows)

    lines.extend(("## Kubernetes manifest deployment (hardened image only)", ""))
    framework = manifest["data"].get("framework", {}) if manifest["state"] == "valid" else {}
    lines.append(f"Framework: {code(framework.get('name'))} {code(framework.get('version'))}")
    if manifest["state"] == "valid" and manifest["data"].get("failed_phase"):
        lines.append(f"Failed phase: {code(manifest['data']['failed_phase'])}")
    lines.append("")
    manifest_rows = []
    for name, label, expected in MANIFEST_ROWS:
        check = find_check(manifest, name)
        actual = value(check.get("observed")) if check else "N/A"
        if check.get("status") == "fail" and actual == "N/A":
            actual = "failed"
        manifest_rows.append((label, expected, actual, check_status(check)))
    add_table(lines, ("Check", "Expected", "Actual", "Result"), manifest_rows)

    lines.extend(("## Kubernetes workload verification (hardened image only)", ""))
    workload_data = workload["data"] if workload["state"] == "valid" else {}
    lines.append(f"Context: {code(workload_data.get('context'))}")
    lines.append(f"Namespace: {code(workload_data.get('namespace'))}")
    lines.append(f"Image: {code(workload_data.get('image'))}")
    if workload["state"] == "valid" and workload_data.get("failed_phase"):
        lines.append(f"Failed phase: {code(workload_data['failed_phase'])}")
    lines.append("")
    workload_rows = []
    for name, label, expected, passed_actual in WORKLOAD_ROWS:
        check = find_check(workload, name)
        actual = passed_actual if check.get("status") == "pass" else "failed" if check.get("status") == "fail" else "N/A"
        workload_rows.append((label, expected, actual, check_status(check)))
    add_table(lines, ("Check", "Expected", "Actual", "Result"), workload_rows)

    return "\n".join(lines).rstrip() + "\n"

def write_summary(output_file, content):
    temporary_file = Path(f"{output_file}.tmp")
    try:
        output_file.parent.mkdir(parents=True, exist_ok=True)
        temporary_file.write_text(content, encoding="utf-8")
        temporary_file.replace(output_file)
    except OSError as exc:
        die(f"Failed to write security summary: {exc}")


def main():
    profile, report_dir, output_file = get_args()
    reports = load_reports(report_dir, profile)
    write_summary(output_file, build_summary(profile, reports))

if __name__ == "__main__":
    main()
