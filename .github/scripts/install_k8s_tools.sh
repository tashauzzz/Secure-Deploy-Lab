#!/usr/bin/env bash

set -euo pipefail

IFS=$'\n\t'

SCRIPT_DIR="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null
	pwd
)"

source "$SCRIPT_DIR/../../scripts/_common.sh"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

read_version() {
  local file="$1"
  local tool="$2"
  local version

  [[ -s "$file" ]] || die "$tool version file missing or empty: $file"
  version="$(tr -d '[:space:]' < "$file")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Invalid $tool version in $file: $version"

  printf '%s' "$version"
}

download() {
  local url="$1"
  local output="$2"

  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --output "$output" \
    "$url"

  [[ -s "$output" ]] || die "Downloaded file is empty: $url"
}

verify_sha256() {
  local checksum="$1"
  local file="$2"
  local label="$3"

  [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] \
    || die "Invalid SHA-256 value for $label"

  printf '%s  %s\n' "$checksum" "$file" \
    | sha256sum --check --status - \
    || die "SHA-256 verification failed for $label"

  info "SHA-256 verification passed: $label"
}

[[ "$#" -eq 1 ]] || die "Usage: $0 INSTALL_DIR"

INSTALL_DIR="$1"
[[ -n "$INSTALL_DIR" ]] || die "INSTALL_DIR must not be empty"

need_cmd awk
need_cmd curl
need_cmd grep
need_cmd install
need_cmd mktemp
need_cmd sha256sum
need_cmd tr

KIND_VERSION="$(read_version "$REPO_ROOT/security/kind/VERSION" kind)"
KUBECTL_VERSION="$(read_version "$REPO_ROOT/security/kubectl/VERSION" kubectl)"
KUBESCAPE_VERSION="$(read_version "$REPO_ROOT/security/kubescape/VERSION" Kubescape)"

mkdir -p "$INSTALL_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

KIND_ASSET="kind-linux-amd64"
KUBESCAPE_ASSET="kubescape_${KUBESCAPE_VERSION}_linux_amd64"

info "Installing pinned Kubernetes tools into: $INSTALL_DIR"
info "kind: $KIND_VERSION"
info "kubectl: $KUBECTL_VERSION"
info "Kubescape: $KUBESCAPE_VERSION"

# kind
KIND_FILE="$WORK_DIR/$KIND_ASSET"
KIND_CHECKSUM_FILE="$WORK_DIR/$KIND_ASSET.sha256sum"

download \
  "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/${KIND_ASSET}" \
  "$KIND_FILE"
download \
  "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/${KIND_ASSET}.sha256sum" \
  "$KIND_CHECKSUM_FILE"

KIND_SHA256="$(awk 'NF { print $1; exit }' "$KIND_CHECKSUM_FILE")"
verify_sha256 "$KIND_SHA256" "$KIND_FILE" "$KIND_ASSET"
install -m 0755 "$KIND_FILE" "$INSTALL_DIR/kind"

# kubectl
KUBECTL_FILE="$WORK_DIR/kubectl"
KUBECTL_CHECKSUM_FILE="$WORK_DIR/kubectl.sha256"

download \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
  "$KUBECTL_FILE"
download \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
  "$KUBECTL_CHECKSUM_FILE"

KUBECTL_SHA256="$(tr -d '[:space:]' < "$KUBECTL_CHECKSUM_FILE")"
verify_sha256 "$KUBECTL_SHA256" "$KUBECTL_FILE" "kubectl v$KUBECTL_VERSION"
install -m 0755 "$KUBECTL_FILE" "$INSTALL_DIR/kubectl"

# Kubescape
KUBESCAPE_FILE="$WORK_DIR/$KUBESCAPE_ASSET"
KUBESCAPE_CHECKSUM_FILE="$WORK_DIR/checksums.sha256"

download \
  "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/${KUBESCAPE_ASSET}" \
  "$KUBESCAPE_FILE"
download \
  "https://github.com/kubescape/kubescape/releases/download/v${KUBESCAPE_VERSION}/checksums.sha256" \
  "$KUBESCAPE_CHECKSUM_FILE"

KUBESCAPE_SHA256="$(
  awk -v asset="$KUBESCAPE_ASSET" \
    '$2 == asset || $2 == "*" asset { print $1; exit }' \
    "$KUBESCAPE_CHECKSUM_FILE"
)"
verify_sha256 "$KUBESCAPE_SHA256" "$KUBESCAPE_FILE" "$KUBESCAPE_ASSET"
install -m 0755 "$KUBESCAPE_FILE" "$INSTALL_DIR/kubescape"

# Verify the installed binaries, not similarly named tools already present in PATH.
KIND_OUTPUT="$("$INSTALL_DIR/kind" version 2>&1)" \
  || die "Installed kind binary failed to run"
grep -Fq "kind v${KIND_VERSION}" <<< "$KIND_OUTPUT" \
  || die "Installed kind version does not match pin: $KIND_VERSION"

KUBECTL_OUTPUT="$("$INSTALL_DIR/kubectl" version --client --output=yaml 2>&1)" \
  || die "Installed kubectl binary failed to run"
grep -Fq "gitVersion: v${KUBECTL_VERSION}" <<< "$KUBECTL_OUTPUT" \
  || die "Installed kubectl version does not match pin: $KUBECTL_VERSION"

KUBESCAPE_OUTPUT="$("$INSTALL_DIR/kubescape" version 2>&1)" \
  || die "Installed Kubescape binary failed to run"
grep -Fq "Your current version is: v${KUBESCAPE_VERSION}" <<< "$KUBESCAPE_OUTPUT" \
  || die "Installed Kubescape version does not match pin: $KUBESCAPE_VERSION"

info "Pinned Kubernetes tools installed and verified"
