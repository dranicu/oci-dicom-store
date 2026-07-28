resource "oci_load_balancer_load_balancer" "orthanc" {
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-private"
  shape          = "flexible"
  subnet_ids     = [oci_core_subnet.application.id]
  is_private     = true

  network_security_group_ids = [
    oci_core_network_security_group.load_balancer.id,
  ]

  shape_details {
    minimum_bandwidth_in_mbps = var.load_balancer_min_bandwidth_mbps
    maximum_bandwidth_in_mbps = var.load_balancer_max_bandwidth_mbps
  }

  freeform_tags = local.tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

resource "oci_load_balancer_backend_set" "orthanc" {
  load_balancer_id = oci_load_balancer_load_balancer.orthanc.id
  name             = "orthanc-http"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "TCP"
    port              = 8042
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
}

resource "oci_load_balancer_backend" "orthanc" {
  count = var.orthanc_replicas

  load_balancer_id = oci_load_balancer_load_balancer.orthanc.id
  backendset_name  = oci_load_balancer_backend_set.orthanc.name
  ip_address       = oci_container_instances_container_instance.orthanc[count.index].vnics[0].private_ip
  port             = 8042
  weight           = 1
  backup           = false
  drain            = false
  offline          = false
}

resource "oci_load_balancer_listener" "orthanc" {
  load_balancer_id         = oci_load_balancer_load_balancer.orthanc.id
  name                     = "orthanc-http"
  default_backend_set_name = oci_load_balancer_backend_set.orthanc.name
  port                     = 8042
  protocol                 = "HTTP"

  connection_configuration {
    idle_timeout_in_seconds = 300
  }
}
