#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/argocd.nu
source scripts/ingress.nu
source scripts/dot-ai.nu
source scripts/cert-manager.nu

def main [] {}

def "main setup" [] {

    rm --force .env

    $env.PROJECT_ID = "vfarcic"
    "export PROJECT_ID=vfarcic\n" | save --append .env

    main create kubernetes google --min-nodes 3 --node-size small --auth false

    main apply certmanager

    main apply ingress traefik --provider google

    kubectl create namespace infra

    (
        main apply argocd --host-name argocd.devopstoolkit.ai
            --ingress-class-name traefik --app-namespace infra
            --admin-password $env.ARGO_CD_PASSWORD --tls true
    )

    kubectl create namespace dot-ai

    (
        kubectl create secret generic dot-ai-secrets
            --namespace dot-ai
            $"--from-literal=anthropic-api-key=($env.ANTHROPIC_API_KEY)"
            $"--from-literal=openai-api-key=($env.OPENAI_API_KEY)"
    )

    main print source

}

def "main destroy" [] {
    
    main destroy kubernetes google --delete_project false

}
