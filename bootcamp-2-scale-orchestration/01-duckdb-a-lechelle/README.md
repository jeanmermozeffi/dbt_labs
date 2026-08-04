# Module 01 — DuckDB a l'echelle : sources externes

## Objectifs

- Comprendre le modele "query in place" de DuckDB (`external_location`).
- Brancher un `source()` dbt directement sur des fichiers parquet, sans etape de chargement.
- Construire staging + dimension + fait sur 24-32 millions de lignes reelles.

## `external_location` : la difference fondamentale avec le bootcamp 1

Dans le premier bootcamp, les donnees "brutes" vivaient DANS Postgres
(`raw.*`, chargees par un script d'init). Ici, les donnees brutes sont
des fichiers parquet SUR DISQUE — DuckDB ne les "importe" jamais dans
son propre stockage interne pour un `source()`, il les LIT directement
a chaque requete. Regardez
[`models/staging/_staging__sources.yml`](../nyc_taxi_dbt/models/staging/_staging__sources.yml) :

```yaml
sources:
  - name: nyc_tlc
    meta:
      external_location: "read_parquet('{{ var('raw_trips_glob') }}', hive_partitioning=true, union_by_name=true)"
    tables:
      - name: yellow_tripdata
```

`external_location` est une fonctionnalite specifique de l'adapter
`dbt-duckdb` (pas du dbt-core generique) : au lieu de pointer vers une
table physique existante, elle donne a dbt l'expression SQL exacte a
utiliser a la place du nom de la source. `{{ source('nyc_tlc',
'yellow_tripdata') }}` se compile alors en :

```sql
read_parquet('data/raw_parquet/**/*.parquet', hive_partitioning=true, union_by_name=true)
```

Trois arguments a bien comprendre :
- **`hive_partitioning=true`** : DuckDB derive automatiquement 2
  colonnes virtuelles (`pickup_year`, `pickup_month`) depuis la
  structure de dossiers `pickup_year=2019/pickup_month=01/`, sans
  qu'elles existent dans les fichiers parquet eux-memes. Approfondi au
  module 03.
- **`union_by_name=true`** : aligne les colonnes par NOM plutot que
  par POSITION entre plusieurs fichiers parquet. Indispensable des que
  le schema peut deriver legerement d'un fichier a l'autre (colonne
  ajoutee/retiree/reordonnee) — le cas typique sur plusieurs annees de
  donnees reelles (module 02).
- **`{{ var('raw_trips_glob') }}`** : le chemin n'est PAS code en dur,
  il vient de `dbt_project.yml` (`vars.raw_trips_glob`). C'est ce qui
  permet, au module 02, de faire pointer exactement le meme projet dbt
  sur des URLs distantes plutot que des fichiers locaux, en changeant
  UNE variable.

## Le staging reste... du staging

[`stg_trips.sql`](../nyc_taxi_dbt/models/staging/stg_trips.sql) fait
exactement ce qu'un staging fait dans le premier bootcamp : renommer,
typer, rien de plus. La difference d'echelle ne change RIEN a la
discipline architecturale — c'est un point important : les principes
du bootcamp 1 (module 02, couches staging/marts) restent valides a
n'importe quelle echelle, seule l'implementation change.

```sql
{{ config(event_time='pickup_at') }}

select
    "VendorID"              as vendor_id,
    tpep_pickup_datetime    as pickup_at,
    ...
from {{ source('nyc_tlc', 'yellow_tripdata') }}
```

`{{ config(event_time='pickup_at') }}` est nouveau par rapport au
bootcamp 1 : c'est ce qui permettra a `fct_trips` (module 04,
microbatch) de filtrer cette source PAR LOT TEMPOREL au lieu de la
scanner integralement a chaque run — sans cette ligne, dbt emet un
avertissement explicite ("no ref or source input with an event_time
configuration") et perd le benefice de performance du microbatch.

## Executer le projet

```bash
cd bootcamp-2-scale-orchestration/nyc_taxi_dbt
export SSL_CERT_FILE=$(.venv/bin/python -c "import certifi; print(certifi.where())")
.venv/bin/dbt seed
.venv/bin/dbt build --event-time-start 2019-01-01 --event-time-end 2019-05-01
```

Resultat mesure : **18 noeuds (1 seed + 2 modeles + 14 tests + 1 test
singulier), 32 millions de lignes, 7,6 secondes de bout en bout**
(dont ~4,5 s de travail dbt, le reste etant le demarrage du process).
DuckDB est un moteur columnar, vectorise, multi-thread par defaut —
la difference avec un `INSERT` ligne-par-ligne traditionnel est
spectaculaire sur ce type de charge analytique.

### La borne de fin est EXCLUSIVE — et l'erreur est invisible

Regardez bien : `--event-time-end 2019-05-01`, pas `2019-04-01`.
Cette borne est **exclusive**. Avec `2019-04-01`, vous ne chargez que
janvier a mars :

```bash
.venv/bin/dbt build --event-time-start 2019-01-01 --event-time-end 2019-04-01
# Done. PASS=18 ...   <- 18 noeuds, tout au vert, aucun avertissement
```

```sql
select count(*) from main.fct_trips;
-- 24 000 000     <- et non 32 000 000
```

**Le run est vert dans les deux cas.** Rien ne vous signale qu'il
manque un quart des donnees : dbt a fait exactement ce qu'on lui a
demande.

Pire — et c'est le piege qui vous mordra vraiment : si `fct_trips`
contenait deja avril (d'un run precedent), une commande bornee a
`2019-04-01` **ne supprime pas** avril. Le microbatch ne retraite que
les lots DANS la fenetre et laisse le reste intact :

```
fct_trips : 31 999 998 lignes    <- apres un build borne a 2019-04-01 !
   2019-01  7 999 999
   2019-02  8 000 000
   2019-03  8 000 001
   2019-04  7 999 998            <- rescape d'un run anterieur
```

Vous croyez alors que votre commande a charge 32 M. Elle en a charge
24 M ; les 8 M restants sont un vestige. **Le nombre de lignes d'une
table ne dit jamais a lui seul ce que votre derniere commande a
fait.** Pour verifier ce que vous chargez reellement, partez d'une
table vide :

```bash
python -c "import duckdb; duckdb.connect('nyc_taxi.duckdb').execute('drop table if exists main.fct_trips')"
```

C'est une propriete du microbatch (approfondie au
[module 04](../04-incremental-microbatch/README.md)), pas un defaut :
elle est ce qui rend les backfills cibles possibles. Mais elle exige
de raisonner en **fenetres**, pas en totaux.

### Pourquoi les mois ne font pas exactement 8 000 000

```
2019-01  7 999 999
2019-02  8 000 000
2019-03  8 000 001
```

Le generateur ecrit 8 M de lignes par FICHIER
(`pickup_year=2019/pickup_month=01/`), mais tire les horodatages
aleatoirement — quelques trajets tombent a cheval sur la frontiere du
mois. Le partitionnement physique (le dossier) et la valeur metier
(`pickup_at`) ne coincident donc pas parfaitement.

Retenez-le : **ne supposez jamais qu'un partitionnement de fichiers
garantit le contenu des fichiers.** Si votre logique metier depend de
"tout janvier est dans le fichier de janvier", testez-le — c'est
exactement ce que fait `assert_dropoff_after_pickup.sql` pour une
autre invariante.

## Exercice

Ajoutez une dimension `dim_zones` (mart, pas juste le `stg_zones`
existant) qui enrichit chaque zone du nombre de trajets dont elle est
le point de depart (`pickup_location_id`), sur le modele du
`dim_customers` du bootcamp 1 (dimension enrichie de mesures agregees
depuis la table de faits).

### Solution

```sql
-- models/marts/dim_zones.sql
with zones as (

    select * from {{ ref('stg_zones') }}

),

pickup_counts as (

    select
        pickup_location_id as location_id,
        count(*) as pickups_count,
        round(avg(fare_amount), 2) as avg_fare_amount

    from {{ ref('fct_trips') }}
    group by pickup_location_id

),

final as (

    select
        z.location_id,
        z.borough,
        z.zone,
        z.service_zone,
        coalesce(p.pickups_count, 0) as pickups_count,
        p.avg_fare_amount

    from zones z
    left join pickup_counts p on p.location_id = z.location_id

)

select * from final
```

Point d'attention specifique a l'echelle : `group by pickup_location_id`
sur 32 millions de lignes reste quasi instantane sur DuckDB
(agregation vectorisee), mais gardez le reflexe du bootcamp 1 : le
`left join` (pas `inner join`) depuis `zones` garantit qu'une zone
sans AUCUN trajet reste visible dans le rapport avec `pickups_count =
0`, plutot que de disparaitre silencieusement.

## Suite

→ [Module 02 — Connecter de vraies donnees distantes](../02-donnees-reelles-distantes/README.md)
