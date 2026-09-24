# FleetOptimiser Kubernetes-lab

Lokal platform til at afprøve service mesh og monitoring, før konfigurationen
eventuelt overføres til det fælles `infra`-repo. Projektet er selvstændigt og
bruger versionsfastlåste upstream Helm-charts. Det kræver Bash, Helm 3 og kubectl;
telemetry-kontrollen bruger desuden Python 3 fra standardbiblioteket.

## Første leverance

```text
Lokalt k3s (node: simon)
├── fleetoptimiser       eksisterende app, PostgreSQL, RabbitMQ og Valkey
├── keycloak             eksisterende login
├── istio-system         Istiod + Istio CRDs
├── monitoring           Prometheus, Grafana, Loki, Alloy og exporters
├── fleetoptimiser-lab    echo-service, mesh-klient og klient uden mesh
└── fleetoptimiser-loadtest  k6-baserede, manuelt aktiverede loadtest-jobs
```

## Aktuel lokal status

Labbet er installeret i det lokale k3s-cluster. Istio, Prometheus, Grafana,
Loki og Alloy er `Running`. FleetOptimiser backend og frontend kører med
Istio-sidecars (`2/2` pods), mens worker, PostgreSQL, RabbitMQ og Valkey endnu
ikke er injiceret.

Følgende checks er gennemført:

- mTLS GET fra en mesh-klient til echo-servicen lykkes
- plaintext fra en klient uden mesh bliver afvist
- POST til echo-servicen bliver afvist af en AuthorizationPolicy
- backendens `/healthz` svarer `{"status":"ok"}` fra mesh-klienten
- frontendens service svarer med login-redirect fra mesh-klienten
- Prometheus indeholder Istio mTLS-metrics
- Loki indeholder logs leveret af Alloy

Namespace-labelen `fleetoptimiser-lab/mesh=enabled` er sat på det eksisterende
`fleetoptimiser` namespace som markering. `values/istiod.yaml` har ingen
discovery selectors, så labelen styrer ikke Istio.
Kun backend og frontend har eksplicitte injection-annotations og revision-labels.

Labbet aktiverer sidecar injection i `fleetoptimiser-lab`, og FleetOptimisers
backend/frontend kan tilkobles med eksplicitte pod-annotations. En STRICT mTLS-politik
kræver krypteret trafik, og en AuthorizationPolicy tillader kun GET fra
`mesh-client` til echo-servicen. Det gør mesh'et målbart, før applikationen kobles
på. FleetOptimisers backend/frontend kobles på med eksplicitte pod-annotations,
mens worker og database-/køservices forbliver uden sidecars indtil deres trafik
er testet.

Traefik fortsætter som eksisterende ingress. Første version tilføjer ingen
gateway, offentlige domæner, DNS-ændringer, Vault eller Roboref-konfiguration.
Grafana og Prometheus tilgås med lokal port-forward.

## Brug

Kommandoerne kontrollerer den dedikerede kubeconfig, API-adressen
`https://127.0.0.1:6443` og det konkrete clusters UID. En anden aktiv KUBECONFIG
afvises. Identiteten ligger i `config/local.env`, uden credentials.

```bash
cd /home/simon/projects/fleetoptimiser-k8s-lab
export KUBECONFIG=/home/simon/projects/.kubeconfigs/fleetoptimiser-k3s.yaml
bash scripts/lab.sh fetch
bash scripts/lab.sh validate
bash scripts/lab.sh preflight
bash scripts/lab.sh deploy
bash scripts/lab.sh verify
bash scripts/lab.sh telemetry
```

Kør loadtestene sekventielt. Hvert job er suspenderet ved installation, så en
test starter først, når den eksplicit aktiveres:

```bash
bash scripts/lab.sh run baseline
bash scripts/lab.sh run 2x
bash scripts/lab.sh run 5x
bash scripts/lab.sh run 10x
bash scripts/lab.sh run soak
```

Baseline-jobbet kører med 5 virtuelle brugere i to minutter. 2x, 5x og 10x
svarer til henholdsvis 10, 25 og 50 virtuelle brugere i to minutter. Soak-testen
kører med 25 virtuelle brugere i 30 minutter for at afsløre langsom vækst i
hukommelsesforbrug, udtømte forbindelsespuljer og ustabile pods. Simulatoren kalder
read-only endpoints for health, konfiguration, statistik, lokationer, simulationer
og workshops. `/readyz` udfører `SELECT 1` mod PostgreSQL.
Den opretter eller ændrer ingen FleetOptimiser-data.

Den første udvidede read-only-test viste timeouts ved 10x og en backend-restart.
Efter en moderat større databasepool og ændring af de relevante synkrone
read-only endpoints til FastAPI's threadpool gennemførte 10x 22.884 requests
med 0 fejl, ca. 239 ms p95 på `readyz` og 0 backend-restarts.

