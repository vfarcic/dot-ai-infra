# Setup Port K8s Exporter

Set up Port's Kubernetes exporter to sync cluster resources to Port.io using ArgoCD and External Secrets Operator (ESO).

## Prerequisites
- ArgoCD installed and configured
- ESO installed with ClusterSecretStore `gcp-secret-manager` configured
- Port.io account with credentials stored in GCP Secret Manager:
  - `port-client-id`
  - `port-client-secret`

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
