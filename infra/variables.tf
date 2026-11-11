variable "openstack_application_credential_id" {
  description = "OpenStack application credential ID used for API authentication"
  type        = string
  sensitive   = true
}

variable "openstack_application_credential_secret" {
  description = "OpenStack application credential secret used for API authentication"
  type        = string
  sensitive   = true
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
  default     = "kube-network"
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
  description = "Subnet host offset assigned to the control-plane node; workers follow sequentially"
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
  default     = "Ubuntu-26.04-eranyaImage-v1.0.img.qcow2"
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

variable "control_plane_flavor_name" {
  description = "Flavor used by the Kubernetes control-plane node"
  type        = string
  default     = "gv.l-3"
}

variable "worker_flavor_name" {
  description = "Flavor used by Kubernetes workers"
  type        = string
  default     = "gv.l-3"
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