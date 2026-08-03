#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
private_key="${BASTION_SSH_PRIVATE_KEY_FILE:-}"

if [[ "${1:-}" == "--private-key" ]]; then
  [[ $# -ge 2 ]] || { printf '%s\n' '--private-key requires a path' >&2; exit 2; }
  private_key="$2"
  shift 2
fi

[[ -n "${private_key}" && -f "${private_key}" ]] || {
  printf 'Set BASTION_SSH_PRIVATE_KEY_FILE or pass --private-key PATH.\n' >&2
  exit 2
}

bastion_ip="$(terraform -chdir="${terraform_dir}" output -raw bastion_public_ip)"
known_hosts_file="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-known-hosts.XXXXXX")"
trap 'rm -f "${known_hosts_file}"' EXIT

ssh \
  -i "${private_key}" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${known_hosts_file}" \
  opc@"${bastion_ip}" \
  "$@"
