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
- For the Gateway exposure below, Cilium must run with kube-proxy replacement
  (`kube_proxy_replacement = true`). Cilium's Gateway API controller does not
  work with kube-proxy.

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

kubectl apply -f manifests/observability/dashboards/
```

The Loki chart ships ten official dashboards (Writes, Reads, Chunks,
Operational, and so on) plus their recording rules. The `alloy-dashboard`
ConfigMap adds one dashboard for Alloy. Grafana's sidecar imports every
ConfigMap labelled `grafana_dashboard: "1"` in its namespace.

Loki comes before Alloy so the push endpoint already exists. Grafana can be
installed in any order; the Loki datasource is resolved when you query it.

## Verify

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get pvc
```

Expected:

- every pod `Running`, with one `alloy-*` pod per node
- three claims `Bound`: Prometheus, Loki, and Grafana, all on
  `csi-cinder-sc-delete`

Check that Alloy is reading logs:

```bash
kubectl -n monitoring logs ds/alloy --tail=20
```

Check that Prometheus scrapes both:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Open <http://localhost:9090/targets>. The `alloy` and `loki` targets must be
`UP`; the Alloy dashboard has no data until they are.

## Open Grafana

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open <http://localhost:3000> and log in as `admin` with the password from
`manifests/observability/kube-prometheus-stack-values.yaml` (`changeme` in the
repository; change it before exposing Grafana).

`adminPassword` only seeds an empty database. After the first start, change the
password in the UI or with:

```bash
kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
  grafana cli admin reset-admin-password '<new-password>'
```

Grafana keeps its database on a 1Gi Cinder volume, so the password, extra users,
API keys, and dashboard edits survive pod restarts. Keep a placeholder in the
repository and never commit the real password.

- **Dashboards** contain the Kubernetes and node dashboards, the ten Loki
  dashboards, and the `Alloy` dashboard.
- **Explore** with the `Loki` datasource: `{namespace="kube-system"}` shows logs
  from the control-plane components.
- **Explore** with the `Prometheus` datasource: `up` shows every scrape target.

## Expose Grafana with Gateway API

`manifests/observability/grafana-gateway.yaml` publishes Grafana on
`https://grafana.local.my.id`. Cilium creates a `LoadBalancer` Service, which
the OpenStack CCM turns into an Octavia load balancer with a floating IP.

This needs the Gateway API CRDs, `gatewayAPI.enabled=true`, and cert-manager with
`config.gatewayAPI.enabled=true`, as described in [tls.md](tls.md). It also needs
Cilium's kube-proxy replacement. None of that is part of the bootstrap, so repeat
the Cilium and cert-manager steps after a rebuild.

The file contains a `letsencrypt-prod` ClusterIssuer. If you already created one
from [tls.md](tls.md), keep a single copy and use the same ACME email in both
places, otherwise the apply overwrites the existing issuer.

Edit the ACME email in the ClusterIssuer, then apply:

```bash
kubectl apply -f manifests/observability/grafana-gateway.yaml
```

Read the floating IP and point an `A` record at it:

```bash
kubectl -n monitoring get service cilium-gateway-grafana
```

Then watch the certificate and the Gateway:

```bash
kubectl -n monitoring get certificate,challenge
kubectl -n monitoring get gateway grafana
```

Expected: `Certificate` and `Challenge` become ready, the Gateway reports
`PROGRAMMED=True`, `https://grafana.local.my.id` serves a valid certificate, and
`http://` redirects with `301`.

```bash
kubectl -n monitoring get httproute
curl -I https://grafana.local.my.id
curl -I http://grafana.local.my.id
```

HTTP-01 needs `grafana.local.my.id` to resolve to the load balancer from the
public internet and port 80 to be reachable. If the name is internal only, use a
DNS-01 solver or a self-signed issuer instead. The floating IP changes on a
rebuild, so update the DNS record afterwards.

## Expose Hubble UI

`manifests/observability/hubble-gateway.yaml` publishes the Hubble UI on
`https://hubble.local.my.id` with the same Gateway API and Let's Encrypt setup.
It creates a second Octavia load balancer, so this hostname gets its own
floating IP.

This needs Hubble itself, which the bootstrap enables only when
`kube_proxy_replacement = true`. Both Services must exist first:

```bash
kubectl -n kube-system get service hubble-ui hubble-relay
```

The HTTP-01 solver is bound to a single Gateway, which is why the file defines
its own `letsencrypt-prod-hubble` issuer. Keep its ACME email in sync with
`grafana-gateway.yaml`.

Apply it after the prerequisites in [tls.md](tls.md):

