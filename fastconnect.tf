resource "oci_core_drg" "fastconnect" {
  count = var.enable_fastconnect ? 1 : 0

  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-fastconnect"
  freeform_tags  = local.tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "oci_core_drg_attachment" "dicom" {
  count = var.enable_fastconnect ? 1 : 0

  drg_id        = oci_core_drg.fastconnect[0].id
  display_name  = "${local.resource_name}-vcn"
  freeform_tags = local.tags

  network_details {
    id             = oci_core_vcn.dicom.id
    type           = "VCN"
    vcn_route_type = "VCN_CIDRS"
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "oci_core_virtual_circuit" "dicom" {
  count = var.enable_fastconnect ? 1 : 0

  compartment_id            = var.compartment_id
  type                      = "PRIVATE"
  display_name              = "${local.resource_name}-private"
  gateway_id                = oci_core_drg.fastconnect[0].id
  provider_service_id       = var.fastconnect_provider_service_id
  provider_service_key_name = var.fastconnect_provider_service_key_name
  bandwidth_shape_name      = var.fastconnect_bandwidth_shape_name
  customer_asn              = var.fastconnect_customer_asn
  bgp_admin_state           = "ENABLED"
  ip_mtu                    = var.fastconnect_ip_mtu
  is_bfd_enabled            = var.fastconnect_is_bfd_enabled
  is_transport_mode         = var.fastconnect_is_transport_mode
  region                    = var.region
  freeform_tags             = local.tags

  depends_on = [oci_core_drg_attachment.dicom]

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}

resource "tls_private_key" "private_ingest" {
  count = var.enable_fastconnect ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 3072
}

resource "tls_self_signed_cert" "private_ingest" {
  count = var.enable_fastconnect ? 1 : 0

  private_key_pem       = tls_private_key.private_ingest[0].private_key_pem
  validity_period_hours = 8760
  early_renewal_hours   = 720
  ip_addresses = [
    oci_load_balancer_load_balancer.orthanc.ip_address_details[0].ip_address,
  ]

  subject {
    common_name  = "${local.resource_name}-private-ingest"
    organization = "OCI DICOM"
  }

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "oci_load_balancer_certificate" "private_ingest" {
  count = var.enable_fastconnect ? 1 : 0

  load_balancer_id   = oci_load_balancer_load_balancer.orthanc.id
  certificate_name   = "private-ingest-${local.suffix}"
  private_key        = tls_private_key.private_ingest[0].private_key_pem
  public_certificate = tls_self_signed_cert.private_ingest[0].cert_pem

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "oci_load_balancer_listener" "private_ingest" {
  count = var.enable_fastconnect ? 1 : 0

  load_balancer_id         = oci_load_balancer_load_balancer.orthanc.id
  name                     = "orthanc-private-tls"
  default_backend_set_name = oci_load_balancer_backend_set.orthanc.name
  port                     = 8443
  protocol                 = "HTTP"

  connection_configuration {
    idle_timeout_in_seconds = 1200
  }

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.private_ingest[0].certificate_name
    protocols               = ["TLSv1.2"]
    server_order_preference = "ENABLED"
  }
}
