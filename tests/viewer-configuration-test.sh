#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-viewer-config-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
validation_public_key="${temporary_dir}/validation.pub"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE9jaURpY29tVGVzdFB1YmxpY0tleQ test' \
  >"${validation_public_key}"

viewer_expression='jsonencode({'
viewer_expression+=' ohif_data_source = local.orthanc_configuration.OHIF.DataSource,'
viewer_expression+=' ohif_router_basename = local.orthanc_configuration.OHIF.RouterBasename,'
viewer_expression+=' ohif_public_path = local.ohif_public_path,'
viewer_expression+=' ohif_enabled_in_explorer = local.orthanc_configuration.OrthancExplorer2.UiOptions.EnableOpenInOhifViewer3,'
viewer_expression+=' stone_enabled_in_explorer = local.orthanc_configuration.OrthancExplorer2.UiOptions.EnableOpenInStoneWebViewer,'
viewer_expression+=' authorization_profiles = local.orthanc_configuration.Authorization.StandardConfigurations'
viewer_expression+=' })'
viewer_configuration="$({
  terraform -chdir="${project_dir}/terraform" console \
    -state="${temporary_dir}/terraform.tfstate" \
    -var-file=terraform.tfvars.example \
    -var="ssh_public_key_path=${validation_public_key}" \
    <<<"${viewer_expression}"
} | jq -r)"

jq -e '
  .ohif_data_source == "dicom-web" and
  .ohif_router_basename == "/orthanc/ohif/" and
  .ohif_public_path == "/orthanc/ohif/" and
  .ohif_enabled_in_explorer == true and
  .stone_enabled_in_explorer == true and
  (.authorization_profiles | index("orthanc-explorer-2") != null) and
  (.authorization_profiles | index("stone-webviewer") != null) and
  (.authorization_profiles | index("ohif") != null)
' <<<"${viewer_configuration}" >/dev/null

printf 'Stone and OHIF share the authenticated DICOMweb and study-authorization configuration.\n'
