data "oci_identity_users" "storage_email" {
  count    = var.create_storage_identity ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_id

  filter {
    name   = "email"
    values = [coalesce(var.storage_identity_email, "unset@example.invalid")]
  }
}

resource "oci_identity_user" "orthanc" {
  count    = var.create_storage_identity ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_id
  name           = "${local.resource_name}-storage"
  description    = "Service identity for ${local.resource_name} Orthanc Object Storage access"
  email          = var.storage_identity_email
  freeform_tags  = local.tags

  lifecycle {
    precondition {
      condition = (
        var.storage_identity_email != null &&
        alltrue([
          for user in data.oci_identity_users.storage_email[0].users :
          user.name == "${local.resource_name}-storage"
        ])
      )
      error_message = "storage_identity_email must be set and cannot belong to another OCI IAM user. Use a unique, monitored address or alias."
    }
  }
}

resource "oci_identity_group" "orthanc" {
  count    = var.create_storage_identity ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_id
  name           = "${local.resource_name}-storage"
  description    = "Least-privilege Object Storage access for ${local.resource_name}"
}

resource "oci_identity_user_group_membership" "orthanc" {
  count    = var.create_storage_identity ? 1 : 0
  provider = oci.home

  group_id = oci_identity_group.orthanc[0].id
  user_id  = oci_identity_user.orthanc[0].id
}

resource "oci_identity_policy" "orthanc_storage" {
  count    = var.create_storage_identity ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_id
  name           = "${local.resource_name}-storage"
  description    = "Allow only the Orthanc service identity to access its DICOM image bucket"
  statements = [
    "Allow group ${oci_identity_group.orthanc[0].name} to read buckets in compartment id ${local.storage_compartment_id} where target.bucket.name = '${local.bucket_name}'",
    "Allow group ${oci_identity_group.orthanc[0].name} to manage objects in compartment id ${local.storage_compartment_id} where target.bucket.name = '${local.bucket_name}'",
  ]
  freeform_tags = local.tags
}

resource "oci_identity_customer_secret_key" "orthanc" {
  count    = var.create_storage_identity ? 1 : 0
  provider = oci.home

  user_id      = oci_identity_user.orthanc[0].id
  display_name = "${local.resource_name}-orthanc-s3"

  depends_on = [
    oci_identity_user_group_membership.orthanc,
    oci_identity_policy.orthanc_storage,
  ]
}
