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
  value       = "http://${oci_load_balancer_load_balancer.orthanc.ip_address_details[0].ip_address}:8042"
}

output "fastconnect_private_ingest_endpoint" {
  description = "TLS private DICOMweb/Orthanc endpoint for FastConnect clients; null when disabled."
  value = var.enable_fastconnect ? (
    "https://${oci_load_balancer_load_balancer.orthanc.ip_address_details[0].ip_address}:8443"
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
  description = "Orthanc administrator username."
  value       = var.orthanc_username
}

output "postgres_username" {
  description = "PostgreSQL administrator username."
  value       = var.postgres_admin_username
}

output "orthanc_password" {
  description = "Generated or supplied Orthanc administrator password."
  value       = local.orthanc_password
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
    vcn                = oci_core_vcn.dicom.id
    gateway_subnet     = oci_core_subnet.gateway.id
    management_subnet  = oci_core_subnet.management.id
    application_subnet = oci_core_subnet.application.id
    database_subnet    = oci_core_subnet.database.id
    bastion            = oci_core_instance.bastion.id
    drg                = try(oci_core_drg.fastconnect[0].id, null)
    drg_attachment     = try(oci_core_drg_attachment.dicom[0].id, null)
    virtual_circuit    = try(oci_core_virtual_circuit.dicom[0].id, null)
    api_gateway        = oci_apigateway_gateway.orthanc.id
    api_deployment     = oci_apigateway_deployment.orthanc.id
    load_balancer      = oci_load_balancer_load_balancer.orthanc.id
    postgres           = oci_psql_db_system.orthanc.id
    bucket             = oci_objectstorage_bucket.dicom.id
    log_group          = oci_logging_log_group.dicom.id
    container_instances = [
      for instance in oci_container_instances_container_instance.orthanc : instance.id
    ]
    containers = [
      for instance in oci_container_instances_container_instance.orthanc : instance.containers[0].container_id
    ]
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
    private_endpoint    = "http://${oci_load_balancer_load_balancer.orthanc.ip_address_details[0].ip_address}:8042"
    private_ingest_endpoint = var.enable_fastconnect ? (
      "https://${oci_load_balancer_load_balancer.orthanc.ip_address_details[0].ip_address}:8443"
    ) : null
    bucket_name         = oci_objectstorage_bucket.dicom.name
    namespace           = data.oci_objectstorage_namespace.this.namespace
    postgres_private_ip = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
    replicas            = var.orthanc_replicas
  }
}
