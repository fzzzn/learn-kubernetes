# Learn Kubernetes

Notes from my Kubernetes learning journey, plus a working reference for a
kubeadm cluster on OpenStack provisioned with OpenTofu: one control plane,
three workers, Cilium, the OpenStack cloud controller manager with Octavia load
balancers, and Cinder CSI.

## Quick start

```bash
tofu -chdir=infra init
tofu -chdir=infra plan
tofu -chdir=infra apply
```

Credentials go in `infra/terraform.tfvars` (see
[docs/infrastructure.md](docs/infrastructure.md)). The node bootstrap runs
through cloud-init; no manual post-boot step is required.

## Documentation

| Document | What it covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Topology, component versions, terminology, bootstrap flow. |
| [docs/setup.md](docs/setup.md) | Deploy and verify the cluster. |
| [docs/upgrade.md](docs/upgrade.md) | Upgrade Kubernetes, Cilium, and the OpenStack add-ons. |
| [docs/manual-setup.md](docs/manual-setup.md) | Build the cluster by hand. |
| [docs/rebuild.md](docs/rebuild.md) | Tear down and rebuild. |
| [docs/infrastructure.md](docs/infrastructure.md) | OpenTofu layout and operations. |

## Repository layout

```text
docs/                     Documentation
infra/                    OpenTofu configuration
  cloud-init/             First-boot node bootstrap
  *.tf                    Network, compute, security, variables, outputs
```

## References

- [JustHumanz/Kube-dojo](https://github.com/JustHumanz/Kube-dojo)
