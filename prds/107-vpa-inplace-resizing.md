# PRD #107: VPA and In-Place Pod Resizing for Cluster Resource Optimization

**Status**: Draft
**Priority**: High
**Created**: 2026-04-06
**GitHub Issue**: [#107](https://github.com/vfarcic/dot-ai-infra/issues/107)

---

## Problem Statement

The dot-ai GKE cluster (v1.33, 3 nodes, 2 vCPU / 8GB each) has ~28 workloads with wildly inaccurate resource allocations:

- **Over-provisioned**: Many workloads request 5-100x their actual usage (e.g., `dot-ai-website` requests 100m CPU / 128Mi memory but uses 1m / 15Mi)
- **No limits at all**: ~15 workloads (Argo CD, External Secrets, monitoring stack, Jaeger, Qdrant, Dex, Crossplane providers) have zero resource requests/limits, risking noisy-neighbor issues
- **Under-provisioned**: Some workloads have requests set too low (e.g., `dot-ai-controller-manager` requests 10m CPU but uses 12m)
- **No autoscaling**: No VPA or HPA is configured; all workloads are single-replica
- **Manual tuning**: Any resource adjustment requires manual editing and pod restarts

This wastes cluster capacity, risks OOM kills and CPU throttling, and makes cost optimization impossible.

## Solution Overview

Implement Vertical Pod Autoscaler (VPA) progressively from `Off` to `Auto` mode, combined with Kubernetes in-place pod resizing (available since K8s 1.32 beta, enabled by default on GKE 1.33), to automatically right-size workloads without restarts.

The phased approach ensures safety: observe first, then automate stable workloads, while keeping manual control over bursty/critical ones.

## Workload Classification

Based on cluster analysis (actual usage collected 2026-04-06):

### Stateful/Critical (in-place resize priority)
| Workload | Namespace | Current Requests | Actual Usage | Issue |
|---|---|---|---|---|
| Prometheus | monitoring | none | 234m CPU / 539Mi | No limits, highest resource consumer |
| Qdrant | dot-ai | none | 5m / 81Mi | StatefulSet, vector DB data |
| Argo CD app-controller | argocd | none | 22m / 529Mi | StatefulSet, sync state in memory |
| Grafana | monitoring | none | 16m / 281Mi | Dashboard availability |

### Stable/Low-Traffic (VPA Auto candidates)
| Workload | Namespace | Current Requests | Actual Usage |
|---|---|---|---|
| external-secrets (3 pods) | external-secrets | none | 1-2m / 27-36Mi each |
| dot-ai-stack-dex | dot-ai | none | 1m / 18Mi |
| dot-ai-website | dot-ai | 100m / 128Mi | 1m / 15Mi |
| node-exporter (DaemonSet) | monitoring | none | 3-4m / 8-9Mi |
| jaeger | jaeger | none | 3m / 17Mi |
| crossplane-rbac-manager | crossplane-system | 100m / 256Mi | 2m / 21Mi |
| argocd-redis | argocd | none | 8m / 8Mi |
| argocd-notifications | argocd | none | 1m / 30Mi |
| argocd-applicationset | argocd | none | 2m / 34Mi |
| argocd-dex-server | argocd | none | 1m / 29Mi |

### Bursty/Variable (VPA Off or Initial, manual tuning)
| Workload | Namespace | Current Requests | Actual Usage | Notes |
|---|---|---|---|---|
| dot-ai (MCP server) | dot-ai | 200m / 512Mi | 3m / 262Mi | Spiky under AI workloads |
| dot-ai-controller-manager | dot-ai | 10m / 128Mi | 12m / 197Mi | Exceeds CPU request |
| argocd-repo-server | argocd | none | 3m / 154Mi | Spikes during git operations |
| argocd-server | argocd | none | 2m / 45Mi | API traffic varies |
| dot-ai-stack-agentic-tools | dot-ai | 100m / 128Mi | 3m / 58Mi | AI workload dependent |

### Infrastructure (careful tuning)
| Workload | Namespace | Current Requests | Actual Usage |
|---|---|---|---|
| crossplane | crossplane-system | 100m / 256Mi | 4m / 172Mi |
| crossplane GCP providers (2) | crossplane-system | none | 2-9m / 128-145Mi |
| kube-state-metrics | monitoring | none | 8m / 30Mi |
| prometheus-operator | monitoring | none | 6m / 49Mi |
| youtube-automation | youtube-automation | 100m / 128Mi | 1m / 22Mi |

## Milestones

### Phase 1: VPA Installation + Observation

- [x] **VPA operator installed via GKE managed addon** — Enabled VPA on the GKE cluster using `gcloud container clusters update --enable-vertical-pod-autoscaling` (GKE-managed, auto-updated by Google). Updated `scripts/kubernetes.nu` with `--enable-vertical-pod-autoscaling` flag for future cluster creation. VPA CRD (`autoscaling.k8s.io/v1`) is available and functional.
- [x] **VPA objects created in Off mode for all workloads** — Created 22 VPA resources in Off mode across all namespaces, co-located with their respective Argo CD Application manifests in `apps/` and `apps-youtube/`. A new `apps/argocd-vpa.yaml` was created for the 7 Argo CD component VPAs. All VPAs are producing recommendations via `kubectl get vpa -A`.

### Phase 2: In-Place Resizing via Kyverno Mutating Policy

- [x] **Kyverno installed via Argo CD** — Deployed Kyverno v3.3.4 as an Argo CD Application in `apps/kyverno.yaml` using the official Helm chart. Reports controller and cleanup hooks disabled (unused, and hooks depended on unavailable bitnami/kubectl image). All 3 controllers (admission, background, cleanup) running healthy with mutating webhooks registered. VPA objects in Off mode co-located and producing recommendations.
- [ ] **Kyverno mutating policy injects resizePolicy on all pods** — Create a Kyverno ClusterPolicy that automatically adds `resizePolicy: [{resourceName: cpu, restartPolicy: NotRequired}, {resourceName: memory, restartPolicy: NotRequired}]` to all containers in all pods cluster-wide. This eliminates the need for per-chart Helm value support or manual patching.
- [ ] **In-place resize validated** — Manually adjust resources on stateful/critical workloads (Prometheus, Qdrant, Argo CD application-controller, Grafana) and confirm the resize status field shows `""` (completed) without pod restart. Verify workloads remain healthy during and after resize.

### Phase 3: VPA Auto Mode for Stable Workloads

- [ ] **Stable workloads switched to VPA Auto** — Move external-secrets, dex, dot-ai-website, node-exporter, jaeger, crossplane-rbac-manager, argocd-redis, argocd-notifications, argocd-applicationset, argocd-dex-server, youtube-automation to `updateMode: "Auto"`. These are low-traffic, predictable workloads where automatic right-sizing is safe.
- [ ] **In-place resize verified for Auto-mode workloads** — Confirm Kyverno policy is injecting `resizePolicy` on Auto-mode workload pods so VPA-driven changes apply without restarts.

### Phase 4: Full Rollout + Monitoring

- [ ] **Remaining workloads graduated to appropriate VPA mode** — Move bursty workloads to `Initial` mode (sets resources on pod creation but doesn't update running pods). Move infrastructure workloads to `Auto` with conservative policies (minAllowed/maxAllowed bounds). Keep only truly unpredictable workloads (dot-ai MCP server) in `Off` mode with manual review.
- [ ] **VPA monitoring and alerting in place** — Grafana dashboard showing VPA recommendations vs actual usage per workload, with alerts for significant recommendation drift (>50% difference sustained over 24h).
- [ ] **Resource governance documented** — Document the VPA policy: which workloads get Auto vs Initial vs Off, how to add VPA to new workloads, and the review process for manual-mode workloads.

## Success Criteria

1. **All workloads have VPA-managed resource requests** — VPA in Auto mode sets and maintains resource requests based on observed usage, eliminating manual guesswork
2. **Resource waste reduced by >60%** — Total requested resources across the cluster are within 2-3x of actual usage (down from current 5-100x)
3. **No restart-induced outages during resizing** — Stateful workloads (Prometheus, Qdrant) resize in-place without data loss or monitoring gaps
4. **VPA Auto covers >50% of workloads** — Majority of stable workloads are automatically right-sized
5. **Recommendation visibility** — All VPA recommendations are visible in Grafana for capacity planning

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| VPA Auto sets resources too low, causing OOM | Pod crashes, service disruption | Use `minAllowed` bounds based on observed P95 usage; start with Off mode to validate recommendations before enabling Auto |
| In-place resize fails for memory (kernel limitation) | Pod restart required anyway | Memory resize may require restart on some workloads; test each target individually in Phase 2 before relying on it |
| VPA conflicts with HPA | Unpredictable scaling behavior | No HPAs exist currently; if HPA is added later, use VPA only for memory and let HPA handle CPU |
| Crossplane/Argo CD helm charts override resource settings | VPA changes get reverted on sync | Configure VPA `containerPolicies` with appropriate bounds; for Helm-managed resources, set resources in Helm values so Argo CD and VPA don't conflict |
| GKE in-place resize beta stability | Unexpected behavior | Feature is beta since 1.32 and enabled by default on GKE; monitor for issues and have restart-based fallback |

## Decision Log

### 2026-04-06: Skip manual resource baseline — let VPA observe and set resources

**Decision**: Removed the Phase 1 task "All workloads have resource requests and limits" (manual baseline). Instead, go directly to VPA Off mode for observation, then let VPA Auto set the correct values automatically.

**Rationale**: VPA in Off mode can observe actual usage and produce recommendations without needing pre-existing requests/limits. Manually setting baseline values with 2-3x multipliers is unnecessary work — VPA will overwrite them when switched to Auto mode. Letting VPA handle it produces data-driven values rather than human guesses. CPU limits in particular cause unnecessary throttling and should be avoided; VPA manages requests intelligently without the downsides of static limits.

**Impact**: Phase 1 reduced from 3 tasks to 2. The overall flow becomes: install VPA → observe in Off mode → review recommendations → enable Auto mode (which sets requests automatically). Success criteria updated to reflect VPA-managed resources rather than manually configured ones.

### 2026-04-06: Use Kyverno mutating policy for resizePolicy instead of per-workload patching

**Decision**: Install Kyverno as an Argo CD Application and use a ClusterPolicy to inject `resizePolicy` into all pod containers cluster-wide, instead of patching each workload individually via kubectl or Helm values.

**Rationale**: `resizePolicy` is a container-level pod spec field that most upstream Helm charts (kube-prometheus-stack, argo-cd) don't expose as a configurable value. Per-workload kubectl patches are not GitOps-compatible — they require operational scripts outside the Argo CD flow. A Kyverno mutating webhook solves this cluster-wide in a single policy, works for all charts regardless of value support, and is fully managed through Argo CD like everything else in this repo.

**Impact**: Phase 2 restructured: install Kyverno → deploy mutating policy → validate in-place resize. Removes need for per-chart resizePolicy support. Phase 3 task "In-place resize enabled for Auto-mode workloads" simplified to verification only (Kyverno already handles injection). Added Kyverno as a dependency.

## Dependencies

- GKE 1.33+ (already running) — required for in-place resize beta
- VPA operator compatible with GKE 1.33
- Kyverno — policy engine for mutating webhook to inject resizePolicy cluster-wide
- Argo CD for GitOps deployment of VPA resources and Kyverno
- Prometheus/Grafana for monitoring (already deployed)

## Out of Scope

- Horizontal Pod Autoscaler (HPA) — all workloads are single-replica by design
- Cluster Autoscaler tuning — may be revisited after VPA optimization reduces total resource requests
- Cost analysis/reporting — focus is on technical right-sizing, not FinOps tooling
