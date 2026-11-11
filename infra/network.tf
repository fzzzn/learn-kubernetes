data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

resource "openstack_networking_network_v2" "private" {
  name           = var.network_name
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name            = var.subnet_name
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.subnet_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
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

resource "openstack_networking_floatingip_v2" "vm" {
  pool = var.external_network_name
}
