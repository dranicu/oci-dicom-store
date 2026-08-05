#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
check_only=false

if [[ "${1:-}" == "--check" ]]; then
  check_only=true
  shift
fi
[[ $# -eq 0 ]] || {
  printf 'Usage: reconcile-keycloak-oci-mappers.sh [--check]\n' >&2
  exit 2
}

for command_name in curl jq terraform; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 1
  }
done

broker_config="$(terraform -chdir="${terraform_dir}" output -json keycloak_oci_broker)"
if [[ "$(jq -r '.enabled' <<<"${broker_config}")" != "true" ]]; then
  printf 'OCI IAM SSO is disabled; no Keycloak broker mappers to reconcile.\n'
  exit 0
fi

keycloak_url="$(terraform -chdir="${terraform_dir}" output -raw keycloak_endpoint)"
admin_username="$(terraform -chdir="${terraform_dir}" output -raw keycloak_admin_username)"
admin_password="$(terraform -chdir="${terraform_dir}" output -raw keycloak_admin_password)"
desired_scope="$(jq -er '.default_scope' <<<"${broker_config}")"
desired_mappers="$(jq -ec '.mappers' <<<"${broker_config}")"

admin_token="$(curl -fsS \
  -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode 'client_id=admin-cli' \
  --data-urlencode "username=${admin_username}" \
  --data-urlencode "password=${admin_password}" \
  "${keycloak_url}/realms/master/protocol/openid-connect/token" | \
  jq -er '.access_token')"

api_root="${keycloak_url}/admin/realms/orthanc"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-keycloak-reconcile.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

request() {
  local method="$1"
  local path="$2"
  local body_file="${3:-}"
  local response_file="${temporary_dir}/response.json"
  local status
  local curl_args=(
    --silent
    --show-error
    --output "${response_file}"
    --write-out '%{http_code}'
    -X "${method}"
    -H "Authorization: Bearer ${admin_token}"
  )
  if [[ -n "${body_file}" ]]; then
    curl_args+=(
      -H 'Content-Type: application/json'
      --data-binary "@${body_file}"
    )
  fi
  status="$(curl "${curl_args[@]}" "${api_root}${path}")"
  if [[ "${status}" != "200" && "${status}" != "201" && "${status}" != "204" ]]; then
    printf 'Keycloak Admin API %s %s returned HTTP %s.\n' \
      "${method}" "${path}" "${status}" >&2
    jq . "${response_file}" >&2 2>/dev/null || true
    exit 1
  fi
  cat "${response_file}"
}

if [[ "${check_only}" == false ]]; then
  # Realm import is bootstrap-only. Reconcile the existing broker explicitly
  # so changes apply to a running stack as well as a new realm.
  idp_file="${temporary_dir}/identity-provider.json"
  request GET '/identity-provider/instances/oci' | \
    jq --arg scope "${desired_scope}" '.config.defaultScope = $scope' >"${idp_file}"
  request PUT '/identity-provider/instances/oci' "${idp_file}" >/dev/null

  existing_mappers="$(request GET '/identity-provider/instances/oci/mappers')"
  while IFS= read -r desired_mapper; do
    mapper_name="$(jq -er '.name' <<<"${desired_mapper}")"
    mapper_id="$(jq -r --arg name "${mapper_name}" \
      '.[] | select(.name == $name) | .id' <<<"${existing_mappers}")"
    mapper_file="${temporary_dir}/mapper.json"

    if [[ -n "${mapper_id}" ]]; then
      jq --arg id "${mapper_id}" '. + {id: $id}' \
        <<<"${desired_mapper}" >"${mapper_file}"
      request PUT \
        "/identity-provider/instances/oci/mappers/${mapper_id}" \
        "${mapper_file}" >/dev/null
    else
      jq . <<<"${desired_mapper}" >"${mapper_file}"
      request POST '/identity-provider/instances/oci/mappers' \
        "${mapper_file}" >/dev/null
    fi
  done < <(jq -c '.[]' <<<"${desired_mappers}")
fi

actual_idp="$(request GET '/identity-provider/instances/oci')"
[[ "$(jq -r '.config.defaultScope' <<<"${actual_idp}")" == "${desired_scope}" ]] || {
  printf 'Keycloak OCI broker scope reconciliation did not persist.\n' >&2
  exit 1
}

actual_mappers="$(request GET '/identity-provider/instances/oci/mappers')"
jq -e \
  --argjson desired "${desired_mappers}" \
  '
    . as $actual |
    [
      $desired[] as $expected |
      any($actual[];
          .name == $expected.name and
          .identityProviderAlias == $expected.identityProviderAlias and
          .identityProviderMapper == $expected.identityProviderMapper and
          .config.claim == $expected.config.claim and
          .config["claim.value"] == $expected.config["claim.value"] and
          .config.role == $expected.config.role and
          .config.syncMode == $expected.config.syncMode)
    ] | all
  ' <<<"${actual_mappers}" >/dev/null || {
  printf 'Keycloak OCI role mapper reconciliation did not persist.\n' >&2
  exit 1
}

if [[ "${check_only}" == true ]]; then
  printf 'OK  Keycloak OCI broker scope and %s role mappers.\n' \
    "$(jq 'length' <<<"${desired_mappers}")"
else
  printf 'Reconciled Keycloak OCI broker scope and %s role mappers.\n' \
    "$(jq 'length' <<<"${desired_mappers}")"
fi
