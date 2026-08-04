# Module 03 — Partitioning, clustering, performance

## Objectifs

- Comprendre le partitionnement Hive et le "file pruning".
- Lire un plan `EXPLAIN ANALYZE` DuckDB et repérer le pruning.
- Savoir quand un partitionnement explicite aide vraiment (et quand DuckDB s'en passe).

## Partitionnement Hive : des dossiers qui deviennent des colonnes

[`scripts/generate_synthetic_trips.py`](../nyc_taxi_dbt/scripts/generate_synthetic_trips.py)
ecrit les donnees dans cette structure :

```
data/raw_parquet/
├── pickup_year=2019/pickup_month=01/trips.parquet
├── pickup_year=2019/pickup_month=02/trips.parquet
├── pickup_year=2019/pickup_month=03/trips.parquet
└── pickup_year=2019/pickup_month=04/trips.parquet
```

C'est le "partitionnement Hive" : le CHEMIN encode la valeur d'une
colonne. Avec `hive_partitioning=true` (module 01),
`pickup_year`/`pickup_month` deviennent des colonnes utilisables dans
un `WHERE`, MEME si elles n'existent dans AUCUN fichier parquet — DuckDB
les derive du chemin.

## La preuve par `EXPLAIN ANALYZE` : le pruning en action

Requete capturee en construisant ce bootcamp, filtrée sur un seul
mois :

```sql
explain analyze
select count(*)
from read_parquet('data/raw_parquet/**/*.parquet', hive_partitioning=true)
where pickup_year = 2019 and pickup_month = '02'
```

Extrait du plan reel obtenu :

```
TABLE_SCAN
  Function: READ_PARQUET
  File Filters: (pickup_month = '02')
  Scanning Files: 1/4
  Total Files Read: 1
  8,000,000 rows
  0.00s
Total Time: 0.0051s
```

**`Scanning Files: 1/4`** : DuckDB a elimine 3 des 4 fichiers SANS LES
OUVRIR, juste en comparant le filtre a la structure de dossiers.
Resultat : 5 millisecondes pour repondre, alors que la table complete
fait 32 millions de lignes. Sans ce pruning, la meme requete devrait
lire (au minimum les metadonnees de) les 4 fichiers.

## Le pruning marche AUSSI sans partitionnement physique

Deuxieme mesure reelle, cette fois sur `fct_trips` (une vraie table
DuckDB, pas des fichiers separes) :

```sql
explain analyze
select count(*), avg(fare_amount)
from main.fct_trips
where pickup_at >= '2019-02-01' and pickup_at < '2019-03-01'
```

```
TABLE_SCAN
  Table: nyc_taxi.main.fct_trips
  Filters: pickup_at >= '2019-02-01'::TIMESTAMP AND pickup_at < '2019-03-01'::TIMESTAMP
  8,000,000 rows
  0.04s
Total Time: 0.0079s
```

DuckDB stocke ses tables en "row groups" avec des statistiques
min/max PAR GROUPE (des "zone maps", le meme principe que les micro-
partitions Snowflake ou le clustering BigQuery). Un `WHERE` sur une
colonne correlee a l'ordre physique des donnees (ici, `pickup_at`,
naturellement croissant puisque `fct_trips` est construite mois par
mois via microbatch — module 04) permet a DuckDB de sauter des groupes
entiers sans meme les lire, MEME sans partitionnement de fichiers
explicite. `avg(fare_amount)` n'a lu QUE les 8M lignes de fevrier, pas
les 32M de la table entiere.

## Quand partitionner physiquement quand meme ?

Si le pruning par zone map marche deja tout seul sur une table
DuckDB, pourquoi le module 01 partitionne-t-il physiquement les
fichiers source (`pickup_year=/pickup_month=`) ? Deux raisons
distinctes :

1. **Le pruning par zone map suppose que les donnees sont
   physiquement ORDONNEES** selon la colonne filtree. Une table
   DuckDB alimentee de facon desordonnee (insertions eparpillees dans
   le temps, comme un flux d'evenements en temps reel plutot qu'un
   backfill mensuel) perd rapidement ce benefice — chaque row group
   finirait par contenir un melange de toutes les periodes.
2. **Les fichiers source (parquet sur disque) ne sont pas geres par
   DuckDB** : ils peuvent venir de N'IMPORTE QUEL producteur (un job
   Spark, un export cloud...). Le partitionnement Hive au niveau du
   SYSTEME DE FICHIERS est le seul moyen de garantir le pruning
   independamment de l'ordre interne de chaque fichier.

Regle pratique : partitionnez physiquement (Hive ou `PARTITION BY` a
l'ecriture) les DONNEES SOURCE volumineuses et append-only ; comptez
sur le tri naturel + les zone maps DuckDB pour les tables internes
alimentees de facon ordonnee (typiquement, le resultat d'un
microbatch chronologique comme `fct_trips`).

## Exercice

Comparez le temps d'execution d'un `count(*)` filtre sur un mois AVEC
et SANS `hive_partitioning=true`, pour mesurer concretement le cout du
pruning desactive.

### Solution

```python
import duckdb, time

con = duckdb.connect()

t0 = time.time()
con.execute("""
    select count(*) from read_parquet('data/raw_parquet/**/*.parquet', hive_partitioning=true)
    where pickup_year = 2019 and pickup_month = '02'
""").fetchone()
print("avec hive_partitioning:", time.time() - t0)

t0 = time.time()
con.execute("""
    select count(*) from read_parquet('data/raw_parquet/**/*.parquet')
    where filename like '%pickup_month=02%'
""").fetchone()
print("sans hive_partitioning (filtre sur le nom de fichier a la main):", time.time() - t0)
```

Sans `hive_partitioning=true`, `pickup_year`/`pickup_month` n'existent
plus comme colonnes — la seule facon de filtrer par fichier est de
retomber sur la pseudo-colonne `filename` (qui existe toujours) avec
un `LIKE`, un pattern bien plus fragile (depend du format exact du
chemin) et qui **desactive le "File Filters" du plan** vu plus haut :
DuckDB doit alors lister/ouvrir tous les fichiers avant de pouvoir
appliquer un `LIKE` sur leur nom, perdant l'essentiel du gain de
pruning. C'est la demonstration concrete que `hive_partitioning=true`
n'est pas cosmetique : c'est ce qui transforme le chemin en un VRAI
predicat de filtrage exploitable par l'optimiseur.

## Suite

→ [Module 04 — Incremental a l'echelle : microbatch](../04-incremental-microbatch/README.md)
