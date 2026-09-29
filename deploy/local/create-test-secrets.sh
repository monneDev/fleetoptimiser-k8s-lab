#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Set KUBECONFIG to the dedicated fleetoptimiser kubeconfig}"

namespace="${1:-fleetoptimiser}"
keycloak_namespace="${2:-keycloak}"
read -r -a kubectl_command <<< "${KUBECTL_COMMAND:-kubectl}"
context_count="$("${kubectl_command[@]}" config get-contexts -o name | wc -l)"

if [[ "$context_count" -ne 1 ]]; then
  echo "Refusing to continue: KUBECONFIG must contain exactly one context." >&2
  exit 1
fi

create_secret() {
  local namespace="$1"
  local name="$2"
  local key="$3"
  local password

  if "${kubectl_command[@]}" get secret "$name" --namespace "$namespace" >/dev/null 2>&1; then
    echo "secret/$name in $namespace already exists; leaving it unchanged"
    return
  fi

  password="$(openssl rand -hex 32)"
  "${kubectl_command[@]}" create secret generic "$name" \
    --namespace "$namespace" \
    --from-literal="${key}=${password}" >/dev/null
  unset password

  echo "secret/$name created in $namespace"
}

create_secret "$namespace" fleetoptimiser-rabbitmq-auth rabbitmq-password
create_secret "$namespace" fleetoptimiser-valkey-auth default
create_secret "$namespace" fleetoptimiser-postgresql-auth password
create_secret "$keycloak_namespace" keycloak-db-credentials password
create_secret "$keycloak_namespace" keycloak-admin-credentials password
