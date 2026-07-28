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
