# AGENTS.md

This repository is infrastructure and documentation, not an application. There
is no build, test suite, linter, or CI. Verification means `tofu` checks plus
commands against a live cluster.

## What is where

- `infra/` - OpenTofu that provisions one control plane and three workers on
  OpenStack. `compute.tf` renders `infra/cloud-init/kubernetes.yaml` through
  `templatefile`; that cloud-init script is the entire bootstrap (kubeadm,
  Cilium, CCM, Cinder CSI). Changing Kubernetes behaviour usually means editing
  this file, not a separate manifest.
- `manifests/observability/` - Helm values only. Nothing here is applied by
  cloud-init.
- `docs/` - English prose. `docs/README.md` is the index; `readme.md` is the
  short landing page. Keep both link tables in sync when adding a doc.

`infra/terraform.tfvars` and `infra/terraform.tfstate` exist locally and are
gitignored. Never commit them or paste their contents (credentials, VM password,
bootstrap token).

## Verify before claiming a change works

```bash
tofu -chdir=infra fmt -check     # formatting
tofu -chdir=infra validate       # syntax and references
tofu -chdir=infra plan -detailed-exitcode   # 0 = no drift, 2 = changes pending
```

There is no way to test cloud-init short of `destroy` + `apply`, and that is the
user's call. Do not run `tofu apply` or `destroy` unless asked; they replace VMs.

Cluster checks that need a live context:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status   # NOT `cilium status -o json`
kubectl -n monitoring get certificate,challenge,gateway
```

`cilium status --wait` fails while the CCM is down, because node addresses are
published by the CCM.

## Gotchas that cost real time

- **kubeadm heredocs.** `infra/cloud-init/kubernetes.yaml` holds two
  `<<'KUBEADM'` blocks (init and join) inside the YAML `content: |` block. The
  body and the closing `KUBEADM` line sit at exactly 6 spaces; the opener is one
  level deeper because it is inside an `if`. A mis-indented edit silently
  produces a broken kubeadm config that only fails on a fresh boot. After
  editing, extract the block, substitute the `${...}` variables, and parse it
  with a YAML loader.
- **`kube_proxy_replacement` is not switchable in place.** It changes the kubeadm
  invocation and Cilium flags, so flipping it requires `destroy` + `apply`. It
  also enables Hubble. Gateway API and Hubble both need it `true`.
- **Control-plane metrics** must be rebound to `0.0.0.0`
  (`bind-address` for controller-manager and scheduler,
  `listen-metrics-urls` for etcd). Without it Prometheus reports them `DOWN`.
  `kubeProxy.enabled: false` in the values file is deliberate: kube-proxy does
  not exist in this mode.
- **`lifecycle { ignore_changes = [security_groups] }` in `infra/compute.tf` is
  load bearing.** The CCM attaches its own `lb-sg-*` group to node ports;
  removing the block makes the next `apply` detach it and break LB to NodePort
  traffic. Add security group rules in `infra/security.tf` instead.
- **`providerID` is immutable.** After a partial `apply` that replaced
  instances, the Node object must be deleted so kubelet re-registers.
- **Docs are 7-bit ASCII.** Diagrams use `+ - |`. Keep it that way.

## Teardown and rebuild order

Gateway API, cert-manager, and the observability stack are not part of the
bootstrap; every `destroy` + `apply` requires reinstalling them. Full sequence is
in `docs/rebuild.md`. Two ordering rules that break if ignored:

1. Delete the Gateway (`kubectl -n monitoring delete gateway public`) before
   deleting LoadBalancer Services, otherwise Cilium recreates the Service.
2. Uninstall the Helm releases before deleting PVCs. A mounted claim keeps the
   `pvc-protection` finalizer and sits in `Terminating` forever. Scaling
   Prometheus to zero does not help: the `Prometheus` CR restores the replica.

## Conventions

- Docs in English, chat replies in Indonesian or English.
- Keep commits logical and scoped; do not push.
- One Gateway (`public` in `monitoring`) serves `grafana.local.my.id`,
  `hubble.local.my.id`, `wordpress.local.my.id`, and `rancher.local.my.id`
  through one Octavia LB. `manifests/observability/gateway.yaml` is the only
  exposure manifest; do not reintroduce a second Gateway without asking, it
  costs another LB and floating IP.
- The HTTP-01 solver is bound to a single Gateway, so one `Certificate` carries
  Grafana and Hubble, and one broken DNS record blocks both. WordPress and
  Rancher each have their own Certificate and listener pair
  (`wordpress-tls`, `rancher-tls`), so a missing record for either cannot stall
  that renewal.
- Routes from outside `monitoring` need an explicit `allowedRoutes` selector on
  their listener. New hostnames get their own listener; widening `from: Same`
  would let any namespace attach to the Grafana/Hubble listeners.
- An HTTP listener that redirects a hostname to HTTPS also swallows the
  `/.well-known/acme-challenge/` path and breaks HTTP-01. Such a listener must
  also admit the `monitoring` namespace so the cert-manager solver route can
  match that path before the redirect.
