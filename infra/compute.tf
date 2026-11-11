data "openstack_images_image_v2" "vm" {
  name        = var.image_name
  most_recent = true
}

locals {
  nodes = merge(
    {
      kube-control-plane = {
        name     = "${var.cluster_name}-control-plane"
        flavor   = var.control_plane_flavor_name
        fixed_ip = cidrhost(var.subnet_cidr, var.node_ip_start)
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
  for_each        = local.nodes
  name            = each.value.name
  flavor_name     = each.value.flavor
  key_pair        = var.key_pair
  security_groups = var.security_groups

  user_data = templatefile("${path.module}/cloud-init/user-data.yaml", {
    vm_password = random_password.vm.result
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
