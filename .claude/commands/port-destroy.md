# Destroy Port Integrations

Remove all Port integrations, Kubernetes resources, and local files created by `/port-setup`.

## Prerequisites

Check the following and instruct the user to install/configure if missing:

- **kubectl** - installed and configured with cluster access
- **helm** - installed
- **gh** - GitHub CLI installed and authenticated
- **Environment variables** set:
  - `PORT_CLIENT_ID`
  - `PORT_CLIENT_SECRET`

## General Guidelines

- **Confirm with user** before proceeding with deletion
- **Order matters** - stop syncing FIRST, then delete Port resources
- **Check existence** before attempting deletion to avoid errors
- **Consult Port MCP tools** to discover what was created

---

# Step 0: Discover What Exists

Before destroying, discover what was created:

1. **Kubernetes**: Check for port-k8s-exporter namespace and how it was deployed (Helm/ArgoCD/Flux)
2. **Port resources**: Use Port MCP tools to list blueprints, entities, actions, integrations
3. **GitHub resources**: Check for workflows (`.github/workflows/manage-*.yaml`) and repository secrets
4. **Local manifests**: Check for Port-related files in the manifest directory (e.g., `apps/port-*.yaml`)

---

# Part 1: Delete Kubernetes Resources (FIRST - stops syncing)

**Critical:** Delete the K8s exporter FIRST to stop new entities from being synced to Port.

## Uninstall Port K8s Exporter

Check deployment method and delete accordingly:

**With ArgoCD/Flux (GitOps):**
Delete the manifest file from Git and let the GitOps tool handle deletion:
```bash
rm <manifest-dir>/port-k8s-exporter.yaml
git add -A && git commit -m "Remove port-k8s-exporter" && git push
```
Wait for ArgoCD/Flux to sync and delete the resources.

**With Helm directly (non-GitOps):**
```bash
helm uninstall port-k8s-exporter -n port-k8s-exporter
kubectl delete secret port-credentials -n port-k8s-exporter
kubectl delete externalsecret port-credentials -n port-k8s-exporter  # if using ESO
kubectl delete namespace port-k8s-exporter
```

---

# Part 2: Delete Port Self-Service Actions

Delete all self-service actions created for CRDs.

1. Use `mcp__port-vscode-eu__list_actions` to find actions with identifiers matching patterns:
   - `create_*`, `update_*`, `delete_*`
2. For each action, use `mcp__port-vscode-eu__delete_action`

---

# Part 3: Delete Port Entities

Delete entities before their blueprints.

1. Use `mcp__port-vscode-eu__list_entities` for each custom blueprint
2. Delete all entities using `mcp__port-vscode-eu__delete_entity`

**Order of deletion** (dependents first):
- Entities with relations to other custom blueprints (e.g., k8s-resource → solution)
- K8s resource entities (pods, services, replicasets, etc.)
- CRD entities (capabilityscanconfig, remediationpolicy, etc.)

---

# Part 4: Delete Port Blueprints

Delete blueprints created during setup.

**Do NOT delete these default blueprints:**
- `cluster`
- `namespace`
- `workload`

**Delete custom blueprints** (use `mcp__port-vscode-eu__delete_blueprint`):
- K8s resources: pod, service, replicaset, ingress, gateway, httproute
- CRDs: capabilityscanconfig, remediationpolicy, resourcesyncconfig, solution, k8s-resource
- GitHub: githubWorkflow, githubWorkflowRun, githubPullRequest
- Other: prompt

---

# Part 5: Delete GitHub Integration Mapping (Optional)

If user wants to remove GitHub integration:

1. Go to Port Data Sources: https://app.port.io/settings/data-sources
2. Find the GitHub integration
3. Either:
   - Remove specific resource mappings (User action required)
   - Or uninstall the entire GitHub App (User action required)

---

# Part 6: Delete GitHub Workflows and Secrets

## Delete Workflow Files

```bash
rm .github/workflows/manage-*.yaml
```

## Delete Repository Secrets

```bash
gh secret delete PORT_CLIENT_ID
gh secret delete PORT_CLIENT_SECRET
gh secret delete KUBE_CONFIG  # if created
```

Commit and push the deletions.

---

# Part 7: Delete Local Manifest Files

Remove manifest files from the configured directory:

1. Delete Port-related manifests (e.g., `apps/port-k8s-exporter.yaml`)
2. Commit and push the deletions

---

# Part 8: Clean Up Port Catalog Folders (Optional)

If folders were created (User action required):

1. Go to [Port Catalog](https://app.getport.io/organization/catalog)
2. Move pages out of folders first
3. Right-click folder → Delete

---

# Verification

After cleanup, verify:

1. **Kubernetes**: `kubectl get ns port-k8s-exporter` returns not found
2. **Port**: No custom blueprints, entities, or actions remain
3. **GitHub**: No Port-related workflows or secrets
4. **Local**: No Port manifests in the repository
