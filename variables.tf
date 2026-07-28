variable "tenancy_id" {
  description = "Tenancy OCID. Required for the least-privilege Orthanc service identity."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_id))
    error_message = "tenancy_id must be a tenancy OCID."
  }
}

variable "compartment_id" {
  description = "Compartment OCID in which the DICOM platform resources are created."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.(compartment|tenancy)\\.", var.compartment_id))
    error_message = "compartment_id must be a compartment or tenancy OCID."
  }
}

variable "region" {
  description = "OCI region identifier for the workload, for example eu-frankfurt-1."
  type        = string
}

variable "home_region" {
  description = "OCI tenancy home region. IAM writes must be sent to this region."
  type        = string
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config used for APIKey or SecurityToken authentication."
  type        = string
  default     = "DEFAULT"
}

variable "oci_auth" {
  description = "OCI provider authentication mode."
  type        = string
  default     = "APIKey"

  validation {
    condition = contains([
      "APIKey",
      "SecurityToken",
      "InstancePrincipal",
      "ResourcePrincipal",
      "OKEWorkloadIdentity",
    ], var.oci_auth)
    error_message = "oci_auth must be a supported OCI Terraform provider auth mode."
  }
}

variable "name" {
  description = "Short lowercase deployment name used in resource names."
  type        = string
  default     = "dicom"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "name must be 3-20 lowercase alphanumeric or hyphen characters and start with a letter."
  }
}

variable "vcn_cidr" {
  description = "Non-overlapping VCN CIDR."
  type        = string
  default     = "10.42.0.0/16"
}

variable "gateway_subnet_cidr" {
  description = "Regional public subnet used by API Gateway."
  type        = string
  default     = "10.42.0.0/24"
}

variable "management_subnet_cidr" {
  description = "Regional public subnet used only by the bastion VM."
  type        = string
  default     = "10.42.1.0/24"
}

variable "application_subnet_cidr" {
  description = "Regional private subnet for Orthanc container instances and the private load balancer."
  type        = string
  default     = "10.42.10.0/24"
}

variable "database_subnet_cidr" {
  description = "Regional private subnet for OCI Database with PostgreSQL."
  type        = string
  default     = "10.42.20.0/24"
}

