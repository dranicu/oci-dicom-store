#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-destroy-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

command_log="${temporary_dir}/commands.log"
export DESTROY_TEST_COMMAND_LOG="${command_log}"

mkdir -p "${temporary_dir}/bin"

cat >"${temporary_dir}/bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform' >>"${DESTROY_TEST_COMMAND_LOG}"
printf ' %q' "$@" >>"${DESTROY_TEST_COMMAND_LOG}"
printf '\n' >>"${DESTROY_TEST_COMMAND_LOG}"
STUB

cat >"${temporary_dir}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh must not be called during destroy\n' >&2
exit 99
STUB

cat >"${temporary_dir}/bin/oci" <<'STUB'
#!/usr/bin/env bash
printf 'OCI CLI must not be called without --purge-bucket\n' >&2
exit 98
STUB

chmod 0700 "${temporary_dir}/bin/terraform" \
  "${temporary_dir}/bin/ssh" \
  "${temporary_dir}/bin/oci"

PATH="${temporary_dir}/bin:${PATH}" \
  BASTION_SSH_PRIVATE_KEY_FILE=/does/not/exist \
  "${project_dir}/scripts/destroy.sh" --auto-approve

expected_commands=$'terraform init\nterraform plan -destroy\nterraform destroy -auto-approve'
actual_commands="$(<"${command_log}")"

[[ "${actual_commands}" == "${expected_commands}" ]] || {
  printf 'Unexpected destroy command sequence:\n%s\n' "${actual_commands}" >&2
  exit 1
}

printf 'Destroy path is independent of bastion SSH and OCI CLI cleanup.\n'
