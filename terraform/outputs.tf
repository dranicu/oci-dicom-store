output "api_endpoint" {
  description = "Orthanc HTTPS endpoint."
  value       = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc"
}

output "dicomweb_endpoint" {
  description = "DICOMweb service root."
  value       = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc/dicom-web"
}

output "private_orthanc_endpoint" {
  description = "Private Orthanc endpoint reachable from the bastion and connected VCN networks."
  value       = "http://${local.nlb_private_ip}:8080/orthanc"
}

output "fastconnect_private_ingest_endpoint" {
  description = "TLS private DICOMweb/Orthanc endpoint for FastConnect clients; null when disabled."
  value = var.enable_fastconnect ? (
    "https://${local.nlb_private_ip}:8443/orthanc"
  ) : null
}

output "fastconnect_private_ingest_certificate" {
  description = "Self-signed certificate to trust when connecting to the FastConnect private-ingest endpoint."
  value       = var.enable_fastconnect ? tls_self_signed_cert.private_ingest[0].cert_pem : null
}

output "fastconnect_status" {
  description = "FastConnect identifiers and provider/BGP lifecycle; null when disabled."
  value = var.enable_fastconnect ? {
    drg_id             = oci_core_drg.fastconnect[0].id
    drg_attachment_id  = oci_core_drg_attachment.dicom[0].id
    virtual_circuit_id = oci_core_virtual_circuit.dicom[0].id
    lifecycle_state    = oci_core_virtual_circuit.dicom[0].state
    provider_state     = oci_core_virtual_circuit.dicom[0].provider_state
    bgp_session_state  = oci_core_virtual_circuit.dicom[0].bgp_session_state
  } : null
}

output "bastion_public_ip" {
  description = "Public IPv4 address of the operator bastion."
  value       = oci_core_instance.bastion.public_ip
}

output "bastion_private_ip" {
  description = "Private IPv4 address of the operator bastion."
  value       = oci_core_instance.bastion.private_ip
}

output "bastion_ssh_command" {
  description = "SSH command prefix; add -i with the private key matching ssh_public_key_path."
  value       = "ssh opc@${oci_core_instance.bastion.public_ip}"
}

output "orthanc_username" {
  description = "Initial Keycloak user assigned the orthanc-admin role."
  value       = var.orthanc_username
}

output "postgres_username" {
  description = "PostgreSQL administrator username."
  value       = var.postgres_admin_username
}

output "orthanc_password" {
  description = "Generated or supplied initial Keycloak Orthanc administrator password."
  value       = local.orthanc_password
  sensitive   = true
}

output "keycloak_endpoint" {
  description = "Keycloak identity-provider endpoint and administration console root."
  value       = "${local.public_base_url}/keycloak"
}

output "keycloak_admin_username" {
  description = "Keycloak master-realm bootstrap administrator."
  value       = "keycloak-admin"
}

output "keycloak_admin_password" {
  description = "Generated Keycloak master-realm bootstrap administrator password."
  value       = local.keycloak_admin_password
  sensitive   = true
}

output "oci_sso" {
  description = "Non-secret OCI IAM Identity Domains SSO configuration and role-group mapping."
  value = {
    enabled             = local.oci_sso_enabled
    identity_domain_id  = local.oci_sso_enabled ? data.oci_identity_domain.orthanc_sso[0].id : null
    identity_domain_url = local.oci_sso_domain_url
    discovery_url       = local.oci_sso_enabled ? "${local.oci_sso_domain_url}/.well-known/openid-configuration" : null
    client_id           = local.oci_sso_enabled ? oci_identity_domains_app.orthanc_sso[0].name : null
    callback_url        = local.oci_sso_callback_url
    group_names         = local.oci_sso_roles
    orthanc_login_url   = "${local.public_base_url}/orthanc/ui/app/"
  }
}

output "s3_compatibility_endpoint" {
  description = "OCI Object Storage S3 compatibility endpoint used by Orthanc."
  value       = local.s3_compatibility_endpoint
}

