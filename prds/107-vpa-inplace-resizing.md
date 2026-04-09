# PRD #107: VPA and In-Place Pod Resizing for Cluster Resource Optimization

**Status**: In Progress
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

Implement Vertical Pod Autoscaler (VPA) progressively from `Off` to `InPlaceOrRecreate` mode (available on GKE 1.34+), combined with Kubernetes in-place pod resizing, to automatically right-size workloads. VPA attempts in-place resize first and falls back to pod recreation when needed.

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

### Phase 2: VPA Auto Mode Canary + Validation

- [x] ~~**Kyverno installed via Argo CD**~~ — Removed. Kyverno was originally added to inject `resizePolicy` into pods, but Kubernetes defaults `resizePolicy[*].restartPolicy` to `NotRequired` when unset, making Kyverno unnecessary. See decision log entry 2026-04-06 "Remove Kyverno".
- [x] **Canary workloads switched to VPA InPlaceOrRecreate** — Switched youtube-automation, jaeger, and dot-ai-website to `updateMode: "InPlaceOrRecreate"` with `minReplicas: 1`. Initially tested with `Auto` mode, then upgraded to `InPlaceOrRecreate` after cluster upgraded to GKE 1.34.6. All three VPAs include `minReplicas: 1` (required for single-replica deployments — VPA updater defaults to requiring 2+ replicas).
- [x] **Canary validated** — VPA applied recommendations to all three canary workloads: youtube-automation (100m/128Mi → 2m/41Mi), jaeger (none → 35m/372Mi), dot-ai-website (100m/128Mi → 2m/28Mi). All pods healthy after resize. VPA fell back to pod recreation (not in-place resize) for the initial large right-sizing — in-place resize is expected only for incremental adjustments on already-right-sized pods. See decision log entries 2026-04-08.

### Phase 3: VPA InPlaceOrRecreate Rollout

- [x] **Stable workloads switched to VPA InPlaceOrRecreate** — Switched all 8 stable workloads to `updateMode: "InPlaceOrRecreate"` with `minReplicas: 1`: external-secrets, dot-ai-stack-dex, node-exporter, crossplane-rbac-manager, argocd-redis, argocd-notifications, argocd-applicationset, argocd-dex-server. Changes applied across 4 files (`apps/argocd-vpa.yaml`, `apps/external-secrets.yaml`, `apps/dot-ai-stack.yaml`, `apps/crossplane.yaml`, `apps/prometheus-stack.yaml`). Argo CD synced successfully; all pods running with VPA-set resource requests matching recommendations. Initial right-sizing used pod recreation (expected for large deltas); subsequent incremental adjustments expected to resize in-place.
- [x] **In-place resize verified for InPlaceOrRecreate workloads** — Confirmed in-place resize works on GKE 1.34.6. Evidence: `crossplane-rbac-manager` pod (running 5h, 0 restarts) received a `ResizeCompleted` event from kubelet — resources changed from 100m/256Mi to 3m/28Mi without pod restart. The pod had pre-existing Helm-configured resource requests, allowing the kubelet to resize in-place. Workloads without prior resource requests (10 of 11) were evicted and recreated for initial right-sizing — this is expected behavior. Future incremental adjustments on already-right-sized pods (e.g., youtube-automation showing VPA target drift of 115Mi→155Mi) will use in-place resize.

### Phase 4: Full Rollout + Monitoring

