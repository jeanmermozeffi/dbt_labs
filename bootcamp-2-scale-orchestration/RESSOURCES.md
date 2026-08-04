# Ressources (complement au bootcamp 1)

## DuckDB

- [duckdb.org/docs](https://duckdb.org/docs/) — reference complete.
- [dbt-duckdb](https://github.com/duckdb/dbt-duckdb) — adapter dbt, y compris `external_location`, `secrets`, `plugins`.
- [DuckDB httpfs extension](https://duckdb.org/docs/extensions/httpfs/overview) — lecture S3/GCS/HTTPS.

## Donnees NYC TLC (le vrai jeu de donnees derriere ce bootcamp)

- [Page officielle NYC TLC Trip Record Data](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page)
- [Dictionnaire des colonnes (PDF officiel)](https://www.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_yellow.pdf)

## Incremental / microbatch

- [dbt docs — Microbatch](https://docs.getdbt.com/docs/build/incremental-microbatch)
- [dbt docs — About incremental strategies](https://docs.getdbt.com/docs/build/incremental-strategy)

## Airflow

- [Airflow docs — Docker Compose](https://airflow.apache.org/docs/apache-airflow/stable/howto/docker-compose/index.html)
- [Airflow constraints files](https://github.com/apache/airflow/tree/main#constraints-files) — a utiliser SYSTEMATIQUEMENT en etendant l'image officielle.
- [Extending the Airflow image](https://airflow.apache.org/docs/docker-stack/build.html)

## astronomer-cosmos

- [astronomer.github.io/astronomer-cosmos](https://astronomer.github.io/astronomer-cosmos/)
- [Execution modes (local / virtualenv / docker / kubernetes)](https://astronomer.github.io/astronomer-cosmos/getting-started/execution-modes.html)

## Aller plus loin

1. Rebranchez ce projet sur les vraies donnees distantes (module 02)
   et laissez tourner un backfill complet sur plusieurs annees (hors
   de ce bootcamp, sur votre propre machine, avec plus de temps/bande
   passante).
2. Remplacez DuckDB par un warehouse cloud (Snowflake/BigQuery/Databricks)
   pour le meme projet, et comparez ce qui change reellement dans le
   SQL compile et les strategies incrementales disponibles.
3. Passez `LocalExecutor` a `CeleryExecutor` ou `KubernetesExecutor`
   sur la stack Airflow pour experimenter la parallelisation reelle.
4. Ajoutez de l'observabilite (module 11 du premier bootcamp,
   Elementary) sur ce second projet — les principes sont identiques,
   seule l'echelle des donnees change.
