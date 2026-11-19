# Setup Kubernetes Cluster

The OpenTofu node bootstrap installs containerd, kubeadm, kubelet, and kubectl,
then initializes the control plane, installs Cilium, the OpenStack cloud
controller manager (CCM), and the Cinder CSI driver. Worker nodes wait for the
control-plane API and join with a generated bootstrap token.

## Deploy and bootstrap

From the repository root:

```bash
tofu -chdir=infra init
tofu -chdir=infra plan
tofu -chdir=infra apply
```

The control plane initializes with kubeadm and installs:

- Cilium through the Cilium CLI, with its pod CIDR kept in sync with
  `pod_network_cidr` and `kubeProxyReplacement=false` so kube-proxy remains in
  charge of Service traffic.
- `openstack-cloud-controller-manager`, which initializes nodes with their
  OpenStack provider IDs and removes the external-cloud-provider taint.
- `openstack-cinder-csi`, which provisions Cinder volumes through the
  `csi-cinder-sc-delete` StorageClass (made the cluster default) and
  `csi-cinder-sc-retain`.

Kubelet runs with `cloud-provider=external` on every node. The CCM uses the
OpenStack application credential from `terraform.tfvars`; the same credential
is stored in the `cloud-config` Secret in `kube-system` and consumed by the
Cinder CSI driver.

The CCM service (LoadBalancer) controller is disabled to avoid requiring
Octavia. Services of type `LoadBalancer` will stay pending unless you enable it
and add `[LoadBalancer]` settings to the cloud configuration.

Cloud-init can take several minutes. Follow the control-plane bootstrap log:

```bash
ssh fauzan@<control-plane-floating-ip>
sudo tail -f /var/log/cloud-init-output.log
```

When cloud-init finishes, verify the cluster:

```bash
ssh fauzan@<control-plane-floating-ip>
kubectl get nodes -o wide
kubectl get pods --all-namespaces
cilium status
kubectl -n kube-system get daemonset openstack-cloud-controller-manager
kubectl -n kube-system get daemonset openstack-cinder-csi-nodeplugin
kubectl -n kube-system get deployment openstack-cinder-csi-controllerplugin
kubectl get storageclass
```

Nodes should report an OpenStack provider ID:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
```

The Cinder controller plugin can remain `Pending` until at least one worker has
joined. The node plugin and the CCM run on the control plane immediately.

Create a test volume to confirm Cinder provisioning:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cinder-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
kubectl get pvc cinder-test
```

Delete the test claim when finished. The default `Delete` reclaim policy
removes the corresponding Cinder volume:

```bash
kubectl delete pvc cinder-test
```

Copy the admin kubeconfig to a workstation and point it at the control-plane
floating IP:

```bash
CP_FIP="$(tofu -chdir=infra output -json vm_floating_ips | jq -r '."kube-control-plane"')"
ssh "fauzan@${CP_FIP}" 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config
CLUSTER="$(kubectl config view -o jsonpath='{.contexts[0].context.cluster}')"
kubectl config set-cluster "${CLUSTER}" --server="https://${CP_FIP}:6443"
chmod 600 ~/.kube/config
kubectl get nodes -o wide
```

If `jq` is not installed, copy the control-plane floating IP from
`tofu -chdir=infra output vm_floating_ips` instead.
