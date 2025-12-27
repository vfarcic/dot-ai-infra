# Setup Port Integrations

Set up Port integrations to sync Kubernetes resources and GitHub Actions to Port.io.

## Prerequisites
- ArgoCD installed and configured
- ESO installed with ClusterSecretStore `gcp-secret-manager` configured
- Port.io account with credentials stored in GCP Secret Manager:
  - `port-client-id`
  - `port-client-secret`
- GitHub account/organization for GitHub Actions integration

---

# Part 1: Kubernetes Exporter

## Steps

### 1. Create ArgoCD Application with ESO

Create `apps/port-k8s-exporter.yaml` with:
- ExternalSecret to pull Port credentials from GCP Secret Manager
- ArgoCD Application for the port-k8s-exporter Helm chart

Key Helm values:
- `secret.useExistingSecret: true` and `secret.name: port-credentials`
- `overwriteConfigurationOnRestart: true` (forces use of configMap config)
- `stateKey` and `CLUSTER_NAME` set to cluster identifier (e.g., "dot-ai")
- `configMap.config` with resource mappings

### 2. Create Blueprints in Port

Create these blueprints using Port MCP tools:

**Standard K8s Resources:**
- `service` - type, clusterIP, ports, selector, labels
- `pod` - phase, node, containers, labels, startTime
- `ingress` - ingressClassName, hosts, rules, tls, labels
- `replicaset` - replicas, availableReplicas, readyReplicas, selector, labels

**Gateway API:**
- `gateway` - gatewayClassName, listeners, addresses, labels
- `httproute` - hostnames, parentRefs, rules, labels

**Custom CRDs (devopstoolkit.live):**
- `capabilityscanconfig` - debounceWindowSeconds, mcpEndpoint, mcpCollection, mcpAuthSecretRef, lastScanTime, ready
- `remediationpolicy` - mode, eventSelectors, mcpEndpoint, mcpTool, confidenceThreshold, maxRiskLevel, rateLimiting, notifications, ready
- `resourcesyncconfig` - debounceWindowSeconds, resyncIntervalMinutes, mcpEndpoint, mcpAuthSecretRef, active, watchedResourceTypes, totalResourcesSynced, syncErrors, lastSyncTime, lastResyncTime
- `solution` - intent, context, resources, labels

**Generic Resource Blueprint:**
- `k8s-resource` - kind, apiVersion, resourceName (for tracking arbitrary K8s resources referenced by Solutions)

All blueprints should have:
- Relation to `namespace` blueprint
- `creationTimestamp` property

### 3. Configure Blueprint Relations

Analyze all exported resources and establish meaningful relations between them based on Kubernetes resource relationships:
- Examine ownerReferences in resource specs to link child resources to parents
- Look at selector labels to connect Services to Workloads
- Examine backend references in Ingress and HTTPRoute to link to Services
- Consider parent/child relationships from Gateway API specs
- Link resources to their Cluster when appropriate

For each relation:
1. Add the relation to the blueprint in Port
2. Add the corresponding JQ mapping in the exporter config to populate the relation

### 4. Configure Resource Mappings

In the Helm values `configMap.config`, define mappings for:

**Core Resources:**
- `v1/namespaces` → namespace blueprint
- `v1/namespaces` (kube-system) → cluster blueprint
- `apps/v1/deployments` → workload blueprint
- `apps/v1/daemonsets` → workload blueprint
- `apps/v1/statefulsets` → workload blueprint
- `apps/v1/replicasets` → replicaset blueprint
- `v1/pods` → pod blueprint
- `v1/services` → service blueprint
- `networking.k8s.io/v1/ingresses` → ingress blueprint

**Gateway API:**
- `gateway.networking.k8s.io/v1/gateways` → gateway blueprint
- `gateway.networking.k8s.io/v1/httproutes` → httproute blueprint

