resource "openstack_networking_secgroup_v2" "cluster" {
  name        = "${var.cluster_name}-security-group"
  description = "Cluster communication and external SSH access"
}

resource "openstack_networking_secgroup_v2" "control_plane" {
  name        = "${var.cluster_name}-control-plane-security-group"
  description = "External Kubernetes API access"
}

resource "openstack_networking_secgroup_v2" "load_balancer" {
  name        = "${var.cluster_name}-load-balancer-security-group"
  description = "Public HTTP and HTTPS load-balancer access"
}

resource "openstack_networking_secgroup_rule_v2" "cluster_ingress" {
  direction         = "ingress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.cluster.id
  remote_group_id   = openstack_networking_secgroup_v2.cluster.id
}

resource "openstack_networking_secgroup_rule_v2" "ssh_ingress" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.cluster.id
}

resource "openstack_networking_secgroup_rule_v2" "kubernetes_api_ingress" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.control_plane.id
}

resource "openstack_networking_secgroup_rule_v2" "load_balancer_http_ingress" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.load_balancer.id
}

resource "openstack_networking_secgroup_rule_v2" "load_balancer_https_ingress" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.load_balancer.id
}
