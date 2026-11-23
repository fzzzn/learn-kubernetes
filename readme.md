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
| [docs/tls.md](docs/tls.md) | Terminate TLS with Cilium Gateway API and cert-manager. |
| [docs/observability.md](docs/observability.md) | Grafana, Prometheus, Loki, Alloy, and Hubble access over HTTPS. |
| [docs/wordpress.md](docs/wordpress.md) | WordPress and MariaDB, exposed over HTTPS with upgrades. |
| [docs/rancher.md](docs/rancher.md) | Rancher server, exposed through the same Gateway. |
| [docs/manual-setup.md](docs/manual-setup.md) | Build the cluster by hand. |
| [docs/rebuild.md](docs/rebuild.md) | Tear down and rebuild. |
| [docs/infrastructure.md](docs/infrastructure.md) | OpenTofu layout and operations. |

## Repository layout

```text
docs/                     Documentation
infra/                    OpenTofu configuration
  cloud-init/             First-boot node bootstrap
  *.tf                    Network, compute, security, variables, outputs
manifests/                Manifests for optional add-ons and workloads
  observability/          Grafana, Prometheus, Loki, Alloy
    dashboards/           Grafana dashboard ConfigMaps
  wordpress/              WordPress and MariaDB, with its HTTPRoutes
  rancher/                Rancher server values and its HTTPRoutes
```

## References

- [JustHumanz/Kube-dojo](https://github.com/JustHumanz/Kube-dojo)
