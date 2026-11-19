# Infrastructure Notes

## Layout

- `providers.tf` - OpenTofu and provider configuration, including generated VM passwords.
- `variables.tf` - Deployment inputs and defaults.
- `network.tf` - Private network, subnet, router, and floating IP allocation.
- `compute.tf` - Kubernetes nodes, boot volumes, and floating IP associations.
- `outputs.tf` - Network, node IP, floating IP, ID, and password outputs.
- `cloud-init/kubernetes.yaml` - First-boot bootstrap for the `fauzan` user,
  containerd, kubeadm, Cilium, the OpenStack CCM, and Cinder CSI.

## Cluster Defaults

The configuration creates one control-plane node and three workers:

| Node | Private IP |
|---|---|
| `kube-control-plane` | `192.168.10.10` |
| `kube-worker-1` | `192.168.10.11` |
| `kube-worker-2` | `192.168.10.12` |
| `kube-worker-3` | `192.168.10.13` |

Private IP allocation starts at `node_ip_start` and continues sequentially. Set
`control_plane_flavor_name` and `worker_flavor_name` independently in
`terraform.tfvars` when different flavors are required.

## Bootstrap

Each node runs `cloud-init/kubernetes.yaml` on first boot. The control plane
initializes kubeadm, creates the bootstrap token, and installs Cilium through
the Cilium CLI. Workers retry `kubeadm join` against the control-plane private
IP until the API server is reachable and the token exists.

Cilium is installed with `kubeProxyReplacement=false`, so kube-proxy remains in
charge of Service traffic. The Cilium pod CIDR is set from `pod_network_cidr`
and must match the kubeadm `networking.podSubnet` value.

Kubelet runs with `cloud-provider=external` on every node, so kubelet does not
publish node addresses; the CCM does. Until it runs, the API server cannot
proxy to kubelets and `cilium status` fails with
`dial tcp: lookup <node> on <resolver>: no such host`. The bootstrap therefore
waits only for the Cilium DaemonSet rollout, then writes
`/etc/kubernetes/cloud.conf` from the OpenStack application credential, stores
it in the `cloud-config` Secret, and installs the OpenStack CCM and Cinder CSI
Helm charts from `https://kubernetes.github.io/cloud-provider-openstack`.
`cilium status --wait` runs last, after the CCM has published node addresses.

The CCM is installed with only the `cloud-node` and `cloud-node-lifecycle`
controllers. It sets each node's OpenStack provider ID and removes the
external-cloud-provider taint. The `service` (Octavia LoadBalancer) controller
is intentionally disabled. Cinder CSI is installed with the snapshotter
disabled; it creates the `csi-cinder-sc-delete` default StorageClass and
`csi-cinder-sc-retain`.

The Kubernetes, Cilium, Helm, and OpenStack cloud-provider versions are pinned
in `variables.tf` with `kubernetes_version`, `cilium_version`,
`cilium_cli_version`, `helm_version`, and
`openstack_cloud_provider_chart_version`.

## Deploy

Run commands from the repository root:

```bash
# Initialize OpenTofu and install required providers.
tofu -chdir=infra init
# Format OpenTofu configuration files.
tofu -chdir=infra fmt
# Validate syntax and resource references.
tofu -chdir=infra validate
# Preview infrastructure changes without applying them.
tofu -chdir=infra plan
# Create or update infrastructure after confirmation.
tofu -chdir=infra apply
```

The provider authenticates with an OpenStack application credential. Set
`openstack_application_credential_id` and
`openstack_application_credential_secret` in `terraform.tfvars` or provide
them through `TF_VAR_` environment variables:

```bash
export TF_VAR_openstack_application_credential_id="your-id"
export TF_VAR_openstack_application_credential_secret="your-secret"
```

Review the plan before applying changes. Changing node keys or names can cause
OpenTofu to replace existing instances and their associated resources.

## Useful Outputs

```bash
# Display the public floating IP for each Kubernetes node.
tofu -chdir=infra output vm_floating_ips
# Display the private IP for each Kubernetes node.
tofu -chdir=infra output vm_access_ips
# Display the OpenStack server ID for each Kubernetes node.
tofu -chdir=infra output vm_ids
# Display only the generated VM password value.
tofu -chdir=infra output -raw vm_password
```

The VM password output is sensitive. Do not copy it into source control or
shared logs.

## SSH

Use the configured OpenStack key pair and the generated `fauzan` user:

```bash
ssh fauzan@<floating-ip>
```

Cloud-init runs on first boot. Changes to `cloud-init/kubernetes.yaml` require
recreating the instance or otherwise rerunning cloud-init.

## Storage

Each node has a boot volume named `<node-name>-boot` using the configured
`volume_type` and `volume_size`. Boot volumes are managed separately and are
not deleted automatically when an instance is destroyed.

The Cinder CSI driver provisions persistent volumes through the OpenStack
Block Storage API. It uses the same `cloud-config` Secret as the CCM and
creates two StorageClasses:

- `csi-cinder-sc-delete` - default, `reclaimPolicy: Delete`
- `csi-cinder-sc-retain` - `reclaimPolicy: Retain`

The Cinder controller plugin schedules on a worker, so it stays `Pending` until
the first worker joins. The node plugin runs on every node, including the
control plane.

## Security

- Keep `terraform.tfvars` and `terraform.tfstate` private.
- Keep OpenStack application credentials out of source control and terminal
  logs. Generated VM passwords are stored in Terraform state.
- The OpenStack application credential is embedded in each node's cloud-init
  user data so the control plane can create the `cloud-config` Secret. Treat
  instance user data and OpenStack metadata as sensitive.
- Use a remote encrypted state backend for shared or production deployments.
