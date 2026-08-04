#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
auto_approve="false"
purge_bucket="false"
destroy_plan=""

usage() {
  cat <<'USAGE'
Usage: scripts/destroy.sh [--auto-approve] [--purge-bucket]

By default, Object Storage data is preserved and OCI rejects deletion of a
non-empty bucket. --purge-bucket permanently deletes the bucket, every current
and versioned object, pre-authenticated request, replication policy, and
uncommitted multipart upload before Terraform destroys the remaining stack.
USAGE
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

for command_name in jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  fi
done

destroy_plan="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-destroy.XXXXXX")"
trap 'rm -f "${destroy_plan}"' EXIT
terraform plan -destroy -out="${destroy_plan}"
plan_json="$(terraform show -json "${destroy_plan}")"

resource_before() {
  local address="$1"
  jq -c --arg address "${address}" '
    [
      .resource_changes[]?
      | select(.address == $address)
      | select(.change.actions == ["delete"])
      | .change.before
    ][0] // null
  ' <<<"${plan_json}"
}

bucket_before="$(resource_before 'oci_objectstorage_bucket.dicom')"
private_ip_before="$(resource_before 'oci_core_private_ip.orthanc_nlb')"
sso_app_before="$(resource_before 'oci_identity_domains_app.orthanc_sso[0]')"
oke_cluster_before="$(resource_before 'oci_containerengine_cluster.orthanc')"
oke_node_pool_before="$(resource_before 'oci_containerengine_node_pool.orthanc')"

needs_oci="false"
if [[ "${purge_bucket}" == "true" && "${bucket_before}" != "null" ]] || \
   [[ "${private_ip_before}" != "null" ]] || \
   [[ "${sso_app_before}" != "null" ]]; then
  needs_oci="true"
fi

if [[ "${needs_oci}" == "true" ]]; then
  if ! command -v oci >/dev/null 2>&1; then
    printf 'Required command is missing: oci\n' >&2
    exit 1
  fi

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
fi

bucket_name=""
namespace=""
if [[ "${purge_bucket}" == "true" && "${bucket_before}" != "null" ]]; then
  bucket_name="$(jq -r '.name' <<<"${bucket_before}")"
  namespace="$(jq -r '.namespace' <<<"${bucket_before}")"

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
elif [[ "${purge_bucket}" == "true" ]]; then
  printf 'No managed Object Storage bucket is present in the destroy plan.\n'
else
  printf '%s\n' \
    'WARNING: This destroys the DICOM platform. OCI will refuse to delete a bucket' \
    'that still contains current or versioned medical images; that safeguard is intentional.' \
    'Use --purge-bucket only after an approved data-retention/decommission process.'
fi

if [[ "${auto_approve}" != "true" ]]; then
  read -r -p 'Type destroy to continue: ' confirmation
  [[ "${confirmation}" == "destroy" ]] || { printf 'Destroy cancelled.\n'; exit 1; }
fi

if [[ -n "${bucket_name}" ]]; then
  oci "${oci_args[@]}" os bucket delete \
    --namespace-name "${namespace}" \
    --bucket-name "${bucket_name}" \
    --empty \
    --force
fi

if [[ "${sso_app_before}" != "null" ]]; then
  sso_app_id="$(jq -r '.id' <<<"${sso_app_before}")"
  sso_endpoint="$(jq -r '.idcs_endpoint' <<<"${sso_app_before}")"
  sso_get_error="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-sso-get.XXXXXX")"

  if sso_app_json="$(
    oci "${oci_args[@]}" --endpoint "${sso_endpoint}" \
      identity-domains app get --app-id "${sso_app_id}" 2>"${sso_get_error}"
  )"; then
    if [[ "$(jq -r '.data.active' <<<"${sso_app_json}")" == "true" ]]; then
      printf 'Deactivating OCI Identity Domains app %s before deletion...\n' "${sso_app_id}"
      oci "${oci_args[@]}" --endpoint "${sso_endpoint}" \
        identity-domains app patch \
        --app-id "${sso_app_id}" \
        --schemas '["urn:ietf:params:scim:api:messages:2.0:PatchOp"]' \
        --operations '[{"op":"replace","path":"active","value":false}]' \
        >/dev/null
    fi
  elif grep -Eq '(^|[^0-9])404([^0-9]|$)|NotAuthorizedOrNotFound' "${sso_get_error}"; then
    printf 'OCI Identity Domains app %s is already absent.\n' "${sso_app_id}"
  else
    cat "${sso_get_error}" >&2
    rm -f "${sso_get_error}"
    exit 1
  fi
  rm -f "${sso_get_error}"
fi

# Delete OKE first so its service controller cannot recreate the unmanaged NLB.
oke_targets=()
[[ "${oke_node_pool_before}" != "null" ]] && oke_targets+=('-target=oci_containerengine_node_pool.orthanc')
[[ "${oke_cluster_before}" != "null" ]] && oke_targets+=('-target=oci_containerengine_cluster.orthanc')
if ((${#oke_targets[@]})); then
  printf 'Destroying OKE before cleaning its Kubernetes-managed Network Load Balancer...\n'
  terraform destroy -auto-approve "${oke_targets[@]}"
fi

if [[ "${private_ip_before}" != "null" ]]; then
  private_ip_id="$(jq -r '.id' <<<"${private_ip_before}")"
  private_ip_address="$(jq -r '.ip_address' <<<"${private_ip_before}")"
  private_ip_compartment="$(jq -r '.compartment_id' <<<"${private_ip_before}")"
  nlb_ids="$(
    oci "${oci_args[@]}" nlb network-load-balancer list \
      --compartment-id "${private_ip_compartment}" \
      --lifecycle-state ACTIVE \
      --all |
      jq -r --arg private_ip_id "${private_ip_id}" --arg ip "${private_ip_address}" '
        (if (.data | type) == "object" then .data.items else .data end)[]?
        | select(any(."ip-addresses"[]?;
            (."reserved-ip".id // "") == $private_ip_id or
            (."ip-address" // "") == $ip))
        | .id
      '
  )"

  nlb_count="$(grep -c . <<<"${nlb_ids}" || true)"
  if ((nlb_count > 1)); then
    printf 'Refusing to delete %s NLBs matching reserved address %s (%s).\n' \
      "${nlb_count}" "${private_ip_address}" "${private_ip_id}" >&2
    exit 1
  elif ((nlb_count == 1)); then
    printf 'Deleting Kubernetes-managed NLB %s before releasing %s...\n' \
      "${nlb_ids}" "${private_ip_address}"
    oci "${oci_args[@]}" nlb network-load-balancer delete \
      --network-load-balancer-id "${nlb_ids}" \
      --force \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED \
      --max-wait-seconds 1800 \
      >/dev/null
  fi
fi

terraform destroy -auto-approve
