resource "oci_core_vcn" "dicom" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${local.resource_name}-vcn"
  dns_label      = "dicom${substr(local.suffix, 0, 6)}"
  freeform_tags  = local.tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-internet"
  enabled        = true
  freeform_tags  = local.tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-nat"
  freeform_tags  = local.tags
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-services"
  freeform_tags  = local.tags

  services {
    service_id = local.all_service_id
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-public-routes"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_drg.fastconnect[0].id
    }
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-private-routes"
  freeform_tags  = local.tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  route_rules {
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_drg.fastconnect[0].id
    }
  }
}

resource "oci_core_security_list" "empty" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-nsg-only"
  freeform_tags  = local.tags
}

resource "oci_core_subnet" "gateway" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.gateway_subnet_cidr
  display_name               = "${local.resource_name}-gateway"
  dns_label                  = "gateway"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "management" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.management_subnet_cidr
  display_name               = "${local.resource_name}-management"
  dns_label                  = "management"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "application" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.application_subnet_cidr
  display_name               = "${local.resource_name}-application"
  dns_label                  = "app"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_subnet" "database" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.dicom.id
  cidr_block                 = var.database_subnet_cidr
  display_name               = "${local.resource_name}-database"
  dns_label                  = "db"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  freeform_tags              = local.tags
}

resource "oci_core_network_security_group" "gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-gateway"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group" "load_balancer" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-load-balancer"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group" "orthanc" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-orthanc"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group" "postgres" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-postgres"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group" "bastion" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-bastion"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "bastion_ssh_ingress" {
  for_each = toset(local.bastion_ssh_cidrs)

  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Approved SSH administrators"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "gateway_https_ingress" {
  for_each = toset(var.allowed_client_cidrs)

  network_security_group_id = oci_core_network_security_group.gateway.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Approved DICOMweb clients"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "gateway_to_lb" {
  network_security_group_id = oci_core_network_security_group.gateway.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.load_balancer.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "API Gateway to private load balancer"

  tcp_options {
    destination_port_range {
      min = 8042
      max = 8042
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_from_gateway" {
  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.gateway.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "API Gateway to load balancer"

  tcp_options {
    destination_port_range {
      min = 8042
      max = 8042
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_to_lb" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.load_balancer.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Bastion to private Orthanc endpoint"

  tcp_options {
    destination_port_range {
      min = 8042
      max = 8042
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_from_bastion" {
  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.bastion.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Bastion to private Orthanc endpoint"

  tcp_options {
    destination_port_range {
      min = 8042
      max = 8042
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_to_private_ingest" {
  count = var.enable_fastconnect ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.load_balancer.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Bastion to TLS private ingest endpoint"

  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_private_ingest_from_bastion" {
  count = var.enable_fastconnect ? 1 : 0

  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.bastion.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Bastion to TLS private ingest endpoint"

  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_private_ingest_from_on_premises" {
  for_each = var.enable_fastconnect ? toset(var.fastconnect_on_premises_cidrs) : toset([])

  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "FastConnect TLS DICOMweb ingest"

  tcp_options {
    destination_port_range {
      min = 8443
      max = 8443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_to_orthanc" {
  network_security_group_id = oci_core_network_security_group.load_balancer.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.orthanc.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Load balancer to Orthanc"

  tcp_options {
    destination_port_range {
      min = 8042
      max = 8042
    }
  }
}

resource "oci_core_network_security_group_security_rule" "orthanc_from_lb" {
  network_security_group_id = oci_core_network_security_group.orthanc.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.load_balancer.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Load balancer to Orthanc"

  tcp_options {
    destination_port_range {
      min = 8042
      max = 8042
    }
  }
}

resource "oci_core_network_security_group_security_rule" "orthanc_to_postgres" {
  network_security_group_id = oci_core_network_security_group.orthanc.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.postgres.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Orthanc metadata index"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "postgres_from_orthanc" {
  network_security_group_id = oci_core_network_security_group.postgres.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.orthanc.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Orthanc metadata index"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_to_postgres" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.postgres.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Bastion PostgreSQL administration"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "postgres_from_bastion" {
  network_security_group_id = oci_core_network_security_group.postgres.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.bastion.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Bastion PostgreSQL administration"

  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_https_egress" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "OS packages and OCI service HTTPS"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_metadata_egress" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"
  description               = "OCI instance metadata service"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_ntp_egress" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"
  description               = "OCI NTP service"

  udp_options {
    destination_port_range {
      min = 123
      max = 123
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_dns_udp" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = var.vcn_cidr
  destination_type          = "CIDR_BLOCK"
  description               = "VCN DNS"

  udp_options {
    destination_port_range {
      min = 53
      max = 53
    }
  }
}

resource "oci_core_network_security_group_security_rule" "bastion_dns_tcp" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = var.vcn_cidr
  destination_type          = "CIDR_BLOCK"
  description               = "VCN DNS fallback"

  tcp_options {
    destination_port_range {
      min = 53
      max = 53
    }
  }
}

resource "oci_core_network_security_group_security_rule" "orthanc_https_egress" {
  network_security_group_id = oci_core_network_security_group.orthanc.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Image pull and OCI Object Storage HTTPS"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "orthanc_dns_udp" {
  network_security_group_id = oci_core_network_security_group.orthanc.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = var.vcn_cidr
  destination_type          = "CIDR_BLOCK"
  description               = "VCN DNS"

  udp_options {
    destination_port_range {
      min = 53
      max = 53
    }
  }
}

resource "oci_core_network_security_group_security_rule" "orthanc_dns_tcp" {
  network_security_group_id = oci_core_network_security_group.orthanc.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = var.vcn_cidr
  destination_type          = "CIDR_BLOCK"
  description               = "VCN DNS fallback"

  tcp_options {
    destination_port_range {
      min = 53
      max = 53
    }
  }
}
