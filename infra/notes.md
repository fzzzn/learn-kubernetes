# Infrastructure Notes

## Layout

- `providers.tf` - OpenTofu and provider configuration, including generated VM passwords.
- `variables.tf` - Deployment inputs and defaults.
- `network.tf` - Private network, subnet, router, and floating IP allocation.
- `compute.tf` - Kubernetes nodes, boot volumes, and floating IP associations.
- `outputs.tf` - Network, node IP, floating IP, ID, and password outputs.
- `cloud-init/user-data.yaml` - First-boot configuration for the `fauzan` user.

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

Cloud-init runs on first boot. Changes to `cloud-init/user-data.yaml` require
recreating the instance or otherwise rerunning cloud-init.

## Storage

Each node has a boot volume named `<node-name>-boot` using the configured
`volume_type` and `volume_size`. Boot volumes are managed separately and are
not deleted automatically when an instance is destroyed.

## Security

- Keep `terraform.tfvars` and `terraform.tfstate` private.
- Keep OpenStack application credentials out of source control and terminal
  logs. Generated VM passwords are stored in Terraform state.
- Use a remote encrypted state backend for shared or production deployments.