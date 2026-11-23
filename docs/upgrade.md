# Upgrading

How to move the cluster to newer Kubernetes, Cilium, and OpenStack
cloud-provider versions. Everything is pinned in `infra/variables.tf`, so an
upgrade always starts by changing a pin.

- [setup.md](setup.md) for the initial deploy
- [rebuild.md](rebuild.md) for a full teardown
- [architecture.md](architecture.md) for component versions and topology

## Version pins

| Variable | Component | Current default |
|---|---|---|
| `kubernetes_version` | kubelet, kubeadm, kubectl | `1.36.6` |
| `cilium_version` | Cilium | `v1.20.5` |
| `cilium_cli_version` | Cilium CLI | `v0.20.3` |
| `helm_version` | Helm | `v3.19.0` |
| `openstack_cloud_provider_chart_version` | OpenStack CCM and Cinder CSI charts | `2.36.5` |

The charts track Kubernetes: `2.36.x` ships app version `v1.36.0`, so a
Kubernetes minor upgrade needs the matching chart minor.

## Choose a path

| Path | Use when | Cost |
|---|---|---|
| [Rebuild](#path-a-rebuild-with-new-pins) | You want the new versions baked into cloud-init, or the cluster is disposable. | New nodes; in-cluster workloads are lost. |
| [In-place](#path-b-in-place-upgrade) | You need to keep running workloads. | More steps, some API downtime on this single control plane. |

The bootstrap in `infra/cloud-init/kubernetes.yaml` only runs at first boot, so
changing a pin does not upgrade a running node. A rebuild is the only way to
make the new pins the source of truth again.

## Before you start

- **Read the compatibility notes.** Cilium publishes a supported Kubernetes
  range per release, and the cloud-provider-openstack chart targets one
  Kubernetes minor. Do not jump a minor before both support it.
- **Upgrade one Kubernetes minor at a time** (`1.36` -> `1.37` -> `1.38`).
  Patch releases within a minor are safe.
- **Upgrade Cilium one release at a time** and follow its upgrade guide for the
  target version. Patch upgrades are safe in place.
- **Keep `kube_proxy_replacement` unchanged.** Switching between kube-proxy and
  Cilium's eBPF datapath is a rebuild, not an upgrade step.
- **Snapshot etcd** before touching the control plane:

  ```bash
  kubectl -n kube-system exec etcd-kube-control-plane -- \
    etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      snapshot save /var/lib/etcd/snapshot.db

  # /var/lib/etcd is a hostPath, so the file is on the control-plane node.
  sudo cp /var/lib/etcd/snapshot.db /root/etcd-snapshot.db
  ```

- **Snapshot the boot volumes** if you plan to roll back:

  ```bash
  openstack volume list
  openstack volume snapshot create --volume <volume-id> <name>-pre-upgrade
  ```

## Path A: rebuild with new pins

This is the simplest path and the one this repository is built for.

1. Update the pins in `infra/variables.tf`.
2. Review the plan:

   ```bash
   tofu -chdir=infra plan
   ```

   A pin change alters `user_data`, so expect the four instances and their
   floating IP associations to be replaced.

3. Clean up in-cluster resources that Terraform does not manage (load balancers,
   PVCs) as described in [rebuild.md](rebuild.md).
4. Rebuild with a clean OS:

   ```bash
   tofu -chdir=infra destroy
   tofu -chdir=infra apply
   ```

   A plain `apply` replaces the instances but reuses the boot volumes, so the
   old OS and its cloud-init state survive. `destroy` + `apply` guarantees the
   new bootstrap runs on a fresh disk.

5. Refresh the floating IPs and kubeconfig, then verify as in
   [setup.md](setup.md).

## Path B: in-place upgrade

All node commands below run as root on the node. Run `kubectl` commands on the
control plane with `KUBECONFIG=/etc/kubernetes/admin.conf` or the copied
kubeconfig.

### 1. Control plane

Move the package repository to the target minor, then upgrade kubeadm and the
cluster:

```bash
# On the control plane
sed -i 's|/v1.36/|/v1.37/|' /etc/apt/sources.list.d/kubernetes.list
apt-get update

apt-mark unhold kubeadm
apt-get install -y kubeadm=1.37.0-1.1
apt-mark hold kubeadm

kubeadm upgrade plan
kubeadm upgrade apply v1.37.0
```

`kubeadm upgrade apply` rewrites the static pod manifests, certificates, and
kubelet configuration. If the release changes the kubeadm config API version,
`kubeadm upgrade plan` reports it. Migrate the stored config and keep the new
file for future upgrades:

```bash
kubeadm config migrate \
  --old-config /etc/kubernetes/kubeadm-init.yaml \
  --new-config /tmp/kubeadm-init.yaml
```

Then upgrade the local kubelet and kubectl:

```bash
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.37.0-1.1 kubectl=1.37.0-1.1
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
kubectl get nodes
```

The control plane reports the new version. This cluster has a single control
plane, so the API is briefly unavailable during `kubeadm upgrade apply`.

`kubeadm upgrade apply` re-applies its CoreDNS addon, which resets the
Deployment to two replicas with a preferred anti-affinity. Re-run the two
commands from the bootstrap after every upgrade:

```bash
kubectl -n kube-system scale deployment/coredns \
  --replicas="$(kubectl get nodes --no-headers | wc -l)"
kubectl -n kube-system patch deployment/coredns --type=merge -p '{
  "spec": {
    "strategy": {"type": "RollingUpdate",
      "rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}},
    "template": {"spec": {"affinity": {"podAntiAffinity": {
      "requiredDuringSchedulingIgnoredDuringExecution": [{
        "labelSelector": {"matchExpressions": [{"key": "k8s-app",
          "operator": "In", "values": ["kube-dns"]}]},
        "topologyKey": "kubernetes.io/hostname"}]}}}}}}'
kubectl -n kube-system rollout status deployment/coredns

kubectl -n kube-system create poddisruptionbudget coredns \
  --selector k8s-app=kube-dns --min-available=2 \
  --dry-run=client -o yaml | kubectl apply -f -
```

Without this, all CoreDNS replicas can land on one node again and a single node
failure takes cluster DNS down with it.

### 2. Cilium

Install the matching CLI first, then upgrade. `cilium upgrade` reuses the values
set by `cilium install` (pod CIDR, `kubeProxyReplacement`, and Hubble).

```bash
ARCH=amd64
CLI_VERSION=v0.21.0
CLI_TARBALL="cilium-linux-${ARCH}.tar.gz"
curl -fsSL -o "/tmp/${CLI_TARBALL}" \
  "https://github.com/cilium/cilium-cli/releases/download/${CLI_VERSION}/${CLI_TARBALL}"
curl -fsSL -o "/tmp/${CLI_TARBALL}.sha256sum" \
  "https://github.com/cilium/cilium-cli/releases/download/${CLI_VERSION}/${CLI_TARBALL}.sha256sum"
(cd /tmp && sha256sum --check "${CLI_TARBALL}.sha256sum")
tar -xzf "/tmp/${CLI_TARBALL}" -C /usr/local/bin cilium

cilium upgrade --version v1.21.0
cilium status --wait --wait-duration 10m
```

Do not run `cilium status --wait` while the CCM is down: with
`cloud-provider=external` the node addresses are published by the CCM.

### 3. Workers, one at a time

Drain, upgrade, uncordon. Repeat for `kube-worker-2` and `kube-worker-3`.

```bash
# On the control plane
kubectl drain kube-worker-1 --ignore-daemonsets --delete-emptydir-data

# On kube-worker-1
sed -i 's|/v1.36/|/v1.37/|' /etc/apt/sources.list.d/kubernetes.list
apt-get update

apt-mark unhold kubeadm
apt-get install -y kubeadm=1.37.0-1.1
apt-mark hold kubeadm
kubeadm upgrade node

apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.37.0-1.1 kubectl=1.37.0-1.1
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet

# On the control plane
kubectl uncordon kube-worker-1
```

`kubeadm upgrade node` on a worker refreshes the kubelet configuration only; it
does not touch etcd or the control plane.

### 4. OpenStack CCM and Cinder CSI

Upgrade both charts with the same values the bootstrap uses. Set `--version` to
the new chart release (for example `2.37.0` for Kubernetes 1.37).

```bash
helm upgrade --install openstack-cloud-controller-manager \
  openstack-cloud-controller-manager \
  --repo https://kubernetes.github.io/cloud-provider-openstack \
  --version 2.37.0 \
  --namespace kube-system \
  --set cluster.name=kube \
  --set secret.enabled=true \
  --set secret.create=false \
  --set secret.name=cloud-config \
  --set dnsPolicy=Default \
  --set "enabledControllers={cloud-node,cloud-node-lifecycle,service}" \
  --wait --timeout 10m

helm upgrade --install openstack-cinder-csi \
  openstack-cinder-csi \
  --repo https://kubernetes.github.io/cloud-provider-openstack \
  --version 2.37.0 \
  --namespace kube-system \
  --set clusterID=kube \
  --set secret.enabled=true \
  --set secret.create=false \
  --set secret.name=cloud-config \
  --set csi.plugin.nodePlugin.dnsPolicy=Default \
  --set csi.snapshotter.enabled=false \
  --set storageClass.enabled=true \
  --set storageClass.delete.isDefault=true

kubectl -n kube-system rollout status \
  daemonset/openstack-cinder-csi-nodeplugin --timeout=5m
```

Keep `dnsPolicy=Default`: CoreDNS cannot schedule until the CCM clears the
`uninitialized` taint, so the CCM and CSI must not depend on cluster DNS.

### 5. Node packages

Apply OS updates on one node at a time, draining first:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# On the node
apt-get update
apt-get upgrade -y
# Reboot if the kernel or containerd changed
reboot
# On the control plane, once the node is Ready
kubectl uncordon <node>
```

## Verify the upgrade

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
cilium status
kubectl get storageclass
```

Expected:

- every node reports the new `VERSION`
- CCM, Cinder node plugin, Cilium, and Cilium Envoy pods are `Running`
- `Cilium: OK`
- `csi-cinder-sc-delete (default)` and `csi-cinder-sc-retain` still exist

Then rerun the storage and load-balancer smoke tests in [setup.md](setup.md).

## Rollback

| Component | Rollback |
|---|---|
| Kubernetes control plane | No downgrade. Restore the etcd snapshot or rebuild with the old pins. |
| Kubernetes packages | Reinstall the previous version (`apt-get install kubelet=<old>-1.1`), but the control plane must be restored from etcd. |
| Cilium | `cilium upgrade --version <previous>`; `helm rollback cilium -n kube-system` also works. |
| CCM / Cinder CSI | `helm rollback openstack-cloud-controller-manager -n kube-system` and `helm rollback openstack-cinder-csi -n kube-system`. |
| Everything | `tofu -chdir=infra destroy` then `apply` with the previous pins. |

In practice the reliable rollback for this cluster is the rebuild path: revert
`infra/variables.tf` and run [rebuild.md](rebuild.md). Keep the etcd snapshot
and boot-volume snapshots until the new version has run for a while.

## Upgrade order

1. Kubernetes control plane (`kubeadm upgrade apply`, then kubelet).
2. Re-apply the CoreDNS scale, anti-affinity, and PDB (step 1 above).
3. Cilium.
4. Workers, one at a time.
5. OpenStack CCM and Cinder CSI charts.
6. Node OS packages.

## In-cluster add-ons

These are installed by hand, so nothing upgrades them automatically. They are
independent of the Kubernetes version and can be bumped at any time:

| Add-on | Upgrade |
|---|---|
| cert-manager | `helm -n cert-manager upgrade cert-manager jetstack/cert-manager --version <new> --reuse-values --set crds.enabled=true` |
| Gateway API CRDs | `kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/<new>/standard-install.yaml` |
| kube-prometheus-stack, Loki, Alloy | `helm -n monitoring upgrade <release> <chart> -f manifests/observability/<release>-values.yaml --reuse-values` |
| metrics-server | `helm -n kube-system upgrade metrics-server metrics-server/metrics-server -f manifests/metrics-server/values.yaml` |
| WordPress | See [wordpress.md](wordpress.md#upgrade): the tag, the rollout, and the database upgrade step. |
| Rancher | `helm -n cattle-system upgrade rancher rancher-stable/rancher -f manifests/rancher/values.yaml --reuse-values` |

One ordering rule matters: upgrade the Gateway API CRDs before Cilium if the
new CRD release is required by the Cilium version, and re-run
`manifests/observability/gateway.yaml` afterwards so the listeners reconcile.

Check after any add-on upgrade:

```bash
helm list -A
kubectl get certificate -n monitoring
kubectl get gateway -n monitoring
```