variable "allowed_client_cidrs" {
  description = "CIDRs allowed to connect to the public API Gateway. Use hospital/VPN egress CIDRs in production."
  type        = list(string)

  validation {
    condition = length(var.allowed_client_cidrs) > 0 && alltrue([
      for cidr in var.allowed_client_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "At least one valid allowed client CIDR is required."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the OpenSSH public key installed for the bastion opc user."
  type        = string
  default     = "~/.ssh/id_rsa.pub"

  validation {
    condition = try(
      fileexists(pathexpand(var.ssh_public_key_path)) &&
      can(regex(
        "^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))\\s+",
        trimspace(file(pathexpand(var.ssh_public_key_path))),
      )),
      false,
    )
    error_message = "ssh_public_key_path must reference an existing valid OpenSSH public key file."
  }
}

variable "bastion_allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the bastion. Defaults to allowed_client_cidrs when empty."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.bastion_allowed_ssh_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every bastion_allowed_ssh_cidrs entry must be a valid CIDR."
  }
}

variable "bastion_shape" {
  description = "Flexible Compute shape used by the bastion."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "bastion_ocpus" {
  description = "OCPUs assigned to the bastion."
  type        = number
  default     = 1

  validation {
    condition     = var.bastion_ocpus >= 1
    error_message = "bastion_ocpus must be at least 1."
  }
}

variable "bastion_memory_gb" {
  description = "Memory in GiB assigned to the bastion."
  type        = number
  default     = 8

  validation {
    condition     = var.bastion_memory_gb >= 8
    error_message = "bastion_memory_gb must be at least 8 GiB."
  }
}

variable "bastion_boot_volume_gb" {
  description = "Bastion boot volume size in GiB."
  type        = number
  default     = 50

  validation {
    condition     = var.bastion_boot_volume_gb >= 50
    error_message = "bastion_boot_volume_gb must be at least 50 GiB."
  }
}

variable "bastion_os_version" {
  description = "Oracle Linux major version for the bastion."
  type        = string
  default     = "9"
}

variable "enable_fastconnect" {
  description = "Create a private FastConnect partner virtual circuit and a TLS large-file ingest path."
  type        = bool
  default     = false
}

variable "fastconnect_on_premises_cidrs" {
  description = "On-premises CIDRs advertised over FastConnect and permitted to use private ingest and bastion SSH."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.fastconnect_on_premises_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "Every fastconnect_on_premises_cidrs entry must be a valid CIDR."
  }
}

variable "fastconnect_provider_service_id" {
  description = "FastConnect partner provider-service OCID supplied by OCI/provider discovery."
  type        = string
  default     = null

  validation {
    condition = (
      var.fastconnect_provider_service_id == null ||
      can(regex("^ocid1\\.providerservice\\.", var.fastconnect_provider_service_id))
    )
    error_message = "fastconnect_provider_service_id must be a provider-service OCID."
  }
}

variable "fastconnect_provider_service_key_name" {
  description = "Optional partner activation/service key obtained from the provider portal."
  type        = string
  default     = null
  sensitive   = true
}

variable "fastconnect_bandwidth_shape_name" {
  description = "Optional partner bandwidth shape, for example 1 Gbps; omit when provider-managed."
  type        = string
  default     = null
}

variable "fastconnect_customer_asn" {
  description = "Optional customer BGP ASN; omit when the partner manages BGP."
  type        = string
  default     = null

  validation {
    condition = (
      var.fastconnect_customer_asn == null ||
      try(
        tonumber(var.fastconnect_customer_asn) >= 1 &&
        tonumber(var.fastconnect_customer_asn) <= 4294967295,
        false,
      )
    )
    error_message = "fastconnect_customer_asn must be a decimal ASN between 1 and 4294967295."
  }
}

variable "fastconnect_ip_mtu" {
  description = "Layer-3 MTU for the FastConnect virtual circuit."
  type        = string
  default     = "MTU_1500"

  validation {
    condition     = contains(["MTU_1500", "MTU_9000"], var.fastconnect_ip_mtu)
    error_message = "fastconnect_ip_mtu must be MTU_1500 or MTU_9000."
  }
}

variable "fastconnect_is_bfd_enabled" {
  description = "Enable Bidirectional Forwarding Detection when supported by the provider and on-premises router."
  type        = bool
  default     = false
}

variable "fastconnect_is_transport_mode" {
  description = "Restrict the virtual circuit to IPSec-encrypted traffic. Requires a separate IPSec-over-FastConnect design."
  type        = bool
  default     = false
}

variable "orthanc_image" {
  description = "Pinned Orthanc Team image. Avoid floating latest tags."
  type        = string
  default     = "orthancteam/orthanc:26.7.0"
}

variable "orthanc_replicas" {
  description = "Number of Orthanc container instances distributed across availability domains."
  type        = number
  default     = 2

  validation {
    condition     = var.orthanc_replicas >= 1 && var.orthanc_replicas <= 6
    error_message = "orthanc_replicas must be between 1 and 6."
  }
}

variable "container_shape" {
  description = "Flexible Container Instances shape."
  type        = string
  default     = "CI.Standard.E4.Flex"
}

variable "container_ocpus" {
  description = "OCPUs per Orthanc container instance."
  type        = number
  default     = 1
}

variable "container_memory_gb" {
  description = "Memory in GiB per Orthanc container instance."
  type        = number
  default     = 8
}

variable "orthanc_aet" {
  description = "DICOM Application Entity Title."
  type        = string
  default     = "ORTHANC"

  validation {
    condition     = length(var.orthanc_aet) >= 1 && length(var.orthanc_aet) <= 16
    error_message = "A DICOM AE title must contain between 1 and 16 characters."
  }
}

variable "orthanc_username" {
  description = "Orthanc API administrator username."
  type        = string
  default     = "orthanc-admin"
}

variable "orthanc_password" {
  description = "Optional Orthanc password. A strong random value is generated when null."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.orthanc_password == null || length(var.orthanc_password) >= 16
    error_message = "orthanc_password must be at least 16 characters when provided."
  }
}

variable "postgres_admin_username" {
  description = "PostgreSQL administrative username used by Orthanc."
  type        = string
  default     = "orthanc"
}

variable "postgres_admin_password" {
  description = "Optional PostgreSQL password. A strong random value is generated when null."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.postgres_admin_password == null || length(var.postgres_admin_password) >= 16
    error_message = "postgres_admin_password must be at least 16 characters when provided."
  }
}

