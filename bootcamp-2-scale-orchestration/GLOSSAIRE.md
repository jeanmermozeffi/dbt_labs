# Glossaire (complement au glossaire du bootcamp 1)

**DuckDB** — Base de donnees analytique EMBARQUEE (pas de serveur,
pas de process a lancer) : l'entrepot entier est un fichier `.duckdb`
sur disque. Voir [module 00](00-setup/README.md).

**`external_location`** — Config specifique a `dbt-duckdb` qui fait
pointer un `source()` dbt directement vers une expression SQL
(typiquement `read_parquet(...)`) au lieu d'une table physique. Voir
[module 01](01-duckdb-a-lechelle/README.md).

**Partitionnement Hive** — Convention ou la structure de dossiers
(`cle=valeur/`) encode des colonnes, derivees automatiquement par
DuckDB (`hive_partitioning=true`) sans exister dans les fichiers eux-
memes. Voir [module 03](03-partitioning-perf/README.md).

**File pruning** — Elimination de fichiers entiers AVANT lecture, sur
la seule base des filtres et de la structure de partitionnement (visible
dans `EXPLAIN ANALYZE` via `Scanning Files: X/Y`). Voir [module 03](03-partitioning-perf/README.md).

**Zone map** — Statistiques min/max conservees par groupe de lignes
("row group") dans une table columnar, permettant de sauter des
groupes entiers sans les lire si le filtre les exclut. Voir [module 03](03-partitioning-perf/README.md).

**`union_by_name`** — Option de `read_parquet` qui aligne les colonnes
de plusieurs fichiers par NOM plutot que par position, pour absorber
un schema qui derive legerement d'un fichier a l'autre. Voir [module 02](02-donnees-reelles-distantes/README.md).

**`microbatch`** — Strategie incrementale (dbt >= 1.9) qui decoupe le
traitement en lots temporels independants (jour/semaine/mois/annee),
rejouables individuellement. Voir [module 04](04-incremental-microbatch/README.md).

**`event_time`** — Config qui declare quelle colonne represente le
temps d'un evenement dans un modele, necessaire pour que `microbatch`
puisse filtrer automatiquement les sources/refs en amont. Voir
[module 04](04-incremental-microbatch/README.md).

**Backfill** — Retraitement d'une plage temporelle passee, scope
explicitement via `--event-time-start`/`--event-time-end`. Voir
[module 04](04-incremental-microbatch/README.md).

**Executor (Airflow)** — Le composant qui decide COMMENT les taches
sont reellement executees : `LocalExecutor` (sous-processus locaux),
`CeleryExecutor` (workers distribues via une file de messages),
`KubernetesExecutor` (un pod par tache). Voir [module 05](05-orchestration-airflow/README.md).

**DAG (Airflow)** — Ici, un DAG Airflow (planification/dependances de
taches) ne pas confondre avec le DAG dbt (dependances de modeles) —
[astronomer-cosmos](06-astronomer-cosmos/README.md) transforme le
second en un ensemble de taches DANS le premier.

**Constraints file (pip)** — Fichier qui fige les versions
compatibles connues d'un ensemble de paquets, sans pour autant les
INSTALLER (contrairement a un `requirements.txt`). Indispensable pour
etendre une image Docker officielle sans faire exploser la resolution
de dependances. Voir [module 05](05-orchestration-airflow/README.md).
