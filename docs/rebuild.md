# Tear Down and Rebuild

Use this when the cluster needs a clean slate: a `cloud-init/kubernetes.yaml`
change, a rebuild after a failed upgrade, or a cluster that cannot be repaired
in place. To upgrade in place instead, see [upgrade.md](upgrade.md).

## Choose the right scope

| Goal | Command | Result |
|---|---|---|
| New nodes, keep network and floating IPs | `tofu -chdir=infra apply` | Instances are replaced because `user_data` changed, but the boot volumes are reused, so the OS is not clean. |
| Everything new | `tofu -chdir=infra destroy`, then `apply` | New network, security groups, floating IPs, boot volumes, VM password, and bootstrap token. |

Only the second option gives a genuinely fresh operating system. The rest of
this document covers that path.

## Stale provider ID after `apply`

The first option replaces the instances but keeps the boot volumes, so kubelet
reconnects with its existing certificates and the Node object survives. Its
`spec.providerID` still points at the instance that was deleted, so the CCM
cannot read the new one and stops refreshing the node:

```text
E1119 09:55:15.354301 12 node_controller.go:288] Error getting instance metadata for node addresses: instance not found
```

The symptom is an `EXTERNAL-IP` that no longer exists, for example a floating IP
that was removed by `worker_floating_ips = false`.

`spec.providerID` is immutable once set, so it cannot be patched. Delete the
Node object and let kubelet register it again, one node at a time:

```bash
kubectl delete node kube-worker-1
kubectl get nodes -w
```

Kubelet re-registers within a few minutes with an empty `providerID`, and the
CCM fills it from the current instance. Restart kubelet on that worker if the
node does not come back. Pods on the node are recreated by their DaemonSets;
the VM, its boot volume, and its data are untouched.

## Before destroying

LoadBalancer Services and PersistentVolumeClaims create OpenStack resources
that Terraform does not manage. Delete them first, or they survive the teardown
and keep consuming quota.

If a Gateway exists, delete it before the loop. Cilium owns the
`LoadBalancer` Service and recreates it when only the Service is deleted:

```bash
kubectl get gateway --all-namespaces
kubectl -n monitoring delete gateway grafana
kubectl -n kube-system delete gateway hubble
```

Delete the Octavia load balancers behind `LoadBalancer` Services:

```bash
kubectl get service --all-namespaces \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' |
  while read -r namespace name; do
    kubectl -n "${namespace}" delete service "${name}"
  done
```

Delete the claims. With the default `csi-cinder-sc-delete` StorageClass this
also removes the Cinder volumes:

```bash
kubectl delete pvc --all-namespaces --all
```

Claims using `csi-cinder-sc-retain` keep their volumes by design. Delete those
volumes manually if they are no longer needed:

```bash
openstack volume list
openstack volume delete <volume-id>
```

## Destroy

```bash
tofu -chdir=infra destroy
```

This removes everything in the state:

- Kubernetes instances and their boot volumes
- floating IPs and their associations
- the private network, subnet, router, and router interface
- the cluster and control-plane security groups and their rules
- the generated VM password and bootstrap token

It does not touch `terraform.tfvars`, the external network, or the image, and it
does not delete resources created inside the cluster (see above).

If a destroy fails part way through, fix the reported resource and run it again.
Re-running is safe because Terraform only acts on what is left in the state.

## Check for leftovers

```bash
openstack server list
openstack volume list
openstack floating ip list
openstack network list
openstack router list
openstack security group list
```

Any `kube-*` entry that remains is either unmanaged or was created outside
Terraform. Remove it before rebuilding if the names would collide. The Octavia
list requires the `python-octaviaclient` plugin:

```bash
openstack loadbalancer list
```

## Rebuild

```bash
tofu -chdir=infra apply
```

The bootstrap is fully automated: containerd, kubeadm, Cilium, the OpenStack
CCM (including Octavia load balancers), and Cinder CSI are installed from
`infra/cloud-init/kubernetes.yaml`. The base cluster needs no manual post-boot
step. Optional add-ons are not part of the bootstrap; see
[Reinstall in-cluster add-ons](#reinstall-in-cluster-add-ons).

New floating IPs and a new VM password are generated on every rebuild. The
control plane always gets one; workers get one each when
`worker_floating_ips = true`:

```bash
tofu -chdir=infra output vm_floating_ips
tofu -chdir=infra output -raw vm_password
```

## Verify the new cluster

Watch the control-plane bootstrap:

```bash
ssh fauzan@<control-plane-floating-ip>
sudo cloud-init status --wait
sudo tail -f /var/log/cloud-init-output.log
```

Then follow the verification and kubeconfig sections of
[setup.md](setup.md). The old workstation kubeconfig points at the previous
floating IP, so refresh it before running `kubectl`.

## Reinstall in-cluster add-ons

`destroy` + `apply` replaces the VMs, so every resource stored inside the
cluster is gone. These add-ons are not part of the bootstrap:

| Add-on | Install guide |
|---|---|
| Gateway API CRDs, Cilium `gatewayAPI.enabled`, cert-manager | [tls.md](tls.md) |
| Grafana, Prometheus, Loki, Alloy, and the Grafana and Hubble Gateways | [observability.md](observability.md) |

Install them in that order. The Gateways reference the `cilium` GatewayClass and
the `letsencrypt-prod` issuers from tls.md and observability.md. The Cilium
upgrade there uses `--reuse-values`, so the kube-proxy-free settings from
cloud-init are preserved.

The cluster is fully functional without them; nothing in `infra/` depends on
these add-ons.
