# PRD #129: Migrate to Grafana Cloud with Alloy (replacing kube-prometheus-stack + Jaeger)

**Status**: In Progress
**Priority**: High
**Created**: 2026-04-22
**GitHub Issue**: [#129](https://github.com/vfarcic/dot-ai-infra/issues/129)

---

## Problem Statement

The cluster runs self-hosted kube-prometheus-stack (Prometheus, Grafana, kube-state-metrics, node-exporter) and self-hosted Jaeger (all-in-one, in-memory storage). This setup has several limitations:

- **No Grafana Assistant access**: The AI-powered agent that can troubleshoot issues, manage dashboards, and correlate signals across metrics and traces is only available in Grafana Cloud
- **No MCP integration**: Claude Code cannot query cluster metrics, traces, or dashboards during development and operations without Grafana Cloud
- **Limited retention**: Prometheus has 7-day retention; Jaeger uses in-memory storage with no persistence
- **No unified observability**: Metrics and traces live in separate, disconnected systems
- **Operational overhead**: Five VPAs, certificates, HTTPRoutes, secrets, and health checks to maintain for self-hosted monitoring components

## Solution Overview

Migrate entirely to Grafana Cloud:

1. **Grafana Alloy** replaces Prometheus, Grafana, kube-state-metrics, and node-exporter as the in-cluster agent — scrapes metrics and forwards to Grafana Cloud Mimir
2. **Grafana Alloy** also replaces Jaeger — receives OTEL traces from dot-ai and forwards to Grafana Cloud Tempo
3. **Grafana Cloud** provides the dashboard UI, Grafana Assistant, long-term metric/trace storage, and the MCP server for Claude Code integration
4. **Grafana MCP server** connects Claude Code directly to cluster observability data

## Current State

### Metrics (apps/prometheus-stack.yaml — 248 lines)
- Argo CD Application: `kube-prometheus-stack` v83.7.0 in `monitoring` namespace
- Prometheus with 7d retention
- Grafana with 2 imported dashboards (gnetId 7249, 6417) at `grafana.devopstoolkit.ai`
- AlertManager disabled
- ExternalSecret for Grafana admin credentials
- HTTPRoute, HealthCheckPolicy, GCP Certificate + CertificateMapEntry for Grafana
- 5 VPAs: prometheus, grafana, kube-state-metrics, node-exporter, prometheus-operator

### Traces (apps/jaeger.yaml — 73 lines)
- Argo CD Application: Jaeger all-in-one v4.7.0 in `jaeger` namespace
- In-memory storage (no persistence)
- Jaeger UI at `jaeger.devopstoolkit.ai`
- GCP Certificate in `apps/crossplane-gcp-certificates.yaml` (lines 1-45)
- 1 VPA

### Trace producer (apps/dot-ai-stack.yaml lines 48-53)
- `OTEL_EXPORTER_TYPE: "jaeger"`
- `OTEL_EXPORTER_OTLP_ENDPOINT: "http://jaeger.jaeger:4318/v1/traces"`

### Dependencies
- No other apps depend on Prometheus, Grafana, or the `monitoring` namespace
- No ServiceMonitors or PodMonitors are defined anywhere in the repo
- No scripts (dot.nu, scripts/*.nu) reference monitoring
- Jaeger is only consumed by dot-ai-stack via OTEL

## Files Affected

| Action | File | Details |
|--------|------|---------|
| **Create** | `.mcp.json` | Grafana Cloud MCP server (Docker stdio transport) |
| **Create** | `apps/alloy.yaml` | Argo CD Application for Grafana Alloy + supporting resources |
| **Delete** | `apps/prometheus-stack.yaml` | After metrics validated |
| **Modify** | `apps/dot-ai-stack.yaml` | Update OTEL endpoint from Jaeger to Alloy |
| **Delete** | `apps/jaeger.yaml` | After traces validated |
| **Modify** | `apps/crossplane-gcp-certificates.yaml` | Remove Jaeger cert resources, add Grafana + Jaeger redirect certs |
| **Modify** | `CLAUDE.md` | Update monitoring documentation |

### Unchanged
- `apps/gateway.yaml`, `apps/external-secrets.yaml`, `apps/external-secrets-resources.yaml`
- `apps/crossplane.yaml`, `apps/crossplane-provider-gcp.yaml`
- `apps/dot-ai-resources.yaml`, `apps/dot-ai-rbac.yaml`, `apps/dot-ai-website.yaml`
- `argocd/` — app-of-apps has `prune: true`, handles removal automatically
- `scripts/`, `dot.nu` — no monitoring references

## Secrets Required

One new GCP Secret Manager secret:
- **`grafana-token`** — Cloud Access Policy token with metrics:write + traces:write scopes

Non-secret values hardcoded in Alloy config:
- Grafana Cloud Prometheus remote write URL and username (numeric instance ID)
- Grafana Cloud Tempo OTLP endpoint URL and username

## Milestones

Each milestone follows: **deploy new -> validate in Grafana Cloud -> remove old -> confirm old is gone**.

**Validation and operations**: Use the Grafana MCP server for all validation steps and any other operations it supports (querying metrics, searching traces, listing datasources, managing dashboards, checking alerts). Prefer MCP over kubectl, curl, or direct API calls whenever Grafana MCP tooling covers the operation.

- [x] **Milestone 1: Connect Claude Code to Grafana Cloud MCP** — Add Grafana MCP server to `.mcp.json`, validate Claude Code can query Grafana Cloud dashboards and data sources via MCP tools
- [x] **Milestone 2a: Deploy Alloy and validate metrics in Grafana Cloud** — Create `apps/alloy.yaml` with Alloy DaemonSet, kube-state-metrics sub-chart, ExternalSecret for API token, and River config scraping kubelet/cAdvisor/nodes/pods and remote-writing to Grafana Cloud Mimir. Validate by querying `up` in Grafana Cloud Explore via MCP
- [x] **Milestone 2b: Remove self-hosted Prometheus + Grafana** — Delete `apps/prometheus-stack.yaml`, add `grafana.devopstoolkit.ai` 301 redirect HTTPRoute + GCP certificate to `apps/alloy.yaml`. Validate `monitoring` namespace resources are pruned and redirect works
- [x] **Milestone 3a: Route traces through Alloy to Grafana Cloud Tempo** — Add OTLP receiver and Tempo exporter to Alloy config, update `apps/dot-ai-stack.yaml` OTEL endpoint from `http://jaeger.jaeger:4318/v1/traces` to `http://alloy.alloy:4318`. Validate using Grafana MCP `tempo_traceql-search` to find traces in Tempo after triggering a dot-ai request via MCP (e.g., dot-ai query)
- [x] **Milestone 3b: Remove Jaeger** — Delete `apps/jaeger.yaml`, remove Jaeger certs from `apps/crossplane-gcp-certificates.yaml`, add `jaeger.devopstoolkit.ai` redirect HTTPRoute to `apps/alloy.yaml`, add Grafana + Jaeger redirect certificates to `apps/crossplane-gcp-certificates.yaml`. Manually delete GCP certs via `gcloud` (see Known Limitations). Validate `jaeger` namespace resources are pruned and redirect works
- [ ] **Milestone 4: Create dashboards in Grafana Cloud** — Use Grafana MCP `update_dashboard` to create dashboards (Kubernetes Cluster, Kubernetes Pods, dot-ai service). Use MCP `search_dashboards` and `get_dashboard_by_uid` to validate they show live data. Use MCP `query_prometheus` to verify underlying metrics
- [ ] **Milestone 5: Update documentation** — Update `CLAUDE.md` with Grafana Cloud URLs, redirects, new secrets, MCP integration notes. Update `.env.vals.yaml` if needed. Use Grafana MCP `list_datasources` and `search_dashboards` to verify documentation matches current state
- [ ] **Cleanup: Revert Argo CD targetRevision to HEAD** — Before merging to main, change `argocd/app.yaml` `targetRevision` back to `HEAD` (temporarily set to feature branch for development)

## Known Limitations

**Crossplane cannot delete GCP Certificate Manager resources.** The Crossplane GCP provider lacks `certificatemanager.certmapentries.delete` and `certificatemanager.certificates.delete` permissions. When certificate resources are removed from manifests, Argo CD will block on pruning because Crossplane's finalizers cannot complete. Workaround:
1. Remove the resources from manifests and push
2. Manually delete via `gcloud certificate-manager maps entries delete <name> --map=devopstoolkit-map --project=vfarcic` and `gcloud certificate-manager certificates delete <name> --project=vfarcic`
3. Crossplane resources will then finalize and be cleaned up

**ProviderConfig `in-use` finalizer counts globally despite being namespace-scoped.** `ProviderConfig` (`gcp.m.upbound.io/v1beta1`) is namespace-scoped, but its `in-use.crossplane.io` finalizer controller counts `ProviderConfigUsage` resources by name across all namespaces. When deleting a ProviderConfig named `default` in one namespace, the finalizer sees usages from other namespaces and blocks deletion with a stale `users` count. Workaround: patch the finalizer off (`kubectl patch providerconfig.gcp.m.upbound.io default -n <ns> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`) after confirming no resources in that namespace reference it. Each namespace with certificate resources needs its own ProviderConfig — define it alongside the certificates in the same manifest.

## Rollback Strategy

All original manifests are preserved in git history. Rollback is a single `git revert` of the merge commit — Argo CD picks up the reverted state and restores everything automatically.

## Success Criteria

- All cluster metrics visible in Grafana Cloud with no gaps
- All dot-ai traces visible in Grafana Cloud Tempo
- Claude Code can query metrics, traces, and dashboards via Grafana MCP
- Grafana Assistant accessible and functional with cluster data
- `grafana.devopstoolkit.ai` and `jaeger.devopstoolkit.ai` redirect to Grafana Cloud
- Self-hosted Prometheus, Grafana, and Jaeger fully decommissioned
- Rollback possible via `git revert` of the merge commit
