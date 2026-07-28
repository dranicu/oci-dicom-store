#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/verify.sh [--dicom /absolute/path/to/test.dcm]

Checks the Orthanc REST and DICOMweb endpoints. With --dicom, it also uploads
one non-production DICOM instance through Orthanc's REST API.
USAGE
}

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/terraform"
dicom_file=""

while (($#)); do
  case "$1" in
    --dicom)
      [[ $# -ge 2 ]] || { printf '%s\n' '--dicom requires a file path' >&2; exit 1; }
      dicom_file="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

api_endpoint="$(terraform -chdir="${terraform_dir}" output -raw api_endpoint)"
dicomweb_endpoint="$(terraform -chdir="${terraform_dir}" output -raw dicomweb_endpoint)"
username="$(terraform -chdir="${terraform_dir}" output -raw orthanc_username)"
password="$(terraform -chdir="${terraform_dir}" output -raw orthanc_password)"

netrc_file="$(mktemp "${TMPDIR:-/tmp}/oci-dicom-netrc.XXXXXX")"
cleanup() {
  rm -f "${netrc_file}"
}
trap cleanup EXIT
chmod 600 "${netrc_file}"
hostname="${api_endpoint#https://}"
hostname="${hostname%%/*}"
printf 'machine %s login %s password %s\n' "${hostname}" "${username}" "${password}" >"${netrc_file}"

curl_common=(
  --fail
  --silent
  --show-error
  --retry 5
  --retry-all-errors
  --connect-timeout 15
  --max-time 300
  --netrc-file "${netrc_file}"
)

system_json="$(curl "${curl_common[@]}" "${api_endpoint}/system")"
jq -e '.Name and .Version' <<<"${system_json}" >/dev/null
printf 'OK  Orthanc REST: %s (%s)\n' \
  "$(jq -r '.Name' <<<"${system_json}")" \
  "$(jq -r '.Version' <<<"${system_json}")"

studies_json="$(curl "${curl_common[@]}" \
  -H 'Accept: application/dicom+json' \
  "${dicomweb_endpoint}/studies?limit=1")"
jq -e 'type == "array"' <<<"${studies_json}" >/dev/null
printf 'OK  DICOMweb QIDO-RS: %s\n' "${dicomweb_endpoint}"

if [[ -n "${dicom_file}" ]]; then
  [[ -f "${dicom_file}" ]] || { printf 'DICOM file not found: %s\n' "${dicom_file}" >&2; exit 1; }
  file_size="$(wc -c <"${dicom_file}" | tr -d ' ')"
  if ((file_size > 20000000)); then
    printf 'Refusing upload: OCI API Gateway limits request bodies to 20 MB (%s bytes supplied).\n' "${file_size}" >&2
    exit 1
  fi
  upload_json="$(curl "${curl_common[@]}" \
    -X POST \
    -H 'Content-Type: application/dicom' \
    --data-binary "@${dicom_file}" \
    "${api_endpoint}/instances")"
  jq -e '.ID or .ParentStudy' <<<"${upload_json}" >/dev/null
  printf 'OK  Test DICOM upload: %s\n' "$(jq -r '.ID // .ParentStudy' <<<"${upload_json}")"
fi

printf 'Deployment verification completed successfully.\n'