**Custom CRDs:**
- `dot-ai.devopstoolkit.live/v1alpha1/capabilityscanconfigs` → capabilityscanconfig blueprint
- `dot-ai.devopstoolkit.live/v1alpha1/remediationpolicies` → remediationpolicy blueprint
- `dot-ai.devopstoolkit.live/v1alpha1/resourcesyncconfigs` → resourcesyncconfig blueprint
- `dot-ai.devopstoolkit.live/v1alpha1/solutions` → solution blueprint

### 5. Map Solution Resources to Generic Blueprint

Solutions reference arbitrary K8s resources in `spec.resources`. Use `itemsToParse` to create a `k8s-resource` entity for each referenced resource:

```yaml
# K8s Resources from Solution spec.resources
- kind: dot-ai.devopstoolkit.live/v1alpha1/solutions
  selector:
    query: "true"
  port:
    itemsToParse: .spec.resources
    entity:
      mappings:
        - identifier: .item.kind + "-" + .item.name + "-" + (.item.namespace // .metadata.namespace) + "-" + env.CLUSTER_NAME
          title: .item.kind + "/" + .item.name
          blueprint: '"k8s-resource"'
          properties:
            kind: .item.kind
            apiVersion: .item.apiVersion
            resourceName: .item.name
          relations:
            Namespace: (.item.namespace // .metadata.namespace) + "-" + env.CLUSTER_NAME
            Solution: .metadata.name + "-" + .metadata.namespace + "-" + env.CLUSTER_NAME
```

This creates entities for ALL resources managed by a Solution (Deployments, Services, Secrets, ConfigMaps, Certificates, etc.) with a relation back to the Solution, enabling visualization of the complete resource tree in Port's Graph View.

### 6. Push and Verify

1. Commit and push to Git
2. Wait for ArgoCD to sync
3. Verify exporter pod is running: `kubectl get pods -n port-k8s-exporter`
4. Check logs for successful syncs: `kubectl logs -n port-k8s-exporter deployment/port-k8s-exporter`
5. Verify entities in Port using MCP tools

## Notes

- For CRDs, you can alternatively use `crdsToDiscover` parameter to auto-create blueprints, but manual creation gives more control over properties
- Standard K8s resources (Service, Pod, etc.) require manual blueprint creation - the exporter only auto-creates cluster, namespace, and workload blueprints by default
- Use `overwriteConfigurationOnRestart: true` to ensure the exporter uses the configMap config instead of the config stored in Port's API

## Troubleshooting

- If new resources aren't syncing, restart the exporter: `kubectl rollout restart deployment/port-k8s-exporter -n port-k8s-exporter`
- Check configMap is updated: `kubectl get configmap port-k8s-exporter -n port-k8s-exporter -o yaml`
- Verify blueprints exist in Port before adding mappings

---

# Part 2: GitHub Integration

Sync GitHub workflows, workflow runs, and pull requests to Port.

## Steps

### 1. Install Port's GitHub App

1. Go to Port's Data Sources page: https://app.port.io/settings/data-sources
2. Click "+ Data source" → select "GitHub"
3. Install the GitHub App on your GitHub account/organization
4. Select the repositories you want to sync
5. Ensure the app has permissions for: actions, checks, pull requests, and repository metadata

### 2. Create GitHub Blueprints

Create these blueprints using Port MCP tools (note: `githubPullRequest` may already exist from onboarding):

**githubWorkflow:**
- path (string) - workflow file path
- status (string/enum) - active, deleted, disabled_fork, disabled_inactivity, disabled_manually
- createdAt (date-time)
- updatedAt (date-time)
- link (url)
- Relation to service blueprint

**githubWorkflowRun:**
- name (string)
- triggeringActor (string)
- status (string/enum) - queued, in_progress, completed, etc.
- conclusion (string/enum) - success, failure, cancelled, etc.
- createdAt, runStartedAt, updatedAt (date-time)
- runNumber, runAttempt (number)
- link (url)
- Relation to githubWorkflow

**githubPullRequest** (if not exists):
- creator (string)
- assignees (array)
- reviewers (array)
- status (enum) - open, closed, merged
- closedAt, updatedAt, mergedAt (date-time)
- link (url)
- Relation to service blueprint

### 3. Configure GitHub Integration Mapping via API