- [ ] **Remaining workloads graduated to appropriate VPA mode** — Move bursty workloads to `Initial` mode (sets resources on pod creation but doesn't update running pods). Move infrastructure workloads to `InPlaceOrRecreate` with conservative policies (minAllowed/maxAllowed bounds) and `minReplicas: 1`. Keep only truly unpredictable workloads (dot-ai MCP server) in `Off` mode with manual review.
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

### 2026-04-06: Remove Kyverno — resizePolicy defaults to NotRequired

**Decision**: Remove Kyverno entirely. Kubernetes defaults `resizePolicy[*].restartPolicy` to `NotRequired` when the field is not set, so in-place pod resizing works out of the box on GKE 1.33 without any mutation.

**Rationale**: Kyverno was added solely to inject `resizePolicy` into all pod containers. Investigation of the Kubernetes documentation confirmed that the default value when `resizePolicy` is unspecified is already `NotRequired` for both CPU and memory. This makes the Kyverno mutating policy unnecessary overhead — three controllers, webhook infrastructure, and CRDs for a field that already has the desired default.

**Impact**: Removed `apps/kyverno.yaml` (Argo CD Application + 3 VPA objects). Phase 2 simplified to just in-place resize validation. Kyverno removed from dependencies. Phase 3 verification task updated to reflect that no policy injection is needed.

### 2026-04-06: Skip manual resize — validate with VPA Auto canary instead

**Decision**: Remove the separate manual in-place resize validation task. Instead, switch a single canary workload (youtube-automation) to VPA Auto and validate that VPA-driven resize works end-to-end without restarts.

**Rationale**: Manual resize only proves the Kubernetes feature works in isolation. What matters is whether VPA Auto can resize pods without restarts end-to-end. Testing with a single low-risk workload validates both in-place resize and VPA Auto in one step, reducing Phase 2 to a single meaningful validation.

**Impact**: Phase 2 simplified from "manual resize then VPA Auto" to "canary VPA Auto validates everything." Phase 3 becomes the broader rollout to remaining stable workloads.

### 2026-04-08: Use InPlaceOrRecreate mode instead of Auto (GKE 1.34+)

**Decision**: Switch VPA update mode from `Auto` to `InPlaceOrRecreate` after cluster upgraded to GKE 1.34.6. This mode attempts in-place pod resizing first and falls back to pod recreation when in-place resize isn't possible.

**Rationale**: Standard `Auto` mode only supports evict-and-recreate. `InPlaceOrRecreate` (available on GKE 1.34+) leverages the Kubernetes in-place pod resize feature, avoiding unnecessary pod restarts for incremental resource adjustments. Initial large right-sizing still triggers recreation, but subsequent adjustments on already-right-sized pods should resize in-place.

**Impact**: All VPA objects use `InPlaceOrRecreate` instead of `Auto`. Phase 3 and 4 task descriptions updated to reflect the new mode. Dependencies updated to require GKE 1.34+ instead of 1.33+.

### 2026-04-08: Add minReplicas: 1 for single-replica deployments

**Decision**: Add `minReplicas: 1` to all VPA `updatePolicy` specs. VPA's updater defaults to requiring at least 2 replicas before it will resize or evict a pod (`--min-replicas=2`). Since all workloads in this cluster are single-replica, the updater was silently skipping every pod.

**Rationale**: Discovered during canary validation — VPA recommendations were correct but the updater never acted. Investigation revealed the updater logs `"Too few replicas"` for pods with fewer than `minReplicas` (default 2). Setting `minReplicas: 1` in each VPA object overrides this per-VPA. This is documented in kubernetes/autoscaler#8609.

**Impact**: All VPA objects (canary and future) must include `minReplicas: 1`. This is a required setting for any single-replica deployment using VPA Auto or InPlaceOrRecreate mode.

### 2026-04-08: In-place resize is incremental — initial right-sizing uses recreation

**Decision**: Accept that VPA's initial right-sizing of over-provisioned workloads will recreate pods, not resize in-place. True in-place resize is expected only for small incremental adjustments on already-right-sized pods.

**Rationale**: Canary testing showed all three workloads (youtube-automation, jaeger, dot-ai-website) were recreated rather than resized in-place, even with `InPlaceOrRecreate` mode. Large resource decreases (e.g., 100m→2m CPU, 128Mi→28Mi memory) exceed what the kubelet can safely resize in-place — particularly memory decreases where current usage may exceed the new limit. VPA falls back to recreation after a timeout.

**Impact**: Success criteria #3 ("No restart-induced outages during resizing") reframed — initial rollout will involve pod recreation for over-provisioned workloads. In-place resize benefit applies to ongoing maintenance after initial right-sizing. Stateful workloads (Prometheus, Qdrant) should be switched last and monitored carefully during the initial recreation.

### 2026-04-09: In-place resize confirmed — works for pods with pre-existing resource requests

**Decision**: In-place resize is verified working on GKE 1.34.6. The determining factor is whether the pod already has resource requests set before VPA acts.

**Rationale**: `crossplane-rbac-manager` was the only workload that resized in-place (0 restarts, `ResizeCompleted` event from kubelet). It was also the only workload that had Helm-configured resource requests (100m CPU/256Mi memory) before VPA switched to InPlaceOrRecreate. All other workloads had no prior requests — VPA had to evict and recreate them to inject requests for the first time. This confirms the pattern: in-place resize requires an existing resource spec to modify. Subsequent VPA adjustments on already-right-sized pods will use in-place resize.

**Impact**: Phase 3 complete. For Phase 4, infrastructure/stateful workloads that already have Helm-configured resources (e.g., crossplane at 100m/256Mi) are good candidates for in-place resize on first VPA action. Workloads without existing requests will experience one pod recreation when first switched to InPlaceOrRecreate, then benefit from in-place resize for subsequent adjustments.

## Dependencies

- GKE 1.34+ (running 1.34.6) — required for VPA InPlaceOrRecreate mode
- VPA operator (GKE managed addon, runs on control plane)
- Argo CD for GitOps deployment of VPA resources
- Prometheus/Grafana for monitoring (already deployed)

## Out of Scope

- Horizontal Pod Autoscaler (HPA) — all workloads are single-replica by design
- Cluster Autoscaler tuning — may be revisited after VPA optimization reduces total resource requests
- Cost analysis/reporting — focus is on technical right-sizing, not FinOps tooling
