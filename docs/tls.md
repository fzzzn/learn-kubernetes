# TLS

Terminate TLS inside the cluster with Cilium's Gateway API implementation and
cert-manager. The Octavia load balancer stays a TCP passthrough, so certificates
never leave the cluster and nothing depends on Barbican.

- [architecture.md](architecture.md) for the Cilium and Octavia topology
- [setup.md](setup.md) for the initial deploy
- [upgrade.md](upgrade.md) when moving Cilium versions

> The community `kubernetes/ingress-nginx` project was retired in March 2026 and
> receives no further security fixes. New setups should use Gateway API. Cilium
> already ships the Envoy data plane as `cilium-envoy`, so no extra ingress
> controller is needed.

## Traffic flow

```text
client --443--> Octavia LB (TCP passthrough) --> NodePort --> Cilium Envoy --> pod
                                                              (TLS terminates)
```

Cilium creates a `LoadBalancer` Service for each Gateway. The OpenStack CCM
turns it into an Octavia load balancer with a floating IP, exactly like any
other `type: LoadBalancer` Service.

## Prerequisites

- Cilium is installed and `cilium status` reports `OK`.
- Cilium runs with kube-proxy replacement, which the Gateway API controller
  requires. This repository sets `kube_proxy_replacement = true` (see
  [infrastructure.md](infrastructure.md)).
- The cluster security group allows NodePort traffic from the subnet (it does
  by default, see [infrastructure.md](infrastructure.md)).
- A DNS name you control, for example `app.example.com`.

### Gateway API CRDs

