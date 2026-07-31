#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy-oke.sh [--private-key PATH] [--user USER]

Renders the sensitive OKE manifest from Terraform outputs, transfers it over
SSH to the configured bastion, applies it to the private OKE cluster, waits for
the workloads and internal NLB, and removes both temporary manifest copies.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"
ssh_user="opc"
umask 077

while (($#)); do
  case "$1" in
    --private-key)
      [[ $# -ge 2 ]] || { printf '%s\n' '--private-key requires a path' >&2; exit 2; }
      private_key="$2"
      shift
      ;;
    --user)
      [[ $# -ge 2 ]] || { printf '%s\n' '--user requires a value' >&2; exit 2; }
      ssh_user="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

for command_name in terraform jq ssh scp; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

[[ -n "${private_key}" ]] || {
  printf 'Set BASTION_SSH_PRIVATE_KEY_FILE or pass --private-key.\n' >&2
  exit 2
}
[[ -f "${private_key}" ]] || {
  printf 'SSH private key does not exist: %s\n' "${private_key}" >&2
  exit 2
}

private_key="$(cd "$(dirname "${private_key}")" && pwd)/$(basename "${private_key}")"
bastion_ip="$(terraform -chdir="${terraform_dir}" output -raw bastion_public_ip)"
namespace="$(terraform -chdir="${terraform_dir}" output -json deployment_summary | jq -r '.name')"
expected_nlb_ip="$(terraform -chdir="${terraform_dir}" output -json deployment_summary | jq -r '.nlb_private_ip')"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-oke.XXXXXX")"
manifest_file="${temporary_dir}/stack.yaml"
remote_manifest="/tmp/oci-dicom-stack-${namespace}.yaml"
known_hosts_file="${temporary_dir}/known_hosts"

cleanup() {
  ssh \
    -i "${private_key}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${known_hosts_file}" \
    "${ssh_user}@${bastion_ip}" \
    "rm -f '${remote_manifest}'" >/dev/null 2>&1 || true
  rm -rf "${temporary_dir}"
}
trap cleanup EXIT

terraform -chdir="${terraform_dir}" output -raw oke_manifest >"${manifest_file}"
chmod 600 "${manifest_file}"

scp \
  -i "${private_key}" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${known_hosts_file}" \
  "${manifest_file}" \
  "${ssh_user}@${bastion_ip}:${remote_manifest}"

ssh \
  -i "${private_key}" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${known_hosts_file}" \
  "${ssh_user}@${bastion_ip}" \
  bash -s -- "${remote_manifest}" "${namespace}" "${expected_nlb_ip}" <<'REMOTE'
set -euo pipefail
manifest_file="$1"
namespace="$2"
expected_nlb_ip="$3"

chmod 600 "${manifest_file}"
kubectl apply -f "${manifest_file}"
rm -f "${manifest_file}"

kubectl -n "${namespace}" wait \
  --for=condition=complete \
  job \
  --selector=app.kubernetes.io/name=keycloak-database-bootstrap \
  --timeout=15m

for deployment in keycloak orthanc-auth-service orthanc dicom-gateway; do
  kubectl -n "${namespace}" rollout status \
    "deployment/${deployment}" \
    --timeout=20m
done

for attempt in $(seq 1 60); do
  actual_nlb_ip="$(
    kubectl -n "${namespace}" get service dicom-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
  )"
  if [[ "${actual_nlb_ip}" == "${expected_nlb_ip}" ]]; then
    printf 'OKE internal NLB is ready at %s.\n' "${actual_nlb_ip}"
    exit 0
  fi
  if [[ -n "${actual_nlb_ip}" ]]; then
    printf 'Waiting for reserved NLB IP %s (controller currently reports %s)...\n' \
      "${expected_nlb_ip}" "${actual_nlb_ip}"
  fi
  sleep 10
done

kubectl -n "${namespace}" describe service dicom-gateway >&2
printf 'OKE internal NLB did not acquire reserved IP %s within 10 minutes.\n' \
  "${expected_nlb_ip}" >&2
exit 1
REMOTE

printf 'OKE Orthanc, authorization service, Keycloak, and NLB deployment completed.\n'