```bash
kubectl apply -f manifests/observability/hubble-gateway.yaml
kubectl -n kube-system get service cilium-gateway-hubble
```

Point an `A` record for `hubble.local.my.id` at that floating IP, then watch the
certificate:

```bash
kubectl -n kube-system get certificate,challenge
kubectl -n kube-system get gateway hubble
curl -s -o /dev/null -w '%{http_code}\n' https://hubble.local.my.id/
curl -s -o /dev/null -w '%{http_code}\n' -u admin:changeme https://hubble.local.my.id/
```

The first `curl` returns `401` (no credentials), the second `200`.

Open `https://hubble.local.my.id`, log in, and pick a namespace. Flows appear
once there is traffic; the connection indicator in the header turns green when
the UI reaches `hubble-relay`. An empty list usually means the namespace filter
matches nothing rather than a broken relay.

The floating IP changes on a rebuild, so update the `A` record afterwards.

> Hubble UI has no authentication of its own, so the manifest puts an nginx
> proxy (`hubble-auth`) in front of it with HTTP basic auth. Log in as `admin`
> with the placeholder password `changeme`.

Change the password before leaving it exposed. The proxy reads the htpasswd file
on every request, so only the Secret needs updating:

```bash
printf 'admin:%s\n' "$(openssl passwd -apr1 'new-password')" > /tmp/htpasswd
kubectl -n kube-system create secret generic hubble-auth \
  --from-file=htpasswd=/tmp/htpasswd --dry-run=client -o yaml | kubectl apply -f -
```

`kubectl apply -f manifests/observability/hubble-gateway.yaml` writes the
placeholder back, so also replace the hash in the manifest if you want the
repository to match the cluster.

Basic auth is one shared credential with no logout and no per-user audit. For
single sign-on, replace `hubble-auth` with `oauth2-proxy` in front of the same
Service and keep the route unchanged.

Remove it when you are done:

```bash
kubectl delete -f manifests/observability/hubble-gateway.yaml
```

Cilium then deletes the Octavia load balancer and its floating IP.

## Uninstall

```bash
helm -n monitoring uninstall alloy loki kube-prometheus-stack
kubectl delete namespace monitoring
```

All three claims use `csi-cinder-sc-delete`, so deleting the namespace also
deletes the Cinder volumes. Nothing is left behind. Deleting the namespace also
removes the Grafana Gateway, and Cilium then deletes the Octavia load balancer
behind it.

The Hubble Gateway lives in `kube-system`, so remove it separately:

```bash
kubectl delete -f manifests/observability/hubble-gateway.yaml
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no org id` in Grafana or Alloy logs | Loki runs with multi-tenancy (`auth_enabled: true`) and the request has no `X-Scope-OrgID` header. | The values file sets `loki.auth_enabled: false`. Re-run the Loki install after changing it. |
| Grafana shows no logs | Alloy cannot reach Loki, or the datasource URL is wrong. | `kubectl -n monitoring logs ds/alloy` and check the push URL. |
| PVC stays `Pending` | The StorageClass name does not exist. | `kubectl get storageclass` and fix `storageClassName` in the values files. |
| Browser keeps asking for the Hubble password | The Secret holds a different htpasswd than the one you type, or the browser cached an old credential | Re-apply the Secret as shown in [Expose Hubble UI](#expose-hubble-ui) and reopen the page in a private window. |
| Hubble UI loads but shows no flows | `hubble-relay` is not ready, or the selected namespace is idle | `kubectl -n kube-system get pods -l k8s-app=hubble-relay` and pick another namespace. |
| `Certificate` stays `READY=False` for a public hostname | The DNS `A` record is missing or still cached, so HTTP-01 cannot validate | `dig +short @1.1.1.1 <hostname>`, fix the record, then `kubectl -n <namespace> delete challenge --all`. |

## Notes

- Prometheus keeps 7 days of metrics. Raise `retention` and the volume size in
  the values file if you need more.
- Loki runs in single-binary mode with filesystem storage, which is enough for a
  lab. A production setup uses object storage and the scalable deployment mode.
- Loki and Alloy are scraped through ServiceMonitors labelled
  `release: kube-prometheus-stack`. That label must match the Helm release name
  of the Grafana stack; if you rename it, update the values files and the
  Prometheus `serviceMonitorSelector` together.
- The values file sets `grafana.ini.server.root_url` to the public hostname, so
  links in alerts and emails work. Change it if you use a different domain.
- Every public hostname gets its own Octavia load balancer and floating IP, so
  Grafana and Hubble together use two of each. Check your quota before adding
  more.
- The commands do not pin chart versions. Add `--version <chart-version>` to
  each install for reproducible upgrades.
