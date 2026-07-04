# Secure-Deploy-Lab — Project README

Secure-Deploy-Lab is a **container and Kubernetes deployment-hardening lab**
built around the same application workload as
[AuthLab](https://github.com/tashauzzz/AuthLab) and
[Secure-CI-template](https://github.com/tashauzzz/Secure-CI-template).

Its role is to document **deployment security**: how the application workload
moves from a functional baseline container to a hardened container and a
policy-validated Kubernetes deployment, with the validation stages reproducible
locally and orchestrated in GitHub Actions.

This project is the deployment-hardening layer of the wider portfolio:

* **[Project 1](https://github.com/tashauzzz/AuthLab):** application security behavior
* **[Project 2](https://github.com/tashauzzz/Secure-CI-template):** CI security verification around the same app
* **[Project 3](https://github.com/tashauzzz/Secure-Deploy-Lab):** container and Kubernetes deployment hardening around the same app

---

## 1) Project scope

Secure-Deploy-Lab focuses on deployment-level security:

* baseline and hardened container comparison,
* container vulnerability scanning and runtime-hardening validation,
* Kubernetes workload policy enforcement,
* validation before and after workload deployment,
* security evidence and summary reporting,
* documented green, non-blocking, and red pipeline behavior.

The baseline variant preserves the functional non-hardened comparison state.
The hardened variant is the deployment candidate and must pass the enforced
container requirements before continuing to Kubernetes validation.

Kubernetes validation runs in a repository-created kind cluster and is limited
to the repository-managed AuthLab workload. Full cluster and platform security
remain outside the project scope.

---

## 2) How to navigate this repo

### Documentation entry points

* **Security Policy — [security_policy.md](docs/security_policy.md)**

  Defines the repository enforcement model: validation jobs, blocking
  conditions, non-blocking findings, report roles, and repository-level
  enforcement.

* **Kubernetes Workload Hardening Policy — [kubernetes_workload_hardening_policy.md](docs/kubernetes_workload_hardening_policy.md)**

  Defines the Kubernetes workload-hardening contract, managed resource scope,
  required controls, enforcement requirements, and assessment boundaries.

* **Pipeline Overview — [pipeline_overview.md](docs/pipeline_overview.md)**

  Explains the validation flow, script responsibilities, supporting files,
  execution profiles, and GitHub Actions orchestration.

* **Red/Green Demo — [red_green_demo.md](docs/red_green_demo.md)**

  Shows representative successful, non-blocking, and blocking pipeline
  behavior tied to the declared policies.