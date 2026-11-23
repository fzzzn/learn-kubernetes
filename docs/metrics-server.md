# metrics-server

`kubectl top`, HorizontalPodAutoscaler, and VerticalPodAutoscaler read the
`metrics.k8s.io` API, which nothing in this cluster provided until now. The
bootstrap installs Cilium, the CCM, and Cinder CSI only; Prometheus scrapes
cAdvisor and kubelet directly on a separate path, which is why dashboards worked
while `kubectl top` returned `Metrics API not available`.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update metrics-server

helm -n kube-system install metrics-server metrics-server/metrics-server \
  --version 3.14.0 -f manifests/metrics-server/values.yaml

kubectl -n kube-system rollout status deploy/metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io     # Available=True
kubectl top nodes
```

Expect `Available=True` within about 30 seconds and node figures that roughly
match Prometheus. The first `kubectl top pods` may report
`metrics not available yet` for a few seconds while the initial scrape lands.

## Why the TLS flags

`manifests/metrics-server/values.yaml` passes two arguments that are not
defaults:

| Argument | Reason |
|---|---|
| `--kubelet-insecure-tls` | kubelet serves its summary API with a certificate that has no address in its SAN list, so metrics-server cannot verify it. |
| `--kubelet-preferred-address-types=InternalIP` | Nodes publish no external address except the control plane; resolving by hostname can hit a name the API server cannot route. |

`--kubelet-insecure-tls` skips certificate verification, not encryption: traffic
still runs over TLS on the node-internal network. On a cluster with proper kubelet
certificates, drop it.

## Relation to Prometheus

They are not redundant and do not compete:

| | metrics-server | Prometheus |
|---|---|---|
| Retention | last scrape only | 7 days |
| Consumers | `kubectl top`, HPA, VPA | dashboards, alerts, queries |
| Storage | in memory | Cinder volume |

metrics-server keeps only the latest sample per pod, so it cannot answer
historical questions and is not a replacement for Prometheus. Prometheus cannot
serve the resource metrics API, so it is not a replacement for metrics-server.

Both scrape kubelet, so the extra load is one request per node every 15 seconds.

## Verify

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory | head
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | head -c 200
```
