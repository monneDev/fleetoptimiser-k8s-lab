# Local Kubernetes lab

This lab targets only a local k3s cluster. All cluster operations must use
scripts/lab.sh, which checks the kubeconfig, API endpoint and
kube-system namespace UID recorded in config/local.env (created per machine by
`lab.sh init`, never committed). Never use an implicit context or read secret
values.

The application code and its chart (charts/fleetoptimiser) live in the
OS2fleetoptimiser repository, checked out next to this one or at
FLEETOPTIMISER_REPO; never change it from here. This repository holds the lab,
the local dependency values (deploy/local) and, until the infra repository
handles more than one cluster, the Scaleway environment (deploy/scaleway).
KUBERNETES.md is the end-to-end guide. Keep upstream Helm charts unmodified. Cluster-scoped
CRDs/webhooks are shared; separate namespaces are not equivalent to separate
clusters.
