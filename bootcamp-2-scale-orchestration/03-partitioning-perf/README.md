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

### Le resultat mesure ne dit PAS ce qu'on attendait

Lancez-le vraiment. Voici ce que ce projet produit :

| Requete | Fichiers lus | Temps |
|---|---|---|
| `count(*)` + filtre hive | **1 / 4** | 3,8 ms |
| `count(*)` + `filename LIKE` | 4 / 4 | 4,1 ms |
| `avg(fare_amount)` + filtre hive | **1 / 4** | 7,2 ms |
| `avg(fare_amount)` + `filename LIKE` | 4 / 4 | 6,9 ms |

Le pruning est bien reel — `Scanning Files: 1/4` n'apparait QUE dans
la version hive. **Mais le temps ne bouge pas.** Sur la derniere
ligne, la version sans pruning est meme (marginalement) plus rapide.

Il serait facile d'ecrire ici que `filename LIKE` "perd l'essentiel du
gain de pruning". La mesure dit le contraire, et il faut le dire :

1. **DuckDB pousse aussi le filtre `filename` vers le bas.** Il ouvre
   les metadonnees des 4 fichiers, mais ne lit les donnees de colonnes
   que du fichier retenu. Le travail evite est donc presque le meme.
2. **A cette echelle, ouvrir 4 metadonnees parquet coute ~0 ms.** Sur
   disque local, avec 4 fichiers, il n'y a tout simplement rien a
   gagner.

### Ce que le pruning fait vraiment economiser

Comparez plutot "lire 1 fichier" a "lire 4 fichiers de donnees" :

```python
select avg(fare_amount) from {glob} where pickup_year=2019 and pickup_month='02'  # 1 fichier
select avg(fare_amount) from {glob}                                               # 4 fichiers
```

```
1 mois  (1 fichier lu)  :   6,8 ms
4 mois  (4 fichiers)    :  18,1 ms      <- 2,7x
```

**Voila le vrai gain** : il vient de la quantite de DONNEES lues, pas
du nombre de fichiers ouverts. 4x le volume pour 2,7x le temps (le
reste etant du cout fixe).

### Alors pourquoi `hive_partitioning=true` plutot que `filename LIKE` ?

Pas pour la vitesse a cette echelle. Pour trois raisons qui, elles,
ne dependent pas du volume :

| | `hive_partitioning=true` | `filename LIKE` |
|---|---|---|
| Typage | `pickup_year = 2019` compare des **entiers** | comparaison de chaine sur un chemin |
| Robustesse | insensible au format du chemin | casse des que l'arborescence change |
| Lisibilite | un predicat metier | un detail d'implementation du stockage |

Et la vitesse redevient decisive des que les conditions changent :
**des milliers de fichiers** (ouvrir 5 000 metadonnees n'est plus
gratuit), ou **du stockage objet distant** (module 02), ou chaque
ouverture de fichier est un aller-retour reseau de plusieurs
millisecondes. C'est la que `Scanning Files: 1/5000` fait la
difference entre 2 secondes et 3 minutes.

**La lecon de methode, plus importante que le resultat** : ce module
affirmait un gain de performance qu'aucune mesure ne soutenait a
cette echelle. Mesurez toujours sur VOS volumes avant de conclure —
une optimisation vraie a grande echelle peut etre parfaitement nulle
a petite echelle, et l'inverse arrive aussi.

## Suite

→ [Module 04 — Incremental a l'echelle : microbatch](../04-incremental-microbatch/README.md)
