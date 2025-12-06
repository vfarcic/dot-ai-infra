#!/usr/bin/env nu

source scripts/kubernetes.nu
source scripts/common.nu
source scripts/argocd.nu
source scripts/ingress.nu
source scripts/dot-ai.nu

def main [] {}

def "main setup" [] {

    rm --force .env

    $env.PROJECT_ID = "vfarcic"
    "export PROJECT_ID=vfarcic\n" | save --append .env

    main create kubernetes google --min-nodes 3 --node-size small --auth false

    main apply ingress traefik --provider google

    # main apply argocd --host-name 34.148.120.91.nip.io --ingress-class-name traefik

    main print source

}

def "main destroy" [] {
    
    main destroy kubernetes google --delete_project false

}
