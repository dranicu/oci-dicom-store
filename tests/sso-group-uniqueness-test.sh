#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-sso-groups-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

terraform -chdir="${project_dir}/terraform" console \
  -state="${temporary_dir}/terraform.tfstate" \
  -var-file=terraform.tfvars.example \
  -var='oci_identity_domain_sso={identity_domain_id="ocid1.domain.oc1..test",group_names={orthanc-viewer="Same",orthanc-uploader="Same",orthanc-editor="Editors",orthanc-admin="Administrators"}}' \
  <<<'true' >"${temporary_dir}/duplicate.out" 2>&1 || true
grep -Fq 'define four' "${temporary_dir}/duplicate.out"
grep -Fq 'unique, trimmed 3-160 character group names' "${temporary_dir}/duplicate.out"

global_unique="$({
  terraform -chdir="${project_dir}/terraform" console \
    -state="${temporary_dir}/global.tfstate" \
    -var-file=terraform.tfvars.example \
    -var='oci_identity_domain_sso={identity_domain_id="ocid1.domain.oc1..test",group_names={orthanc-viewer="Tenant A - Orthanc Viewers",orthanc-uploader="Uploaders",orthanc-editor="Editors",orthanc-admin="Administrators"}}' \
    <<<'length(distinct([for group_name in values(local.oci_sso_role_labels) : lower(trimspace(group_name))])) == length(local.oci_sso_role_labels)'
})"
[[ "${global_unique}" == "false" ]]

printf 'OCI SSO group names reject both local and platform/tenant collisions.\n'
