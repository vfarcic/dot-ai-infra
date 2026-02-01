#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/argocd.nu
source scripts/ingress.nu
source scripts/dot-ai.nu
source scripts/cert-manager.nu
source scripts/vm.nu

def main [] {}

def "main setup" [] {

    $env.PROJECT_ID = "vfarcic"
    "export PROJECT_ID=vfarcic\n" | save --append .env

    main create kubernetes google --name dot-ai --min-nodes 3 --node-size small --auth false

    main apply certmanager

    # main apply ingress traefik --provider google

    kubectl create namespace infra

    kubectl create namespace examples

    (
        main apply argocd --host-name argocd.devopstoolkit.ai
            --app-namespace infra --admin-password $env.ARGO_CD_PASSWORD
            --gateway-api true
    )

    kubectl create namespace dot-ai

    (
        kubectl create secret generic dot-ai-secrets
            --namespace dot-ai
            $"--from-literal=anthropic-api-key=($env.ANTHROPIC_API_KEY)"
            $"--from-literal=openai-api-key=($env.OPENAI_API_KEY)"
            $"--from-literal=auth-token=($env.DOT_AI_AUTH_TOKEN)"
            $"--from-literal=SLACK_WEBHOOK_URL=($env.SLACK_WEBHOOK_URL)"
    )

    main print source

}

def "main destroy" [] {

    main destroy kubernetes google --delete_project false

}

# Sets up an isolated OpenClaw VM on Linode
#
# Examples:
# > main setup openclaw
# > main setup openclaw --size g6-standard-2
def "main setup openclaw" [
    --size: string = "g6-standard-1"  # VM size (g6-nanode-1=1GB, g6-standard-1=2GB, g6-standard-2=4GB)
] {

    let vm = (main create vm "openclaw" --provider linode --size $size)

    main wait-ssh $vm.ip

    print $"
(ansi green_bold)OpenClaw VM created successfully!(ansi reset)

  IP Address: (ansi yellow_bold)($vm.ip)(ansi reset)
  SSH:        (ansi yellow_bold)ssh root@($vm.ip)(ansi reset)

Next steps:
  1. Run system hardening (Milestone 2)
  2. Install Tailscale VPN (Milestone 3)
  3. Install Docker and OpenClaw (Milestone 4)
"

    main print source
}

# Destroys the OpenClaw VM
#
# Examples:
# > main destroy openclaw
# > main destroy openclaw --force
def "main destroy openclaw" [
    --force  # Skip confirmation prompt
] {

    if $force {
        main destroy vm "openclaw" --provider linode --force
    } else {
        main destroy vm "openclaw" --provider linode
    }
}
