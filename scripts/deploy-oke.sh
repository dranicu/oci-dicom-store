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
source "${project_dir}/scripts/ssh-trust.sh"
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
calico_profile="$(terraform -chdir="${terraform_dir}" output -json deployment_summary | jq -er '.calico_profile')"
calico_source_dir="${project_dir}/kubernetes/calico/${calico_profile}"
[[ -f "${calico_source_dir}/kustomization.yaml" ]] || {
  printf 'No Calico policy-only profile for Kubernetes minor %s.\n' "${calico_profile}" >&2
  exit 1
}
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-oke.XXXXXX")"
manifest_file="${temporary_dir}/stack.yaml"
remote_manifest="/tmp/oci-dicom-stack-${namespace}.yaml"
remote_calico_dir="/tmp/oci-dicom-calico-${namespace}"
oci_dicom_prepare_ssh_trust "${terraform_dir}"

cleanup() {
  ssh \
    -i "${private_key}" \
    "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
    "${ssh_user}@${bastion_ip}" \
    "rm -f '${remote_manifest}'; rm -rf '${remote_calico_dir}'" >/dev/null 2>&1 || true
  rm -rf "${temporary_dir}"
}
trap cleanup EXIT

terraform -chdir="${terraform_dir}" output -raw oke_manifest >"${manifest_file}"
chmod 600 "${manifest_file}"

ssh \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${ssh_user}@${bastion_ip}" \
  "rm -rf '${remote_calico_dir}'; mkdir -m 700 -p '${remote_calico_dir}/${calico_profile}' '${remote_calico_dir}/policy-only'"

scp \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${project_dir}/kubernetes/calico/policy-only/kustomization.yaml" \
  "${ssh_user}@${bastion_ip}:${remote_calico_dir}/policy-only/kustomization.yaml"

scp \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${calico_source_dir}/kustomization.yaml" \
  "${ssh_user}@${bastion_ip}:${remote_calico_dir}/${calico_profile}/kustomization.yaml"

scp \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${manifest_file}" \
  "${ssh_user}@${bastion_ip}:${remote_manifest}"

ssh \
  -i "${private_key}" \
  "${OCI_DICOM_SSH_TRUST_OPTIONS[@]}" \
  "${ssh_user}@${bastion_ip}" \
  bash -s -- "${remote_manifest}" "${namespace}" "${expected_nlb_ip}" "${remote_calico_dir}" "${calico_profile}" <<'REMOTE'
set -euo pipefail
manifest_file="$1"
namespace="$2"
expected_nlb_ip="$3"
calico_dir="$4"
calico_profile="$5"

/usr/local/bin/kubectl apply -k "${calico_dir}/${calico_profile}"
/usr/local/bin/kubectl -n kube-system rollout status \
  daemonset/calico-node \
  --timeout=15m
/usr/local/bin/kubectl -n kube-system rollout status \
  deployment/calico-kube-controllers \
  --timeout=15m
rm -rf "${calico_dir}"

chmod 600 "${manifest_file}"
bootstrap_job="$(awk '
  $1 == "kind:" && $2 == "Job" { in_job = 1; next }
  in_job && $1 == "name:" { print $2; exit }
' "${manifest_file}")"
[[ "${bootstrap_job}" =~ ^keycloak-database-bootstrap-[a-f0-9]{12}$ ]] || {
  printf 'Unable to identify the Keycloak bootstrap Job in %s.\n' \
    "${manifest_file}" >&2
  exit 1
}

if /usr/local/bin/kubectl -n "${namespace}" get \
  "job/${bootstrap_job}" >/dev/null 2>&1; then
  bootstrap_complete="$(
    /usr/local/bin/kubectl -n "${namespace}" get \
      "job/${bootstrap_job}" \
      --output=jsonpath='{.status.succeeded}'
  )"
  if [[ "${bootstrap_complete}" != "1" ]]; then
    /usr/local/bin/kubectl -n "${namespace}" delete \
      "job/${bootstrap_job}" \
      --wait=true
  fi
fi

/usr/local/bin/kubectl apply -f "${manifest_file}"
rm -f "${manifest_file}"

/usr/local/bin/kubectl -n "${namespace}" wait \
  --for=condition=complete \
  "job/${bootstrap_job}" \
  --timeout=15m

while IFS= read -r stale_job; do
  [[ "${stale_job}" == "job.batch/${bootstrap_job}" ]] && continue
  /usr/local/bin/kubectl -n "${namespace}" delete \
    "${stale_job}" \
    --ignore-not-found \
    --wait=false
done < <(
  /usr/local/bin/kubectl -n "${namespace}" get jobs \
    --selector=app.kubernetes.io/name=keycloak-database-bootstrap \
    --output=name
)

for deployment in keycloak orthanc-auth-service orthanc dicom-gateway; do
  /usr/local/bin/kubectl -n "${namespace}" rollout status \
    "deployment/${deployment}" \
    --timeout=20m
done

for attempt in $(seq 1 60); do
  actual_nlb_ip="$(
    /usr/local/bin/kubectl -n "${namespace}" get service dicom-gateway \
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

/usr/local/bin/kubectl -n "${namespace}" describe service dicom-gateway >&2
printf 'OKE internal NLB did not acquire reserved IP %s within 10 minutes.\n' \
  "${expected_nlb_ip}" >&2
exit 1
REMOTE

"${project_dir}/scripts/reconcile-keycloak-oci-mappers.sh"

printf 'OKE Orthanc, authorization service, Keycloak, and NLB deployment completed.\n'
