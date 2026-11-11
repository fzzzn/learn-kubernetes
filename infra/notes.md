# Infrastructure Notes

## Layout

- `providers.tf` - OpenTofu and provider configuration, including generated VM passwords.
- `variables.tf` - Deployment inputs and defaults.
- `network.tf` - Private network, subnet, router, and floating IP allocation.
- `compute.tf` - Kubernetes nodes, boot volumes, and floating IP associations.
- `outputs.tf` - Network, node IP, floating IP, ID, and password outputs.
- `cloud-init/user-data.yaml` - First-boot configuration for the `fauzan` user and Nginx.

## Cluster Defaults

The configuration creates one master and three workers:

| Node | Private IP |
|---|---|
| `kube-master` | `192.168.10.10` |
| `kube-worker-1` | `192.168.10.11` |
| `kube-worker-2` | `192.168.10.12` |
| `kube-worker-3` | `192.168.10.13` |

Private IP allocation starts at `node_ip_start` and continues sequentially. Set
`master_flavor_name` and `worker_flavor_name` independently in
`terraform.tfvars` when different flavors are required.

## Deploy

Run commands from the repository root:

```bash
tofu -chdir=infra init
tofu -chdir=infra fmt
tofu -chdir=infra validate
tofu -chdir=infra plan
tofu -chdir=infra apply
```

Review the plan before applying changes. Changing node keys or names can cause
OpenTofu to replace existing instances and their associated resources.

## Useful Outputs

```bash
tofu -chdir=infra output vm_floating_ips
tofu -chdir=infra output vm_access_ips
tofu -chdir=infra output vm_ids
tofu -chdir=infra output -raw vm_password
```

The VM password output is sensitive. Do not copy it into source control or
shared logs.

## SSH

Use the configured OpenStack key pair and the generated `fauzan` user:

```bash
ssh fauzan@<floating-ip>
```

Cloud-init runs on first boot. Changes to `cloud-init/user-data.yaml` require
recreating the instance or otherwise rerunning cloud-init.

## Storage

Each node has a boot volume named `<node-name>-boot` using the configured
`volume_type` and `volume_size`. Boot volumes are managed separately and are
not deleted automatically when an instance is destroyed.

## Security

- Keep `terraform.tfvars` and `terraform.tfstate` private.
- OpenStack and generated VM passwords are stored in Terraform state.
- Use a remote encrypted state backend for shared or production deployments.