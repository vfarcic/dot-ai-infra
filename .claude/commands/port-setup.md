# Setup Port Integrations

Set up Port integrations to sync Kubernetes resources and GitHub Actions to Port.io.

## Prerequisites

Check the following and instruct the user to install/configure if missing:

- **kubectl** - installed and configured with cluster access
- **helm** - installed (for checking chart versions)
- **gh** - GitHub CLI installed and authenticated
- **Environment variables** set:
  - `PORT_CLIENT_ID`
  - `PORT_CLIENT_SECRET`

## General Guidelines

- **Always check latest versions** of third-party tools (Helm charts, GitHub Actions, etc.) before creating manifests. Use `helm search repo` or check the official documentation.
- **Consult Port MCP tools** when in doubt - use them to explore existing blueprints, entities, actions, and integrations.
- **Validate each step** before moving to the next - verify resources are created, synced, and working as expected.
- **User actions vs automated**: Some steps require user action (marked with "User action required") - present these as instructions. Other steps can be executed directly.

---

# Step 0: Discover Environment

Before starting, discover what tools are available and gather configuration:

1. **GitOps Tool**: Check for ArgoCD (`argocd` namespace) or Flux (`flux-system` namespace)
2. **ESO**: Check for External Secrets Operator CRD and available ClusterSecretStores
3. **Manifest directory**: Ask the user where manifests should be stored (e.g., `apps/`, `manifests/`, `k8s/`)

| GitOps Tool | Deployment Method | Self-Service Actions |
|-------------|-------------------|---------------------|
| ArgoCD | ArgoCD Application manifests in Git | Commit YAML to Git → ArgoCD syncs |
| Flux | Flux HelmRelease/Kustomization in Git | Commit YAML to Git → Flux syncs |
| Neither | Manifests in Git + `kubectl apply` | Commit YAML to Git → `kubectl apply` |

| ESO Status | Secrets Method |
|------------|----------------|
| Installed with ClusterSecretStore | Use ExternalSecret to pull from secret manager |
| Not installed | Create Secret directly with `kubectl create secret` |

**Note:** Always store manifests in Git for auditability, regardless of GitOps availability.

---

# Part 1: Kubernetes Exporter

## Step 1: Create Port Credentials Secret

Create a Secret named `port-credentials` in the `port-k8s-exporter` namespace with keys `PORT_CLIENT_ID` and `PORT_CLIENT_SECRET`.

- **With ESO**: Create an ExternalSecret referencing the available ClusterSecretStore
- **Without ESO**: Create the Secret directly with `kubectl create secret`

## Step 2: Deploy the K8s Exporter

Deploy the `port-k8s-exporter` Helm chart from `https://port-labs.github.io/helm-charts`.

Key Helm values:
- `secret.useExistingSecret: true` and `secret.name: port-credentials`
- `overwriteConfigurationOnRestart: true` (forces use of configMap config)
- `stateKey` and `extraEnv[].CLUSTER_NAME` set to cluster identifier
- `configMap.config` with resource mappings (see Step 4)

Deployment method based on discovery:
- **ArgoCD**: Create ArgoCD Application manifest
- **Flux**: Create HelmRepository + HelmRelease manifests
- **Neither**: Run `helm install` then commit values to Git

## Step 3: Create Blueprints in Port

**Default blueprints** (always created by the exporter):
- `cluster` (Port concept, not a K8s resource)
- `namespace` (from namespaces)
- `workload` (from deployments, daemonsets, statefulsets)

**Discover and recommend:**
1. Run `kubectl api-resources` to list all available resources
2. Exclude resources already covered by defaults (namespaces, deployments, daemonsets, statefulsets)
3. Present findings to the user with recommendations
4. Let user select which additional resources to track

Create selected blueprints using Port MCP tools. All blueprints should have:
- Relation to `namespace` blueprint
- `creationTimestamp` property

## Step 4: Configure Resource Mappings

In the Helm values `configMap.config`, define mappings for the resources selected in Step 3.

