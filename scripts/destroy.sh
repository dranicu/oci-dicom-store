#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
auto_approve="false"

if [[ "${1:-}" == "--auto-approve" ]]; then
  auto_approve="true"
elif [[ -n "${1:-}" ]]; then
  printf 'Usage: scripts/destroy.sh [--auto-approve]\n' >&2
  exit 1
fi

cd "${terraform_dir}"
terraform init
terraform plan -destroy

printf '%s\n' \
  'WARNING: This destroys the DICOM platform. OCI will refuse to delete a bucket' \
  'that still contains current or versioned medical images; that safeguard is intentional.'

if [[ "${auto_approve}" == "true" ]]; then
  terraform destroy -auto-approve
  exit 0
fi

read -r -p 'Type destroy to continue: ' confirmation
[[ "${confirmation}" == "destroy" ]] || { printf 'Destroy cancelled.\n'; exit 1; }
terraform destroy
