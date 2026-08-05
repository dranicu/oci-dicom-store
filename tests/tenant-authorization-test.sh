#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
permissions="$({
  terraform -chdir="${project_dir}/terraform" console \
    -var-file=terraform.tfvars.example \
    <<<'jsonencode(local.orthanc_role_permissions)'
} | jq -r)"

jq -e '
  ."available-labels" == ["tenant-hospital-a", "tenant-hospital-b"] and
  .roles."tenant-hospital-a-viewer"."authorized-labels" == ["tenant-hospital-a"] and
  .roles."tenant-hospital-b-viewer"."authorized-labels" == ["tenant-hospital-b"] and
  .roles."tenant-hospital-a-editor"."authorized-labels" == ["tenant-hospital-a"] and
  (.roles."tenant-hospital-a-editor".permissions | index("edit-labels") | not) and
  .roles."orthanc-admin"."authorized-labels" == ["*"]
' <<<"${permissions}" >/dev/null

printf 'Tenant roles are label-scoped and only the platform administrator is global.\n'
