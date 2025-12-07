#!/usr/bin/env nu

# Installs ArgoCD with optional ingress and applications setup
#
# Examples:
# > main apply argocd --host_name argocd.example.com --ingress_class_name nginx
# > main apply argocd --host_name argocd.example.com --tls
def "main apply argocd" [
    --host-name = "",
    --apply-apps = true,
    --ingress-class-name = "traefik",
    --admin-password = "admin123",
    --app-namespace = "a-team",
    --tls = false,
    --cluster-issuer = "letsencrypt"
] {

    let git_url = git config --get remote.origin.url

    let hashed_password = (
        htpasswd -nbBC 10 "" $admin_password
            | tr -d ':\n'
            | sed 's/$2y/$2a/'
    )

    {
        configs: {
            secret: {
                argocdServerAdminPasswordMtime: "2021-11-08T15:04:05Z"
            }
            cm: {
                application.resourceTrackingMethod: annotation
                timeout.reconciliation: 60s
            }
            params: { "server.insecure": true }
        }
        server: {
            ingress: ({
                enabled: true
                ingressClassName: $ingress_class_name
                hostname: $host_name
            } | if $tls {
                $in | merge {
                    annotations: { "cert-manager.io/cluster-issuer": $cluster_issuer }
                    tls: true
                }
            } else { $in })
            extraArgs: [
                --insecure
            ]
        }
    } | save argocd-values.yaml --force

    helm repo add argo https://argoproj.github.io/argo-helm

    helm repo update
  
    (
        helm upgrade --install argocd argo/argo-cd
            --namespace argocd --create-namespace
            --values argocd-values.yaml --wait
            --set $"configs.secret.argocdServerAdminPassword=($hashed_password)"
    )

    mkdir argocd

    {
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata: {
            name: apps
            namespace: argocd
        }
        spec: {
            project: default
            source: {
                repoURL: $git_url
                targetRevision: HEAD
                path: apps
            }
            destination: {
                server: "https://kubernetes.default.svc"
                namespace: $app_namespace
            }
            syncPolicy: {
                automated: {
                    selfHeal: true
                    prune: true
                    allowEmpty: true
                }
                syncOptions: [
                    "SkipDryRunOnMissingResource=true"
                ]
            }
        }
    } | save argocd/app.yaml --force

    if $apply_apps {
        
        kubectl apply --filename argocd/app.yaml

    }

}
