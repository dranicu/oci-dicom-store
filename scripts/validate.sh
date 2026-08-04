#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"

terraform -chdir="${terraform_dir}" fmt -check -recursive
terraform -chdir="${terraform_dir}" init -backend=false
terraform -chdir="${terraform_dir}" validate

for script_file in "${project_dir}"/scripts/*.sh; do
  bash -n "${script_file}"
done

for json_file in "${project_dir}"/tests/fixtures/*.json; do
  jq -e . "${json_file}" >/dev/null
done

for test_script in "${project_dir}"/tests/*-test.sh; do
  bash "${test_script}"
done

if command -v ansible-playbook >/dev/null 2>&1; then
  ANSIBLE_CONFIG="${project_dir}/ansible/ansible.cfg" \
    ansible-playbook \
      --syntax-check \
      -i "${project_dir}/ansible/inventory/validation.yml" \
      "${project_dir}/ansible/playbooks/bastion.yml"
else
  printf 'Warning: ansible-playbook is unavailable; skipped bastion syntax check.\n' >&2
fi

printf 'Static validation passed.\n'
