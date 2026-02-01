# PRD: Deploy OpenClaw on Linode VM

**Issue**: [#23](https://github.com/vfarcic/dot-ai-infra/issues/23)
**Status**: In Progress
**Priority**: High
**Created**: 2026-02-01

## Problem Statement

Running OpenClaw (personal AI assistant) in a production Kubernetes cluster poses significant security risks. Container escape vulnerabilities (CVE-2025-31133, CVE-2025-52565, CVE-2025-52881) allow attackers to break out of containers and access the host system. Since all containers share the host kernel, a compromised AI agent could enable lateral movement to other production workloads, access cluster secrets, and compromise the entire infrastructure.

Security researchers have found over 1,800 exposed OpenClaw instances leaking API keys, chat histories, and credentials. The platform's MCP implementation has shell access by design, making it a high-risk workload that requires hardware-level isolation.

## Solution Overview

Deploy OpenClaw on an isolated Linode VM with defense-in-depth security:

1. **Hardware isolation**: Separate VM with its own kernel (no shared kernel with production)
2. **Network isolation**: Tailscale VPN mesh (no public ports exposed)
3. **Access control**: SSH key authentication only (no passwords)
4. **Container sandboxing**: Docker with security hardening
5. **Firewall**: UFW with strict egress rules

Create Nushell scripts integrated into the existing `dot.nu` automation framework for reproducible provisioning and configuration.

## Scope

- **In Scope**:
  - Linode VM provisioning scripts
  - System hardening (UFW, SSH, fail2ban)
  - Tailscale VPN installation and configuration
  - Docker installation with security settings
  - OpenClaw installation and initial configuration
  - Nushell automation integrated with `dot.nu`

- **Out of Scope**:
  - Integration with dot-ai platform (separate PRD)
  - Backup and disaster recovery
  - Multiple OpenClaw instances
  - Custom OpenClaw skills/plugins

## Technical Context

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Production GKE Cluster (Isolated)                          │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐           │
│  │ dot-ai  │ │ ArgoCD  │ │ Gateway │ │ Jaeger  │           │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘           │
└─────────────────────────────────────────────────────────────┘
                         │
                         │ No direct connection
                         │ (future: API integration via Tailscale)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Linode VM (Isolated)                                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Tailscale VPN (private mesh network)                │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ UFW Firewall                                        │   │
│  │ - SSH: Tailscale only                               │   │
│  │ - Gateway: Tailscale only (port 18789)              │   │
│  │ - Egress: HTTPS (443), DNS (53) only                │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Docker (hardened)                                   │   │
│  │ ┌─────────────────────────────────────────────────┐ │   │
│  │ │ OpenClaw Container                              │ │   │
│  │ │ - Non-root user                                 │ │   │
│  │ │ - Read-only root filesystem                     │ │   │
│  │ │ - Dropped capabilities                          │ │   │
│  │ └─────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### VM Sizing

| Plan | RAM | vCPU | Storage | Price | Use Case |
|------|-----|------|---------|-------|----------|
| Linode 2GB | 2GB | 1 | 50GB | $12/mo | Default (recommended) |
| Linode 4GB | 4GB | 2 | 80GB | $24/mo | Browser automation + multiple channels |

**Note**: VMs can be resized in-place via warm/cold resize. Start with 2GB, upgrade if needed.

### Security Layers

| Layer | Technology | Purpose |
|-------|------------|---------|
| Network | Tailscale | Zero-trust mesh VPN, no public ports |
| Firewall | UFW | Strict ingress/egress rules |
| Access | SSH keys | No password authentication |
| Intrusion | fail2ban | Block brute-force attempts |
| Container | Docker | Isolated execution environment |
| Runtime | Security context | Non-root, read-only, dropped caps |

### Files to Create

| File | Purpose |
|------|---------|
| `scripts/vm.nu` | Generic VM provisioning and management (supports Linode, extensible to other providers) |
| `scripts/openclaw.nu` | OpenClaw installation and hardening |

### Files to Modify

| File | Changes |
|------|---------|
| `dot.nu` | Add `main setup openclaw` and `main destroy openclaw` commands |

### Environment Variables Required

| Variable | Purpose | Storage |
|----------|---------|---------|
| `LINODE_TOKEN` | Linode API authentication | `.env` (local) |
| `TAILSCALE_AUTH_KEY` | Tailscale device authentication | `.env` (local) |
| `ANTHROPIC_API_KEY` | OpenClaw LLM provider | VM only |

## Success Criteria

- [ ] OpenClaw accessible only via Tailscale VPN (no public ports)
- [ ] SSH access working with key authentication only
- [ ] UFW firewall active with strict rules
- [ ] OpenClaw gateway responding and functional
- [ ] Can send messages via configured channels (WhatsApp/Telegram/etc.)
- [ ] VM can be provisioned and destroyed via `nu dot.nu` commands
- [ ] Documentation complete for initial setup and daily usage

## Milestones

### Milestone 1: Linode VM Provisioning Script
- [x] Create `scripts/vm.nu` with VM create/destroy/list functions
- [x] Support configurable VM size (2GB default, 4GB option)
- [x] Handle Linode API token securely
- [x] Wait for VM boot and SSH availability
- [x] Output VM IP and credentials to `.env`

### Milestone 2: System Hardening Script
- [x] Create `scripts/openclaw.nu` with hardening functions
- [x] Configure SSH key-only authentication (disable password auth)
- [x] Install and configure UFW firewall
- [x] Install fail2ban for brute-force protection
- [x] Apply system updates

### Milestone 3: Tailscale VPN Integration
- [x] Install Tailscale on VM
- [x] Configure Tailscale authentication
- [x] Update UFW rules to allow Tailscale traffic only
- [x] Document Tailscale setup for user's devices
- [x] Verify connectivity via Tailscale IP

### Milestone 4: Docker and OpenClaw Installation
- [ ] Install Docker with security best practices
- [ ] Install OpenClaw via official method
- [ ] Configure OpenClaw gateway with authentication
- [ ] Set up LLM provider (Anthropic API key)
- [ ] Verify OpenClaw is running and accessible

### Milestone 5: Integration with dot.nu
- [x] Add `main setup openclaw` command to `dot.nu`
- [x] Add `main destroy openclaw` command to `dot.nu`
- [ ] Test full provisioning workflow end-to-end
- [ ] Test destroy workflow

### Milestone 6: Documentation and Validation
- [ ] Document prerequisites (linode-cli, Tailscale account)
- [ ] Document initial setup steps
- [ ] Document how to access OpenClaw via Tailscale
- [ ] Document channel integration (WhatsApp, Telegram, etc.)
- [ ] Validate security by attempting public access (should fail)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Tailscale service outage | Medium | SSH still accessible via Tailscale; document manual IP access as emergency fallback |
| OpenClaw security vulnerability | High | Hardware isolation contains blast radius to single VM |
| Linode API token compromise | Medium | Use read/write scope only, rotate regularly |
| SSH key loss | High | Document key backup procedure |
| VM cost overrun | Low | Default to 2GB ($12/mo); can resize down if needed |

## Dependencies

- Linode account with API access
- Tailscale account (free personal tier)
- `linode-cli` installed locally
- Anthropic API key (or other LLM provider)
- SSH key pair for authentication

## Non-Goals

- High availability / redundancy
- Automated backups
- Integration with dot-ai platform
- Custom OpenClaw skill development
- Multi-user access

## Timeline

Not estimated - milestones provide natural checkpoints for progress tracking.
