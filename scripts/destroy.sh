#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
auto_approve="false"
purge_bucket="false"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/destroy.sh [--auto-approve] [--purge-bucket]

By default, Object Storage data is preserved and OCI rejects deletion of a
non-empty bucket. --purge-bucket permanently deletes the bucket, every current
and versioned object, pre-authenticated request, replication policy, and
uncommitted multipart upload before Terraform destroys the remaining stack.
When an OKE deployment exists, set BASTION_SSH_PRIVATE_KEY_FILE so the script
can delete the Kubernetes namespace and its OCI Network Load Balancer first.
USAGE
}

cleanup_oke() {
  if ! terraform output -raw oke_cluster_id >/dev/null 2>&1; then
    return
  fi

  [[ -n "${private_key}" && -f "${private_key}" ]] || {
    printf '%s\n' \
      'An OKE deployment exists and must be removed before Terraform deletes its VCN.' \
      'Set BASTION_SSH_PRIVATE_KEY_FILE to the key for the deployed bastion and retry.' >&2
    exit 1
  }

  for command_name in jq ssh; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      printf '%s is required to clean up the OKE namespace.\n' "${command_name}" >&2
      exit 1
    }
  done

  bastion_ip="$(terraform output -raw bastion_public_ip)"
  namespace="$(terraform output -json deployment_summary | jq -r '.name')"
  temporary_known_hosts="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-known-hosts.XXXXXX")"
  trap 'rm -f "${temporary_known_hosts}"' RETURN

  printf 'Deleting OKE namespace %s and waiting for its Network Load Balancer cleanup...\n' \
    "${namespace}"
  ssh \
    -i "${private_key}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${temporary_known_hosts}" \
    "opc@${bastion_ip}" \
    "kubectl delete namespace '${namespace}' --ignore-not-found --wait=true --timeout=20m"
  rm -f "${temporary_known_hosts}"
  trap - RETURN
}

while (($#)); do
  case "$1" in
    --auto-approve)
      auto_approve="true"
      ;;
    --purge-bucket)
      purge_bucket="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

cd "${terraform_dir}"
terraform init

if [[ "${purge_bucket}" == "true" ]]; then
  for command_name in jq oci; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      printf 'Required command is missing for --purge-bucket: %s\n' "${command_name}" >&2
      exit 1
    fi
  done

  destroy_plan="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-destroy.XXXXXX")"
  trap 'rm -f "${destroy_plan}"' EXIT
  terraform plan -destroy -out="${destroy_plan}"
  plan_json="$(terraform show -json "${destroy_plan}")"
  bucket_details="$(
    jq -r '
      [
        .resource_changes[]?
        | select(.address == "oci_objectstorage_bucket.dicom")
        | select(.change.actions == ["delete"])
        | .change.before
        | [.name, .namespace]
        | @tsv
      ][0] // ""
    ' <<<"${plan_json}"
  )"

  if [[ -n "${bucket_details}" ]]; then
    IFS=$'\t' read -r bucket_name namespace <<<"${bucket_details}"
    oci_auth="$(jq -r '.variables.oci_auth.value' <<<"${plan_json}")"
    oci_profile="$(jq -r '.variables.oci_profile.value' <<<"${plan_json}")"
    region="$(jq -r '.variables.region.value' <<<"${plan_json}")"
    oci_args=(--region "${region}")

    case "${oci_auth}" in
      APIKey)
        oci_args+=(--profile "${oci_profile}" --auth api_key)
        ;;
      SecurityToken)
        oci_args+=(--profile "${oci_profile}" --auth security_token)
        ;;
      InstancePrincipal)
        oci_args+=(--auth instance_principal)
        ;;
      ResourcePrincipal)
        oci_args+=(--auth resource_principal)
        ;;
      OKEWorkloadIdentity)
        oci_args+=(--auth oke_workload_identity)
        ;;
      *)
        printf 'Unsupported OCI authentication mode: %s\n' "${oci_auth}" >&2
        exit 1
        ;;
    esac

    printf '%s\n' \
      'DANGER: bucket cleanup is irreversible.' \
      "Bucket: ${bucket_name}" \
      'Every current and versioned DICOM object, pre-authenticated request,' \
      'replication policy, and uncommitted multipart upload will be deleted.'

    if [[ "${auto_approve}" != "true" ]]; then
      read -r -p "Type purge ${bucket_name} to continue: " confirmation
      if [[ "${confirmation}" != "purge ${bucket_name}" ]]; then
        printf 'Destroy cancelled.\n'
        exit 1
      fi
    fi

    oci "${oci_args[@]}" os bucket delete \
      --namespace-name "${namespace}" \
      --bucket-name "${bucket_name}" \
      --empty \
      --force
  else
    printf 'No managed Object Storage bucket is present in the destroy plan.\n'
  fi
else
  terraform plan -destroy
  printf '%s\n' \
    'WARNING: This destroys the DICOM platform. OCI will refuse to delete a bucket' \
    'that still contains current or versioned medical images; that safeguard is intentional.' \
    'Use --purge-bucket only after an approved data-retention/decommission process.'
fi

if [[ "${auto_approve}" == "true" ]]; then
  cleanup_oke
  terraform destroy -auto-approve
  exit 0
fi

read -r -p 'Type destroy to continue: ' confirmation
[[ "${confirmation}" == "destroy" ]] || { printf 'Destroy cancelled.\n'; exit 1; }
cleanup_oke
terraform destroy
