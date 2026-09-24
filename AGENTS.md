# Local Kubernetes lab

Follow /home/simon/.codex/RTK.md for shell commands.
This project targets only the local k3s cluster. All cluster operations must
use scripts/lab.sh, which checks the explicit kubeconfig, API endpoint and
kube-system namespace UID. Never use an implicit context or read secret values.
The sibling infra and OS2fleetoptimiser repositories are references; changes
to them are a separate task. Keep upstream Helm charts unmodified.
Do not enable injection or change workloads in existing application namespaces
as part of the initial lab installation. Cluster-scoped CRDs/webhooks are shared;
separate namespaces are not equivalent to separate clusters.
