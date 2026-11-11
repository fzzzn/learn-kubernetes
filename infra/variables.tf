variable "openstack_tenant_name" {
  description = "The OpenStack tenant name"
  type        = string
}

variable "openstack_user_domain_name" {
  description = "The OpenStack user domain name"
  type        = string
}

variable "openstack_project_domain_name" {
  description = "The OpenStack project domain name"
  type        = string
}

variable "openstack_user_name" {
  description = "The OpenStack user name"
  type        = string
}

variable "openstack_password" {
  description = "The OpenStack password"
  type        = string
}

variable "openstack_auth_url" {
  description = "The OpenStack authentication URL"
  type        = string
}

variable "openstack_region" {
  description = "The OpenStack region"
  type        = string
  default     = "RegionOne"
}

variable "external_network_name" {
  description = "Name of the existing external network used by the router"
  type        = string
  default     = "public"
}

variable "network_name" {
  description = "Name of the private network"
  type        = string
  default     = "test-network"
}

variable "subnet_name" {
  description = "Name of the private subnet"
  type        = string
  default     = "kube-subnet"
}

variable "subnet_cidr" {
  description = "CIDR for the private subnet"
  type        = string
  default     = "192.168.10.0/24"
}

variable "dns_nameservers" {
  description = "DNS servers advertised to instances on the private subnet"
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
}

variable "node_ip_start" {
  description = "Subnet host offset assigned to the master node; workers follow sequentially"
  type        = number
  default     = 10
}

variable "router_name" {
  description = "Name of the virtual router"
  type        = string
  default     = "kube-vrouter"
}

variable "cluster_name" {
  description = "Base name used for the Kubernetes nodes"
  type        = string
  default     = "kube"
}

variable "image_name" {
  description = "Name of the image used by the VM"
  type        = string
  default     = "debian-13-genericcloud-amd64"
}

variable "volume_size" {
  description = "Boot volume size in GB"
  type        = number
  default     = 50
}

variable "volume_type" {
  description = "Volume type for the VM boot volume"
  type        = string
  default     = "Standard_vDisk-T0"
}

variable "master_flavor_name" {
  description = "Flavor used by the Kubernetes master"
  type        = string
  default     = "gv.s-1"
}

variable "worker_flavor_name" {
  description = "Flavor used by Kubernetes workers"
  type        = string
  default     = "gv.s-1"
}

variable "worker_count" {
  description = "Number of Kubernetes worker nodes"
  type        = number
  default     = 3
}

variable "key_pair" {
  description = "Existing OpenStack key pair to assign to the VM"
  type        = string
  default     = "FZN-PGP"
}

variable "security_groups" {
  description = "Security groups assigned to the VM"
  type        = list(string)
  default     = ["default"]
}