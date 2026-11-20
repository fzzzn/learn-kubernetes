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

variable "worker_floating_ips" {
  description = "Allocate a floating IP for each worker; disable to reach workers through the control plane"
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "Kubernetes version for kubeadm, kubelet, and kubectl"
  type        = string
  default     = "1.36.6"
}

variable "pod_network_cidr" {
  description = "Pod network CIDR used by the cluster CNI"
  type        = string
  default     = "10.244.0.0/16"
}

variable "cilium_version" {
  description = "Cilium version installed by the Cilium CLI"
  type        = string
  default     = "v1.20.5"
}

variable "cilium_cli_version" {
  description = "Cilium CLI version downloaded on the control plane"
  type        = string
  default     = "v0.20.3"
}

variable "kube_proxy_replacement" {
  description = "Run Cilium in kube-proxy-free mode; also enables Hubble"
  type        = bool
  default     = false
}

variable "helm_version" {
  description = "Helm version downloaded on the control plane"
  type        = string
  default     = "v3.19.0"
}

variable "openstack_cloud_provider_chart_version" {
  description = "Version of the openstack-cloud-controller-manager and openstack-cinder-csi Helm charts"
  type        = string
  default     = "2.36.5"
}

variable "openstack_lb_provider" {
  description = "Octavia load-balancer provider for LoadBalancer Services; empty uses the cloud default (for example amphora or ovn)"
  type        = string
  default     = ""
}

variable "openstack_lb_manage_security_groups" {
  description = "Let the CCM create and manage a security group for each LoadBalancer Service"
  type        = bool
  default     = true
}

variable "key_pair" {
  description = "Existing OpenStack key pair to assign to the VM"
  type        = string
  default     = "FZN-PGP"
}
