# PRD: Migrate from GKE to Linode Kubernetes Engine

**Issue**: [#21](https://github.com/vfarcic/dot-ai-infra/issues/21)
**Status**: Draft
**Priority**: High
**Created**: 2026-01-31

## Problem Statement

The current dot-ai infrastructure is hosted on Google Kubernetes Engine (GKE), which incurs higher hosting costs. Migration to Linode Kubernetes Engine (LKE) would reduce operational expenses while maintaining the same functionality and reliability.

## Solution Overview

Create a parallel Linode LKE cluster with Argo CD managing all deployments. Continue using GCP Secret Manager for secrets (accessed via service account key instead of Workload Identity). Disable Argo CD sync on GKE, modify the existing `apps/` directory in place for Linode compatibility, perform a zero-downtime DNS cutover, then decommission GKE and associated GCP resources.

**Key Decision**: Modify `apps/` in place rather than creating a separate `apps-linode/` directory. This ensures external CI workflows (from other repos) that update files in `apps/` continue working without modification.

## Scope

- **In Scope**: `dot-ai-infra` repository only
- **Out of Scope**: Application code changes (dot-ai application itself), external CI workflow changes

## Technical Context

### Current GCP-Specific Components

| Component | Current (GKE) | Target (Linode) |
|-----------|---------------|-----------------|
| Gateway | `gke-l7-global-external-managed` | Envoy Gateway (`eg`) |
| TLS Certificates | GCP Certificate Manager via Crossplane | cert-manager + Let's Encrypt |
| Secrets Auth | GKE Workload Identity | GCP Service Account Key |
| Backend Policies | `GCPBackendPolicy` CRD | Remove (not needed) |
| Crossplane Provider | `provider-gcp` | `provider-linode` (optional) |
| Load Balancer | GKE L7 Global LB | Linode NodeBalancer |
| Node Autoscaling | GKE Autopilot/Autoscaler | LKE native autoscaling |

### Files Requiring Changes

**Modify in place for Linode:**
- `apps/gateway.yaml` - Change gatewayClassName, remove certmap annotation
- `apps/external-secrets.yaml` - Change auth from Workload Identity to secret ref

**New files to add:**
- `apps/envoy-gateway.yaml` - Gateway controller installation
- `apps/cert-manager.yaml` - cert-manager installation
- `apps/cluster-issuer.yaml` - Let's Encrypt ClusterIssuer
- `apps/certificate.yaml` - TLS certificate for domains

**Delete (GCP-only):**
- `apps/dot-ai-gcpbackendpolicy.yaml`
- `apps/dot-ai-ui-gcpbackendpolicy.yaml`
- `apps/crossplane-provider-gcp.yaml`
- `apps/crossplane-gcp-certificates.yaml`

**Unchanged:**
- `apps/external-secrets-resources.yaml` - Same GCP Secret Manager references
- `apps/dot-ai-stack.yaml` - Gateway API is portable
- `apps/prometheus-stack.yaml`
- `apps/jaeger.yaml`
- `apps/crossplane.yaml`

### Secrets Strategy

Continue using GCP Secret Manager. Authentication changes from GKE Workload Identity to a GCP service account key stored as a Kubernetes secret. This is the only manual bootstrap step required.

## Success Criteria

- [ ] All services accessible via Linode cluster (dot-ai API, UI, Argo CD, Jaeger)
- [ ] TLS certificates issued and valid for all domains
- [ ] External Secrets successfully pulling from GCP Secret Manager
- [ ] Node autoscaling functional (min/max configured per pool)
- [ ] DNS cutover completed with zero downtime
- [ ] External CI workflows continue working (no changes required)
- [ ] GKE cluster and associated GCP resources decommissioned

## Milestones

### Milestone 1: Preparation
- [ ] Create GCP service account key for External Secrets authentication
- [ ] Document bootstrap procedure
- [ ] Lower DNS TTL to 60s (do this early, wait 24-48h before cutover)

### Milestone 2: Linode Cluster Provisioning
- [ ] Provision LKE cluster with appropriate node sizes
- [ ] Configure node pool autoscaling (min/max)
- [ ] Install Argo CD
- [ ] Bootstrap GCP service account secret

### Milestone 3: Disable GKE Sync and Modify Apps
- [ ] Disable Argo CD auto-sync on GKE cluster (apps keep running, just frozen)
- [ ] Modify `apps/gateway.yaml` for Linode (gatewayClassName, remove certmap)
- [ ] Modify `apps/external-secrets.yaml` with key-based auth
- [ ] Add `apps/envoy-gateway.yaml` (Gateway controller)
- [ ] Add `apps/cert-manager.yaml`
- [ ] Add `apps/cluster-issuer.yaml` (Let's Encrypt)
- [ ] Add `apps/certificate.yaml` (TLS cert for domains)
- [ ] Delete GCP-only files (GCPBackendPolicy, Crossplane GCP resources)

### Milestone 4: Linode Deployment
- [ ] Point Linode Argo CD at `apps/` directory
- [ ] Verify all applications synced and healthy
- [ ] Verify Gateway controller and cert-manager running
- [ ] Verify TLS certificates issued

### Milestone 5: Validation
- [ ] Test all endpoints via `/etc/hosts` override
- [ ] Verify dot-ai API functional
- [ ] Verify dot-ai UI functional
- [ ] Verify Argo CD UI accessible
- [ ] Verify Jaeger UI accessible
- [ ] Verify Prometheus/Grafana functional

### Milestone 6: DNS Cutover
- [ ] Confirm DNS TTL is 60s (from Milestone 1)
- [ ] Update DNS records to Linode load balancer IP
- [ ] Monitor error rates and logs
- [ ] Confirm all traffic flowing through Linode

### Milestone 7: GKE Decommissioning
- [ ] Verify Linode cluster stable post-cutover
- [ ] Delete GKE cluster
- [ ] Remove GCP Certificate Manager resources
- [ ] Remove GKE-specific IAM bindings (keep External Secrets SA)
- [ ] Clean up any orphaned GCP resources

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Service disruption during DNS cutover | High | Lower TTL beforehand, test with hosts file first |
| cert-manager fails to issue certificates | Medium | Test in staging, have DNS-01 solver as backup |
| External Secrets can't auth to GCP | High | Test service account key before full deployment |
| LKE autoscaling behavior differs from GKE | Low | Configure conservative min/max, monitor closely |
| Rollback needed after DNS switch | Medium | GKE still running (frozen), can revert DNS and re-enable sync |
| External CI updates apps during migration | Low | Migration window is short; coordinate timing if needed |

## Rollback Plan

1. **Before DNS cutover** (Linode issues found):
   - Revert `apps/` changes via git
   - Re-enable Argo CD auto-sync on GKE
   - GKE resumes normal operation
   - Iterate on Linode setup separately

2. **After DNS cutover** (Linode issues found):
   - Revert DNS to GKE IP addresses
   - Revert `apps/` changes via git
   - Re-enable Argo CD auto-sync on GKE
   - GKE resumes serving traffic after DNS TTL expires
   - Investigate and fix Linode issues before retry

## Dependencies

- GCP service account with Secret Manager access
- Linode account with LKE access
- DNS management access (for TTL changes and cutover)
- Domain: `devopstoolkit.ai`
- Coordination with any external CI pipelines (timing only, no changes needed)

## Timeline

Not estimated - milestones provide natural checkpoints for progress tracking.