The Port MCP tools don't include an `update_integration` tool, so use the Port REST API to configure the mapping.

First, get the integration identifier:
```bash
# List integrations to find the GitHub one
curl -s "https://api.getport.io/v1/integration" \
  -H "Authorization: Bearer $PORT_TOKEN" | jq '.integrations[] | select(.integrationType == "GitHub")'
```

Then update the integration config:
```bash
curl -X PATCH "https://api.getport.io/v1/integration/<INTEGRATION_ID>" \
  -H "Authorization: Bearer $PORT_TOKEN" \
  -H "Content-Type: application/json" \
  -d @github_mapping.json
```

**github_mapping.json:**
```json
{
  "config": {
    "createMissingRelatedEntities": true,
    "resources": [
      {
        "kind": "pull-request",
        "selector": {
          "query": "true",
          "closedPullRequests": true
        },
        "port": {
          "entity": {
            "mappings": {
              "identifier": ".head.repo.name + \"/\" + (.id|tostring)",
              "title": ".title",
              "blueprint": "\"githubPullRequest\"",
              "properties": {
                "creator": ".user.login",
                "assignees": "[.assignees[].login]",
                "reviewers": "[.requested_reviewers[].login]",
                "status": "if .merged then \"merged\" elif .state == \"closed\" then \"closed\" else \"open\" end",
                "closedAt": ".closed_at",
                "updatedAt": ".updated_at",
                "mergedAt": ".merged_at",
                "link": ".html_url"
              },
              "relations": {
                "service": ".head.repo.name"
              }
            }
          }
        }
      },
      {
        "kind": "workflow",
        "selector": {
          "query": "true"
        },
        "port": {
          "entity": {
            "mappings": {
              "identifier": ".repo + \"/\" + (.id|tostring)",
              "title": ".name",
              "blueprint": "\"githubWorkflow\"",
              "properties": {
                "path": ".path",
                "status": ".state",
                "createdAt": ".created_at",
                "updatedAt": ".updated_at",
                "link": ".html_url"
              },
              "relations": {
                "repository": ".repo"
              }
            }
          }
        }
      },
      {
        "kind": "workflow-run",
        "selector": {
          "query": "true"
        },
        "port": {
          "entity": {
            "mappings": {
              "identifier": ".repository.name + \"/\" + (.id|tostring)",
              "title": ".display_title",
              "blueprint": "\"githubWorkflowRun\"",
              "properties": {
                "name": ".name",
                "triggeringActor": ".triggering_actor.login",
                "status": ".status",
                "conclusion": ".conclusion",
                "createdAt": ".created_at",
                "runStartedAt": ".run_started_at",
                "updatedAt": ".updated_at",
                "runNumber": ".run_number",
                "runAttempt": ".run_attempt",
                "link": ".html_url"
              },
              "relations": {
                "workflow": ".repository.name + \"/\" + (.workflow_id|tostring)"
              }
            }
          }
        }
      }
    ]
  }
}
```

### 4. Trigger Resync

After updating the config, trigger a resync:
```bash
curl -X PATCH "https://api.getport.io/v1/integration/<INTEGRATION_ID>" \
  -H "Authorization: Bearer $PORT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

### 5. Verify GitHub Integration

1. Check integration logs for successful syncs
2. Verify entities appear in Port catalog:
   - GitHub Workflows
   - GitHub Workflow Runs
   - Pull Requests
3. Verify relations between workflow runs → workflows

## Important Notes

- **closedPullRequests: true** - By default, Port only syncs open PRs. Add this to the pull-request selector to include closed/merged PRs.
- **createMissingRelatedEntities: true** - Ensures related entities are created even if they don't exist yet.
- The GitHub App must have the correct permissions enabled in GitHub (Settings → Applications → Configure).

## Optional: Link GitHub to Kubernetes

To connect GitHub workflows to Kubernetes workloads:

1. Add a `repository` relation to the `workload` blueprint
2. Update K8s exporter mappings to extract repository info from labels/annotations
3. This enables tracing from deployment → workflow run → workflow → repository
