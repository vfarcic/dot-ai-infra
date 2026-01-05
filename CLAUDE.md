# CLAUDE.md

This file provides context for Claude Code when working with this repository.

## Project Overview

This is a GitOps infrastructure repository for deploying the **dot-ai** platform (an AI-driven DevOps solution) on Google Kubernetes Engine (GKE). It uses Argo CD for continuous deployment.

## Key Technologies

- **Kubernetes/GKE** - Container orchestration on Google Cloud
- **Argo CD** - GitOps continuous deployment
- **Helm** - Package management for Kubernetes apps
- **Nushell** - Shell scripting (`.nu` files)
- **External Secrets + vals** - Secrets management with GCP Secret Manager
- **Gateway API** - Kubernetes ingress/routing

## Directory Structure

```
apps/           # Argo CD Application manifests (Kubernetes resources to deploy)
scripts/        # Nushell modules for infrastructure automation
argocd/         # Argo CD self-management configuration
examples/       # Test resources (warning events, etc.)
dot.nu          # Main Nushell entry point
```

## Common Commands

All commands are run via `dot.nu` using Nushell:

```bash
# Full cluster setup (creates GKE cluster, installs all components)
nu dot.nu setup

# Destroy the cluster
nu dot.nu destroy
```

## Nushell Scripts

The `scripts/` directory contains modular Nushell functions:

- `kubernetes.nu` - Cluster creation/deletion
- `argocd.nu` - Argo CD installation
- `cert-manager.nu` - TLS certificate management
- `ingress.nu` - Ingress configuration
- `dot-ai.nu` - dot-ai specific utilities
- `common.nu` - Shared helper functions

## Deployed Services

| Service | Domain |
|---------|--------|
| dot-ai API | `dot-ai.devopstoolkit.ai` |
| dot-ai UI | `ui.devopstoolkit.ai` |
| Argo CD | `argocd.devopstoolkit.ai` |

## Argo CD Applications

Apps in `apps/` are automatically synced by Argo CD. Key applications:

- `dot-ai-stack.yaml` - Main dot-ai platform (Helm chart from `ghcr.io/vfarcic/dot-ai-stack`)
- `external-secrets.yaml` - External Secrets operator
- `gateway.yaml` - GKE Gateway for routing

## Secrets Management

Secrets are stored in GCP Secret Manager and referenced via:
1. `.env.vals.yaml` - vals references to GCP secrets
2. External Secrets operator - creates Kubernetes secrets from GCP

Required environment variables for setup:
- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `DOT_AI_AUTH_TOKEN`
- `SLACK_WEBHOOK_URL`
- `ARGO_CD_PASSWORD`

## Dependency Updates

Renovate is configured to automatically update Helm chart versions in `apps/*.yaml` files.

## Custom Resources

This project works with the custom `Solution` CRD (`dot-ai.devopstoolkit.live/v1alpha1`) defined by the dot-ai platform.

## MCP Integration

The `.mcp.json` configures the dot-ai MCP server at `https://dot-ai.devopstoolkit.ai` for Claude Code integration.
