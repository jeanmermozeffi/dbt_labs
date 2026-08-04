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

```bash
dbt build --select monthly_borough_revenue+ --event-time-start 2019-05-01 --event-time-end 2019-06-01
```

0 erreur. Le test de volume doit passer au vert sur les donnees
actuelles (pas de vraie chute), et vous devez pouvoir DEMONTRER qu'il
detecterait une chute en cassant volontairement les donnees d'un mois
(supprimez la moitie des lignes d'un fichier parquet source, relancez,
observez le warning).

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
