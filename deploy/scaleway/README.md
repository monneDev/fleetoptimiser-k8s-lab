# Scaleway Kapsule

This environment lives here until the infra repository handles more than one
cluster; then it moves there. The chart comes from the OS2fleetoptimiser
checkout next to this repository, or from `FLEETOPTIMISER_REPO`.

`fleetoptimiser-values.yaml` is the starting point for a production
deployment on Scaleway Kapsule, and `deploy-app` installs it. Replace every
`CHANGE_ME` value before deploying; the script refuses to run while any are
left.

Kapsule provides the Kubernetes control plane. The ingress controller,
cert-manager, databases, RabbitMQ, Valkey, Keycloak and, if used, Argo CD and
Vault are platform services owned outside this repository. The values assume:

- an amd64 node pool, since the MSSQL driver is only in the amd64 image
- images in Scaleway Container Registry
- `registry-secret` in the application namespace
- ingress-nginx and cert-manager with a `letsencrypt-prod` ClusterIssuer
- external MSSQL, RabbitMQ and Valkey services
- an existing `fleetoptimiser-secrets` Secret

The values enable the Ingress, NetworkPolicies, PodDisruptionBudgets, two
replicas per component and the database initialisation Job. The service mesh
is off; Istio can be added later as a separate platform layer, after which the
chart's `mesh` and `httpRoute` replace the Ingress. See the chart
README in OS2fleetoptimiser (`charts/fleetoptimiser/README.md`) for the options.

## Secrets

Create the registry Secret the way Scaleway documents it:

```sh
kubectl create namespace fleetoptimiser
kubectl create secret docker-registry registry-secret \
  --namespace fleetoptimiser \
  --docker-server=rg.fr-par.scw.cloud \
  --docker-username=nologin \
  --docker-password="$SCW_SECRET_KEY"
```

Create the runtime Secret without writing the values to a file:

```sh
kubectl create secret generic fleetoptimiser-secrets \
  --namespace fleetoptimiser \
  --from-literal=database-password='<database password>' \
  --from-literal=rabbitmq-password='<rabbitmq password>' \
  --from-literal=valkey-password='<valkey password>' \
  --from-literal=keycloak-id='<client id>' \
  --from-literal=keycloak-secret='<client secret>' \
  --from-literal=keycloak-issuer='https://auth.example.dk/realms/fleetoptimiser' \
  --from-literal=better-auth-secret='<random 32+ byte value>' \
  --from-literal=better-auth-url='https://fleetoptimiser.example.dk'
```

## Deploy

Use a dedicated kubeconfig with exactly one context:

```sh
export KUBECONFIG="$HOME/.kube/fleetoptimiser-scaleway.yaml"
deploy/scaleway/deploy-app <image-tag>
```

The script checks the kubeconfig, the `CHANGE_ME` values and both Secrets,
lints the chart, runs `helm upgrade --install --atomic --wait` with the given
tag for both images and waits for every rollout. Use an immutable tag, not
`latest`. `FLEETOPTIMISER_VALUES`, `FLEETOPTIMISER_NAMESPACE` and
`FLEETOPTIMISER_RELEASE` override the defaults.
