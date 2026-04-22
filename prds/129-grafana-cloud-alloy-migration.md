# PRD #129: Migrate to Grafana Cloud with Alloy (replacing kube-prometheus-stack + Jaeger)

**Status**: Not Started
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
| **Modify** | `.mcp.json` | Add Grafana Cloud MCP server |
| **Create** | `apps/alloy.yaml` | Argo CD Application for Grafana Alloy + supporting resources |
| **Move** | `apps/prometheus-stack.yaml` -> `legacy/prometheus-stack.yaml` | After metrics validated |
| **Modify** | `apps/dot-ai-stack.yaml` | Update OTEL endpoint from Jaeger to Alloy |
| **Move** | `apps/jaeger.yaml` -> `legacy/jaeger.yaml` | After traces validated |
| **Modify** | `apps/crossplane-gcp-certificates.yaml` | Remove Jaeger cert resources (lines 1-45) |
| **Modify** | `CLAUDE.md` | Update monitoring documentation |

### Unchanged
- `apps/gateway.yaml`, `apps/external-secrets.yaml`, `apps/external-secrets-resources.yaml`
- `apps/crossplane.yaml`, `apps/crossplane-provider-gcp.yaml`
- `apps/dot-ai-resources.yaml`, `apps/dot-ai-rbac.yaml`, `apps/dot-ai-website.yaml`
- `argocd/` — app-of-apps has `prune: true`, handles removal automatically
- `scripts/`, `dot.nu` — no monitoring references

## Secrets Required

One new GCP Secret Manager secret:
- **`grafana-cloud-api-token`** — API token with MetricsPublisher + TracesPublisher scopes

Non-secret values hardcoded in Alloy config:
- Grafana Cloud Prometheus remote write URL and username (numeric instance ID)
- Grafana Cloud Tempo OTLP endpoint URL and username

## Milestones

Each milestone follows: **deploy new -> validate in Grafana Cloud -> remove old -> confirm old is gone**.

- [ ] **Milestone 1: Connect Claude Code to Grafana Cloud MCP** — Add Grafana MCP server to `.mcp.json`, validate Claude Code can query Grafana Cloud dashboards and data sources via MCP tools
- [ ] **Milestone 2a: Deploy Alloy and validate metrics in Grafana Cloud** — Create `apps/alloy.yaml` with Alloy DaemonSet, kube-state-metrics sub-chart, ExternalSecret for API token, and River config scraping kubelet/cAdvisor/nodes/pods and remote-writing to Grafana Cloud Mimir. Validate by querying `up` in Grafana Cloud Explore via MCP
- [ ] **Milestone 2b: Remove self-hosted Prometheus + Grafana** — Move `apps/prometheus-stack.yaml` to `legacy/`, add `grafana.devopstoolkit.ai` 301 redirect HTTPRoute + GCP certificate to `apps/alloy.yaml`. Validate `monitoring` namespace resources are pruned and redirect works
- [ ] **Milestone 3a: Route traces through Alloy to Grafana Cloud Tempo** — Add OTLP receiver and Tempo exporter to Alloy config, update `apps/dot-ai-stack.yaml` OTEL endpoint from `http://jaeger.jaeger:4318/v1/traces` to `http://alloy.alloy:4318`. Validate by triggering a dot-ai request and finding the trace in Grafana Cloud Tempo via MCP
- [ ] **Milestone 3b: Remove Jaeger** — Move `apps/jaeger.yaml` to `legacy/`, remove Jaeger certs from `apps/crossplane-gcp-certificates.yaml`, add `jaeger.devopstoolkit.ai` redirect to `apps/alloy.yaml`. Validate `jaeger` namespace resources are pruned and redirect works
- [ ] **Milestone 4: Create dashboards in Grafana Cloud** — Import dashboards gnetId 7249 (Kubernetes Cluster) and 6417 (Kubernetes Pods), enable Grafana Cloud Kubernetes Integration for enhanced dashboards, optionally create dot-ai service dashboard with traces + metrics correlation. Validate all dashboards show live data via MCP
- [ ] **Milestone 5: Update documentation** — Update `CLAUDE.md` with Grafana Cloud URLs, redirects, new secrets, MCP integration notes. Update `.env.vals.yaml` if needed. Validate documentation matches current state

## Rollback Strategy

All original manifests are preserved in `legacy/`. Rollback is incremental per milestone:

**Metrics rollback (undo Milestone 2)**:
1. `git mv legacy/prometheus-stack.yaml apps/prometheus-stack.yaml`
2. Remove metrics-related resources from `apps/alloy.yaml`

**Traces rollback (undo Milestone 3)**:
1. `git mv legacy/jaeger.yaml apps/jaeger.yaml`
2. Revert `apps/dot-ai-stack.yaml` OTEL config to Jaeger endpoint
3. Restore Jaeger certs in `apps/crossplane-gcp-certificates.yaml`

**Full rollback**:
1. Restore both files from `legacy/` to `apps/`
2. Revert all modified files, remove `apps/alloy.yaml`
3. Commit and push — Argo CD restores everything

## Success Criteria

- All cluster metrics visible in Grafana Cloud with no gaps
- All dot-ai traces visible in Grafana Cloud Tempo
- Claude Code can query metrics, traces, and dashboards via Grafana MCP
- Grafana Assistant accessible and functional with cluster data
- `grafana.devopstoolkit.ai` and `jaeger.devopstoolkit.ai` redirect to Grafana Cloud
- Self-hosted Prometheus, Grafana, and Jaeger fully decommissioned
- Original manifests preserved in `legacy/` for rollback
