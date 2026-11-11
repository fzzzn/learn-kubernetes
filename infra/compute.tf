data "openstack_images_image_v2" "vm" {
  name        = var.image_name
  most_recent = true
}

resource "openstack_blockstorage_volume_v3" "vm_boot" {
  name        = "${var.instance_name}-boot"
  image_id    = data.openstack_images_image_v2.vm.id
  size        = var.volume_size
  volume_type = var.volume_type
}

resource "openstack_compute_instance_v2" "vm" {
  name            = var.instance_name
  flavor_name     = var.flavor_name
  key_pair        = var.key_pair
  security_groups = var.security_groups

  user_data = templatefile("${path.module}/cloud-init/user-data.yaml", {
    vm_password = random_password.vm.result
  })

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.vm_boot.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }

  network {
    uuid = openstack_networking_network_v2.private.id
  }

  depends_on = [openstack_networking_router_interface_v2.private]
}

resource "openstack_compute_floatingip_associate_v2" "vm" {
  floating_ip = openstack_networking_floatingip_v2.vm.address
  instance_id = openstack_compute_instance_v2.vm.id
}
