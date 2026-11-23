# Architecture

How the cluster is put together: the OpenStack and Kubernetes topology, the
pinned component versions, the terminology, and the automated bootstrap flow.

- Automated deploy: [setup.md](setup.md)
- Manual build: [manual-setup.md](manual-setup.md)
- Teardown and rebuild: [rebuild.md](rebuild.md)
- OpenTofu layout: [infrastructure.md](infrastructure.md)

## Contents

1. [Topology](#topology)
2. [Components and versions](#components-and-versions)
3. [Terminology](#terminology)
4. [How the automation works](#how-the-automation-works)

## Topology

### OpenStack layer

```text
                            Internet / workstation
                                      |
                                      v
               +---------------------------------------------+
               |          External network: public           |
               |         floating IP pool 160.20.x.x         |
               +---------------------------------------------+
                                      |
                                      v
                            +-------------------+
                            |   kube-vrouter    |
                            | external gateway  |
                            |       SNAT        |
                            +-------------------+
                                      | 192.168.10.1
                                      v
+----------------------------------------------------------------------------+
| kube-network / kube-subnet 192.168.10.0/24                                 |
|                                                                            |
| +--------------------+  +--------------------+  +--------------------+     |
| | kube-control-plane |  | kube-worker-1      |  | kube-worker-2      |     |
| | 192.168.10.10      |  | 192.168.10.11      |  | 192.168.10.12      | ... |
| | + floating IP      |  | + floating IP      |  | + floating IP      |     |
| +--------------------+  +--------------------+  +--------------------+     |
|                                                                            |
+----------------------------------------------------------------------------+

Managed per workload, outside the node network:
+------------------------------------+  +------------------------------------+
| Octavia load balancer              |  | Cinder volume                      |
| one per LoadBalancer Service       |  | one per PersistentVolumeClaim      |
| VIP on kube-subnet + FIP           |  | attached to the running node       |
+------------------------------------+  +------------------------------------+
```

The control plane always gets a floating IP for SSH, and it is added to the API
server certificate SANs so `kubectl` works from outside. Workers get one only
when `worker_floating_ips = true` (the default); without it, reach them through
the control plane with `ssh -J`.

### Kubernetes layer

```text
+---------------------------- control plane -----------------------------+
| kube-apiserver :6443      etcd :2379                                   |
| kube-controller-manager   kube-scheduler                               |
| coredns (one per node)    metrics-server                               |
| cilium-agent              cilium-envoy                                 |
| cilium-operator           openstack-cloud-controller-manager           |
| openstack-cinder-csi-controllerplugin                                  |
+------------------------------------------------------------------------+
+------------------------------- workers --------------------------------+
| kubelet :10250                                                         |
| cilium-agent              cilium-envoy                                 |
| coredns                   openstack-cinder-csi-nodeplugin              |
+------------------------------------------------------------------------+
```

### Bootstrap sequence

```text
cloud-init runs on every node at first boot
  |
  +- swap off, overlay/br_netfilter modules, sysctl
  +- containerd with SystemdCgroup = true
  +- kubelet, kubeadm, kubectl 1.36.6 (held)
  |
  +- control plane
  |    +- kubeadm init --config          -> /etc/kubernetes/admin.conf
  |    +- kubeadm token create <token>   -> lets workers join
  |    +- /etc/kubernetes/cloud.conf     -> Secret kube-system/cloud-config
  |    +- cilium install + DaemonSet rollout
  |    +- helm install CCM (node, node-lifecycle, service)
  |    +- helm install Cinder CSI
  |    +- cilium status --wait
  |
  +- workers
       +- kubeadm join --config, retried until the API and token are ready
```

### Traffic flows

```text
1. kubectl           -> https://<cp-floating-ip>:6443 -> kube-apiserver
2. Pod -> Pod        -> Cilium eBPF/VXLAN, 10.244.0.0/16, no kube-proxy
3. ClusterIP Service -> kube-proxy iptables -> Pod
4. LoadBalancer      -> Octavia VIP (+ floating IP) -> node:NodePort
                        -> kube-proxy -> Pod
5. PVC               -> Cinder CSI -> Cinder API -> volume -> attach -> mount
6. Node bootstrap    -> CCM -> OpenStack API -> providerID + node addresses
                        + remove the uninitialized taint
```

With `kube_proxy_replacement = true`, Service and NodePort traffic in steps 3
and 4 is handled by Cilium's eBPF datapath and kube-proxy is not installed.

## Components and versions

| Component | Version | Source |
|---|---|---|
| Ubuntu | 26.04 LTS | `image_name` |
| Kubernetes (kubelet, kubeadm, kubectl) | 1.36.6 | `pkgs.k8s.io` |
| Cilium | 1.20.5 | Cilium CLI |
| Cilium CLI | 0.20.3 | GitHub release |
| Helm | 3.19.0 | get.helm.sh |
| OpenStack CCM | chart 2.36.5, app v1.36.0 | cloud-provider-openstack |
| Cinder CSI | chart 2.36.5, app v1.36.0 | cloud-provider-openstack |
| kubeadm API | `v1beta4` | kubeadm |
| containerd | distribution package | Ubuntu |

All versions are pinned in `infra/variables.tf`.

## Terminology

### OpenStack

| Term | Meaning |
|---|---|
| Project / tenant | OpenStack account that owns the resources and pays quota. |
| Region | API endpoint group, `RegionOne` here. |
| Application credential | ID + secret pair used instead of a password for API auth. |
| Network | Layer 2 domain, `kube-network`. |
| Subnet | Layer 3 range on a network, `kube-subnet` `192.168.10.0/24`. |
| Router | Provides SNAT and the gateway between the subnet and the external network. |
| Floating IP | Public address from the external network, NATed to a private port. |
| Security group | Stateful firewall rules attached to ports/instances. |
| Flavor | CPU/RAM sizing, `gv.l-3`. |
| Image | Boot disk template, Ubuntu 26.04 here. |
| Boot volume | Cinder volume created from the image and attached as the system disk. |
| Octavia | OpenStack load-balancer service (Neutron LBaaS successor). |
| Amphora | Octavia provider that runs load balancers in dedicated VMs. |
| OVN provider | Octavia provider that implements load balancing inside OVN. |
| Cinder | OpenStack block storage service. |
| Availability zone | Placement domain, `nova` for instances here. |

### Kubernetes

| Term | Meaning |
|---|---|
| Control plane | Nodes running the API server, etcd, scheduler, and controller manager. |
| Worker | Node that runs application pods. |
| kubelet | Node agent that starts containers from pod specs. |
| kube-apiserver | Single entry point for all cluster API traffic, port 6443. |
| etcd | Key-value store holding all cluster state. |
| kube-scheduler | Assigns pods to nodes. |
| kube-controller-manager | Runs built-in control loops. |
| kube-proxy | Programs iptables/IPVS for Service traffic (default; absent when Cilium replaces it). |
| CNI | Container network interface; Cilium is the implementation here. |
| CSI | Container storage interface; Cinder CSI is the implementation here. |
| CCM | Cloud controller manager; bridges Kubernetes and OpenStack. |
| providerID | `openstack:///<instance-uuid>` set by the CCM on each node. |
| Taint / toleration | Scheduling restriction; the CCM removes the cloud-provider taint. |
| Pod CIDR | Range pods get IPs from, `10.244.0.0/16`. |
| Service | Stable virtual IP in front of pods. |
| ClusterIP | Service reachable only inside the cluster. |
| NodePort | Service exposed on every node in `30000-32767`. |
| LoadBalancer | Service exposed through a cloud load balancer (Octavia here). |
| PV / PVC | PersistentVolume (real storage) and PersistentVolumeClaim (request). |
| StorageClass | Template for dynamic volume provisioning. |
| kubeconfig | File holding API endpoint, certificate, and credentials. |
| RBAC | Role-based access control for API operations. |

### kubeadm and Cilium

| Term | Meaning |
|---|---|
| `InitConfiguration` | kubeadm config for `kubeadm init`. |
| `ClusterConfiguration` | Cluster-wide kubeadm config (subnet, version, SANs). |
| `JoinConfiguration` | kubeadm config for `kubeadm join`. |
| `v1beta4` | kubeadm config API version used by Kubernetes 1.36. |
| `nodeRegistration.name` | Node name; must match the OpenStack instance name for the CCM. |
| `kubeletExtraArgs` | List of `{name, value}` passed to kubelet; sets `cloud-provider=external`. |
| `extraArgs` | List of `{name, value}` that overrides control-plane or etcd flags; used to expose their metrics. |
| Bootstrap token | Short-lived credential that lets workers join. |
| `kubeProxyReplacement=false` | Cilium leaves Service handling to kube-proxy; `kube_proxy_replacement = true` reverses this. |
| Cluster-pool IPAM | Cilium allocates pod IPs from `clusterPoolIPv4PodCIDRList`. |
| Cilium agent / operator | Per-node datapath agent and cluster-wide controller. |
| cilium-envoy | Envoy daemon used for L7 policy and ingress features. |

## How the automation works

`infra/compute.tf` renders `infra/cloud-init/kubernetes.yaml` with
`templatefile` and passes the result as instance user data. The script runs once
per node and branches on `is_control_plane`:

- Control plane: initializes the cluster, publishes the bootstrap token,
  installs Cilium, the CCM, and Cinder CSI.
- Workers: retry `kubeadm join` until the API server answers and the token
  exists.

To reproduce these steps by hand, see [manual-setup.md](manual-setup.md).
