# Module 06 — astronomer-cosmos : dbt comme DAG Airflow natif

## Objectifs

- Transformer un projet dbt en taches Airflow individuelles (pas une seule tache monolithique).
- Comprendre `ProjectConfig`, `ProfileConfig`, `ExecutionConfig`, `RenderConfig`.
- Savoir diagnostiquer les incompatibilites de version Cosmos/Airflow.
- Comprendre et resoudre le conflit d'acces concurrent a DuckDB.

## Pourquoi pas juste une tache `BashOperator` qui lance `dbt build` ?

Ca marcherait, mais vous perdriez tout ce qui fait l'interet
d'Airflow : granularite (voir QUEL modele a echoue, pas juste "dbt a
plante"), parallelisation automatique du DAG dbt independamment du
DAG Airflow global, retry PAR MODELE, alerting cible. Cosmos convertit
le DAG dbt en un sous-graphe de vraies taches Airflow — chaque
`model.run`, `model.test`, `seed.seed` devient un noeud individuel
dans l'UI Airflow.

## Le DAG de ce projet

[`dags/nyc_taxi_dbt_dag.py`](../airflow/dags/nyc_taxi_dbt_dag.py) :

```python
from cosmos import DbtDag, ExecutionConfig, ProfileConfig, ProjectConfig, RenderConfig

profile_config = ProfileConfig(
    profile_name="nyc_taxi_dbt",
    target_name="dev",
    profiles_yml_filepath=PROJECT_DIR / "profiles.yml",
)

execution_config = ExecutionConfig(
    dbt_executable_path="/home/airflow/dbt_venv/bin/dbt",
)

render_config = RenderConfig(emit_datasets=False)

nyc_taxi_dbt_dag = DbtDag(
    dag_id="nyc_taxi_dbt",
    project_config=ProjectConfig(str(PROJECT_DIR), install_dbt_deps=False),
    profile_config=profile_config,
    execution_config=execution_config,
    render_config=render_config,
    schedule="@monthly",
    start_date=datetime(2019, 1, 1),
    catchup=False,
    default_args={"retries": 5, "retry_delay": timedelta(seconds=20)},
    operator_args={"pool": "duckdb_pool"},
)
```

- **`ProfileConfig`** : ou trouver le `profiles.yml` (module 00 —
  celui du projet, commite, sans secret : DuckDB).
- **`ExecutionConfig.dbt_executable_path`** : pointe explicitement
  vers le venv ISOLE de dbt (module 05) — sans ca, Cosmos cherche
  `dbt` dans le PATH de l'environnement Airflow, ou il n'existe pas.
- **`ProjectConfig(install_dbt_deps=False)`** : `dbt_packages/` existe
  deja (genere cote hote) — inutile de refaire cet appel reseau a
  chaque parsing du DAG.
