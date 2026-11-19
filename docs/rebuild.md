# Tear Down and Rebuild

Use this when the cluster needs a clean slate: an
`infra/cloud-init/kubernetes.yaml` change or a cluster that cannot be repaired
in place.

## Choose the right scope

| Goal | Command | Result |
|---|---|---|
| New nodes, keep network and floating IPs | `tofu -chdir=infra apply` | Instances are replaced because `user_data` changed, but the boot volumes are reused, so the OS is not clean. |
| Everything new | `tofu -chdir=infra destroy`, then `apply` | New network, security groups, floating IPs, boot volumes, VM password, and bootstrap token. |

Only the second option gives a genuinely fresh operating system. The rest of
this document covers that path.

## Before destroying

LoadBalancer Services and PersistentVolumeClaims create OpenStack resources
that Terraform does not manage. Delete them first, or they survive the teardown
and keep consuming quota.

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
`infra/cloud-init/kubernetes.yaml`. No manual post-boot step is required.

New floating IPs and a new VM password are generated on every rebuild:

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
