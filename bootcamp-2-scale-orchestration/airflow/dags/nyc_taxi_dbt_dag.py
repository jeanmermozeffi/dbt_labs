"""
Transforme le projet dbt nyc_taxi_dbt en DAG Airflow natif via
astronomer-cosmos : chaque modele/test/seed dbt devient une tache
Airflow individuelle, avec les dependances du DAG dbt automatiquement
traduites en dependances de taches Airflow. Voir bootcamp-2.../06-astronomer-cosmos.
"""
import os
from datetime import datetime, timedelta
from pathlib import Path

from cosmos import DbtDag, ExecutionConfig, ProfileConfig, ProjectConfig, RenderConfig

PROJECT_DIR = Path(os.environ.get("DBT_PROJECT_DIR", "/opt/airflow/nyc_taxi_dbt"))

profile_config = ProfileConfig(
    profile_name="nyc_taxi_dbt",
    target_name="dev",
    profiles_yml_filepath=PROJECT_DIR / "profiles.yml",
)

# dbt vit dans un venv ISOLE de celui d'Airflow (voir Dockerfile) :
# on pointe explicitement dessus plutot que de laisser Cosmos chercher
# `dbt` dans le PATH de l'environnement Airflow (ou il n'existe pas).
execution_config = ExecutionConfig(
    dbt_executable_path="/home/airflow/dbt_venv/bin/dbt",
)

# emit_datasets=False : Cosmos cree par defaut un "Dataset" Airflow par
# modele dbt (pour le scheduling inter-DAG data-aware). On n'en a pas
# besoin ici (schedule simple @monthly) et ca declenche un bug ORM
# connu d'Airflow 2.10.x (`Can't flush None value found in collection
# DatasetModel.aliases`, rencontre avec `airflow dags test` en
# construisant ce bootcamp -- voir module 06).
render_config = RenderConfig(emit_datasets=False)

nyc_taxi_dbt_dag = DbtDag(
    dag_id="nyc_taxi_dbt",
    # install_dbt_deps=False : dbt_packages/ existe deja (dbt deps a
    # tourne cote hote, monte via le meme volume) -- inutile de
    # refaire cet appel reseau a chaque parsing du DAG.
    project_config=ProjectConfig(str(PROJECT_DIR), install_dbt_deps=False),
    profile_config=profile_config,
    execution_config=execution_config,
    render_config=render_config,
    schedule="@monthly",
    start_date=datetime(2019, 1, 1),
    catchup=False,
    # DuckDB est un fichier local a UN SEUL ecrivain a la fois. Deux
    # taches dbt independantes (ex: taxi_zone_lookup.seed et
    # stg_trips.run, qui n'ont aucune dependance entre elles dans le
    # DAG dbt) lancees en parallele par Airflow se disputent le meme
    # fichier .duckdb et l'une des deux echoue avec
    # `IO Error: Could not set lock on file` (rencontre en construisant
    # ce bootcamp). Le pool `duckdb_pool` (1 slot, cree dans
    # airflow-init, voir docker-compose.yaml) force l'execution
    # sequentielle de toutes les taches dbt entre elles.
    #
    # Meme avec le pool, une collision residuelle reste possible : le
    # dag-processor re-analyse periodiquement le fichier de DAG (donc
    # re-invoque `dbt ls` via Cosmos) INDEPENDAMMENT de l'executor, et
    # peut ouvrir sa propre connexion DuckDB pile pendant qu'une tache
    # tourne. `retries` genereux + `retry_delay` court absorbent cette
    # contention transitoire plutot que de la faire disparaitre
    # totalement -- solution definitive : passer a `LoadMode.DBT_MANIFEST`
    # (Cosmos lit un manifest.json pre-genere, sans jamais se
    # connecter a l'entrepot pour parser le DAG). Voir bootcamp-2.../06-astronomer-cosmos.
    default_args={"retries": 5, "retry_delay": timedelta(seconds=20)},
    operator_args={"pool": "duckdb_pool"},
)
