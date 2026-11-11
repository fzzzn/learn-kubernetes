terraform {
  required_version = ">= 0.14.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53.0"
    }
  }
}

provider "openstack" {
  tenant_name         = var.openstack_tenant_name
  user_domain_name    = var.openstack_user_domain_name
  project_domain_name = var.openstack_project_domain_name
  user_name           = var.openstack_user_name
  password            = var.openstack_password
  auth_url            = var.openstack_auth_url
  region              = var.openstack_region
}

data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

data "openstack_images_image_v2" "vm" {
  name        = var.image_name
  most_recent = true
}

resource "openstack_networking_network_v2" "private" {
  name           = var.network_name
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name             = var.subnet_name
  network_id       = openstack_networking_network_v2.private.id
  cidr             = var.subnet_cidr
  ip_version       = 4
  dns_nameservers  = var.dns_nameservers
}

resource "openstack_networking_router_v2" "vrouter" {
  name                = var.router_name
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "private" {
  router_id = openstack_networking_router_v2.vrouter.id
  subnet_id = openstack_networking_subnet_v2.private.id
}

resource "openstack_compute_instance_v2" "vm" {
  name            = var.instance_name
  flavor_name     = var.flavor_name
  key_pair        = var.key_pair
  security_groups = var.security_groups
  user_data      = file("${path.module}/cloud-init.yaml")

  block_device {
    uuid                  = data.openstack_images_image_v2.vm.id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = var.volume_size
    volume_type           = var.volume_type
    boot_index             = 0
    delete_on_termination = true
  }

  network {
    uuid = openstack_networking_network_v2.private.id
  }

  depends_on = [openstack_networking_router_interface_v2.private]
}

resource "openstack_networking_floatingip_v2" "vm" {
  pool = var.external_network_name
}

resource "openstack_compute_floatingip_associate_v2" "vm" {
  floating_ip = openstack_networking_floatingip_v2.vm.address
  instance_id = openstack_compute_instance_v2.vm.id
}

output "router_id" {
  description = "ID of the virtual router"
  value       = openstack_networking_router_v2.vrouter.id
}

output "network_id" {
  description = "ID of the private network"
  value       = openstack_networking_network_v2.private.id
}

output "subnet_id" {
  description = "ID of the private subnet"
  value       = openstack_networking_subnet_v2.private.id
}

output "vm_id" {
  description = "ID of the VM"
  value       = openstack_compute_instance_v2.vm.id
}

output "vm_access_ip" {
  description = "VM address on the private network"
  value       = openstack_compute_instance_v2.vm.access_ip_v4
}

output "vm_floating_ip" {
  description = "Floating IP assigned to the VM"
  value       = openstack_networking_floatingip_v2.vm.address
}
