# FleetOptimiser på lokal k3s

Guiden fører dig fra en tom maskine til FleetOptimiser kørende i dit eget
k3s-cluster med login, service mesh (Istio, STRICT mTLS), monitoring og
loadtest. Alle kommandoer køres fra roden af dette repo, `fleetoptimiser-k8s-lab`.

Det hele er kun til lokal udvikling. Adgangskoder genereres tilfældigt og
ligger kun som Kubernetes Secrets i dit cluster.

```text
k3s (én node)
├── fleetoptimiser           backend, frontend, worker, PostgreSQL, RabbitMQ, Valkey
├── keycloak                 Keycloak og dens PostgreSQL
├── istio-system             Istio control plane
├── monitoring               Prometheus, Grafana, Loki, Alloy
├── fleetoptimiser-lab       mesh-demo og testklienter
└── fleetoptimiser-loadtest  k6-loadtests
```

| Hvad | Hvor |
|---|---|
| Helm-chart til appen | `charts/fleetoptimiser` i OS2fleetoptimiser |
| Values og detaljer for de lokale afhængigheder | [`deploy/local`](deploy/local/README.md) |
| Istio, monitoring og loadtest | [`README.md`](README.md) |

## 1. Forudsætninger

- Linux eller WSL2 med k3s. Opsætningen er udviklet på én ARM64-node med
  Kubernetes 1.36 (k3s v1.36.3+k3s1).
- Docker til at bygge images, Helm 3, git, openssl og Python 3.
- Omkring 4 CPU-kerner, 8 GB fri RAM og 20 GB fri disk. Hele stakken bruger
  ca. 4 GiB RAM i hvile, og de lokale volumes fylder ca. 17 GiB.

Installer k3s, hvis du ikke har det:

```sh
curl -sfL https://get.k3s.io | sh -
```

## 2. Hent koden

Labbet installerer chartet fra en `OS2fleetoptimiser`-checkout ved siden af
dette repo:

```text
projects/
├── OS2fleetoptimiser        app-kode og Helm-chart
└── fleetoptimiser-k8s-lab   dette repo
```

Kubernetes-branchen er endnu ikke i OS2-upstream. Den ligger i det private
repo `monneDev/OS2fleetoptimiser`, som du skal være inviteret til:

```sh
git clone -b kubernetes-deployment https://github.com/monneDev/OS2fleetoptimiser.git
git clone https://github.com/monneDev/fleetoptimiser-k8s-lab.git
cd fleetoptimiser-k8s-lab
```

Ligger OS2fleetoptimiser et andet sted, så sæt
`FLEETOPTIMISER_REPO=/sti/til/OS2fleetoptimiser`.

## 3. Kubeconfig og cluster-identitet

Brug en dedikeret kubeconfig med præcis én context, så kommandoerne ikke kan
ramme et andet cluster:

```sh
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/fleetoptimiser-k3s.yaml
sudo chown "$USER" ~/.kube/fleetoptimiser-k3s.yaml
chmod 600 ~/.kube/fleetoptimiser-k3s.yaml
export KUBECONFIG="$HOME/.kube/fleetoptimiser-k3s.yaml"
kubectl get nodes
```

Registrér dit clusters identitet til lab-scriptet. Det skriver
`config/local.env`, som ikke committes:

```sh
bash scripts/lab.sh init
```

Sæt `KUBECONFIG` som ovenfor i hver ny terminal.

## 4. Byg og importér images

k3s bruger sin egen containerd og kan ikke se Dockers images. Byg dem og
importér dem i k3s:

```sh
docker build -t fleetoptimiser-backend:local ../OS2fleetoptimiser
docker build -t fleetoptimiser-frontend:local ../OS2fleetoptimiser/fleetoptimiser-frontend
docker save fleetoptimiser-backend:local fleetoptimiser-frontend:local \
  | sudo k3s ctr images import -
```

Chartet bruger `pullPolicy: Never`, så en ny kodeversion kræver, at du bygger
og importerer igen og derefter genstarter pods, fx
`kubectl rollout restart deployment -n fleetoptimiser`.

## 5. Namespaces og secrets

```sh
kubectl create namespace fleetoptimiser
kubectl create namespace keycloak
./deploy/local/create-test-secrets.sh
```

Scriptet genererer tilfældige adgangskoder til PostgreSQL, RabbitMQ, Valkey og
Keycloak og overskriver aldrig eksisterende secrets.

## 6. PostgreSQL, RabbitMQ og Valkey

```sh
helm upgrade --install fleetoptimiser-postgresql \
  oci://registry-1.docker.io/bitnamicharts/postgresql --version 16.7.27 \
  --namespace fleetoptimiser --values deploy/local/postgresql-values.yaml \
  --wait --timeout 10m

helm upgrade --install fleetoptimiser-rabbitmq \
  oci://registry-1.docker.io/bitnamicharts/rabbitmq --version 16.0.14 \
  --namespace fleetoptimiser --values deploy/local/rabbitmq-values.yaml \
  --wait --timeout 10m

helm repo add valkey https://valkey.io/valkey-helm/
helm repo update valkey
helm upgrade --install fleetoptimiser-valkey valkey/valkey --version 0.11.0 \
  --namespace fleetoptimiser --values deploy/local/valkey-values.yaml \
  --wait --timeout 10m
```

PostgreSQL og RabbitMQ bruger arkiverede Bitnami-images (`bitnamilegacy`), som
ikke længere opdateres. De er kun til lokal brug.

## 7. Keycloak

