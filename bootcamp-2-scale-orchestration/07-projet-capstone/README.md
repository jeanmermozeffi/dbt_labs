# Module 07 — Projet capstone

## Objectif

Comme pour le premier bootcamp : un cahier des charges, pas un
tutoriel pas-a-pas. Faites-le avant de regarder la section solution.

**Contexte** : l'equipe finance veut un rapport mensuel du revenu
total et du nombre de trajets, par borough, avec alerte si le
volume d'un mois chute de plus de 20% par rapport au mois precedent
(signe probable d'un probleme d'ingestion plutot que d'une vraie
baisse d'activite).

## Cahier des charges

### 1. Nouveau mart

`models/marts/monthly_borough_revenue.sql` : grain = 1 ligne par
(mois x borough), avec `trip_count`, `total_revenue`,
`avg_fare_amount`. Reutilisez `fct_trips` et `stg_zones` (module 01).

### 2. Test de non-regression de volume

Un test qui echoue (severity=warn) si le nombre de trajets d'un mois
est inferieur a 80% du mois precedent, pour le MEME borough. Indice :
`LAG()` en SQL fenetre.

### 3. Extension du DAG

Ajoutez ce nouveau modele au DAG Cosmos existant (aucune modification
du fichier DAG necessaire si vous avez bien suivi la structure du
projet — verifiez pourquoi).

### 4. Backfill controle

Ajoutez un mois de donnees supplementaire (mai 2019) avec le
generateur (module 00), et rejouez UNIQUEMENT le backfill de ce mois
via `--event-time-start`/`--event-time-end` (module 04) — sans
recalculer les mois deja charges.

## Criteres d'acceptation

**Piege de selecteur, a resoudre avant tout le reste.** La commande
qui vient naturellement est fausse :

```bash
dbt build --select monthly_borough_revenue+ --event-time-start 2019-05-01 --event-time-end 2019-06-01
```

Verifiez ce qu'elle selectionne reellement :

```bash
dbt ls --select "monthly_borough_revenue+"
```

```
nyc_taxi_dbt.marts.monthly_borough_revenue
nyc_taxi_dbt.assert_no_volume_drop_month_over_month
```

**`fct_trips` n'y est pas.** Le `+` a droite prend les descendants ;
or `fct_trips` est un ANCETRE. Les flags `--event-time-*` ne
s'appliquent donc a aucun modele microbatch : mai ne sera jamais
charge, et le mart se reconstruira sur les donnees deja presentes,
sans la moindre erreur. Le bon selecteur porte un `+` **des deux
cotes** :

```bash
dbt ls --select "+monthly_borough_revenue+"
# nyc_taxi_dbt.marts.fct_trips          <- present, cette fois
# nyc_taxi_dbt.marts.monthly_borough_revenue
# nyc_taxi_dbt.staging.stg_trips
# ... + les 15 tests
```

```bash
dbt build --select "+monthly_borough_revenue+" \
    --event-time-start 2019-05-01 --event-time-end 2019-06-01
```

Prenez le reflexe : **tout `--select` destine a un backfill doit etre
valide avec `dbt ls` avant d'etre lance.** Un selecteur trop etroit ne
produit aucune erreur, seulement des donnees manquantes.

Resultat attendu sur les 4 mois deja en place :

```
Done. PASS=20 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=20
```

Et le mart doit contenir **20 lignes** (4 mois x 5 boroughs) :

```
  2019-01-01  Bronx          1 633 875      33 876 713
  2019-01-01  Brooklyn       1 550 199      31 972 324
  ...
```

### Demontrer que le test detecte vraiment une chute

Un test au vert ne prouve rien tant que vous ne l'avez pas vu rougir.
L'enonce suggere de mutiler un fichier parquet source — **ne faites
pas ca** : vous detruiriez une donnee que seul le generateur peut
recreer. Cassez plutot la TABLE, que le microbatch sait reconstruire :

```python
import duckdb
c = duckdb.connect('nyc_taxi.duckdb')
c.execute("""delete from main.fct_trips
             where pickup_at >= '2019-04-01' and pickup_at < '2019-05-01'
               and hash(rowid) % 100 < 50""")
# avril ramene a 3 999 641 lignes (~50%)
```

```bash
dbt build --select "monthly_borough_revenue+"
```

```
2 of 2 WARN 5 assert_no_volume_drop_month_over_month [WARN 5 in 0.02s]
[WARNING]: Got 5 results, configured to warn if != 0
Done. PASS=1 WARN=1 ERROR=0 SKIP=0 NO-OP=0 TOTAL=2
```

**`WARN 5`** : les cinq boroughs, chacun sous les 80 % du mois
precedent. Le test fait son travail, et `severity='warn'` le signale
sans bloquer le pipeline — le bon choix ici, puisqu'une vraie baisse
saisonniere de 20 % reste plausible.

Restaurez avec un backfill scope d'un seul lot :

```bash
dbt build --select "fct_trips+" --event-time-start 2019-04-01 --event-time-end 2019-05-01
```

```
Batch 1 of 1 START batch 2019-04 of main.fct_trips ... [RUN]
Batch 1 of 1 OK created batch 2019-04 of main.fct_trips [OK in 0.95s]
Done. PASS=8 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=8
```

**Une seconde pour reparer 4 millions de lignes**, sans toucher a
janvier, fevrier ni mars. C'est la demonstration la plus concrete de
ce que `microbatch` (module 04) vous achete : un incident circonscrit
a une periode se repare en rejouant cette periode, pas le pipeline
entier. Sur un historique de 5 ans, la difference se compte en heures.

## Solution

### 1. Le mart

```sql
-- models/marts/monthly_borough_revenue.sql
with trips as (

    select * from {{ ref('fct_trips') }}

),

zones as (

    select * from {{ ref('stg_zones') }}

),

joined as (

    select
        date_trunc('month', t.pickup_at) as trip_month,
        z.borough,
        t.total_amount

    from trips t
    inner join zones z on z.location_id = t.pickup_location_id

)

select
    trip_month,
    borough,
    count(*) as trip_count,
    round(sum(total_amount), 2) as total_revenue,
    round(avg(total_amount), 2) as avg_fare_amount
from joined
group by trip_month, borough
order by trip_month, borough
```

### 2. Le test de non-regression

```sql
-- tests/assert_no_volume_drop_month_over_month.sql
{{ config(severity='warn') }}

with monthly as (

    select
        trip_month,
        borough,
        trip_count,
        lag(trip_count) over (partition by borough order by trip_month) as previous_month_count

    from {{ ref('monthly_borough_revenue') }}

)

select *
from monthly
where previous_month_count is not null
  and trip_count < previous_month_count * 0.8
```

`LAG() OVER (PARTITION BY borough ORDER BY trip_month)` recupere la
valeur du mois PRECEDENT pour le MEME borough sur la ligne courante —
sans autojointure. `previous_month_count is not null` exclut
naturellement le tout premier mois de chaque borough (rien a comparer).

### 3. Pourquoi le DAG n'a besoin d'AUCUNE modification

`DbtDag(project_config=ProjectConfig(str(PROJECT_DIR)), ...)` (module 06)
pointe sur le DOSSIER du projet, pas sur une liste de modeles
explicite. Cosmos re-parse le projet (via `dbt ls`) a chaque analyse
du DAG par le `dag-processor` — tout nouveau modele/test present dans
`models/`/`tests/` est automatiquement decouvert et ajoute au graphe
de taches Airflow. C'est le meme principe que `ref()`/`source()` en
dbt (module 01, bootcamp 1) : le DAG se deduit du CODE, jamais d'une
liste maintenue a la main.

### 4. Le backfill controle

```bash
# generer mai 2019 (adapter scripts/generate_synthetic_trips.py, module 00)
.venv/bin/python scripts/generate_synthetic_trips.py

dbt build --select monthly_borough_revenue+ \
    --event-time-start 2019-05-01 --event-time-end 2019-06-01
```

Seul le lot de mai est (re)traite dans `fct_trips` (microbatch,
module 04) ; `monthly_borough_revenue`, lui, n'est PAS microbatch
(c'est un agregat complet, pas un flux d'evenements) — il se
reconstruit entierement a chaque run, mais reste rapide (agregation
de 32-40M lignes en quelques secondes sur DuckDB, module 01).

**Ce melange est volontaire et vaut d'etre compris.** Dans un meme
`dbt build`, deux modeles voisins obeissent a des regles opposees :

| | `fct_trips` | `monthly_borough_revenue` |
|---|---|---|
| Materialisation | `incremental` / `microbatch` | `table` |
| Effet de `--event-time-*` | limite les lots traites | **aucun** |
| Cout d'un run | proportionnel a la fenetre | proportionnel au TOTAL |

Consequence pratique : le mart voit toujours l'integralite de
`fct_trips`, y compris les mois que vous n'avez pas retraites. C'est
ce qui rend le test de non-regression possible (il compare des mois
entre eux), et c'est aussi pourquoi un `fct_trips` partiellement
charge produit un mart faux **sans aucune erreur** — exactement le
piege du [module 01](../01-duckdb-a-lechelle/README.md).

La regle : reservez `microbatch` aux tables de FAITS a l'echelle des
evenements ; laissez les agregats en `table` tant que leur
reconstruction complete reste de l'ordre de la seconde. Passer un
agregat en incremental "par principe" ajoute une complexite (et une
classe de bugs) pour un gain souvent nul.

## Fin du bootcamp 2

Vous avez : ingere des dizaines de millions de lignes reelles sans
serveur de base de donnees, brancne le meme projet sur de vraies
donnees publiques a 487 millions de lignes en quelques secondes,
compris le partitionnement et le pruning au niveau moteur, maitrise
`microbatch` et ses pieges reels, et orchestre le tout avec un
Airflow 3.x en conteneurs — en debuggant, dans l'ordre, une bonne
douzaine de problemes reels d'infrastructure (SSL, reseau Docker,
resolution pip, compatibilite de versions, architecture d'API interne,
authentification inter-services, concurrence d'ecriture). C'est
exactement ce type de friction que rencontre un data engineer senior
en production — et savoir la diagnostiquer methodiquement (lire le
message d'erreur exact, isoler la cause, verifier l'hypothese avant
de corriger) compte davantage que de la memoriser a l'avance.

Retour au sommaire : [`../README.md`](../README.md).
