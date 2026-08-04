# Module 05 — Orchestration Airflow (3.1.5)

## Objectifs

- Comprendre ce qu'un orchestrateur apporte que `dbt` seul n'a pas.
- Monter une stack Airflow **3.1.5** minimale via Docker Compose.
- Comprendre l'architecture Airflow >= 3.0 (api-server / dag-processor / scheduler) — un changement majeur vs. 2.x.

## Ce que dbt NE fait PAS

dbt sait CE QU'IL FAUT FAIRE et DANS QUEL ORDRE (le DAG de modeles).
Il ne sait PAS **QUAND** lancer un run, **QUOI FAIRE si ca echoue**
(retry, alerte), ni **COMMENT** ca s'articule avec le reste de la
plateforme. C'est le role d'un orchestrateur — Airflow ici.

## Airflow >= 3.0 : une architecture repensee

Ce bootcamp utilise **Airflow 3.1.5**, pas 2.x — un choix delibere
pour rester a jour avec la version que l'ecosysteme adopte
actuellement. Si vous avez deja utilise Airflow 2.x, plusieurs
changements structurels comptent :

| | Airflow 2.x | Airflow 3.x |
|---|---|---|
| Interface web | `airflow webserver` (Flask/UI classique) | `airflow api-server` (FastAPI + UI React) |
| Parsing des DAGs | Fait par le scheduler (ou optionnellement separe) | **Toujours** un processus a part : `airflow dag-processor` |
| Communication taches <-> metadonnees | Acces direct a la base de donnees | API HTTP interne ("Task Execution API"), authentifiee par JWT |

[`docker-compose.yaml`](../airflow/docker-compose.yaml) reflete cette
architecture : `postgres` (metadonnees), `airflow-dag-processor`,
`airflow-apiserver`, `airflow-scheduler`, tous batis depuis la meme
image ([`Dockerfile`](../airflow/Dockerfile)), avec `LocalExecutor`
(sous-processus locaux — pas de Celery/Redis, volontairement, pour
rester simple a comprendre).

## Pourquoi dbt vit dans un venv SEPARE de celui d'Airflow

```dockerfile
FROM apache/airflow:3.1.5-python3.12

RUN pip install --no-cache-dir \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-3.1.5/constraints-3.12.txt" \
    "astronomer-cosmos==1.15.*"

RUN python -m venv /home/airflow/dbt_venv && \
    /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-duckdb==1.10.*"
```

**Deux pieges reels, dans l'ordre ou on les a rencontres en
construisant cette image :**

1. `pip install astronomer-cosmos[dbt-duckdb]` SANS `--constraint`
   fait exploser le resolveur de pip contre l'immense arbre de
   dependances deja installe par l'image de base
   (`ResolutionTooDeep: 200000`). Le fichier de contraintes officiel
   d'Airflow fige les versions deja connues-compatibles ; sans lui,
   pip explore un espace combinatoire ingerable.
2. Meme AVEC le fichier de contraintes, installer `dbt-duckdb`
   DIRECTEMENT dans l'environnement Airflow echoue quand meme
   (`ResolutionImpossible`, `protobuf==4.25.6` exige par les
   contraintes Airflow vs. une version differente requise par la
   chaine de dependances de dbt). **dbt-core et Airflow ne doivent
   jamais partager le meme environnement Python** — c'est le pattern
   officiellement recommande par Astronomer. La solution : un second
   venv, `/home/airflow/dbt_venv`, completement isole, ou dbt installe
   ses propres dependances sans jamais toucher a celles d'Airflow.

## Demarrer la stack

```bash
cd bootcamp-2-scale-orchestration/airflow
docker compose build
docker compose up -d postgres
docker compose run --rm airflow-init      # db migrate + cree le pool duckdb_pool (module 06)
docker compose up -d airflow-dag-processor airflow-scheduler airflow-apiserver
```

UI sur http://localhost:8080. Port Postgres (5433) distinct du
premier bootcamp (5432) : les deux stacks Docker peuvent tourner en
parallele sans conflit.

### Se connecter a l'UI : pas de `airflow users create` en 3.x

Contrairement a Airflow 2.x, il n'y a plus de commande
`airflow users create` (la liste des groupes CLI ne contient meme
plus de groupe `users` — verifiez avec `airflow --help`). Par defaut,
Airflow 3.x utilise le **`SimpleAuthManager`** : au tout premier
demarrage de l'api-server, il genere lui-meme un utilisateur `admin`
avec un mot de passe aleatoire, ecrit dans les logs ET dans
`/opt/airflow/simple_auth_manager_passwords.json.generated` (dans le
conteneur) :

```bash
docker logs nyc_taxi_airflow_apiserver 2>&1 | grep "Password for user"
# Simple auth manager | Password for user 'admin': <mot-de-passe>
```

