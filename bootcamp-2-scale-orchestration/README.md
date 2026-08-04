# Bootcamp 2 — dbt a l'echelle : gros volumes + orchestration

Suite directe du [premier bootcamp](../bootcamp/README.md). La ou
celui-ci travaillait sur quelques centaines de lignes Postgres, celui-ci
travaille sur des **dizaines de millions de lignes reelles** (schema
NYC TLC Taxi), sur **DuckDB**, avec une **vraie orchestration Airflow**.

## Pourquoi un second bootcamp separe

Changer d'echelle n'est pas juste "plus de lignes" : ca change le
moteur qu'on utilise (module 00), la facon de brancher les sources
(module 01/02), les strategies de materialisation (module 04), et ca
introduit un besoin qui n'existait pas encore : un vrai scheduler
externe (module 05/06). Plutot que d'alourdir le premier bootcamp,
ce second parcours est un projet dbt independant
([`nyc_taxi_dbt/`](nyc_taxi_dbt/)), avec son propre venv, son propre
adapter (`dbt-duckdb`), pour que vous puissiez comparer les deux
architectures cote a cote.

## Le jeu de donnees

Schema **NYC TLC Yellow Taxi** (le vrai schema public :
`VendorID`, `tpep_pickup_datetime`, `PULocationID`, `fare_amount`...).
Genere localement de facon synthetique
([`scripts/generate_synthetic_trips.py`](nyc_taxi_dbt/scripts/generate_synthetic_trips.py))
pour que le bootcamp soit rejouable a l'identique sans dependre de la
disponibilite d'un CDN tiers — **32 millions de lignes reelles dans
ce repo**, generees et chargees en quelques secondes. Le
[module 02](02-donnees-reelles-distantes/README.md) documente,
avec des chiffres mesures en conditions reelles (pas des estimations),
comment brancher ce meme projet sur les vrais fichiers publics :
**487 655 363 lignes comptees en moins de 10 secondes**, sans rien
telecharger, via lecture parquet a distance.

## Sommaire

| # | Module | Vous saurez... |
|---|--------|-----------------|
| 00 | [Setup](00-setup/README.md) | Installer dbt-duckdb, pourquoi DuckDB n'a besoin d'aucun serveur |
| 01 | [DuckDB a l'echelle](01-duckdb-a-lechelle/README.md) | Sources externes (`external_location`), generer/charger des dizaines de millions de lignes |
| 02 | [Connecter de vraies donnees distantes](02-donnees-reelles-distantes/README.md) | `httpfs`, lire des parquet a distance sans les telecharger, gerer le schema drift |
| 03 | [Partitioning, clustering, performance](03-partitioning-perf/README.md) | Partitionnement Hive, `EXPLAIN ANALYZE`, pruning de fichiers/row groups |
| 04 | [Incremental a l'echelle : microbatch](04-incremental-microbatch/README.md) | La strategie `microbatch` (dbt >= 1.9), ses pieges reels, backfills scopes |
| 05 | [Orchestration Airflow](05-orchestration-airflow/README.md) | Stack Airflow via Docker Compose (LocalExecutor), DAGs |
| 06 | [astronomer-cosmos](06-astronomer-cosmos/README.md) | Transformer le projet dbt en taches Airflow natives |
| 07 | [Projet capstone](07-projet-capstone/README.md) | Etendre a plusieurs annees + scheduler + alerting, seul(e) |

## Prerequis

Avoir fait (ou au moins lu) le [premier bootcamp](../bootcamp/README.md) :
celui-ci suppose acquis `ref()`/`source()`, les tests generiques, les
materialisations de base, les macros. On ne re-explique pas ces
fondamentaux ici, seulement ce qui change a l'echelle.

Les deux fiches de reference du bootcamp 1 restent valables
telles quelles (la CLI et la structure de fichiers sont identiques,
seul l'adapter change) — gardez-les sous la main :

- [reference-cli.md](../bootcamp/reference-cli.md) — commandes,
  syntaxe `--select`, lecture des sorties dbt.
- [reference-fichiers.md](../bootcamp/reference-fichiers.md) — role de
  chaque fichier `.sql` / `.yml`, priorite des configs.

Une difference a noter des le [module 00](00-setup/README.md) : ce
projet met son `profiles.yml` **dans le repo** (et non dans `~/.dbt/`),
parce que DuckDB n'a aucun secret a proteger. Il n'y a donc ni `.env`
ni `set -a && source .env && set +a` dans ce bootcamp.
