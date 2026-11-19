data "openstack_images_image_v2" "vm" {
  name        = var.image_name
  most_recent = true
}

locals {
  kubernetes_major_minor = join(".", slice(split(".", var.kubernetes_version), 0, 2))
  control_plane_ip       = cidrhost(var.subnet_cidr, var.node_ip_start)

  nodes = merge(
    {
      kube-control-plane = {
        name     = "${var.cluster_name}-control-plane"
        flavor   = var.control_plane_flavor_name
        fixed_ip = local.control_plane_ip
      }
    },
    {
      for index in range(var.worker_count) : "kube-worker-${index + 1}" => {
        name     = "${var.cluster_name}-worker-${index + 1}"
        flavor   = var.worker_flavor_name
        fixed_ip = cidrhost(var.subnet_cidr, var.node_ip_start + index + 1)
      }
    }
  )
}

resource "openstack_blockstorage_volume_v3" "vm_boot" {
  for_each    = local.nodes
  name        = "${each.value.name}-boot"
  image_id    = data.openstack_images_image_v2.vm.id
  size        = var.volume_size
  volume_type = var.volume_type
}

resource "openstack_compute_instance_v2" "vm" {
  for_each    = local.nodes
  name        = each.value.name
  flavor_name = each.value.flavor
  key_pair    = var.key_pair
  security_groups = concat(
    [openstack_networking_secgroup_v2.cluster.name],
    each.key == "kube-control-plane" ? [openstack_networking_secgroup_v2.control_plane.name] : []
  )

  user_data = templatefile("${path.module}/cloud-init/kubernetes.yaml", {
    vm_password                             = random_password.vm.result
    kubernetes_major_minor                  = local.kubernetes_major_minor
    kubernetes_version                      = var.kubernetes_version
    pod_network_cidr                        = var.pod_network_cidr
    is_control_plane                        = each.key == "kube-control-plane"
    node_name                               = each.value.name
    cluster_name                            = var.cluster_name
    control_plane_ip                        = local.control_plane_ip
    floating_ip                             = openstack_networking_floatingip_v2.vm[each.key].address
    bootstrap_token                         = "${random_string.bootstrap_token_id.result}.${random_string.bootstrap_token_secret.result}"
    cilium_version                          = var.cilium_version
    cilium_cli_version                      = var.cilium_cli_version
    helm_version                            = var.helm_version
    openstack_cloud_provider_chart_version  = var.openstack_cloud_provider_chart_version
    openstack_auth_url                      = var.openstack_auth_url
    openstack_region                        = var.openstack_region
    openstack_application_credential_id     = var.openstack_application_credential_id
    openstack_application_credential_secret = var.openstack_application_credential_secret
  })

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.vm_boot[each.key].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }

  network {
    uuid        = openstack_networking_network_v2.private.id
    fixed_ip_v4 = each.value.fixed_ip
  }

  depends_on = [openstack_networking_router_interface_v2.private]
}

resource "openstack_compute_floatingip_associate_v2" "vm" {
  for_each    = local.nodes
  floating_ip = openstack_networking_floatingip_v2.vm[each.key].address
  instance_id = openstack_compute_instance_v2.vm[each.key].id
}
