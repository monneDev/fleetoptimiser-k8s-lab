#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$LAB_ROOT/config/local.env"
export HELM_CACHE_HOME="$LAB_ROOT/.cache/helm/cache"
export HELM_CONFIG_HOME="$LAB_ROOT/.cache/helm/config"
export HELM_DATA_HOME="$LAB_ROOT/.cache/helm/data"

die() { printf '%s\n' "$*" >&2; exit 1; }
k() {
  local kubectl_path
  kubectl_path=$(command -v kubectl 2>/dev/null || true)
  if [[ -n "$kubectl_path" && -x "$kubectl_path" ]]; then
    kubectl --request-timeout=20s "$@"
  elif command -v k3s >/dev/null 2>&1; then
    k3s kubectl --request-timeout=20s "$@"
  else
    die 'Neither a working kubectl nor k3s executable was found.'
  fi
}

guard() {
  [[ -f "$LAB_KUBECONFIG" ]] || die 'Local kubeconfig is missing.'
  [[ -z "${KUBECONFIG:-}" || "$KUBECONFIG" == "$LAB_KUBECONFIG" ]] || die 'KUBECONFIG differs from config/local.env; refusing.'
  export KUBECONFIG="$LAB_KUBECONFIG"
  local context_count api uid
  context_count=$(k config get-contexts -o name | awk 'NF { count++ } END { print count+0 }')
  [[ "$context_count" == 1 ]] || die 'Exactly one kubeconfig context is required.'
  api=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  [[ "$api" == "$LAB_API" && "$api" == https://127.0.0.1:6443 ]] || die 'Expected the local k3s API.'
  uid=$(k get namespace kube-system -o jsonpath='{.metadata.uid}')
  [[ "$uid" == "$LAB_CLUSTER_UID" ]] || die 'Cluster UID differs from the verified local cluster.'
  printf 'Verified local k3s (%s).\n' "$uid"
}

owned_namespaces() {
  local ns owner present
  for ns in istio-system monitoring fleetoptimiser-lab; do
    present=$(k get namespace "$ns" --ignore-not-found -o name)
    if [[ -n "$present" ]]; then
      owner=$(k get namespace "$ns" -o jsonpath='{.metadata.labels.fleetoptimiser-lab/owner}')
      [[ "$owner" == local ]] || die "Namespace $ns already exists and is not owned by this lab."
    fi
  done
}

enable_fleetoptimiser_mesh() {
  [[ "$(k get namespace fleetoptimiser -o name)" == namespace/fleetoptimiser ]] || die 'fleetoptimiser namespace is missing.'
  k label namespace fleetoptimiser fleetoptimiser-lab/mesh=enabled --overwrite
}

fetch() {
  mkdir -p "$LAB_ROOT/.cache/charts"
  while read -r release ns chart version repo values; do
    [[ -z "$release" || "$release" == \#* ]] && continue
    if [[ ! -s "$LAB_ROOT/.cache/charts/$chart-$version.tgz" ]]; then
      helm pull "$chart" --repo "$repo" --version "$version" --destination "$LAB_ROOT/.cache/charts"
    fi
  done < "$LAB_ROOT/config/charts.tsv"
}

validate() {
  bash -n "$LAB_ROOT/scripts/lab.sh"
  mkdir -p "$LAB_ROOT/rendered"
  chmod 700 "$LAB_ROOT/rendered"
  # Rendered Helm Secrets may contain generated credentials; never commit them.
  umask 077
  while read -r release ns chart version repo values; do
    [[ -z "$release" || "$release" == \#* ]] && continue
    local package="$LAB_ROOT/.cache/charts/$chart-$version.tgz"
    [[ -s "$package" ]] || die 'Run fetch first.'
    helm lint "$package" --values "$LAB_ROOT/values/$values" --kube-version 1.36.3
    helm template "$release" "$package" --namespace "$ns" --values "$LAB_ROOT/values/$values" \
      --kube-version 1.36.3 --include-crds > "$LAB_ROOT/rendered/$release.yaml"
  done < "$LAB_ROOT/config/charts.tsv"
  printf 'All charts linted and rendered for Kubernetes 1.36.3.\n'
}

deploy() {
  guard
  owned_namespaces
  # Pre-render everything before the first cluster write.
  validate
  k apply -f "$LAB_ROOT/manifests/namespaces.yaml"
  while read -r release ns chart version repo values; do
    [[ -z "$release" || "$release" == \#* ]] && continue
    helm upgrade --install "$release" "$LAB_ROOT/.cache/charts/$chart-$version.tgz" \
      --namespace "$ns" --values "$LAB_ROOT/values/$values" --wait --timeout 10m
  done < "$LAB_ROOT/config/charts.tsv"
  enable_fleetoptimiser_mesh
  k apply -f "$LAB_ROOT/manifests/mesh-demo.yaml"
  k apply -f "$LAB_ROOT/manifests/mesh-monitor.yaml"
  k apply -f "$LAB_ROOT/manifests/loadtest.yaml"
  k apply -f "$LAB_ROOT/manifests/workload-monitoring.yaml"
  k apply -f "$LAB_ROOT/manifests/workload-dashboard.yaml"
  for app in echo mesh-client plain-client; do
    k -n fleetoptimiser-lab rollout status "deployment/$app" --timeout=180s
  done
}

run_loadtest() {
  guard
  local level job wait_timeout
  level="${1:-}"
  case "$level" in
    baseline|2x|5x|10x) ;;
    soak) ;;
    *) die 'Choose one load level: baseline, 2x, 5x, 10x or soak.' ;;
  esac
  wait_timeout=10m
  [[ "$level" == soak ]] && wait_timeout=35m
  job="fleetoptimiser-loadtest-$level"
  [[ "$(k get job "$job" -n fleetoptimiser-loadtest -o name 2>/dev/null)" == "job.batch/$job" ]] || die "Loadtest job $job is not installed. Run deploy first."
  k patch job "$job" -n fleetoptimiser-loadtest --type merge -p '{"spec":{"suspend":false}}'
  if ! k wait --for=condition=complete "job/$job" -n fleetoptimiser-loadtest --timeout="$wait_timeout"; then
    k logs -n fleetoptimiser-loadtest "job/$job" --all-containers=true || true
    die "Loadtest $level failed."
  fi
  k logs -n fleetoptimiser-loadtest "job/$job" --all-containers=true
}

verify() {
  guard
  local body code proxies
  for app in echo mesh-client; do
    proxies=$(k -n fleetoptimiser-lab get pods -l "app=$app" -o jsonpath='{.items[0].metadata.annotations.sidecar\.istio\.io/status}')
    [[ "$proxies" == *istio-proxy* ]] || die "$app lacks an Istio sidecar."
  done
  body=$(k -n fleetoptimiser-lab exec deployment/mesh-client -c curl -- \
    curl --fail --silent --show-error --max-time 10 http://echo/)
  [[ "$body" == fleetoptimiser-lab-ok ]] || die 'Mesh request did not return the expected body.'
  if k -n fleetoptimiser-lab exec deployment/plain-client -c curl -- \
    curl --fail --silent --show-error --max-time 10 http://echo/; then
    die 'Plaintext request unexpectedly succeeded.'
  fi
  code=$(k -n fleetoptimiser-lab exec deployment/mesh-client -c curl -- \
    curl --silent --show-error --max-time 10 -X POST -o /dev/null -w '%{http_code}' http://echo/)
  [[ "$code" == 403 ]] || die "Expected policy to reject POST with 403, got $code."
  # Positive request after the negative test rules out a general service outage.
  k -n fleetoptimiser-lab exec deployment/mesh-client -c curl -- \
    curl --fail --silent --show-error --max-time 10 http://echo/
  printf '\nPASS: injected sidecars, mesh GET, plaintext rejection, POST rejection.\n'
  k get pods -n monitoring
  k get pods -n istio-system
}

verify_app() {
  guard
  local app proxies mode body code
  for app in backend frontend worker; do
    proxies=$(k -n fleetoptimiser get pods -l "app.kubernetes.io/component=$app" -o jsonpath='{.items[0].metadata.annotations.sidecar\.istio\.io/status}')
    [[ "$proxies" == *istio-proxy* ]] || die "fleetoptimiser $app lacks an Istio sidecar."
  done
  mode=$(k -n fleetoptimiser get peerauthentication fleetoptimiser -o jsonpath='{.spec.mtls.mode}')
  [[ "$mode" == STRICT ]] || die "Expected STRICT PeerAuthentication in fleetoptimiser, got '$mode'."
  body=$(k -n fleetoptimiser-lab exec deployment/mesh-client -c curl -- \
    curl --fail --silent --show-error --max-time 10 http://fleetoptimiser-backend.fleetoptimiser:3001/healthz)
  [[ "$body" == *'"ok"'* ]] || die 'Allowed mesh identity could not reach the backend.'
  code=$(k -n fleetoptimiser-lab exec deployment/mesh-client -c curl -- \
    curl --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' http://fleetoptimiser-frontend.fleetoptimiser:3000/)
  [[ "$code" == [23]* ]] || die "Allowed mesh identity got $code from the frontend."
  if k -n fleetoptimiser-lab exec deployment/plain-client -c curl -- \
    curl --fail --silent --show-error --max-time 10 http://fleetoptimiser-backend.fleetoptimiser:3001/healthz; then
    die 'Plaintext request to the backend unexpectedly succeeded.'
  fi
  # The worker is in the mesh but not an allowed caller of the backend.
  code=$(k -n fleetoptimiser exec deployment/fleetoptimiser-worker -c worker -- python -c '
import urllib.error, urllib.request
try:
    print(urllib.request.urlopen("http://fleetoptimiser-backend:3001/healthz", timeout=10).status)
except urllib.error.HTTPError as error:
    print(error.code)')
  [[ "$code" == 403 ]] || die "Expected the backend policy to reject the worker with 403, got $code."
  # Positive request after the negative tests rules out a general outage.
  k -n fleetoptimiser-lab exec deployment/mesh-client -c curl -- \
    curl --fail --silent --show-error --max-time 10 http://fleetoptimiser-backend.fleetoptimiser:3001/healthz
  printf '\nPASS: app sidecars, STRICT mTLS, allowed backend/frontend calls, plaintext and worker rejection.\n'
}

telemetry() {
  guard
  # Print only aggregate results, not log contents or credential-bearing config.
  k get --raw '/api/v1/namespaces/monitoring/services/http:lab-monitoring-prometheus:9090/proxy/api/v1/query?query=istio_requests_total%7Bdestination_service_namespace%3D~%22fleetoptimiser(-lab)?%22%2Cconnection_security_policy%3D%22mutual_tls%22%7D' | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("data",{}).get("result",[]); assert d.get("status")=="success" and any(float(r["value"][1])>0 for r in rows), "No mTLS traffic metrics yet; run verify and wait for a scrape"; print("PASS: Prometheus contains mutual_tls request metrics.")'
  k get --raw '/api/v1/namespaces/monitoring/services/http:lab-loki:3100/proxy/loki/api/v1/query_range?query=%7Bnamespace%3D%22fleetoptimiser-lab%22%7D&limit=1' | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("data",{}).get("result",[]); assert d.get("status")=="success" and any(r.get("values") for r in rows), "No lab logs in Loki yet"; print("PASS: Loki contains lab pod logs delivered by Alloy.")'
}

case "${1:-help}" in
  fetch) fetch ;;
  validate) validate ;;
  preflight)
    guard
    owned_namespaces
    k get nodes
    k top nodes
    ;;
  deploy) deploy ;;
  verify) verify ;;
  verify-app) verify_app ;;
  telemetry) telemetry ;;
  run) run_loadtest "${2:-}" ;;
  status)
    guard
    helm list -A
    k get pods -n monitoring
    k get pods -n fleetoptimiser-lab
    ;;
  grafana) guard; k -n monitoring port-forward --address 127.0.0.1 service/lab-monitoring-grafana 3000:80 ;;
  prometheus) guard; k -n monitoring port-forward --address 127.0.0.1 service/lab-monitoring-prometheus 9090:9090 ;;
  kubectl) guard; shift; k "$@" ;;
  *) printf '%s\n' 'Usage: bash scripts/lab.sh {fetch|validate|preflight|deploy|verify|verify-app|telemetry|status|grafana|prometheus|kubectl ...}' ;;
esac
