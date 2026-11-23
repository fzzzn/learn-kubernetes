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

## Resource limits

Every values file in `manifests/observability/` and `manifests/rancher/` sets
requests and a memory limit, sized from peaks measured on this cluster rather
than from the chart defaults (which set none at all):

| Workload | Peak seen | Limit |
|---|---|---|
| Prometheus | 761Mi | 2Gi |
| Rancher | 1497Mi | 2Gi |
| Grafana | 558Mi | 768Mi |
| Loki | 264Mi | 512Mi |
| Alloy (per node) | 236Mi | 384Mi |
| Alertmanager | 53Mi | 128Mi |

Before this, 73 containers ran without any memory limit while the scheduler saw
only 1.2Gi of requests against 9Gi actually in use. A pod could grow until the
kernel OOM-killed something on the node, and nothing stopped it at scheduling
time.

Rancher's limit is deliberately generous: its first-boot chart installation
burst to 1497Mi, and a tighter limit OOM-kills it mid-install, which leaves
system releases in `pending-install` (see [rancher.md](rancher.md)).

Raising one of these means re-running that chart's `helm upgrade` with the
values file. Limits do not apply retroactively to running pods.

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
`UP`; the Alloy dashboard has no data until they are. `kube-controller-manager`,
`kube-scheduler`, and `kube-etcd` are `UP` as well, because the bootstrap rebinds
those metrics endpoints to `0.0.0.0`. There is no `kube-proxy` target: the values
file disables that monitor for kube-proxy-free clusters.

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

## Expose Grafana and Hubble with Gateway API

`manifests/observability/gateway.yaml` publishes all three hostnames through one
Cilium Gateway, so they share a single Octavia load balancer and floating IP:

| Hostname | Backend |
|---|---|
| `grafana.local.my.id` | `kube-prometheus-stack-grafana` |
| `hubble.local.my.id` | `hubble-auth`, an nginx proxy in front of `hubble-ui` |
| `wordpress.local.my.id` | `wordpress` in the `wordpress` namespace |

This needs the Gateway API CRDs, `gatewayAPI.enabled=true`, and cert-manager with
`config.gatewayAPI.enabled=true`, as described in [tls.md](tls.md). It also needs
Cilium's kube-proxy replacement. None of that is part of the bootstrap, so repeat
the Cilium and cert-manager steps after a rebuild.

Hubble itself is enabled by `kube_proxy_replacement = true`. Both Services must
exist before its routes work:

```bash
kubectl -n kube-system get service hubble-ui hubble-relay
```

The file contains a `letsencrypt-prod` ClusterIssuer whose HTTP-01 solver points
at the `public` Gateway. If you already created one from [tls.md](tls.md), keep a
single copy and use the same ACME email in both places, otherwise the apply
overwrites the existing issuer.

One `Certificate` carries Grafana and Hubble, because `gatewayHTTPRoute.parentRefs`
accepts a single Gateway. Renewal fails for both names if either `A` record is
missing. WordPress has its own `wordpress-tls` Certificate and its own
`wordpress-http`/`wordpress-https` listener pair, so a missing wordpress record
only leaves WordPress on HTTP.

That listener pair also accepts routes from `monitoring`, because the HTTP-01
solver route lives there and must match `/.well-known/acme-challenge/` before the
HTTP listener's redirect to HTTPS. Without it the challenge answers `301` and
never validates.

Edit the ACME email in the ClusterIssuer, then apply:

```bash
kubectl apply -f manifests/observability/gateway.yaml
```

Read the floating IP and point the `A` records for all three names at it:

```bash
kubectl -n monitoring get service cilium-gateway-public
```

Then watch the certificates and the Gateway:

```bash
kubectl -n monitoring get certificate,challenge
kubectl -n monitoring get gateway public
```

Expected: both `Certificate` objects and the `Challenge` become ready, the Gateway
reports `PROGRAMMED=True` for every listener, all hostnames serve a valid
certificate, and `http://` redirects with `301`.

```bash
kubectl -n monitoring get httproute -A
curl -I https://grafana.local.my.id
curl -s -o /dev/null -w '%{http_code}\n' https://hubble.local.my.id/
curl -s -o /dev/null -w '%{http_code}\n' -u admin:changeme https://hubble.local.my.id/
curl -I https://wordpress.local.my.id
```