Den komplette serie blev gentaget den 14. september 2026 efter Grafana-stabiliseringen.
De faktiske resultater var:

| Niveau | VUs | Requests | Fejl | Samlet p95 | `readyz` p95 |
|---|---:|---:|---:|---:|---:|
| Baseline | 5 | 8.640 | 0 % | 63,5 ms | 58,1 ms |
| 2x | 10 | 17.160 | 0 % | 64,0 ms | 53,6 ms |
| 5x | 25 | 24.924 | 0 % | 191,9 ms | 117,9 ms |
| 10x | 50 | 24.252 | 0 % | 503,8 ms | 275,8 ms |

Alle fire jobs gennemførte uden afbrudte iterationer. Ved 10x nåede den lokale
backend cirka 1 CPU-kerne, og request-raten fladede ud omkring 200 requests/s.
Det viser et kapacitetsplateau på den lokale maskine, men ingen fejl.

En 30-minutters soak-test blev derefter kørt med 25 VUs:

| Test | Varighed | Iterationer | Requests | Fejl | Samlet p95 | `readyz` p95 |
|---|---:|---:|---:|---:|---:|---:|
| Soak | 30 min | 26.982 | 323.784 | 0 % | 276 ms | 153 ms |

Backend, PostgreSQL, loadtest-pod og Grafana fik ingen nye restarts eller
OOMKilled-hændelser under soak-testen. Backend-memory lå efter testen omkring
349 MiB og faldt tilbage efter belastningen.

`baseline` er indtil videre en teknisk referenceprofil på 5 VUs. Den svarer ikke
nødvendigvis til den faktiske produktionsbelastning. For at kunne kalde profilerne
1x, 2x, 5x og 10x i produktionsmæssig forstand skal den nuværende produktion måles
og dokumenteres først.

Ingen backend- eller loadtest-pods blev genstartet under serien.

Den aktive deployment er Helm revision 6 med image-tagget `async-test`.
Revision 5 med `pool-test` kan bruges til rollback:

```bash
helm rollback fleetoptimiser 5 \
  --namespace fleetoptimiser \
  --kubeconfig /home/simon/projects/.kubeconfigs/fleetoptimiser-k3s.yaml
```

`fetch` henter fastlåste chart-versioner. `validate` linter og renderer lokalt;
den ændrer ikke clusteret. `deploy` installerer de fem releases i
`config/charts.tsv` i rækkefølge og derefter mesh-demoen. Der er ingen automatisk
sletning eller overtagelse af eksisterende namespaces. En afbrudt installation
kan fortsættes med samme kommando; se først `status` ved fejl.

Helm opdaterer ikke automatisk alle CRDs ved senere chart-opgraderinger.
Versionsændringer kræver derfor en separat gennemgang af upstreams upgrade-guide.

```bash
bash scripts/lab.sh grafana       # http://localhost:3000
bash scripts/lab.sh prometheus    # http://localhost:9090
bash scripts/lab.sh status
```

Grafana bruger chartets genererede admin-password. Ejeren kan hente det lokalt
fra Secret `lab-monitoring-grafana` (felt `admin-password`) i `monitoring` og
logge ind som `admin`. Credentials skal ikke kopieres til dokumentation eller chat.

## Forberedt, ikke deployet: FleetOptimiser med STRICT mTLS

Den kørende deployment (Helm revision 6) har sidecars på backend og frontend,
men ingen PeerAuthentication eller AuthorizationPolicy i `fleetoptimiser`.
mTLS er derfor kun PERMISSIVE, og loadtestene ovenfor ramte backend i
plaintext fra et namespace uden mesh.

Næste version er forberedt i filerne, men ikke installeret:

- Chart 0.2.0 i `OS2fleetoptimiser/charts/fleetoptimiser` giver hver komponent
  sin egen ServiceAccount og kan slå mesh, PeerAuthentication,
  AuthorizationPolicies og en Gateway API HTTPRoute til via values.
- `OS2fleetoptimiser/deploy/local/fleetoptimiser-values.yaml` slår mesh til for
  backend, frontend og worker med STRICT mTLS. Backend accepterer kun kald fra
  frontend, `mesh-client` og k6; frontend kun fra `mesh-client`.
- `manifests/loadtest.yaml` kører k6 med sidecar som ServiceAccount `k6`, så
  loadtesten går gennem mTLS og AuthorizationPolicy.
- `bash scripts/lab.sh verify-app` kontrollerer sidecars på alle tre
  komponenter, STRICT mTLS, tilladte kald til backend og frontend og at
  plaintext og workeren bliver afvist.

Når det skal i brug, køres i rækkefølge:

