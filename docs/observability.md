# Observability

Metrics and logs on top of the cluster: Prometheus and Grafana for metrics,
Loki for logs, and Grafana Alloy to ship them. This is an add-on, not part of
the bootstrap, so the cluster stays usable if a chart fails.

Values files live in `manifests/observability/`. Run the commands from the
repository root, on a machine with `helm` and a working kubeconfig.

| Release | Chart | What it does |
|---|---|---|
| `kube-prometheus-stack` | `prometheus-community/kube-prometheus-stack` | Prometheus, Grafana, node-exporter, kube-state-metrics, default dashboards |
| `loki` | `grafana/loki` | Log storage, single binary, Cinder volume |
| `alloy` | `grafana/alloy` | DaemonSet that tails pod logs and pushes them to Loki |

> Promtail reached end of life in March 2026 and receives no security fixes.
> Alloy is its replacement and does the same job.

## Prerequisites

- The cluster is up and `cilium status` is healthy.
- The `csi-cinder-sc-delete` StorageClass exists, which the bootstrap creates.
- `helm` is available. The control plane already has it at `/usr/local/bin/helm`.

## Install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values manifests/observability/kube-prometheus-stack-values.yaml

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values manifests/observability/loki-values.yaml

helm upgrade --install alloy grafana/alloy \
  --namespace monitoring \
  --values manifests/observability/alloy-values.yaml
```

Loki comes before Alloy so the push endpoint already exists. Grafana can be
installed in any order; the Loki datasource is resolved when you query it.

## Verify

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get pvc
```

Expected:

- every pod `Running`, with one `alloy-*` pod per node
- two claims `Bound`: Prometheus and Loki, both on `csi-cinder-sc-delete`

Check that Alloy is reading logs:

```bash
kubectl -n monitoring logs ds/alloy --tail=20
```

## Open Grafana

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open <http://localhost:3000> and log in as `admin` with the password from
`manifests/observability/kube-prometheus-stack-values.yaml` (`changeme` by
default; change it before exposing Grafana).

- **Dashboards** already contain the Kubernetes and node dashboards.
- **Explore** with the `Loki` datasource: `{namespace="kube-system"}` shows logs
  from the control-plane components.
- **Explore** with the `Prometheus` datasource: `up` shows every scrape target.

To expose Grafana with Octavia instead of port-forwarding, change the Service to
`type: LoadBalancer` and point DNS at the floating IP. Do that only after
changing the admin password.

## Uninstall

```bash
helm -n monitoring uninstall alloy loki kube-prometheus-stack
kubectl delete namespace monitoring
```

Both claims use `csi-cinder-sc-delete`, so deleting the namespace also deletes
the Cinder volumes. Nothing is left behind.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no org id` in Grafana or Alloy logs | Loki runs with multi-tenancy (`auth_enabled: true`) and the request has no `X-Scope-OrgID` header. | The values file sets `loki.auth_enabled: false`. Re-run the Loki install after changing it. |
| Grafana shows no logs | Alloy cannot reach Loki, or the datasource URL is wrong. | `kubectl -n monitoring logs ds/alloy` and check the push URL. |
| PVC stays `Pending` | The StorageClass name does not exist. | `kubectl get storageclass` and fix `storageClassName` in the values files. |

## Notes

- Prometheus keeps 7 days of metrics. Raise `retention` and the volume size in
  the values file if you need more.
- Loki runs in single-binary mode with filesystem storage, which is enough for a
  lab. A production setup uses object storage and the scalable deployment mode.
- The stack is not scraped by itself; add a `ServiceMonitor` if you want
  Prometheus to monitor Loki or Alloy.
- The commands do not pin chart versions. Add `--version <chart-version>` to
  each install for reproducible upgrades.