```sh
helm upgrade --install keycloak-postgresql \
  oci://registry-1.docker.io/bitnamicharts/postgresql --version 16.7.27 \
  --namespace keycloak --values deploy/local/keycloak-postgresql-values.yaml \
  --wait --timeout 10m

helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo update codecentric
helm upgrade --install keycloak codecentric/keycloakx --version 2.3.0 \
  --namespace keycloak --values deploy/local/keycloak-values.yaml \
  --wait --timeout 10m
```

Keycloak er eksponeret som NodePort 30080. Både din browser og
frontend-poden skal kunne nå den på **samme** adresse, ellers passer tokenets
issuer ikke. Brug derfor maskinens IP-adresse, ikke `localhost`:

```sh
HOST_IP=$(hostname -I | awk '{print $1}')
echo "http://$HOST_IP:30080/admin"
```

Log ind som `admin`. Adgangskoden står i din egen Secret:

```sh
kubectl get secret keycloak-admin-credentials -n keycloak \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Opret i admin-konsollen:

1. En realm med navnet `fleetoptimiser`.
2. En client i realmen:
   - Client ID: `fleetoptimiser-frontend`
   - Client authentication: slået til. Standard flow: slået til.
   - Valid redirect URIs: `http://localhost:3000/*`
   - Web origins: `http://localhost:3000`
3. Kopiér client secret fra fanen **Credentials** på clienten.
4. En bruger med e-mail og navn, og en adgangskode under **Credentials** med
   **Temporary** slået fra.

## 8. Frontendens login-secret

Frontenden læser Keycloak- og Better Auth-indstillingerne fra én Secret.
Indsæt client secret, når du bliver spurgt; den havner ikke i shell-historikken:

```sh
HOST_IP=$(hostname -I | awk '{print $1}')
read -rsp 'Keycloak client secret: ' KEYCLOAK_CLIENT_SECRET; echo
kubectl create secret generic fleetoptimiser-frontend-auth -n fleetoptimiser \
  --from-literal=keycloak-id=fleetoptimiser-frontend \
  --from-literal=keycloak-secret="$KEYCLOAK_CLIENT_SECRET" \
  --from-literal=keycloak-issuer="http://$HOST_IP:30080/realms/fleetoptimiser" \
  --from-literal=better-auth-secret="$(openssl rand -hex 32)" \
  --from-literal=better-auth-url=http://localhost:3000
unset KEYCLOAK_CLIENT_SECRET
```

## 9. Istio, monitoring og loadtest-jobs

```sh
bash scripts/lab.sh fetch
bash scripts/lab.sh validate
bash scripts/lab.sh preflight
bash scripts/lab.sh deploy
bash scripts/lab.sh verify
```

`deploy` installerer Istio, Prometheus, Grafana, Loki og Alloy samt mesh-demoen
og de suspenderede k6-jobs. `verify` bekræfter, at mTLS og policies virker i
mesh-demoen.

## 10. FleetOptimiser

Første gang med testdata, så der er lokationer, biler og ture at arbejde med:

```sh
bash scripts/lab.sh app --set runtime.seedDummyData=true
```

Senere opgraderinger køres uden `--set`; data ligger i PostgreSQL. Seedingen
springer over, hvis der allerede er data.

Chartet installeres med Istio-sidecars og STRICT mTLS fra
`deploy/local/fleetoptimiser-values.yaml`. Vil du køre uden mesh, så tilføj
`--set mesh.enabled=false`.

## 11. Kontrollér og log ind

```sh
bash scripts/lab.sh verify-app
bash scripts/lab.sh frontend
```

`verify-app` kontrollerer sidecars, STRICT mTLS og at kun de tilladte
identiteter kan kalde backend og frontend. `frontend` åbner en port-forward;
gå til <http://localhost:3000> og log ind med brugeren fra trin 7.

## 12. Loadtest og monitoring

```sh
bash scripts/lab.sh run baseline    # også: 2x, 5x, 10x, soak
bash scripts/lab.sh grafana         # http://localhost:3030
bash scripts/lab.sh prometheus      # http://localhost:9090
```

Grafanas admin-adgangskode ligger i Secret `lab-monitoring-grafana` (felt
`admin-password`) i `monitoring`. Dashboardet hedder
`FleetOptimiser workload test`. Se [`README.md`](README.md) for
testprofiler, målinger og begrænsninger.

## Fejlfinding

| Symptom | Årsag og løsning |
|---|---|
| Pod står i `ErrImageNeverPull` | Imaget er ikke importeret i k3s. Gentag trin 4. |
| Backend genstarter med `Database configuration is required` | Chartets DB-værdier eller `fleetoptimiser-postgresql-auth` mangler. |
| `lab.sh` siger `Cluster UID differs` | k3s er geninstalleret. Slet `config/local.env` og kør `init` igen. |
| `app` fejler med `no matches for kind PeerAuthentication` | Istio er ikke installeret. Kør trin 9 før trin 10. |
| Login fejler eller hænger efter redirect | Keycloak-adressen i `fleetoptimiser-frontend-auth` skal være maskinens IP, ikke `localhost`. På WSL2 skifter IP'en ved genstart; opret secret'en igen og kør `kubectl rollout restart deployment/fleetoptimiser-frontend -n fleetoptimiser`. |
| Keycloak siger `Invalid redirect uri` | Redirect URI på clienten skal være `http://localhost:3000/*`. |

## Oprydning

Fjern appen: `helm uninstall fleetoptimiser -n fleetoptimiser`. Fjern alt,
inklusive data og selve k3s: `/usr/local/bin/k3s-uninstall.sh`.
