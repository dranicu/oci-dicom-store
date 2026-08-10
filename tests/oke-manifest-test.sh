#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/oci-dicom-manifest-test.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

cat >"${temporary_dir}/main.tf" <<'HCL'
variable "template_path" { type = string }
locals {
  values = {
    namespace                     = "dicom-test"
    orthanc_replicas              = 2
    keycloak_replicas             = 2
    orthanc_image                 = "example.invalid/orthanc:1"
    orthanc_auth_service_image    = "example.invalid/auth:1"
    keycloak_image                = "example.invalid/keycloak:1"
    nginx_image                   = "example.invalid/nginx:1"
    postgres_client_image         = "example.invalid/postgres:1"
    orthanc_config_b64            = "e30="
    permissions_b64               = "e30="
    keycloak_realm_b64            = "e30="
    nginx_config_b64              = "e30="
    postgres_host                 = "10.42.20.10"
    postgres_username_b64         = "dGVzdA=="
    postgres_password_b64         = "dGVzdA=="
    keycloak_password_b64         = "dGVzdA=="
    keycloak_admin_username_b64   = "dGVzdA=="
    keycloak_admin_password_b64   = "dGVzdA=="
    orthanc_auth_users_b64        = "e30="
    orthanc_auth_secret_b64       = "dGVzdA=="
    public_base_url               = "https://example.invalid"
    nlb_private_ip                = "10.42.10.10"
    nlb_subnet_id                 = "ocid1.subnet.test"
    nlb_nsg_id                    = "ocid1.networksecuritygroup.test"
    compartment_id                = "ocid1.compartment.test"
    keycloak_trusted_proxy_cidr   = "10.42.12.0/22"
    oke_nodes_subnet_cidr         = "10.42.8.0/24"
    postgres_cidr                 = "10.42.20.10/32"
    gateway_ingress_cidrs         = ["10.42.0.0/24", "192.0.2.0/24"]
    orthanc_host_id               = "12345678"
    enable_fastconnect            = true
    private_ingest_cert_b64       = "dGVzdA=="
    private_ingest_key_b64        = "dGVzdA=="
    keycloak_bootstrap_id         = "0123456789ab"
    orthanc_config_hash           = "orthanc"
    auth_service_config_hash      = "auth"
    keycloak_config_hash          = "keycloak"
    nginx_config_hash             = "nginx"
  }
}
output "rendered" {
  value     = templatefile(var.template_path, local.values)
  sensitive = true
}
HCL

terraform -chdir="${temporary_dir}" init -backend=false >/dev/null
terraform -chdir="${temporary_dir}" apply -auto-approve \
  -var="template_path=${project_dir}/terraform/templates/stack.yaml.tftpl" >/dev/null
terraform -chdir="${temporary_dir}" output -raw rendered >"${temporary_dir}/stack.yaml"

ruby -ryaml - "${temporary_dir}/stack.yaml" <<'RUBY'
source = File.read(ARGV.fetch(0))

check_unique_keys = lambda do |node|
  if node.is_a?(Psych::Nodes::Mapping)
    keys = {}
    node.children.each_slice(2) do |key, value|
      name = key.respond_to?(:value) ? key.value : key.to_s
      raise "duplicate YAML key: #{name}" if keys[name]
      keys[name] = true
      check_unique_keys.call(value)
    end
  elsif node.respond_to?(:children) && node.children
    node.children.each { |child| check_unique_keys.call(child) }
  end
end
check_unique_keys.call(Psych.parse_stream(source))

objects = YAML.load_stream(source).compact
workloads = objects.select { |item| ["Deployment", "Job"].include?(item["kind"]) }
raise "unexpected workload count" unless workloads.length == 5
workloads.each do |workload|
  pod_spec = workload.dig("spec", "template", "spec")
  raise "service token enabled" unless pod_spec["automountServiceAccountToken"] == false
  raise "seccomp missing" unless pod_spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
  (pod_spec.fetch("initContainers", []) + pod_spec.fetch("containers")).each do |container|
    context = container.fetch("securityContext")
    raise "privilege escalation enabled" unless context["allowPrivilegeEscalation"] == false
    raise "capabilities retained" unless context.dig("capabilities", "drop") == ["ALL"]
  end
end

deployments = objects.select { |item| item["kind"] == "Deployment" }.to_h do |item|
  [item.dig("metadata", "name"), item]
end
raise "Keycloak is not HA" unless deployments.dig("keycloak", "spec", "replicas") == 2
raise "Keycloak spread missing" if deployments.dig("keycloak", "spec", "template", "spec", "topologySpreadConstraints").empty?
raise "authorization spread missing" if deployments.dig("orthanc-auth-service", "spec", "template", "spec", "topologySpreadConstraints").empty?

secret = objects.find { |item| item["kind"] == "Secret" && item.dig("metadata", "name") == "orthanc-runtime" }
raise "unused auth username remains" if secret.fetch("data").key?("auth-username")
raise "unused auth password remains" if secret.fetch("data").key?("auth-password")

policies = objects.select { |item| item["kind"] == "NetworkPolicy" }.map { |item| item.dig("metadata", "name") }.sort
expected = %w[allow-dns default-deny dicom-gateway keycloak keycloak-database-bootstrap orthanc orthanc-authorization].sort
raise "network policy set differs" unless policies == expected
RUBY

printf 'OKE manifest is valid YAML with hardened workloads and enforced policy definitions.\n'
