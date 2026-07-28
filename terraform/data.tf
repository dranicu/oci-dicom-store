data "oci_identity_availability_domains" "available" {
  compartment_id = var.tenancy_id
}

data "oci_core_images" "bastion" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = var.bastion_os_version
  shape                    = var.bastion_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_id
}