variable "postgres_version" {
  description = "OCI Database with PostgreSQL major version."
  type        = string
  default     = "14"
}

variable "postgres_shape" {
  description = "OCI Database with PostgreSQL flexible shape."
  type        = string
  default     = "PostgreSQL.VM.Standard.E5.Flex"
}

variable "postgres_ocpus" {
  description = "OCPUs for each PostgreSQL instance."
  type        = number
  default     = 1
}

variable "postgres_memory_gb" {
  description = "Memory in GiB for each PostgreSQL instance."
  type        = number
  default     = 16
}

variable "postgres_instances" {
  description = "PostgreSQL instance count. Use 2 or more for production availability."
  type        = number
  default     = 2

  validation {
    condition     = var.postgres_instances >= 1 && var.postgres_instances <= 3
    error_message = "postgres_instances must be between 1 and 3."
  }
}

variable "postgres_backup_retention_days" {
  description = "Automatic PostgreSQL backup retention."
  type        = number
  default     = 14

  validation {
    condition     = var.postgres_backup_retention_days >= 1
    error_message = "postgres_backup_retention_days must be at least 1."
  }
}

variable "postgres_backup_start" {
  description = "UTC hour and minute for daily PostgreSQL backups, in HH:MM format."
  type        = string
  default     = "02:00"

  validation {
    condition = can(regex(
      "^([01][0-9]|2[0-3]):[0-5][0-9]$",
      var.postgres_backup_start,
    ))
    error_message = "postgres_backup_start must use the OCI PostgreSQL HH:MM format, for example 02:00."
  }
}

variable "postgres_maintenance_window_start" {
  description = "UTC PostgreSQL maintenance start in lowercase day HH:MM:SS format."
  type        = string
  default     = "sun 03:00:00"

  validation {
    condition = can(regex(
      "^(mon|tue|wed|thu|fri|sat|sun) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$",
      var.postgres_maintenance_window_start,
    ))
    error_message = "postgres_maintenance_window_start must use day HH:MM:SS, for example sun 03:00:00."
  }
}

variable "object_storage_bucket_name" {
  description = "Optional explicit bucket name. A regionally unique suffix is added when null."
  type        = string
  default     = null
}

variable "storage_compartment_id" {
  description = "Compartment for the DICOM bucket. Defaults to the Object Storage namespace's configured S3 compartment."
  type        = string
  default     = null
}

variable "create_storage_identity" {
  description = "Create a dedicated OCI IAM user, group, policy, and Customer Secret Key for Orthanc."
  type        = bool
  default     = true
}

variable "storage_identity_email" {
  description = "Unique primary email for the generated OCI IAM service user. Required by identity domains when create_storage_identity is true."
  type        = string
  default     = null

  validation {
    condition = (
      var.storage_identity_email == null ||
      can(regex(
        "^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$",
        var.storage_identity_email,
      ))
    )
    error_message = "storage_identity_email must be a syntactically valid email address."
  }
}

variable "storage_access_key" {
  description = "Existing OCI Customer Secret Key access key. Required when create_storage_identity is false."
  type        = string
  default     = null
  sensitive   = true
}

variable "storage_secret_key" {
  description = "Existing OCI Customer Secret Key secret. Required when create_storage_identity is false."
  type        = string
  default     = null
  sensitive   = true
}

variable "enable_object_versioning" {
  description = "Enable Object Storage versioning to protect images from accidental overwrite or deletion."
  type        = bool
  default     = true
}

variable "load_balancer_min_bandwidth_mbps" {
  description = "Minimum flexible load balancer bandwidth."
  type        = number
  default     = 10
}

variable "load_balancer_max_bandwidth_mbps" {
  description = "Maximum flexible load balancer bandwidth."
  type        = number
  default     = 100
}

variable "api_rate_limit_rps" {
  description = "Per-client API Gateway request rate."
  type        = number
  default     = 100
}

variable "cors_allowed_origins" {
  description = "Optional browser origins allowed by API Gateway. Leave empty for no CORS policy."
  type        = list(string)
  default     = []
}

variable "alarm_notification_topic_id" {
  description = "Optional Notifications topic OCID for unhealthy backend and 5xx alarms."
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Additional free-form tags applied to resources."
  type        = map(string)
  default     = {}
}
