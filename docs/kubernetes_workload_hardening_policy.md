# Kubernetes Workload Hardening Policy

## 1. Purpose / Scope

This policy defines the Kubernetes workload-hardening contract for the AuthLab deployment.

It covers:

* repository-managed Kubernetes resources
* static and live Kubescape validation
* manifest deployment
* workload runtime verification
* Service and NetworkPolicy enforcement

The scope is limited to the AuthLab workload and does not represent a full Kubernetes cluster-security assessment.

---

## 2. Policy framework

The repository uses the following project-owned Kubescape framework:

| Property                 | Value                                                  |
| ------------------------ | ------------------------------------------------------ |
| Name                     | `AuthLabKubernetesHardening`                           |
| Version                  | `1.0.0`                                                |
| Scanning scopes          | `file`, `cluster`                                      |
| Required controls        | 19                                                     |
| Project-specific control | `AL-K8S-001`                                           |
| Framework file           | `security/kubescape/authlab-kubernetes-hardening.json` |

The framework combines selected Kubescape workload controls with an AuthLab-specific Service exposure control.

Static and live scans require the expected framework identity, the complete
19-control set, and every expected control to be evaluated and passed.

---

## 3. Managed resource scope

Static policy validation covers exactly six version-controlled non-secret resources:

| Kind           | Namespace      | Name               |
| -------------- | -------------- | ------------------ |
| Namespace      | cluster-scoped | `authlab`          |
| ServiceAccount | `authlab`      | `authlab`          |
| ConfigMap      | `authlab`      | `authlab-config`   |
| NetworkPolicy  | `authlab`      | `default-deny-all` |
| Deployment     | `authlab`      | `authlab`          |
| Service        | `authlab`      | `authlab`          |

The generated `k8s/secret.local.yaml` manifest is excluded from the static Kubescape input.

The deployment stage applies seven required manifests:

* the six policy resources
* the generated Secret

The live Kubescape report must include all six required policy resources. Additional resources created by Kubernetes at runtime are allowed.

---

## 4. Required controls

| Policy area                  | Controls                                                                                                                                                                  |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Secrets and identity         | `C-0012` Applications credentials in configuration files; `C-0034` Automatic mapping of service account                                                                   |
| Container isolation          | `C-0013` Non-root containers; `C-0016` Allow privilege escalation; `C-0017` Immutable container filesystem; `C-0046` Insecure capabilities; `C-0057` Privileged container |
| Host exposure                | `C-0038` Host PID/IPC privileges; `C-0041` HostNetwork access; `C-0044` Container hostPort; `C-0048` HostPath mount; `C-0074` Container runtime socket mounted            |
| Network and Service exposure | `C-0030` Ingress and Egress blocked; `C-0054` Cluster internal networking; `AL-K8S-001` AuthLab Service exposure contract                                                 |
| Resource governance          | `C-0268` Ensure CPU requests are set; `C-0269` Ensure memory requests are set; `C-0270` Ensure CPU limits are set; `C-0271` Ensure memory limits are set                  |

### 4.1 AuthLab Service exposure contract

`AL-K8S-001` requires `Service/authlab` in namespace `authlab` to:

* use a non-headless `ClusterIP`
* have no `externalIPs`, `externalName`, or `nodePort`
* define exactly one TCP port named `http`
* expose port `5000`
* target the named container port `http`
* use the selectors `app.kubernetes.io/name=authlab`,
  `app.kubernetes.io/component=web`, and
  `app.kubernetes.io/part-of=secure-deploy-lab`


---

## 5. Static validation and deployment

Static validation and deployment require:

* all seven manifest files to exist and be non-empty
* all 19 Kubescape controls to pass
* exactly the six expected policy resources in the static report
* all seven required manifests to be applied successfully

---

## 6. Live enforcement

Live workload verification requires:

* successful Deployment rollout
* a Ready Pod using `authlab-deploy:hardened` for both the application and init containers
* the live `Opaque` Secret `authlab-secret` to contain exactly
  `ADMIN_MFA_SECRET`, `ADMIN_PWHASH`, `DEV_API_KEY`, and `SECRET_KEY`,
  and to be referenced by both the application and init containers
* all 19 live Kubescape controls to pass
* all six required project resources to appear in the live report
* HTTP `200` responses from `/health` and `/ready` through `Service/authlab`
* verified default-deny ingress and egress behavior

---

## 7. Scope limitations

This policy does not assess:

* Kubernetes control-plane configuration
* API server or admission-controller hardening
* etcd configuration or encryption
* kubelet or node operating-system hardening
* cluster audit logging
* general cluster-wide RBAC design
* cloud-provider infrastructure
* production availability or disaster recovery

The validation environment is a repository-created kind cluster.

The resulting claim is limited to the repository-managed AuthLab workload satisfying the declared project-owned Kubernetes hardening contract.
