---
type: platform-adapter
title: Kubernetes 叢集（k3d 開發 / k3s 生產）
description: The two clusters, their differing CPU architectures, and what a single node cannot test.
tags:
  - kubernetes
  - k3s
  - multi-arch
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/k8s — the two clusters, and why there are two

## What this directory is for

Kubernetes is where the pilot is deployed and where blue/green promotion is
verified. Since 2026-08-31 there are **two** clusters, on two machines, with
**different CPU architectures**. That last fact is not a detail; it is the
thing most likely to bite anyone reading this.

| | Mac (`k3d-devops-lab`) | Ubuntu box (`ubu`) |
|---|---|---|
| Role | **dev + SIT + UAT** | **prod** |
| Substrate | k3d — nodes are Docker containers inside a Linux VM | k3s — a systemd service on bare metal |
| Arch | `linux/arm64` (Apple Silicon) | `linux/amd64` (Intel i7-6700HQ) |
| Nodes | 1 server + 2 agents | 1 server, single node |
| Built by | `create_cluster.sh` | `bootstrap_k3s.sh` |
| Reached as | `kubectl --context k3d-devops-lab` | `kubectl --context ubu` |

## Start here

```bash
# the Mac practice cluster (dev/SIT/UAT)
platform/k8s/create_cluster.sh
platform/k8s/verify_cluster.sh

# the Ubuntu production cluster -- idempotent, safe to re-run
platform/k8s/bootstrap_k3s.sh
kubectl --context ubu get nodes
```

## The one thing that will bite you: architecture

Every image built on the Mac is **arm64 only**. Sending one to the Ubuntu
cluster fails, and it fails *late and quietly*:

```
docker save        -> succeeds
ctr images import  -> "saved", exit 0
ctr images ls      -> the image is listed, with a size
kubectl apply      -> accepted, Deployment created
kubelet            -> ErrImageNeverPull
containerd (in a log line nobody reads)
                   -> no match for platform in manifest: not found
```

This was proven by doing it, on 2026-08-31, not inferred. It is the same shape
as this platform's other recurring defect: **something registers as present but
cannot execute** (`promtool check rules` reporting SUCCESS on a rule that fails
every evaluation cycle; `tofu apply` reporting "10 resources created" while
creating nothing).

The guard is `platform/tests/test_image_arch.sh`. It asserts every own-built
image deployed to a cluster carries a build for that cluster's architecture,
and it reports **VACUOUS** rather than PASS for a cluster with no own-built
images — because "every image matches" is trivially true of an empty set, and a
green line meaning "nothing was examined" is the failure the guard exists for.

Do not fix an architecture mismatch by emulating. The build must happen on a
machine of the target architecture, or in CI on a runner of that architecture.

## Why the Ubuntu cluster is a single node

There is one physical machine. A second node would be a second k3s process on
the same kernel, sharing the same RAM and the same disk — the same failure
domain — so it would test nothing that one node does not, while costing a
control plane's worth of overhead. This would be the right choice at 64 GB too.

**What single-node therefore cannot test, and must never be claimed as tested:**

- node drain / cordon and the rescheduling that follows
- pod anti-affinity *across nodes*
- eviction on node failure

Blue/green, rolling updates and PodDisruptionBudget `minAvailable` **are**
testable here, because they are pod-level behaviours.

## Why Traefik is disabled on the Ubuntu cluster

The k3d cluster has no ingress controller either. Keeping the two substrates
identical except for the single variable under test — containers-in-a-VM versus
systemd on metal — is what makes a behavioural difference attributable to that
variable. Ingress is a later step with its own verification, not something that
arrives by default and is therefore never examined.

## Files

| File | What it does |
|---|---|
| `create_cluster.sh` | Rebuilds the k3d practice cluster on the Mac, with a registry wired in at creation time. Produces an empty, reachable cluster and stops. |
| `bootstrap_k3s.sh` | Installs k3s on the Ubuntu box over SSH, merges its kubeconfig into `~/.kube/config` as context `ubu`, and verifies reachability **from the Mac**. Idempotent. |
| `verify_cluster.sh` | Asserts the cluster is usable, not merely present. |
| `station2-twin/` | The pilot's manifests, blue/green promotion, and network policy. |
| `station2-twin/metrics-service.yaml` | A NodePort that makes the in-cluster copy reachable by the Prometheus outside it. It carries the same `color` selector as the traffic Service, so the metrics describe the copy that is actually serving. |

Neither bootstrap script deploys a workload, deliberately. Bundling substrate
and workload makes a failure ambiguous between the two.

## Known gaps (as of 2026-08-31)

1. **The Ubuntu cluster has no workload yet.** `test_image_arch.sh` reports it
   VACUOUS, which is the honest state.
2. **The pilot's K8s copy on the Mac runs on a static database password**
   (`PGPASSWORD=twin-bootstrap`), not Vault dynamic credentials — while the
   Compose copy does use Vault. The board's "migrated to K8s" claim is
   therefore true of the deployment and not of the credential path.
   *(The other half of this — the K8s copy being unscraped — was closed on
   2026-09-01: see `station2-twin/metrics-service.yaml` and
   `platform/tests/test_migration_observed.sh`.)*
3. **The Ubuntu box was unreachable at the time of writing** (SSH and 6443 both
   timed out while its NIC still answered ARP — consistent with suspend).
   A host that suspends is not yet a production host; that must be settled
   before the `prod` label means anything.