**For nested resources** (arrays inside a resource spec), use `itemsToParse`:

```yaml
- kind: your.api/v1/yourresource
  selector:
    query: "true"
  port:
    itemsToParse: .spec.items
    entity:
      mappings:
        - identifier: .item.name + "-" + .metadata.namespace + "-" + env.CLUSTER_NAME
          blueprint: '"child-blueprint"'
          properties:
            name: .item.name
          relations:
            Parent: .metadata.name + "-" + .metadata.namespace + "-" + env.CLUSTER_NAME
```

## Step 5: Configure Blueprint Relations

Analyze exported resources and establish relations:
- Examine ownerReferences to link child → parent resources
- Use selector labels to connect Services → Workloads
- Link Ingress/HTTPRoute → Services via backend references

For each relation:
1. Add the relation to the blueprint in Port
2. Add the corresponding JQ mapping in the exporter config

---

# Part 2: GitHub Integration

Sync GitHub workflows, workflow runs, and pull requests to Port.

## Step 1: Install Port's GitHub App (User action required)

1. Go to Port's Data Sources: https://app.port.io/settings/data-sources
2. Click "+ Data source" → select "GitHub"
3. Install the GitHub App on your account/organization
4. Select repositories to sync
5. Ensure permissions for: actions, checks, pull requests, repository metadata

## Step 2: Create GitHub Blueprints

Create blueprints for `githubWorkflow`, `githubWorkflowRun`, and `githubPullRequest` (if not exists) using Port MCP tools. Inspect integration kinds to determine appropriate properties.

## Step 3: Configure GitHub Integration Mapping

Use Port REST API to update the integration config with mappings for `pull-request`, `workflow`, and `workflow-run` kinds.

---

# Part 3: Organize Catalog with Folders

## Step 1: Create Folders in Port UI (User action required)

Folder creation via REST API is not supported. Create folders manually:

1. Go to [Port Catalog](https://app.getport.io/organization/catalog)
2. Click `+ New` → `New folder`
3. Create folders for logical groupings (e.g., "GitHub", "Kubernetes Core", "Kubernetes CRDs")

**Note:** Identifiers are auto-generated using snake_case.

## Step 2: Move Pages into Folders via API

Use REST API to move pages. The `"after": null` field is required when moving pages to empty folders.

---

# Part 4: Self-Service Actions for CRDs

Create Port self-service actions that trigger GitHub workflows to manage CRD manifests.

## Step 0: Configure GitHub Repository Secrets

Use `gh secret set` to add required secrets:
- `PORT_CLIENT_ID` - Port client ID
- `PORT_CLIENT_SECRET` - Port client secret
- `KUBE_CONFIG` - (Only for non-GitOps) Base64-encoded kubeconfig

## Step 1: Create GitHub Workflows

Create workflow for each CRD with `workflow_dispatch` trigger accepting:
- `action` (create/update/delete)
- `name`, `namespace`
- Resource-specific inputs
- `port_run_id`

**Workflow steps:**
1. Checkout repository
2. Report "RUNNING" status to Port using `port-labs/port-github-action@v1`
3. Create/update/delete manifest in the configured manifest directory
4. Commit and push to Git
5. **Non-GitOps only**: Run `kubectl apply` or `kubectl delete`
6. Report "SUCCESS" or "FAILURE" to Port

## Step 2: Create Port Self-Service Actions

Create 3 actions per CRD using Port MCP tools:

- **CREATE** - Creates new resources (no entity context)
- **DAY-2** - Updates existing resources (has entity context)
- **DELETE** - Deletes resources (has entity context)

**Key template expressions:**
- `{{ .inputs.fieldName }}` - User input value
- `{{ .run.id }}` - Port action run ID
- `{{ .entity.identifier }}` - Entity identifier (for DAY-2/DELETE)
- `{{ .entity.identifier | split("-") | last }}` - Extract resource name from identifier

**For DAY-2 actions**, pre-populate inputs with current entity values:

```json
"default": {
  "jqQuery": ".entity.properties.someField // \"default_value\""
}
```