The Hubble requests return `401` without credentials and `200` with them. Open
`https://hubble.local.my.id`, log in, and pick a namespace. Flows appear once
there is traffic; the connection indicator in the header turns green when the UI
reaches `hubble-relay`. An empty list usually means the namespace filter matches
nothing rather than a broken relay.

HTTP-01 needs every name to resolve to the load balancer from the public
internet and port 80 to be reachable. If the names are internal only, use a
DNS-01 solver or a self-signed issuer instead. The floating IP changes on a
rebuild, so update all three records afterwards.

> Hubble UI has no authentication of its own, so the manifest puts an nginx
> proxy (`hubble-auth`) in front of it with HTTP basic auth. Log in as `admin`
> with the placeholder password `changeme`.

Change the password before leaving it exposed. The proxy reads the htpasswd file
on every request, so only the Secret needs updating:

```bash
printf 'admin:%s\n' "$(openssl passwd -apr1 'new-password')" > /tmp/htpasswd
kubectl -n monitoring create secret generic hubble-auth \
  --from-file=htpasswd=/tmp/htpasswd --dry-run=client -o yaml | kubectl apply -f -
```

`kubectl apply -f manifests/observability/gateway.yaml` writes the placeholder
back, so also replace the hash in the manifest if you want the repository to
match the cluster.

Basic auth is one shared credential with no logout and no per-user audit. For
single sign-on, replace `hubble-auth` with `oauth2-proxy` in front of the same
Service and keep the route unchanged.

Remove the exposure when you are done:

```bash
kubectl delete -f manifests/observability/gateway.yaml
```

Cilium then deletes the Octavia load balancer and its floating IP.

## Uninstall

```bash
helm -n monitoring uninstall alloy loki kube-prometheus-stack
kubectl delete namespace monitoring
```

All three claims use `csi-cinder-sc-delete`, so deleting the namespace also
deletes the Cinder volumes. Nothing is left behind. Deleting the namespace also
removes the public Gateway and the Hubble auth proxy, and Cilium then deletes the
Octavia load balancer behind it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no org id` in Grafana or Alloy logs | Loki runs with multi-tenancy (`auth_enabled: true`) and the request has no `X-Scope-OrgID` header. | The values file sets `loki.auth_enabled: false`. Re-run the Loki install after changing it. |
| Grafana shows no logs | Alloy cannot reach Loki, or the datasource URL is wrong. | `kubectl -n monitoring logs ds/alloy` and check the push URL. |
| PVC stays `Pending` | The StorageClass name does not exist. | `kubectl get storageclass` and fix `storageClassName` in the values files. |
| Browser keeps asking for the Hubble password | The Secret holds a different htpasswd than the one you type, or the browser cached an old credential | Re-apply the Secret as shown in [Expose Hubble UI](#expose-grafana-and-hubble-with-gateway-api) and reopen the page in a private window. |
| Hubble UI loads but shows no flows | `hubble-relay` is not ready, or the selected namespace is idle | `kubectl -n kube-system get pods -l k8s-app=hubble-relay` and pick another namespace. |
| `Certificate` stays `READY=False` for a public hostname | The DNS `A` record is missing or still cached, so HTTP-01 cannot validate | `dig +short @1.1.1.1 <hostname>`, fix the record, then `kubectl -n <namespace> delete challenge --all`. |
| `Challenge` self-check fails with `no such host` while `dig` resolves | The solver validates from inside the cluster through CoreDNS, not from your workstation. A record created seconds ago is not cached yet. | Wait a few minutes and let cert-manager retry, or restart the order with `kubectl -n monitoring delete challenge --all`. |
| WordPress returns `404` on the load balancer but works with `port-forward` | No HTTPRoute is attached, or the route is in a namespace its listener does not allow | `kubectl -n wordpress get httproute` and compare `allowedRoutes` on the `wordpress-http`/`wordpress-https` listeners. |

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
- All public hostnames share one Octavia load balancer and floating IP. Each
  additional Gateway costs another pair, so check your quota before adding one.
- The commands do not pin chart versions. Add `--version <chart-version>` to
  each install for reproducible upgrades.
