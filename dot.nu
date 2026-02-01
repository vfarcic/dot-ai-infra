#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/argocd.nu
source scripts/ingress.nu
source scripts/dot-ai.nu
source scripts/cert-manager.nu

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

def "main setup linode cluster" [] {

    main create kubernetes linode --name dot-ai --min-nodes 3 --max-nodes 6 --node-size medium

    print $"(ansi green_bold)Linode cluster ready!(ansi reset)"
    print $"Next step: nu dot.nu setup linode argocd"

    main print source

}

def "main setup linode argocd" [] {

    kubectl create namespace infra

    kubectl create namespace external-secrets

    kubectl create namespace dot-ai

    # Bootstrap GCP service account secret for External Secrets
    # This secret allows External Secrets to authenticate with GCP Secret Manager
    print $"(ansi yellow_bold)Creating GCP service account secret for External Secrets...(ansi reset)"
    print $"Ensure GCP_SA_KEY environment variable contains the base64-encoded service account JSON key"

    if "GCP_SA_KEY" in $env {
        # Strip newlines from base64 (macOS base64 adds line breaks)
        let key_json = ($env.GCP_SA_KEY | str replace -a "\n" "" | decode base64 | decode)
        (
            kubectl create secret generic gcp-sa-key
                --namespace external-secrets
                $"--from-literal=key.json=($key_json)"
        )
    } else {
        print $"(ansi red_bold)GCP_SA_KEY not set! You must create the secret manually:(ansi reset)"
        print "kubectl create secret generic gcp-sa-key --namespace external-secrets --from-file=key.json=<path-to-key>"
    }

    (
        main apply argocd --host-name argocd.devopstoolkit.ai
            --app-namespace infra --admin-password $env.ARGO_CD_PASSWORD
            --gateway-api true
    )

    print $"(ansi green_bold)Argo CD setup complete!(ansi reset)"
    print $"Argo CD will sync apps from the apps/ directory."
    print $"Monitor with: kubectl get applications -n argocd"

}

def "main destroy" [] {

    main destroy kubernetes google --delete_project false

}

def "main destroy linode" [] {

    main destroy kubernetes linode

}
