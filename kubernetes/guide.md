# Cluster Guide

Complete reference for the cluster this repository builds: what the topology
looks like, what the terminology means, and how to build the same cluster by
hand if you do not want to use the automation.

- Automated path: `tofu -chdir=infra apply` (see [setup.md](setup.md))
- Teardown: see [rebuild.md](rebuild.md)
- Infrastructure layout: see [../infra/notes.md](../infra/notes.md)

## Contents

1. [Topology](#topology)
2. [Components and versions](#components-and-versions)
3. [Terminology](#terminology)
4. [How the automation works](#how-the-automation-works)
5. [Manual build](#manual-build)
6. [Verification](#verification)
7. [Troubleshooting](#troubleshooting)

## Topology

### OpenStack layer

```
                       Internet / workstation
                                 │
                 ┌───────────────▼────────────────┐
                 │  External network: public      │
                 │  floating IP pool 160.20.x.x   │
                 └───────────────┬────────────────┘
                                 │
                      ┌──────────▼──────────┐
                      │  kube-vrouter       │
                      │  external gateway   │
                      │  SNAT               │
                      └──────────┬──────────┘
                                 │ 192.168.10.1
   ┌─────────────────────────────▼──────────────────────────────────────────┐
   │ kube-network / kube-subnet 192.168.10.0/24                             │
   │                                                                        │
   │  ┌───────────────────┐  ┌────────────────┐  ┌────────────────┐         │
   │  │ kube-control-plane│  │ kube-worker-1  │  │ kube-worker-2  │  ...    │
   │  │ 192.168.10.10     │  │ 192.168.10.11  │  │ 192.168.10.12  │         │
   │  │ + floating IP     │  │ + floating IP  │  │ + floating IP  │         │
   │  └───────────────────┘  └────────────────┘  └────────────────┘         │
   └────────────────────────────────────────────────────────────────────────┘

   Managed per workload, outside the node network:

   ┌────────────────────────────────┐   ┌────────────────────────────────┐
   │ Octavia load balancer          │   │ Cinder volume                  │
   │ one per LoadBalancer Service   │   │ one per PersistentVolumeClaim  │
   │ VIP on kube-subnet + floating  │   │ attached to the node running   │
   │ IP from the external network   │   │ the pod                        │
   └────────────────────────────────┘   └────────────────────────────────┘
```

Every node gets a floating IP for SSH. The control-plane floating IP is also
added to the API server certificate SANs, so `kubectl` works from outside.

### Kubernetes layer

```
┌──────────────────────────── control plane ─────────────────────────────┐
│ kube-apiserver :6443        etcd :2379                                 │
│ kube-controller-manager     kube-scheduler                             │
│ kube-proxy                  coredns (2 replicas)                       │
│ cilium-agent                cilium-envoy                               │
│ cilium-operator             openstack-cloud-controller-manager         │
│ openstack-cinder-csi-controllerplugin                                  │
└─────────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────── workers ─────────────────────────────────┐
│ kubelet :10250              kube-proxy                                  │
│ cilium-agent                cilium-envoy                               │
│ openstack-cinder-csi-nodeplugin                                         │
└─────────────────────────────────────────────────────────────────────────┘

Pod network: 10.244.0.0/16 (Cilium cluster-pool IPAM)
Service network: 10.96.0.0/12 (kubeadm default)
Node network: 192.168.10.0/24
```

### Bootstrap sequence

```
cloud-init runs on every node at first boot
  │
  ├─ swap off, overlay/br_netfilter modules, sysctl
  ├─ containerd with SystemdCgroup = true
  ├─ kubelet, kubeadm, kubectl 1.36.6 (held)
  │
  ├─ control plane
  │    ├─ kubeadm init --config          → /etc/kubernetes/admin.conf
  │    ├─ kubeadm token create <token>   → lets workers join
  │    ├─ /etc/kubernetes/cloud.conf     → Secret kube-system/cloud-config
  │    ├─ cilium install + DaemonSet rollout
  │    ├─ helm install CCM (node, node-lifecycle, service)
  │    ├─ helm install Cinder CSI
  │    └─ cilium status --wait
  │
  └─ workers
       └─ kubeadm join --config, retried until the API and token are ready
```

### Traffic flows

```
1. kubectl           → https://<cp-floating-ip>:6443 → kube-apiserver
2. Pod → Pod         → Cilium eBPF/VXLAN, 10.244.0.0/16, no kube-proxy
3. ClusterIP Service → kube-proxy iptables → Pod
4. LoadBalancer      → Octavia VIP (+ floating IP) → node:NodePort
                     → kube-proxy → Pod
5. PVC               → Cinder CSI → Cinder API → volume → attach → mount
6. Node bootstrap    → CCM → OpenStack API → providerID + node addresses
                     + remove the uninitialized taint
```

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
| kube-proxy | Programs iptables/IPVS for Service traffic (kept in this cluster). |
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
| Bootstrap token | Short-lived credential that lets workers join. |
| `kubeProxyReplacement=false` | Cilium leaves Service handling to kube-proxy. |
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

The next section reproduces the same steps by hand. Use it to understand the
bootstrap or to build the cluster without OpenTofu and cloud-init.

## Manual build

> These commands mirror `infra/cloud-init/kubernetes.yaml`. Run OpenStack
> commands from a workstation with the CLI configured, and node commands as
> root on each instance. The variables in step 1 live in the workstation shell;
> substitute the literal values on the nodes, or export them there as well.

### 1. Variables

```bash
CLUSTER=kube
NET=kube-network
SUBNET=kube-subnet
CIDR=192.168.10.0/24
CP_IP=192.168.10.10
POD_CIDR=10.244.0.0/16
K8S=1.36.6
IMAGE="Ubuntu-26.04-eranyaImage-v1.0.img.qcow2"
FLAVOR=gv.l-3
VOLUME_TYPE=Standard_vDisk-T0
KEYPAIR=FZN-PGP
EXTERNAL=public
AUTH_URL=https://160.20.104.10:5000/v3
REGION=RegionOne
```

### 2. Network

```bash
openstack network create "${NET}"
openstack subnet create "${SUBNET}" \
  --network "${NET}" \
  --subnet-range "${CIDR}" \
  --dns-nameserver 1.1.1.1 \
  --dns-nameserver 1.0.0.1
openstack router create "${CLUSTER}-vrouter"
openstack router set "${CLUSTER}-vrouter" --external-gateway "${EXTERNAL}"
openstack router add subnet "${CLUSTER}-vrouter" "${SUBNET}"
```

### 3. Security groups

```bash
openstack security group create "${CLUSTER}-security-group"
openstack security group rule create --ingress --ethertype IPv4 \
  --remote-group "${CLUSTER}-security-group" "${CLUSTER}-security-group"
openstack security group rule create --ingress --ethertype IPv4 \
  --protocol tcp --dst-port 22 "${CLUSTER}-security-group"
openstack security group rule create --ingress --ethertype IPv4 \
  --protocol tcp --dst-port 30000:32767 --remote-ip "${CIDR}" \
  "${CLUSTER}-security-group"

openstack security group create "${CLUSTER}-control-plane-security-group"
openstack security group rule create --ingress --ethertype IPv4 \
  --protocol tcp --dst-port 6443 "${CLUSTER}-control-plane-security-group"
```

The NodePort rule lets Octavia reach the backends. The control-plane group is
only attached to the control-plane instance.

### 4. Boot volumes and instances

Repeat for `kube-control-plane` (`192.168.10.10`) and each worker
(`192.168.10.11`, `.12`, ...), changing the name, IP, and security groups.

```bash
openstack volume create --image "${IMAGE}" --size 50 --type "${VOLUME_TYPE}" \
  --bootable kube-control-plane-boot

VOL_ID="$(openstack volume show kube-control-plane-boot -f value -c id)"
NET_ID="$(openstack network show "${NET}" -f value -c id)"

openstack server create \
  --flavor "${FLAVOR}" \
  --key-name "${KEYPAIR}" \
  --security-group "${CLUSTER}-security-group" \
  --security-group "${CLUSTER}-control-plane-security-group" \
  --nic net-id="${NET_ID}",v4-fixed-ip="${CP_IP}" \
  --block-device uuid="${VOL_ID}",source_type=volume,destination_type=volume,boot_index=0,delete_on_termination=false \
  kube-control-plane
```

Workers use only `--security-group "${CLUSTER}-security-group"`.

The instance name must equal the Kubernetes node name. The CCM resolves nodes by
instance name when it sets `providerID` and node addresses.

### 5. Floating IPs

```bash
openstack floating ip create "${EXTERNAL}" -f value -c floating_ip_address
openstack server add floating ip kube-control-plane 160.20.x.x
```

Repeat for each node and keep a note of the control-plane address.

### 6. Node base setup

Run on every node as root:

```bash
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

cat >/etc/modules-load.d/kubernetes.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

apt-get update
apt-get install -y apt-transport-https ca-certificates curl gpg containerd

containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key |
  gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y \
  kubelet="${K8S}-1.1" kubeadm="${K8S}-1.1" kubectl="${K8S}-1.1"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

install -d -m 0755 /etc/kubernetes /etc/cacert
```

`/etc/cacert` exists because the Cinder CSI chart mounts it by default.

### 7. Control plane: initialize

```bash
cat >/etc/kubernetes/kubeadm-init.yaml <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.10.10
  bindPort: 6443
nodeRegistration:
  name: kube-control-plane
  kubeletExtraArgs:
    - name: cloud-provider
      value: external
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: kube
kubernetesVersion: v1.36.6
networking:
  podSubnet: 10.244.0.0/16
apiServer:
  certSANs:
    - 192.168.10.10
    - 160.20.x.x
EOF
chmod 0600 /etc/kubernetes/kubeadm-init.yaml

kubeadm init --config /etc/kubernetes/kubeadm-init.yaml
```

Then create the bootstrap token and the user kubeconfig:

```bash
TOKEN="$(openssl rand -hex 3).$(openssl rand -hex 8)"
kubeadm token create "${TOKEN}" --ttl 0 \
  --kubeconfig=/etc/kubernetes/admin.conf

install -d -m 0700 /home/ubuntu/.kube
install -m 0600 -o ubuntu -g ubuntu \
  /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
```

Replace `ubuntu` with the login user created by your image.

### 8. Control plane: cloud configuration

```bash
cat >/etc/kubernetes/cloud.conf <<'EOF'
[Global]
auth-url = https://160.20.104.10:5000/v3
application-credential-id = <application-credential-id>
application-credential-secret = <application-credential-secret>
region = RegionOne

[LoadBalancer]
subnet-id = <subnet-id>
floating-network-id = <external-network-id>
manage-security-groups = true
EOF
chmod 0600 /etc/kubernetes/cloud.conf

export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl -n kube-system create secret generic cloud-config \
  --from-file=cloud.conf=/etc/kubernetes/cloud.conf
```

Get the IDs with:

```bash
openstack subnet show kube-subnet -f value -c id
openstack network show public -f value -c id
```

For an OVN Octavia deployment add these lines to the `[LoadBalancer]` section:

```
lb-provider = ovn
lb-method = SOURCE_IP_PORT
```

### 9. Control plane: Cilium

```bash
ARCH=amd64
curl -fsSL -o /tmp/cilium.tar.gz \
  "https://github.com/cilium/cilium-cli/releases/download/v0.20.3/cilium-linux-${ARCH}.tar.gz"
curl -fsSL -o /tmp/cilium.tar.gz.sha256sum \
  "https://github.com/cilium/cilium-cli/releases/download/v0.20.3/cilium-linux-${ARCH}.tar.gz.sha256sum"
(cd /tmp && sha256sum --check cilium.tar.gz.sha256sum)
tar -xzf /tmp/cilium.tar.gz -C /usr/local/bin cilium

cilium install \
  --version v1.20.5 \
  --set "ipam.operator.clusterPoolIPv4PodCIDRList={10.244.0.0/16}" \
  --set "kubeProxyReplacement=false"

kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
```

Do not run `cilium status --wait` yet: with `cloud-provider=external` the node
addresses are published by the CCM, so the API server cannot proxy to kubelets
until the CCM runs.

### 10. Control plane: CCM and Cinder CSI

```bash
HELM_TARBALL="helm-v3.19.0-linux-${ARCH}.tar.gz"
curl -fsSL -o "/tmp/${HELM_TARBALL}" "https://get.helm.sh/${HELM_TARBALL}"
curl -fsSL -o "/tmp/${HELM_TARBALL}.sha256sum" "https://get.helm.sh/${HELM_TARBALL}.sha256sum"
(cd /tmp && sha256sum --check "${HELM_TARBALL}.sha256sum")
tar -xzf "/tmp/${HELM_TARBALL}" -C /tmp "linux-${ARCH}/helm"
install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm

helm upgrade --install openstack-cloud-controller-manager \
  openstack-cloud-controller-manager \
  --repo https://kubernetes.github.io/cloud-provider-openstack \
  --version 2.36.5 \
  --namespace kube-system \
  --set cluster.name=kube \
  --set secret.enabled=true \
  --set secret.create=false \
  --set secret.name=cloud-config \
  --set dnsPolicy=Default \
  --set "enabledControllers={cloud-node,cloud-node-lifecycle,service}" \
  --wait --timeout 10m

helm upgrade --install openstack-cinder-csi \
  openstack-cinder-csi \
  --repo https://kubernetes.github.io/cloud-provider-openstack \
  --version 2.36.5 \
  --namespace kube-system \
  --set clusterID=kube \
  --set secret.enabled=true \
  --set secret.create=false \
  --set secret.name=cloud-config \
  --set csi.plugin.nodePlugin.dnsPolicy=Default \
  --set csi.snapshotter.enabled=false \
  --set storageClass.enabled=true \
  --set storageClass.delete.isDefault=true

kubectl -n kube-system rollout status \
  daemonset/openstack-cinder-csi-nodeplugin --timeout=5m

cilium status --wait --wait-duration 10m
```

`dnsPolicy=Default` is required because CoreDNS does not tolerate the
`node.cloudprovider.kubernetes.io/uninitialized` taint that exists until the CCM
starts.

### 11. Workers: join

Run on each worker with its own name:

```bash
cat >/etc/kubernetes/kubeadm-join.yaml <<'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: 192.168.10.10:6443
    token: <token-from-step-7>
    unsafeSkipCAVerification: true
nodeRegistration:
  name: kube-worker-1
  kubeletExtraArgs:
    - name: cloud-provider
      value: external
EOF
chmod 0600 /etc/kubernetes/kubeadm-join.yaml
kubeadm join --config /etc/kubernetes/kubeadm-join.yaml
```

The automation uses `unsafeSkipCAVerification` because the control-plane
certificate is not known in advance. For a stricter setup, replace it with
`caCertHashes` from:

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt |
  openssl rsa -pubin -outform der 2>/dev/null |
  sha256sum | awk '{print $1}'
```

## Verification

```bash
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
kubectl -n kube-system get pods -o wide
kubectl get storageclass
cilium status
```

Expected:

- all nodes `Ready`, with `INTERNAL-IP`, `EXTERNAL-IP`, and `openstack:///<uuid>`
- `cilium`, `cilium-envoy`, `cilium-operator`, CCM, and the Cinder node plugin
  running
- `csi-cinder-sc-delete (default)` and `csi-cinder-sc-retain` present
- `Cilium: OK`

Storage and load-balancer smoke tests are in [setup.md](setup.md).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `neither $XDG_CACHE_HOME nor $HOME are defined` | Helm invoked without `HOME`, typically from cloud-init `runcmd`. | `export HOME=/root` before Helm or Cilium CLI calls. |
| `Cilium: 8 errors`, `dial tcp: lookup kube-worker-1 on 1.1.1.1:53: no such host` | kubelet does not publish node addresses with `cloud-provider=external`; the CCM has not run yet. | Install the CCM before running `cilium status --wait`. |
| Nodes `NotReady` with `uninitialized` taint | CCM has not initialized the node yet. | Check the CCM pod and its log. |
| Cinder controller plugin `Pending` | It has no toleration for the control-plane taint. | Wait for a worker to join. |
| `LoadBalancer` Service stuck `<pending>` | Octavia unavailable, wrong provider, or the LB method is invalid. | Check CCM logs; with `ovn` set `lb-method = SOURCE_IP_PORT`. |
| Load balancer created but `curl` times out | Node security group blocks NodePort traffic. | Allow TCP `30000-32767` from the subnet. |
| `kubeadm join` fails with token errors | Token not created yet, or wrong token. | Workers retry; verify with `kubeadm token list` on the control plane. |
| PVC stuck `Pending` | No default StorageClass or Cinder API unreachable. | Check `kubectl get storageclass` and the Cinder controller log. |
