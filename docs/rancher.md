# Rancher

Rancher 2.15.3 runs in `cattle-system` and is published at
`https://rancher.local.my.id` through the shared `public` Gateway. It is optional
and not part of the bootstrap; nothing in `infra/` depends on it.

```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update rancher-stable

kubectl create namespace cattle-system
kubectl apply -f manifests/observability/gateway.yaml   # listeners + rancher-tls
kubectl -n monitoring get certificate rancher-tls        # wait for READY=True

helm -n cattle-system install rancher rancher-stable/rancher \
  --version 2.15.3 -f manifests/rancher/values.yaml
kubectl -n cattle-system rollout status deploy/rancher
kubectl apply -f manifests/rancher/gateway-route.yaml
```

Apply the Gateway file first so the `rancher-tls` Secret exists; the HTTPS
listener rejects a missing certificate. The routes then attach to the
`rancher-http`/`rancher-https` listeners, which accept routes from
`cattle-system` and `monitoring`, the second for the HTTP-01 solver.

Point an `A` record for `rancher.local.my.id` at the floating IP before the
certificate can issue:

```bash
kubectl -n monitoring get service cilium-gateway-public
```

## Values worth knowing

`manifests/rancher/values.yaml` sets four things, and each one has a reason:

| Setting | Why |
|---|---|
| `replicas: 1` | The chart default of three does not fit three workers with headroom. |
| `tls: external` | TLS ends at the Gateway, so Rancher must not make its own certificate. |
| `networkExposure.type: none` | Otherwise the chart creates a second Gateway and a second Octavia LB. |
| `bootstrapPassword: changeme` | Placeholder; change it at first login. |

Without `networkExposure.type: none`, the chart's Gateway template uses
`gatewayClassName: traefik` and ports 8000/8443, which do not exist here.

## First login

The bootstrap password is in a Secret, and the setup URL logs you straight in:

```bash
kubectl -n cattle-system get secret bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}{{ "\n" }}'

echo "https://rancher.local.my.id/dashboard/?setup=<password>"
```

Rancher asks you to set a real admin password on that page. It stores only the
hash afterwards, so the Secret keeps answering with the original value and is no
longer the way in.

## Verify

```bash
kubectl -n cattle-system get pods
helm list -A | grep -E 'rancher|fleet'
curl -s https://rancher.local.my.id/ | head -c 200     # API root JSON
curl -o /dev/null -w '%{http_code}\n' https://rancher.local.my.id/dashboard/
```

Expected: `rancher` and `rancher-webhook` pods `1/1 Running`, every release
`deployed`, the API root returns a `collection`, and the dashboard returns `200`.
The HTTP listener answers `301` to HTTPS.

## System charts settle slowly

On first boot Rancher installs its own system charts (`fleet`, `rancher-webhook`,
`rancher-turtles`) through `helm-operation` pods. A first attempt can fail while
another is still running, and the failing attempt leaves a release in
`pending-install` even though the workload is healthy. Rancher then waits an hour
before retrying.

Symptom: every pod is healthy but `helm list` shows `pending-install`, and the
logs repeat `container not found ("proxy")` for a job pod that already completed.

Fix by removing the stale Helm state, which makes Rancher reinstall the chart:

```bash
kubectl -n cattle-system delete app rancher-webhook
kubectl -n cattle-system delete secret sh.helm.release.v1.rancher-webhook.v1
kubectl annotate clusterrepo rancher-charts \
  force-sync="$(date +%s)" --overwrite
helm -n cattle-system list | grep webhook     # deployed
```

Deleting the Pods or waiting does not help; the status lives in that Secret.

## Constraints

- Rancher is a management server, not a workload. It wants its own cluster in
  production; here it shares the lab cluster and adds roughly 500Mi of RAM plus
  the fleet controllers.
- `useBundledSystemChart: false` (the default) means Rancher downloads charts
  from `git.rancher.io` at first boot, so the cluster needs outbound HTTPS.
- Upgrades are `helm upgrade` with a newer `--version`, keeping the same values
  file. Read Rancher's upgrade notes first; some minor versions need a specific
  intermediate release.
- Deleting the namespace leaves the CRDs and every other `cattle-*` namespace
  behind. There are ten of them, including `cattle-global-data` and
  `cattle-ui-plugin-system`:

```bash
helm -n cattle-system uninstall rancher
kubectl get ns | grep cattle
kubectl delete namespace $(kubectl get ns -o name | grep cattle | cut -d/ -f2)
```

The CRDs (85 of them) stay after that; remove them only if Rancher is not coming
back, because they hold all cluster registration and project data.
