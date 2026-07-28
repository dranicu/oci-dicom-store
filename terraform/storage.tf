resource "oci_objectstorage_bucket" "dicom" {
  compartment_id = local.storage_compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = local.bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = var.enable_object_versioning ? "Enabled" : "Disabled"
  auto_tiering   = "Disabled"

  object_events_enabled = true
  freeform_tags         = local.tags

  lifecycle {
    precondition {
      condition = (
        data.oci_objectstorage_namespace_metadata.this.default_s3compartment_id == null ||
        data.oci_objectstorage_namespace_metadata.this.default_s3compartment_id == "" ||
        local.storage_compartment_id == data.oci_objectstorage_namespace_metadata.this.default_s3compartment_id
      )
      error_message = "storage_compartment_id must match Object Storage namespace default_s3compartment_id for Orthanc's S3-compatible API access."
    }
  }
}
