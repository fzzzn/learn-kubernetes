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

output "external_network_id" {
  description = "ID of the external network used for floating IPs"
  value       = data.openstack_networking_network_v2.external.id
}

output "vm_ids" {
  description = "IDs of the Kubernetes nodes"
  value       = { for role, vm in openstack_compute_instance_v2.vm : role => vm.id }
}

output "vm_access_ips" {
  description = "Private IPs of the Kubernetes nodes"
  value       = { for role, vm in openstack_compute_instance_v2.vm : role => vm.access_ip_v4 }
}

output "vm_floating_ips" {
  description = "Floating IPs assigned to the Kubernetes nodes"
  value       = { for role, ip in openstack_networking_floatingip_v2.vm : role => ip.address }
}

output "vm_password" {
  description = "Generated password for the fauzan VM user"
  value       = random_password.vm.result
  sensitive   = true
}

output "control_plane_access_ip" {
  description = "Private IP used by worker nodes to reach the Kubernetes API"
  value       = local.control_plane_ip
}
