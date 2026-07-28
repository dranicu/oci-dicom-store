resource "oci_container_instances_container_instance" "orthanc" {
  count = var.orthanc_replicas

  availability_domain = data.oci_identity_availability_domains.available.availability_domains[
    count.index % length(data.oci_identity_availability_domains.available.availability_domains)
  ].name
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-orthanc-${count.index + 1}"
  shape          = var.container_shape

  container_restart_policy             = "ALWAYS"
  graceful_shutdown_timeout_in_seconds = "60"
  freeform_tags                        = local.tags

  shape_config {
    ocpus         = var.container_ocpus
    memory_in_gbs = var.container_memory_gb
  }

  vnics {
    subnet_id             = oci_core_subnet.application.id
    nsg_ids               = [oci_core_network_security_group.orthanc.id]
    is_public_ip_assigned = false
    display_name          = "${local.resource_name}-orthanc-${count.index + 1}"
  }

  volumes {
    name        = "orthanc-config"
    volume_type = "CONFIGFILE"

    configs {
      file_name = "orthanc.json"
      data      = base64encode(jsonencode(local.orthanc_configuration))
    }
  }

  containers {
    display_name                   = "orthanc"
    image_url                      = "docker.io/${var.orthanc_image}"
    is_resource_principal_disabled = true
    environment_variables = {
      MALLOC_ARENA_MAX = "5"
      VERBOSE_STARTUP  = "false"
    }

    health_checks {
      name                     = "orthanc-http"
      health_check_type        = "TCP"
      port                     = 8042
      initial_delay_in_seconds = 90
      interval_in_seconds      = 30
      timeout_in_seconds       = 5
      failure_threshold        = 5
      success_threshold        = 1
      failure_action           = "KILL"
    }

    resource_config {
      vcpus_limit         = var.container_ocpus
      memory_limit_in_gbs = var.container_memory_gb
    }

    volume_mounts {
      volume_name  = "orthanc-config"
      mount_path   = "/etc/orthanc"
      is_read_only = true
    }
  }

  depends_on = [
    oci_identity_customer_secret_key.orthanc,
    oci_identity_policy.orthanc_storage,
    oci_objectstorage_bucket.dicom,
    oci_psql_db_system.orthanc,
  ]

  lifecycle {
    create_before_destroy = true
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
