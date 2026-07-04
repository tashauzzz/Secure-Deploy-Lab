# Security Policy

## 1. Purpose / Scope

This policy defines the current security enforcement model for the repository validation pipeline.

It covers:

* baseline and hardened container image validation
* container vulnerability scanning
* container runtime verification
* static Kubernetes workload policy checks
* Kubernetes manifest deployment
* live Kubernetes workload verification
* security summary aggregation

The Kubernetes scope is limited to repository-managed workload resources and does not represent a full cluster-security assessment.

---

## 2. Jobs

### `container-hardening`

Builds and validates both image variants.

It records baseline vulnerability evidence, enforces the hardened image policy, runs runtime smoke checks for both variants, and verifies the hardened runtime contract.

After successful validation, the verified hardened image is made available
to the Kubernetes job. In GitHub Actions, it is transferred as a workflow
artifact.

### `kubernetes-workload-hardening`

Loads the verified hardened image, prepares the kind cluster, runs static
Kubescape validation, applies the required manifests, and verifies the
deployed workload.

### `summary`

Aggregates available reports into `reports/security-summary.md`.

The summary job is artifact-only. Missing producer reports may result in a
partial summary, but the summary job does not replace or override
producer-stage enforcement.

---

## 3. Validation stages and enforcement role

| Tool / stage                  | Layer                                                  | Enforcement mode   | Artifact                                                            |
| ----------------------------- | ------------------------------------------------------ | -------------- | ------------------------------------------------------------------- |
| Trivy baseline                | Baseline image OS and library vulnerabilities          | Evidence-only  | `reports/trivy-baseline.json`, `reports/trivy-baseline-checks.json` |
| Baseline runtime smoke        | Baseline container availability                        | Blocking       | `reports/run-baseline.json`                                         |
| Trivy hardened                | Hardened image OS and library vulnerabilities          | Selective gate | `reports/trivy-hardened.json`, `reports/trivy-hardened-checks.json` |
| Hardened runtime smoke        | Hardened container availability                        | Blocking       | `reports/run-hardened.json`                                         |
| Hardened runtime verification | Container runtime hardening                            | Blocking       | `reports/hardened-runtime-checks.json`                              |
| Kubescape static              | Version-controlled Kubernetes resources                | Blocking       | `reports/kubescape-manifests.json`                                  |
| Manifest deployment           | Static inventory and manifest application              | Blocking       | `reports/k8s-manifest-checks.json`                                  |
| Kubescape live                | Deployed Kubernetes workload                           | Blocking       | `reports/kubescape-live.json`                                       |
| Workload verification         | Live runtime, Secret, service, and network enforcement | Blocking       | `reports/k8s-workload-checks.json`                                  |
| Security summary                 | Aggregated report / partial summary                     | Artifact-only  | `reports/security-summary.md`                                      |                                                   

---

## 4. Blocking conditions

The pipeline blocks on:

* tool or runtime failure for any enabled blocking validation stage
* a missing, empty, or invalid required producer report within an enabled
  blocking validation stage
* failure of any required baseline or hardened runtime smoke check
* hardened image base-image **EOL**
* hardened image **fixable CRITICAL** vulnerabilities
* hardened image **fixable HIGH** vulnerabilities
* failure of the hardened runtime contract:
  * execution of an unexpected container image
  * root execution
  * unreadable or writable application code
  * an absent or non-writable `/app/data` directory
  * logging mode other than `LOG_TO_STDOUT=true`
  * a writable `/app/logs` surface
  * Docker health status other than `healthy`
* failure of the static Kubernetes workload contract, including the expected
  framework identity, complete control set, and exact policy-resource inventory
* failure to apply the complete required manifest set
* failure of the deployed workload runtime or live Secret contract
* failure of live Kubernetes policy validation, Service health checks, or
  NetworkPolicy enforcement

### 4.1 Repository-level enforcement

Repository-level merge enforcement is controlled through a GitHub ruleset on the default branch. The protected `main` branch requires changes to go through a pull request and requires selected status checks to pass before merge.

The current required PR checks are:

* `Container hardening`
* `Kubernetes workload hardening`
* `Security summary`

This means that the full container and Kubernetes validation pipeline must pass before a pull request can be merged into `main`.

Scheduled runs execute the same complete validation path against the current default-branch revision and are not configured as separate merge-required checks.

The ruleset also blocks force pushes and branch deletion for the protected branch.

---

## 5. Non-blocking findings

The following findings are recorded for review but do not currently block the pipeline:

* baseline base-image EOL condition
* baseline fixable CRITICAL findings
* baseline fixable HIGH findings
* unfixed CRITICAL and HIGH findings in either image variant
* MEDIUM, LOW, and UNKNOWN findings in either image variant

Baseline evidence mode applies only to vulnerability findings. Baseline runtime smoke checks remain blocking.

---

## 6. Reviewed suppressions

There are currently no active scanner suppressions.

The baseline `evidence_only` mode is an explicit comparison policy and is not treated as a suppression.