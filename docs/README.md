# Documentation

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | OpenStack and Kubernetes topology, component versions, terminology, bootstrap and traffic flow. |
| [setup.md](setup.md) | Deploy the cluster with OpenTofu, then verify nodes, storage, load balancers, and kubeconfig. |
| [upgrade.md](upgrade.md) | Upgrade Kubernetes, Cilium, the OpenStack CCM, and Cinder CSI, in place or by rebuilding. |
| [tls.md](tls.md) | Terminate TLS with Cilium Gateway API and cert-manager. |
| [observability.md](observability.md) | Metrics, logs, dashboards, and public HTTPS access to Grafana and Hubble. |
| [wordpress.md](wordpress.md) | Deploy WordPress and MariaDB, expose the site over HTTPS, and upgrade it. |
| [manual-setup.md](manual-setup.md) | Build the same cluster by hand, step by step, without OpenTofu or cloud-init. |
| [rebuild.md](rebuild.md) | Clean up in-cluster resources, destroy the stack, and rebuild from scratch. |
| [infrastructure.md](infrastructure.md) | The `infra/` OpenTofu layout, defaults, outputs, storage, and security groups. |

## Suggested reading order

1. [architecture.md](architecture.md) to understand what gets built.
2. [setup.md](setup.md) to build it.
3. [infrastructure.md](infrastructure.md) when changing the OpenTofu configuration.
4. [rebuild.md](rebuild.md) when the cluster needs a clean slate.
5. [upgrade.md](upgrade.md) when moving to a newer Kubernetes or Cilium release.
6. [tls.md](tls.md) when exposing an application over HTTPS.
7. [observability.md](observability.md) when you want metrics and logs.
8. [wordpress.md](wordpress.md) when you want to run a real workload on it.

Use [manual-setup.md](manual-setup.md) as a reference for the bootstrap, or when
building the cluster without the automation.
