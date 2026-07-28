#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy.sh [--auto-approve | --plan-only] [terraform arguments...]

Creates a reviewed Terraform plan and, unless --plan-only is used, applies it.
Pass --auto-approve for non-interactive automation.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plan_file="${project_dir}/dicom.tfplan"
mode="interactive"
terraform_args=()

while (($#)); do
  case "$1" in
    --auto-approve)
      mode="auto"
      ;;
    --plan-only)
      mode="plan"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      terraform_args+=("$1")
      ;;
  esac
  shift
done

for command_name in terraform jq curl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  fi
done

if [[ ! -f "${project_dir}/terraform.tfvars" ]] &&
   [[ -z "${TF_VAR_tenancy_id:-}" || -z "${TF_VAR_compartment_id:-}" ]]; then
  printf 'Create terraform.tfvars from terraform.tfvars.example or export required TF_VAR_* values.\n' >&2
  exit 1
fi

cd "${project_dir}"
terraform fmt -check -recursive
terraform init
terraform validate
terraform plan -out="${plan_file}" "${terraform_args[@]}"

plan_json="$(terraform show -json "${plan_file}")"
identity_plan="$(
  jq -r '
    [
      .resource_changes[]?
      | select(.address == "oci_identity_user.orthanc[0]")
      | .change.after
      | [.compartment_id, .email, (.id // "")]
      | @tsv
    ][0] // ""
  ' <<<"${plan_json}"
)"

if [[ -n "${identity_plan}" ]]; then
  if ! command -v oci >/dev/null 2>&1; then
    printf 'OCI CLI is required when create_storage_identity is true.\n' >&2
    exit 1
  fi

  IFS=$'\t' read -r identity_tenancy identity_email managed_user_id \
    <<<"${identity_plan}"
  oci_auth="$(jq -r '.variables.oci_auth.value' <<<"${plan_json}")"
  oci_profile="$(jq -r '.variables.oci_profile.value' <<<"${plan_json}")"
  oci_args=()

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
  esac

  identity_email_collision="$(
    oci "${oci_args[@]}" iam user list \
      --compartment-id "${identity_tenancy}" \
      --all \
      --output json |
      jq -r \
        --arg email "${identity_email}" \
        --arg managed_user_id "${managed_user_id}" \
        '
          [
            .data[]
            | select(.email == $email)
            | .id
            | select(. != $managed_user_id)
          ]
          | length > 0
        '
  )"

  if [[ "${identity_email_collision}" == "true" ]]; then
    printf '%s\n' \
      'storage_identity_email is already assigned to another OCI IAM user.' \
      'Set a unique, monitored address or alias before applying.' >&2
    exit 1
  fi
fi

if [[ "${mode}" == "plan" ]]; then
  printf 'Plan saved to %s\n' "${plan_file}"
  exit 0
fi

if [[ "${mode}" == "auto" ]]; then
  terraform apply -auto-approve "${plan_file}"
else
  terraform apply "${plan_file}"
fi

terraform output deployment_summary

if [[ -n "${BASTION_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  printf '\nConfiguring the operator bastion with Ansible...\n'
  "${project_dir}/scripts/configure-bastion.sh" \
    --private-key "${BASTION_SSH_PRIVATE_KEY_FILE}"
else
  printf '\nBastion VM created. Configure it with:\n'
  printf 'scripts/configure-bastion.sh --private-key /path/to/private/key\n'
fi

printf '\nRun scripts/verify.sh to check the deployed control plane and DICOM APIs.\n'