```bash
cd /home/simon/projects/OS2fleetoptimiser
helm upgrade fleetoptimiser charts/fleetoptimiser \
  --namespace fleetoptimiser \
  --values deploy/local/fleetoptimiser-values.yaml \
  --kubeconfig /home/simon/projects/.kubeconfigs/fleetoptimiser-k3s.yaml \
  --wait --timeout 10m
cd /home/simon/projects/fleetoptimiser-k8s-lab
bash scripts/lab.sh deploy
bash scripts/lab.sh verify-app
bash scripts/lab.sh run baseline
```

Opgraderingen genstarter alle tre FleetOptimiser-pods, fordi de får nye
ServiceAccounts, og workeren får en sidecar. Job-templates kan ikke ændres, så
findes der gamle loadtest-jobs, når `deploy` køres, skal de slettes først. De
nye loadtest-resultater inkluderer mTLS og er ikke direkte sammenlignelige med
tallene ovenfor. Rollback til den nuværende version:
`helm rollback fleetoptimiser 6 --namespace fleetoptimiser`.

Efter `verify-app` mangler stadig de manuelle dele af testplanen: login via
Keycloak, et Celery-job gennem worker, RabbitMQ og Valkey, en rolling update
under et langt job og afbrydelse af en simulation.

## Hvad måles?

Prometheus indsamler Kubernetes-metrics og sidecar-metrics via `lab-envoy` og
`fleetoptimiser-envoy` PodMonitors. k6 sender
sine testmetrics til Prometheus' remote-write endpoint. Grafana-dashboardet
`FleetOptimiser workload test` samler loadtest, mesh, pods og node i én visning.
Grafana har Kubernetes-dashboards og Loki-datakilden. Alloy læser
pod-logs gennem Kubernetes-API'et med én collector; det kræver ingen hostPath.
Logs begrænses til FleetOptimiser, labbet, Istio og monitoring.

Eksempler til Prometheus/Grafana Explore efter `verify`:

```promql
sum by (connection_security_policy) (istio_requests_total{destination_service_namespace="fleetoptimiser-lab"})
sum by (pod) (container_memory_working_set_bytes{namespace="fleetoptimiser",container!="",container!="POD"})
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="fleetoptimiser"}[1h]))
kube_pod_container_status_last_terminated_reason{namespace="fleetoptimiser",reason="OOMKilled"}
```

Loki-query: `{namespace="fleetoptimiser-lab"}`. Vent op til et minut på scrape og
loglevering. Database-/kømetrics er endnu ikke inkluderet; de lokale database-
chartsenes exporters er slået fra og kræver et separat, kontrolleret upgrade.

## Lokale begrænsninger og senere integration

Dette er ét cluster med én node. Namespaces adskiller ressourcer logisk, men
Istio-webhooks, CRDs, CPU, hukommelse og disk er fælles. Projektmappen alene giver
ikke cluster-isolation. Flere virtuelle noder på samme maskine giver heller ikke
beskyttelse mod tab af maskinen.

Prometheus beholder op til to døgn metrics og ca. 3 GB blokdata på en 5 GiB PVC.
Loki beholder ca. to døgn logs på en 5 GiB lokal PVC; tidsbaseret retention er
ikke en hård diskgrænse. Grafana får 1 GiB. Alt bruger `local-path`, uden HA eller
backup. Ressourcegrænserne er begyndelsesværdier til labbet og skal måles under
belastning. Loki har ingen egen autentifikation i denne lokale profil.

Næste trin er at gennemgå FleetOptimisers trafikveje, teste login, API og Celery
og derefter beslutte, om worker, database og køer også skal have sidecars. En
namespace-label alene aktiverer ikke injection her; pod-annotations og revision-
labels bestemmer, hvilke FleetOptimiser-workloads der kobles på.

Derefter tilføjes workload-simulatoren med repræsentative testdata, realistiske
beregningsjobs og aftalte målegrænser. Den lille echo-demo er en mesh-smoketest,
ikke en belastningstest af FleetOptimiser.

Ved overførsel til `infra` kan `values/*.yaml` indlæses i Kubenix-modulernes
`kubernetes.helm.releases.<navn>.values`, mens namespace-, policy- og
PodMonitor-manifester omsættes til platformens ressourcer. Afstem ejerskab af de
fælles releases: en fælles platform skal genbruge eksisterende Istio/monitoring,
ikke installere et parallelt lab. Lokale storage-, adgangs- og clusterindstillinger
skal erstattes med målmiljøets valg.

## Kilder og versionsvalg

- [Istio Helm-installation](https://istio.io/latest/docs/setup/install/helm/)
- [Istio understøttede versioner](https://istio.io/latest/docs/releases/supported-releases/):
  1.31 understøtter Kubernetes 1.36; reference-repoets 1.29 gør det ikke officielt.
- [Loki monolithic installation](https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/)
- [Alloy API-baseret logindsamling](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes/)

Monitoring-chartversionerne tager udgangspunkt i det eksisterende `infra`-repo.
Filerne i det repo er kun brugt som reference; labbet henter selv sine charts.