Ce mot de passe **change a chaque recreation** du conteneur
`airflow-apiserver` (`--force-recreate`, ou volume de logs efface) —
si l'ancien ne fonctionne plus, relancez la commande ci-dessus pour
en recuperer un nouveau. En production, on remplace `SimpleAuthManager`
par le `FabAuthManager` (RBAC complet, LDAP/OAuth...) via
`AIRFLOW__CORE__AUTH_MANAGER` — hors scope de ce bootcamp, qui reste
volontairement sur l'option la plus simple pour se concentrer sur
dbt+Cosmos.

## Deux options de configuration INDISPENSABLES en multi-conteneurs

Sans elles, la stack demarre... et chaque tache echoue au premier
run, silencieusement cote UI (juste "failed", sans indice evident).
Les deux ont ete decouvertes en debuggant ce echec en conditions
reelles :

```yaml
# docker-compose.yaml, environment commun a tous les services Airflow
AIRFLOW__CORE__EXECUTION_API_SERVER_URL: http://airflow-apiserver:8080/execution/
AIRFLOW__API_AUTH__JWT_SECRET: ${AIRFLOW_JWT_SECRET:-local-dev-only-change-me}
```

Generez votre cle une fois, dans le `.env` a cote du compose :

```bash
echo "AIRFLOW_JWT_SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')" >> .env
```

- **`EXECUTION_API_SERVER_URL`** : en Airflow 3.x, chaque tache (executee
  par le scheduler) appelle l'api-server via HTTP pour rapporter son
  etat — ce n'est PAS un acces direct a la base. Sans cette URL
  explicite, la tache essaie `http://localhost:...` (le conteneur DU
  SCHEDULER, ou rien n'ecoute) et echoue avec
  `httpx.ConnectError: [Errno 111] Connection refused`.
- **`JWT_SECRET`** : les appels a l'Execution API sont authentifies par
  un jeton JWT, signe par le scheduler et verifie par l'api-server.
  **Sans valeur explicite, CHAQUE conteneur genere sa PROPRE cle
  aleatoire au demarrage** — le scheduler signe avec une cle, l'api-
  server verifie avec une autre : `Invalid auth token: Signature
  verification failed`, systematiquement, sur la toute premiere tache.
  Cette valeur doit etre **identique** sur tous les services — d'ou
  le fait de la definir une seule fois dans le bloc `environment`
  commun, et non service par service.

  **Ne la codez jamais en dur dans le compose.** Ce fichier est
  commite ; une cle de signature ecrite dedans est un secret publie
  (ce depot est public, et les bots scannent GitHub en continu). Le
  `${AIRFLOW_JWT_SECRET:-...}` ci-dessus lit la vraie valeur depuis
  l'environnement et ne laisse dans git qu'un fallback inoffensif,
  explicitement nomme pour qu'on ne le confonde pas avec une vraie
  cle. C'est la meme discipline que le `.env` + `env_var()` du
  [bootcamp 1](../../bootcamp/00-setup/README.md), appliquee a un
  autre outil.

## `AIRFLOW__CORE__DAGBAG_IMPORT_TIMEOUT` : le piege du parsing lent

Troisieme probleme rencontre : le DAG
([`nyc_taxi_dbt_dag.py`](../airflow/dags/nyc_taxi_dbt_dag.py), module 06)
n'apparaissait JAMAIS dans l'UI — ni erreur, ni DAG. Cause : Cosmos
invoque `dbt ls` en sous-processus pour construire le DAG a partir du
projet dbt, ce qui prend ~30-50 secondes ici (largement au-dela du
timeout par defaut de 30s pour parser un fichier de DAG). Le
dag-processor tuait le parsing en cours de route, sans jamais rien
logger d'exploitable dans l'UI (juste `# DAGs: 0, # Errors: 0` — un
silence trompeur).

```yaml
AIRFLOW__CORE__DAGBAG_IMPORT_TIMEOUT: '300'
```

## Exercice

`docker-compose.yaml` ne configure aucune limite de ressources.
Ajoutez `deploy.resources.limits` sur `airflow-scheduler` (1 CPU,
512 Mo) pour eviter qu'un DAG mal ecrit ne consomme toute votre
machine.

### Solution

```yaml
  airflow-scheduler:
    <<: *airflow-common
    container_name: nyc_taxi_airflow_scheduler
    command: scheduler
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
    depends_on:
      airflow-init:
        condition: service_completed_successfully
```

Verifiez avec `docker stats nyc_taxi_airflow_scheduler` que la limite
est bien respectee — `docker compose` applique nativement
`deploy.resources.limits`, pas seulement en mode Swarm.

## Suite

→ [Module 06 — astronomer-cosmos](../06-astronomer-cosmos/README.md)
