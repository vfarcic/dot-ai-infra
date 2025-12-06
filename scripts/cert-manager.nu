#!/usr/bin/env nu

# Installs cert-manager for managing TLS certificates in Kubernetes
def "main apply certmanager" [] {

    (
        helm upgrade --install cert-manager cert-manager
            --repo https://charts.jetstack.io
            --namespace cert-manager --create-namespace
            --set crds.enabled=true --wait
    )

}

# Creates a ClusterIssuer for Let's Encrypt certificates
def "main apply clusterissuer" [
    --email: string          # Email for Let's Encrypt notifications
    --name: string = "letsencrypt"  # Name of the ClusterIssuer
    --ingress-class: string = "traefik"  # Ingress class for HTTP01 challenge
] {

    let issuer = $"apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ($name)
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ($email)
    privateKeySecretRef:
      name: ($name)
    solvers:
    - http01:
        ingress:
          class: ($ingress_class)
"

    $issuer | kubectl apply --filename -

}