- **`RenderConfig(emit_datasets=False)`** : desactive la creation
  automatique d'un objet `Dataset` Airflow par modele dbt (utilise
  pour le scheduling inter-DAG "data-aware"). Pas necessaire ici
  (schedule simple), et ca evite un bug ORM rencontre sur une version
  anterieure d'Airflow lors de nos tests (`Can't flush None value
  found in collection DatasetModel.aliases`).

## Piege n°1 : Cosmos et Airflow n'avancent pas toujours au meme rythme

Premiere tentative avec `astronomer-cosmos==1.9.*` (une version encore
recente a l'epoque) sur Airflow 3.1.5 :

```
ImportError: cannot import name 'context_to_airflow_vars' from
'airflow.utils.operator_helpers'
```

Cosmos 1.9 a ete ecrit contre l'API interne d'Airflow 2.x ; cette
fonction n'existe plus en Airflow 3. **Lecon generale sur les
integrations tierces avec un framework qui evolue vite** : une version
"recente il y a quelques mois" n'est pas garantie compatible avec la
toute derniere version majeure du framework hote. Correctif : monter
a `astronomer-cosmos==1.15.*` (la derniere disponible au moment de
construire ce bootcamp), qui supporte Airflow 3 nativement. Verifiez
toujours la matrice de compatibilite officielle avant de figer une
version dans un `Dockerfile`.

## Piege n°2 : DuckDB et l'execution parallele ne font pas bon menage

Une fois le DAG visible et les taches lancees, echec systematique et
aleatoire :

```
_duckdb.IOException: IO Error: Could not set lock on file "nyc_taxi.duckdb"
```

**Cause** : `taxi_zone_lookup.seed` et `stg_trips.run` n'ont AUCUNE
dependance entre eux dans le DAG dbt (l'un charge un seed, l'autre
transforme une source — rien ne les relie). Cosmos les traduit donc en
deux taches Airflow SANS dependance, qu'Airflow lance en parallele
avec `LocalExecutor`. Chacune ouvre sa PROPRE connexion DuckDB au
MEME fichier — et DuckDB, contrairement a Postgres, **n'autorise
qu'un seul processus ecrivain a la fois** sur un fichier donne.

**La solution : un Pool Airflow dedie, 1 seul slot** :

```yaml
# airflow-init, dans docker-compose.yaml
airflow pools set duckdb_pool 1 "DuckDB : un seul ecrivain a la fois sur nyc_taxi.duckdb"
```

```python
# nyc_taxi_dbt_dag.py
operator_args={"pool": "duckdb_pool"},
```

Un pool avec `slots=1` force Airflow a n'executer QU'UNE tache de ce
pool a la fois, quelle que soit la forme du DAG — exactement
l'inverse de la parallelisation qu'on cherche d'habitude, mais
necessaire ici a cause d'une contrainte du MOTEUR de donnees, pas
d'une contrainte logique du DAG. **Une regle a retenir pour tout
projet DuckDB + orchestrateur : un seul pipeline peut ecrire dans le
fichier a un instant T.** Sur Postgres/Snowflake/BigQuery (multi-
ecrivain natif), ce probleme n'existe pas — c'est une consideration
SPECIFIQUE aux entrepots embarques a fichier unique.

Meme avec le pool, une collision residuelle rare persistait : le
`dag-processor` re-analyse periodiquement le fichier de DAG en
arriere-plan (donc re-invoque `dbt ls`, qui ouvre lui aussi une
connexion DuckDB) **independamment de l'executor** — le pool ne
couvre que les TACHES, pas cette activite de fond. Des `retries`
genereux (`retries=5, retry_delay=20s`) absorbent cette contention
residuelle. La solution definitive, pour un vrai projet en
production : passer Cosmos en `RenderConfig(load_method=LoadMode.DBT_MANIFEST)`
avec un `manifest.json` pre-genere (`dbt parse` cote CI, artifact
publie) — le dag-processor lit alors un fichier JSON statique pour
construire le DAG, sans jamais ouvrir de connexion a l'entrepot. Ca
resout AUSSI le probleme de lenteur de parsing du module 05
(`DAGBAG_IMPORT_TIMEOUT`) : lire un JSON est quasi instantane compare
a l'invocation d'un sous-processus `dbt ls`.

## Le run complet, valide

```bash
docker compose exec postgres psql -U airflow -d airflow -c \
  "update dag set is_paused=false where dag_id='nyc_taxi_dbt';"
docker compose run --rm --no-deps --entrypoint airflow airflow-apiserver \
  dags trigger nyc_taxi_dbt
```

Resultat mesure, apres application des correctifs ci-dessus : **8/8
taches en succes** (`taxi_zone_lookup.seed/.test`,
`stg_trips.run/.test`, `stg_zones.run/.test`, `fct_trips.run/.test`),
DAG run au statut `success`. Verification finale, directement sur le
fichier DuckDB produit par Airflow :

```
fct_trips: 31 999 998 lignes
taxi_zone_lookup: 50 lignes
```

Le pipeline complet — ingestion, staging, faits, tests — orchestre
par un vrai scheduler, sur 32 millions de lignes.

## Exercice

Le pool `duckdb_pool` serialise TOUTES les taches dbt, y compris
celles qui pourraient legitimement tourner en parallele sur un autre
entrepot (ex: `stg_trips.test` et `stg_zones.test`, deux tests
independants). Sur un vrai warehouse multi-ecrivain (Postgres,
Snowflake...), quelle modification apporteriez-vous au DAG pour
retrouver la parallelisation, tout en gardant le meme code dbt ?

### Solution

Retirer `operator_args={"pool": "duckdb_pool"}` (et la creation du
pool dans `airflow-init`) suffit : la contrainte "un seul ecrivain"
est une propriete de DUCKDB, pas de Cosmos ni du DAG dbt lui-meme.
En changeant uniquement `profiles.yml` (`type: postgres` au lieu de
`type: duckdb`, comme dans le premier bootcamp) et en retirant le
pool, EXACTEMENT le meme DAG genere par Cosmos retrouverait sa
parallelisation naturelle — la preuve que la contrainte etait bien
au niveau infrastructure (le moteur de stockage), jamais encodee dans
la logique metier du projet dbt.

## Suite

→ [Module 07 — Projet capstone](../07-projet-capstone/README.md)