output "oke_cluster_id" {
  description = "OKE cluster OCID."
  value       = oci_containerengine_cluster.orthanc.id
}

output "oke_manifest" {
  description = "Rendered sensitive Kubernetes manifest consumed by scripts/deploy-oke.sh."
  value       = local.oke_manifest
  sensitive   = true
}

output "postgres_password" {
  description = "Generated or supplied PostgreSQL administrator password."
  value       = local.postgres_password
  sensitive   = true
}

output "resource_ocids" {
  description = "OCIDs of the deployed resources for inventory and cleanup."
  value = {
    vcn                 = oci_core_vcn.dicom.id
    gateway_subnet      = oci_core_subnet.gateway.id
    management_subnet   = oci_core_subnet.management.id
    application_subnet  = oci_core_subnet.application.id
    oke_api_subnet      = oci_core_subnet.oke_api.id
    oke_nodes_subnet    = oci_core_subnet.oke_nodes.id
    oke_pods_subnet     = oci_core_subnet.oke_pods.id
    database_subnet     = oci_core_subnet.database.id
    bastion             = oci_core_instance.bastion.id
    drg                 = try(oci_core_drg.fastconnect[0].id, null)
    drg_attachment      = try(oci_core_drg_attachment.dicom[0].id, null)
    virtual_circuit     = try(oci_core_virtual_circuit.dicom[0].id, null)
    api_gateway         = oci_apigateway_gateway.orthanc.id
    api_deployment      = oci_apigateway_deployment.orthanc.id
    keycloak_deployment = oci_apigateway_deployment.keycloak.id
    reserved_nlb_ip     = oci_core_private_ip.orthanc_nlb.id
    oke_cluster         = oci_containerengine_cluster.orthanc.id
    oke_node_pool       = oci_containerengine_node_pool.orthanc.id
    postgres            = oci_psql_db_system.orthanc.id
    bucket              = oci_objectstorage_bucket.dicom.id
    log_group           = oci_logging_log_group.dicom.id
    oci_sso_app         = local.oci_sso_enabled ? coalesce(oci_identity_domains_app.orthanc_sso[0].ocid, oci_identity_domains_app.orthanc_sso[0].id) : null
    oci_sso_groups = {
      for role, group in oci_identity_domains_group.orthanc_sso :
      role => coalesce(group.ocid, group.id)
    }
  }
}

output "deployment_summary" {
  description = "Non-secret deployment summary."
  value = {
    name                = local.resource_name
    region              = var.region
    bastion_public_ip   = oci_core_instance.bastion.public_ip
    bastion_ssh_command = "ssh opc@${oci_core_instance.bastion.public_ip}"
    api_endpoint        = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc"
    dicomweb_endpoint   = "https://${oci_apigateway_gateway.orthanc.hostname}/orthanc/dicom-web"
    keycloak_endpoint   = "${local.public_base_url}/keycloak"
    oci_sso_enabled     = local.oci_sso_enabled
    oci_sso_domain      = local.oci_sso_domain_url
    oci_sso_groups      = local.oci_sso_roles
    private_endpoint    = "http://${local.nlb_private_ip}:8080/orthanc"
    private_ingest_endpoint = var.enable_fastconnect ? (
      "https://${local.nlb_private_ip}:8443/orthanc"
    ) : null
    bucket_name            = oci_objectstorage_bucket.dicom.name
    namespace              = data.oci_objectstorage_namespace.this.namespace
    s3_endpoint            = local.s3_compatibility_endpoint
    oke_cluster_id         = oci_containerengine_cluster.orthanc.id
    oke_node_pool_id       = oci_containerengine_node_pool.orthanc.id
    oke_kubernetes_version = var.oke_kubernetes_version
    oke_node_image         = local.oke_node_image_name
    bastion_kubectl_arch   = local.bastion_kubectl_arch
    nlb_private_ip         = local.nlb_private_ip
    postgres_private_ip    = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
    replicas               = var.orthanc_replicas
  }
}
