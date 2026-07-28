locals {
  suffix = random_string.suffix.result

  resource_name = "${var.name}-${local.suffix}"
  bucket_name   = coalesce(var.object_storage_bucket_name, "${var.name}-images-${local.suffix}")

  orthanc_password = coalesce(var.orthanc_password, random_password.orthanc.result)
  postgres_password = coalesce(
    var.postgres_admin_password,
    random_password.postgres.result,
  )
  storage_access_key = var.create_storage_identity ? oci_identity_customer_secret_key.orthanc[0].id : var.storage_access_key
  storage_secret_key = var.create_storage_identity ? oci_identity_customer_secret_key.orthanc[0].key : var.storage_secret_key

  tags = merge(
    {
      "managed-by" = "terraform"
      "project"    = "oci-cloud-native-dicom"
      "deployment" = local.resource_name
    },
    var.freeform_tags,
  )

  all_service_id = data.oci_core_services.all_services.services[0].id
  bastion_ssh_public_key = trimspace(
    file(pathexpand(var.ssh_public_key_path)),
  )
  bastion_ssh_cidrs = distinct(concat(
    length(var.bastion_allowed_ssh_cidrs) > 0 ? (
      var.bastion_allowed_ssh_cidrs
    ) : var.allowed_client_cidrs,
    var.enable_fastconnect ? var.fastconnect_on_premises_cidrs : [],
  ))

  orthanc_configuration = {
    Name                  = local.resource_name
    DicomAet              = var.orthanc_aet
    DicomServerEnabled    = false
    RemoteAccessAllowed   = true
    AuthenticationEnabled = true
    RegisteredUsers = {
      (var.orthanc_username) = local.orthanc_password
    }
    StableAge              = 2
    StrictAetComparison    = true
    HttpCompressionEnabled = true
    MetricsEnabled         = true
    ExecuteLuaEnabled      = false

    DicomWeb = {
      Enable = true
      Root   = "/dicom-web/"
    }

    PostgreSQL = {
      EnableIndex              = true
      EnableStorage            = false
      Host                     = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
      Port                     = 5432
      Database                 = "postgres"
      Username                 = var.postgres_admin_username
      Password                 = local.postgres_password
      EnableSsl                = true
      Lock                     = false
      MaximumConnectionRetries = 60
      ConnectionRetryInterval  = 5
      IndexConnectionsCount    = 20
      TransactionMode          = "ReadCommitted"
      ApplicationName          = local.resource_name
    }

    AwsS3Storage = {
      BucketName        = oci_objectstorage_bucket.dicom.name
      Region            = var.region
      Endpoint          = "https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oci.customer-oci.com"
      AccessKey         = local.storage_access_key
      SecretKey         = local.storage_secret_key
      ConnectionTimeout = 30
      RequestTimeout    = 1200
      MaxConnections    = 25
      MaxRetries        = 10
      StorageStructure  = "flat"
      VirtualAddressing = false
    }
  }
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "random_password" "orthanc" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#%+-.:=?@_"
}

resource "random_password" "postgres" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#%+-.:=?@_"
}

check "storage_credentials" {
  assert {
    condition = (
      var.create_storage_identity ||
      (var.storage_access_key != null && var.storage_secret_key != null)
    )
    error_message = "Set both storage_access_key and storage_secret_key when create_storage_identity is false."
  }
}

check "fastconnect_inputs" {
  assert {
    condition = !var.enable_fastconnect || (
      var.fastconnect_provider_service_id != null &&
      length(var.fastconnect_on_premises_cidrs) > 0
    )
    error_message = "When enable_fastconnect is true, set fastconnect_provider_service_id and at least one fastconnect_on_premises_cidrs entry."
  }
}