Install the standard channel CRDs. Cilium 1.20 supports Gateway API v1.6.3;
check the [Gateway API releases](https://github.com/kubernetes-sigs/gateway-api/releases)
when you upgrade Cilium.

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

### Cilium Gateway API

The bootstrap installs Cilium without Gateway API, and the chart default is
`gatewayAPI.enabled: false`. Install the CRDs first, then enable it. The
upgrade reuses the existing values, so the kube-proxy-free settings, the API
server address, and Hubble stay as they are.

Check that kube-proxy replacement is already on:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
```

The output must contain `KubeProxyReplacement: True`. If it says `Disabled`,
stop here: set `kube_proxy_replacement = true` and rebuild before enabling
Gateway API. Switching in place is not supported, see
[infrastructure.md](infrastructure.md).

```bash
helm repo add cilium https://helm.cilium.io
helm repo update

helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --version 1.20.5 \
  --reuse-values \
  --set gatewayAPI.enabled=true

kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
```

Cilium creates a GatewayClass named `cilium`:

```bash
kubectl get gatewayclass
```

The bootstrap does not enable Gateway API, so after a `tofu destroy` + `apply`
repeat this section. It is the only part of the TLS setup that is not
reproducible from `infra/`.

### cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set config.gatewayAPI.enabled=true
```

`config.gatewayAPI.enabled=true` is required; without it the issuer and the
Gateway resources are ignored. If cert-manager was already running before the
Gateway API CRDs existed, restart it so it picks them up:

```bash
kubectl -n cert-manager rollout restart deployment/cert-manager
```

## Deploy the application

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.29
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: default
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
```

## Gateway

The Gateway declares both listeners. HTTPS references the Secret that
cert-manager fills in the next step.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: app.example.com
    - name: https
      protocol: HTTPS
      port: 443
      hostname: app.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: web-tls
```

## Certificate

### Issuer

HTTP-01 through the Gateway needs a listener on port 80. cert-manager creates a
temporary HTTPRoute for the challenge.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: web
                namespace: default
                kind: Gateway
```

If your DNS provider is supported by cert-manager, DNS-01 is more robust: it
does not need port 80 or a public challenge route, and it also works for
wildcard names.

`gatewayHTTPRoute.parentRefs` accepts a single Gateway, so one issuer can only
solve challenges for one Gateway. A Gateway can still serve several hostnames,
and a single Certificate can list several `dnsNames`; the repository does both
with the `public` Gateway. Only split into separate Gateways when you need
separate load balancers, and give each one its own issuer.

### Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: default
spec:
  secretName: web-tls
  dnsNames:
    - app.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

The Secret must live in the same namespace as the Gateway.

## Routes

Route HTTPS traffic to the Service and redirect HTTP to HTTPS:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web
  namespace: default
spec:
  parentRefs:
    - name: web
      sectionName: https
  hostnames:
    - app.example.com
  rules:
    - backendRefs:
        - name: web
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-redirect
  namespace: default
spec:
  parentRefs:
    - name: web
      sectionName: http
  hostnames:
    - app.example.com
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

## DNS

Read the floating IP assigned to the Gateway Service:

```bash
kubectl get service cilium-gateway-web \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Point an `A` record for `app.example.com` at that address. The name of the
Service is `cilium-gateway-<gateway-name>`.

The address belongs to the Octavia load balancer and changes if the Service is
recreated, for example after `tofu destroy` + `apply`. Update DNS after a
rebuild, or automate the record with your DNS provider.

For a complete example, see [observability.md](observability.md), which exposes
Grafana on `https://grafana.local.my.id` and the Hubble UI on
`https://hubble.local.my.id`.

## Verify

```bash
kubectl get gateway web
kubectl get certificate web-tls
kubectl get challenge
kubectl get service cilium-gateway-web

curl -I https://app.example.com
curl -I http://app.example.com
```

Expected:

- the Gateway reports `PROGRAMMED=True`
- the Certificate reports `READY=True`
- `https://` returns `200` with a valid Let's Encrypt certificate
- `http://` returns `301` to `https://`

Check the certificate chain from outside the cluster:

```bash
openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null |
  openssl x509 -noout -subject -issuer -dates
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `GatewayClass cilium not found` | Gateway API CRDs missing or `gatewayAPI.enabled=false`. | Install the CRDs and enable the feature. |
| Certificate stuck `READY=False`, Challenge pending | DNS does not resolve to the load balancer, or port 80 is unreachable. | Check the `A` record and the Gateway HTTP listener. |
| HTTPRoute reports `ResolvedRefs=False` | Backend Service name or port is wrong. | Fix `backendRefs` and recheck `kubectl get httproute`. |
| `503` from Envoy | Service has no ready endpoints. | Check the Deployment and `kubectl get endpoints web`. |
| Browser shows the wrong certificate | `certificateRefs` points at a different Secret, or the Secret is in another namespace. | Keep the Secret next to the Gateway. |
| `curl` times out | Floating IP missing or NodePort blocked. | Check the Service `EXTERNAL-IP` and the cluster security group. |

## Octavia termination instead

Terminating TLS on Octavia is possible on this cloud, but the CCM has no
annotation for certificates, so it is a manual path. Barbican must be available
(verify with `openstack secret list`; a successful empty list means it works).

```bash
openssl pkcs12 -export -out server.p12 \
  -inkey server.key -in server.crt -certfile chain.crt

openstack secret store --name web-tls \
  --secret-type certificate \
  --payload-content-type application/octet-stream \
  --file server.p12 \
  -f value -c "Secret href"
```

Attach a `TERMINATED_HTTPS` listener to the load balancer with
`--default-tls-container-ref <secret-ref>`. Because the CCM reconciles the
listeners of Services it manages, run this only against a Service of type
`NodePort` and manage the load balancer yourself (CLI or Terraform). You then
own the floating IP, the security groups, the health monitor, and certificate
renewal.

For most clusters the Gateway API path above is simpler: certificates are
renewed automatically and the load balancer stays a plain L4 passthrough.

## Shell note

Commands in this repository use bash syntax. In fish, use `set NAME (command)`
instead of `NAME=$(command)`, or run the snippet with `bash -c '...'`.
