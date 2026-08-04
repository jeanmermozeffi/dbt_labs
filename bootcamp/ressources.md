# Ressources pour aller plus loin

## Documentation officielle

- [docs.getdbt.com](https://docs.getdbt.com/) — la reference, toujours a jour.
- [dbt Style Guide](https://docs.getdbt.com/best-practices/how-we-style/0-how-we-style-our-dbt-projects) — les conventions utilisees dans ce bootcamp en sont directement inspirees.
- [dbt Labs — Best Practices](https://docs.getdbt.com/best-practices) — architecture staging/marts, structuration de projet.

## Packages utilises dans ce projet

- [dbt-labs/dbt_utils](https://github.com/dbt-labs/dbt-utils) — `pivot`, `date_spine`, `generate_surrogate_key`, `get_column_values`...
- [metaplane/dbt_expectations](https://github.com/metaplane/dbt-expectations) — tests statistiques inspires de Great Expectations.
- [dbt-labs/codegen](https://github.com/dbt-labs/dbt-codegen) — generation de YAML/SQL depuis le catalogue reel.

## Semantic Layer / MetricFlow

- [MetricFlow docs](https://docs.getdbt.com/docs/build/about-metricflow)
- [dbt Semantic Layer](https://docs.getdbt.com/docs/use-dbt-semantic-layer/dbt-sl)

## Ecosysteme d'observabilite

- [Elementary](https://www.elementary-data.com/) — observabilite open-source pour projets dbt (freshness, anomalies de volume, lineage de colonnes).
- [Datafold](https://www.datafold.com/) — diff de donnees entre branches, tres utile en revue de PR sur des gros changements de modele.

## Orchestration

- [astronomer-cosmos](https://astronomer.github.io/astronomer-cosmos/) — execute un projet dbt comme des taches Airflow natives.
- [dagster-dbt](https://docs.dagster.io/integrations/libraries/dbt) — integration dbt/Dagster (assets).

## Postgres (pour approfondir la partie warehouse de ce bootcamp)

- [Postgres EXPLAIN docs](https://www.postgresql.org/docs/current/using-explain.html)
- [explain.dalibo.com](https://explain.dalibo.com/) — visualiseur de plans `EXPLAIN ANALYZE`.

## Communaute

- [dbt Community Slack](https://www.getdbt.com/community/)
- [dbt Discourse](https://discourse.getdbt.com/)

## Aller plus loin apres ce bootcamp

1. Faites tourner ce projet sur un adapter different (DuckDB en local
   est le plus simple a tester : `pip install dbt-duckdb`, un seul
   fichier `.duckdb`) — comparez ce qui change dans le SQL compile.
2. Ajoutez `dbt-metricflow` et executez de vraies requetes `mf query`
   sur le semantic layer du [module 08](08-semantic-layer-metricflow/README.md).
3. Installez Elementary sur ce projet et observez ce qu'il detecte
   automatiquement que vous avez configure manuellement dans les
   modules 07 et 11.
4. Reproduisez l'integralite du bootcamp sur un jeu de donnees reel —
   voir la conclusion du [module 12](12-projet-capstone/README.md).
