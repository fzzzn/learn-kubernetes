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

output "vm_password" {
  description = "Generated password for the fauzan VM user"
  value       = random_password.vm.result
  sensitive   = true
}
