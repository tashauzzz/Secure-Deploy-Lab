# Pipeline overview

## 1. Purpose

This document provides a concise execution-oriented overview of the repository validation pipeline.

It focuses on:

* script responsibilities
* supporting files that affect pipeline execution
* execution profiles (`local` and `validation`)
* baseline and hardened image flow
* the relationship between local runs and GitHub Actions orchestration

---

## 2. Validation flow

The repository validates the application through the following sequence:

```text
environment bootstrap
→ database initialization
→ baseline image build
→ baseline vulnerability evidence
→ baseline runtime smoke checks
→ hardened image build
→ hardened vulnerability gate
→ hardened runtime smoke and hardening verification
→ verified hardened image selection
→ Kubernetes Secret generation
→ kind cluster preparation
→ static manifest policy and deployment
→ live workload verification
→ security summary
```

The baseline and hardened variants use the same application source and dependency set.

The baseline variant reproduces the container definition built and validated in [Project 2](https://github.com/tashauzzz/Secure-CI-template) and serves as the non-hardened comparison state. Project 2 transferred its image between jobs within the same workflow run but did not publish it for consumption by later projects, so this repository rebuilds the baseline definition.

The hardened variant adds the runtime-hardening properties required by this project. After successful container validation, only the verified hardened image continues to Kubernetes validation. In GitHub Actions, it is transferred to the Kubernetes job as a workflow artifact.

---

## 3. Script map

### 3.1 Environment, database, and image preparation

These scripts prepare the selected execution profile and build one image variant at a time.

* [00_env_bootstrap.sh](../scripts/00_env_bootstrap.sh) — selects the `local` or `validation` profile, creates or reuses `.venv`, installs `requirements.txt`, generates the effective environment file, and validates the required runtime values; with `--force`, rebuilds the selected environment file and regenerates its values
* [01_app_db_bootstrap.sh](../scripts/01_app_db_bootstrap.sh) — recreates and verifies the profile-specific SQLite database and writes the matching database-ready marker under `.state/`
* [02_build_image.sh](../scripts/02_build_image.sh) — selects the profile and image variant, exports the corresponding Compose variables, builds the shared `authlab` service with the selected Dockerfile, and verifies that the expected local image was created

### 3.2 Container scanning and runtime verification

These scripts operate on images that have already been built by `02_build_image.sh`.

* [03_scan_trivy.sh](../scripts/03_scan_trivy.sh) — scans the existing baseline or hardened image for OS and library vulnerabilities with the pinned Trivy container, writes raw and normalized reports, records baseline policy results as evidence, and enforces the EOL and fixable CRITICAL/HIGH thresholds for the hardened variant
* [04_run_image.sh](../scripts/04_run_image.sh) — validates the selected profile environment, database-ready marker, database file, and local image; starts the existing image through Compose with `--no-build`; verifies `/health`, `/ready`, `/login`, and the unauthenticated session endpoint; and leaves the container running for later verification
* [05_verify_hardening.sh](../scripts/05_verify_hardening.sh) — inspects the already running hardened Compose container and verifies the expected image, non-root execution, readable but non-writable application code, writable runtime data, stdout logging, restricted file-log surface, and healthy Docker status

### 3.3 Kubernetes preparation and workload validation

These scripts continue from the verified hardened image.

* [06_prepare_k8s_secret.sh](../scripts/06_prepare_k8s_secret.sh) — generates the ignored `k8s/secret.local.yaml` manifest from the selected profile environment and writes it with private file permissions
* [07_prepare_kind.sh](../scripts/07_prepare_kind.sh) — verifies the pinned kind and kubectl versions, creates or reuses the kind cluster, loads `authlab-deploy:hardened`, and verifies the image inside each kind node; with `--recreate`, deletes an existing project cluster and creates a fresh one before loading the image
* [08_apply_k8s.sh](../scripts/08_apply_k8s.sh) — runs the static Kubescape policy against the six version-controlled non-secret resources, validates their exact inventory, and applies those resources together with the generated Secret
* [09_verify_k8s.sh](../scripts/09_verify_k8s.sh) — verifies the Deployment rollout, hardened image use, live Secret contract, live Kubescape policy, Service health, and default-deny ingress and egress behavior

### 3.4 Reporting and cleanup

* [10_security_summary.sh](../scripts/10_security_summary.sh) — renders available producer reports into `reports/security-summary.md`
* [99_cleanup.sh](../scripts/99_cleanup.sh) — removes the Compose runtime in `compose` mode and both the Compose runtime and kind cluster in `all` mode

Cleanup does not remove built images, generated reports, or project database files.

---

## 4. Supporting files and configuration

Some pipeline responsibilities are implemented through supporting files rather than standalone stages.

### 4.1 GitHub Actions

* [.github/workflows/security.yaml](../.github/workflows/security.yaml) — defines job ordering, artifact handoff, report collection, and cleanup behavior
* [.github/scripts/install_k8s_tools.sh](../.github/scripts/install_k8s_tools.sh) — installs and verifies the pinned kind, kubectl, and Kubescape binaries used by the Kubernetes job
* [.github/dependabot.yml](../.github/dependabot.yml) — defines automated update proposals for GitHub Actions dependencies

### 4.2 Container configuration

* [docker-compose.yaml](../docker-compose.yaml) — defines the shared Compose service and selects the effective image, Dockerfile, environment file, UID/GID, and logging mode through exported variables
* [dockerfile.baseline](../dockerfile.baseline) — defines the functional non-hardened comparison image
* [dockerfile.hardened](../dockerfile.hardened) — defines the hardened image and its restricted runtime filesystem and user model
* [.env.example](../.env.example) — provides the `local` profile template
* [.env.validation.example](../.env.validation.example) — provides the unattended `validation` profile template
* [requirements.txt](../requirements.txt) — defines the Python dependencies installed on the host and in both image variants

Both Dockerfiles use the same base image, OS package refresh, Python dependencies, and application source. Their main difference is runtime posture rather than software composition.

### 4.3 Kubernetes configuration

The repository contains six version-controlled non-secret Kubernetes manifests:

* [namespace.yaml](../k8s/namespace.yaml)
* [serviceaccount.yaml](../k8s/serviceaccount.yaml)
* [configmap.yaml](../k8s/configmap.yaml)
* [networkpolicy.yaml](../k8s/networkpolicy.yaml)
* [deployment.yaml](../k8s/deployment.yaml)
* [service.yaml](../k8s/service.yaml)

The Secret files are:

* [secret.example.yaml](../k8s/secret.example.yaml) — non-sensitive example structure
* `k8s/secret.local.yaml` — generated profile-specific Secret excluded from version control

### 4.4 Security tooling and internal helpers

* [security/trivy/VERSION](../security/trivy/VERSION) — pins the Trivy runner version
* [security/kubescape/VERSION](../security/kubescape/VERSION) — pins the Kubescape version
* [security/kind/VERSION](../security/kind/VERSION) — pins the kind version
* [security/kubectl/VERSION](../security/kubectl/VERSION) — pins the kubectl version
* [security/kubescape/authlab-kubernetes-hardening.json](../security/kubescape/authlab-kubernetes-hardening.json) — defines the project-owned Kubescape framework
* [scripts/_common.sh](../scripts/_common.sh) — provides shared repository, logging, and failure helpers
* [scripts/_env_profiles.sh](../scripts/_env_profiles.sh) — maps execution profiles to environment and state files
* [scripts/_image_variants.sh](../scripts/_image_variants.sh) — maps image variants to Dockerfiles, image references, reports, and Compose variables
* [scripts/_kubescape.sh](../scripts/_kubescape.sh) — executes and validates static and live Kubescape scans
* [scripts/_networkpolicy_verify.sh](../scripts/_networkpolicy_verify.sh) — verifies default-deny ingress and egress with temporary positive- and negative-control Pods
* [scripts/db/db_init.py](../scripts/db/db_init.py) — recreates and verifies the SQLite database
* [scripts/summary/security_summary.py](../scripts/summary/security_summary.py) — validates producer-report contracts and renders the markdown summary

---

## 5. Local execution and profiles

### 5.1 Local prerequisites

Local execution requires the following host tools:

* Docker Engine with Docker Compose v2
* Python 3 with virtual-environment support
* `curl`
* `jq`
* kind
* kubectl
* Kubescape

Trivy does not require a host installation because `03_scan_trivy.sh` runs the pinned Trivy container image.

The local kind, kubectl, and Kubescape versions must match the repository pins under `security/`. The stage scripts verify those versions before use.

### 5.2 Execution profiles

The repository uses two execution profiles:

* `validation`
* `local`

The `validation` profile is the pipeline-shaped execution mode. It is used by GitHub Actions and can also be selected locally to reproduce the CI path.

The `local` profile is intended for interactive local execution and debugging.

Both profiles can exist locally at the same time.

| Profile      | Environment template      | Effective environment | Database-ready marker        |
| ------------ | ------------------------- | --------------------- | ---------------------------- |
| `local`      | `.env.example`            | `.env`                | `.state/db-ready.local`      |
| `validation` | `.env.validation.example` | `.env.validation`     | `.state/db-ready.validation` |

Local execution begins with:

* `00_env_bootstrap.sh local|validation`
* `01_app_db_bootstrap.sh local|validation`

The remaining stages follow the numeric script order. Scripts `02` through `04` run once for each image variant, while `05` applies only to the hardened runtime. Scripts `06` through `10` continue with Kubernetes preparation, workload verification, and summary generation.

The `local` profile requests the administrator password interactively. The `validation` profile generates it automatically for unattended execution.

`04_run_image.sh` requires the database-ready marker and database file associated with the selected profile.

Runtime environments are removed with `99_cleanup.sh` in either `compose` or `all` mode.

---

## 6. GitHub Actions execution

GitHub Actions uses the `validation` profile.

Scheduled runs execute the same complete container and Kubernetes validation path against the current default-branch revision.

A practical difference from local execution is Kubernetes tool preparation: the workflow installs the pinned kind, kubectl, and Kubescape binaries through the CI-only installer, while local execution expects those tools to be installed beforehand. The stage scripts verify that their versions match the repository pins.

