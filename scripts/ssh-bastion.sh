#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

cd "${project_dir}"
bastion_ip="$(terraform output -raw bastion_public_ip)"
exec ssh -i "${private_key}" opc@"${bastion_ip}" "$@"
