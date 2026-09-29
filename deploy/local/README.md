# Local Kubernetes dependencies

These values are intended only for a local k3s development cluster. Production
data services are owned and configured by the infrastructure platform.

Always select a dedicated, single-context kubeconfig explicitly. On a k3s
node it can be copied from the k3s default:

```sh
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/fleetoptimiser-k3s.yaml
sudo chown "$USER" ~/.kube/fleetoptimiser-k3s.yaml
chmod 600 ~/.kube/fleetoptimiser-k3s.yaml
export KUBECONFIG="$HOME/.kube/fleetoptimiser-k3s.yaml"
```

The commands below assume `KUBECONFIG` is set this way.

## RabbitMQ

Install the pinned third-party Helm chart:

```sh
helm upgrade --install fleetoptimiser-rabbitmq \
  oci://registry-1.docker.io/bitnamicharts/rabbitmq \
  --version 16.0.14 \
  --namespace fleetoptimiser \
  --values deploy/local/rabbitmq-values.yaml \
  --wait \
  --timeout 10m
```

The chart normally refers to a Bitnami image that is no longer published in the
maintained registry. The local values therefore pin the matching archived image
from `bitnamilegacy`. That image no longer receives updates and must not be used
for production. Select a supported chart/image strategy with the infrastructure
owners before production deployment.

The local Secret script creates the password in a Kubernetes Secret. Do not
commit or print the generated value. Check the broker process without
retrieving that Secret:

```sh
kubectl exec -n fleetoptimiser fleetoptimiser-rabbitmq-0 -- \
  rabbitmq-diagnostics -q ping
```

Remove the local release with:

```sh
helm uninstall fleetoptimiser-rabbitmq --namespace fleetoptimiser
```

## Valkey

The local cluster uses the official Valkey chart in standalone mode. Add its
repository and install the pinned chart version:

```sh
helm repo add valkey https://valkey.io/valkey-helm/
helm repo update valkey
helm upgrade --install fleetoptimiser-valkey valkey/valkey \
  --version 0.11.0 \
  --namespace fleetoptimiser \
  --values deploy/local/valkey-values.yaml \
  --wait \
  --timeout 10m
```

The local values create one standalone Valkey instance with a 1 GiB
`local-path` volume and a ClusterIP service.

Confirm that unauthenticated access is rejected without retrieving any Secret:

```sh
kubectl exec -n fleetoptimiser deploy/fleetoptimiser-valkey -- \
  valkey-cli ping
```

The expected response is `NOAUTH Authentication required.` An authenticated
`PONG` is verified during installation by injecting the Secret directly into a
short-lived client pod; the password is not copied to the terminal.

Remove the local release with:

```sh
helm uninstall fleetoptimiser-valkey --namespace fleetoptimiser
```

Production uses the Valkey operator already declared in the infra repository;
Kubenix renders that operator's Helm chart and adds the required `Valkey`
custom resource. The direct standalone chart here is only a lightweight local
dependency for application testing.

## Local authentication Secrets

Create the namespaces and the test Secrets for RabbitMQ, Valkey, PostgreSQL and
Keycloak before installing or upgrading the releases:

```sh
kubectl create namespace fleetoptimiser
kubectl create namespace keycloak
./deploy/local/create-test-secrets.sh
```

The script requires a kubeconfig with exactly one context, generates random
passwords and never overwrites an existing Secret. Passwords are neither
printed nor stored in Git. The values files contain only Secret references.

RabbitMQ uses `fleetoptimiser-rabbitmq-auth` with key `rabbitmq-password`.
Valkey uses `fleetoptimiser-valkey-auth` with key `default` for its default ACL
user. PostgreSQL uses `fleetoptimiser-postgresql-auth` with key `password`.
Keycloak uses `keycloak-db-credentials` and `keycloak-admin-credentials`, both
with key `password`, in the `keycloak` namespace.
Application connection URLs will be assembled from these Secrets by the
FleetOptimiser chart rather than committed as plaintext values.

## PostgreSQL

The ARM64 development node cannot run the standard Microsoft SQL Server Linux
container. Local end-to-end tests therefore use PostgreSQL in standalone mode;
production remains free to use the external MSSQL service declared by the infra
repository.

Create the test Secrets as described above, then install the pinned third-party
chart:

```sh
helm upgrade --install fleetoptimiser-postgresql \
  oci://registry-1.docker.io/bitnamicharts/postgresql \
  --version 16.7.27 \
  --namespace fleetoptimiser \
  --values deploy/local/postgresql-values.yaml \
  --wait \
  --timeout 10m
```

The release creates one PostgreSQL pod, a ClusterIP Service and a 2 GiB
`local-path` PVC. The FleetOptimiser chart will use these non-secret settings:

```text
DB_SERVER=postgresql+psycopg2
DB_URL=fleetoptimiser-postgresql:5432
DB_NAME=fleetoptimiser
DB_USER=fleetoptimiser
```

`DB_PASSWORD` will come from Secret `fleetoptimiser-postgresql-auth`, key
`password`.

Remove the local release with:

```sh
helm uninstall fleetoptimiser-postgresql --namespace fleetoptimiser
```

## Backend/Celery smoke test

After importing the local backend image and installing the FleetOptimiser chart,
the following request verifies the complete backend path without frontend or
Keycloak:

```sh
sudo k3s kubectl --kubeconfig "$KUBECONFIG" \
  exec -n fleetoptimiser deployment/fleetoptimiser-backend -- \
  curl --fail-with-body --silent --show-error \
  -H 'Content-Type: application/json' \
  --data '{"start_date":"2026-08-17","end_date":"2026-08-31","location_id":1,"location_ids":[1],"intelligent_allocation":false,"limit_km":false,"simulation_vehicles":[{"id":0,"simulation_count":1},{"id":3,"simulation_count":1}],"current_vehicles":[0,3],"settings":null}' \
  http://127.0.0.1:3001/fleet-simulation/simulation
```

The response contains an `id`. Query that id to follow the asynchronous Celery
job:

```sh
sudo k3s kubectl --kubeconfig "$KUBECONFIG" \
  exec -n fleetoptimiser deployment/fleetoptimiser-backend -- \
  curl --fail --silent --show-error \
  'http://127.0.0.1:3001/fleet-simulation/simulation/<task-id>'
```

The local smoke test completed successfully with 126 trips and zero
unallocated trips. It exercises Backend → RabbitMQ → Celery worker →
PostgreSQL/Valkey → Backend result retrieval.

## Local Keycloak

Keycloak uses the codecentric `keycloakx` chart for local testing. Install its
database first:

```sh
helm upgrade --install keycloak-postgresql \
  oci://registry-1.docker.io/bitnamicharts/postgresql \
  --version 16.7.27 \
  --namespace keycloak \
  --values deploy/local/keycloak-postgresql-values.yaml \
  --wait \
  --timeout 10m
```

Then install Keycloak:

```sh
helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo update codecentric
helm upgrade --install keycloak codecentric/keycloakx \
  --version 2.3.0 \
  --namespace keycloak \
  --values deploy/local/keycloak-values.yaml \
  --wait \
  --timeout 10m
```

This release is local-only and has no ingress. The admin password is supplied
by `keycloak-admin-credentials`; access it through a temporary port-forward when
creating the FleetOptimiser OIDC client.
