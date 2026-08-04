# Module 05 — Materialisations incrementales et performance

## Objectifs

- Comprendre pourquoi et quand passer un modele en `incremental`.
- Maitriser `is_incremental()`, `unique_key`, les strategies
  incrementales et `on_schema_change`.
- Savoir diagnostiquer un pattern "high-water mark" casse.
- Configurer des index Postgres depuis dbt.

## Pourquoi l'incremental existe

`table` recalcule TOUT a chaque `dbt run`. Sur 200 lignes (ce
projet), c'est instantane. Sur 200 millions de lignes d'evenements en
production, c'est des heures de calcul et de cout warehouse — pour
ne re-ecrire, la plupart du temps, que les quelques milliers de
lignes arrivees depuis hier. `incremental` ne retraite que le delta.

## Le pattern "high-water mark", en vrai dans ce projet

[`fct_orders.sql`](../../models/marts/core/fct_orders.sql) :

```sql
{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='delete+insert',
        on_schema_change='append_new_columns',
    )
}}

with orders as (

    select * from {{ ref('stg_orders') }}

    {% if is_incremental() %}
    where updated_at > (select coalesce(max(updated_at), '1900-01-01'::timestamp) from {{ this }})
    {% endif %}

),
...
```

- **`is_incremental()`** est `True` seulement si : (a) le modele est
  configure `incremental`, (b) la table cible existe deja, (c) on n'a
  pas passe `--full-refresh`. Au tout premier `dbt run`, elle est
  `False` : tout se charge (comme une `table` normale).
- **`{{ this }}`** = reference a la table que CE modele est en train
  de construire — permet d'interroger son propre etat actuel
  (`max(updated_at)`) pour savoir ou reprendre.
- **`coalesce(max(updated_at), '1900-01-01')`** : au premier run,
  `{{ this }}` est vide, `max()` renvoie `NULL` — sans le
  `coalesce`, le `where` deviendrait `where updated_at > NULL`, qui
  ne matche JAMAIS rien en SQL (NULL n'est comparable a rien), et la
  table resterait vide pour toujours. Piege classique, invisible en
  local si vous testez toujours avec `--full-refresh`.

## `unique_key` et les strategies incrementales

`unique_key='order_id'` dit a dbt : "s'il existe deja une ligne avec
cet `order_id`, remplace-la plutot que d'en ajouter une seconde."
Sans `unique_key`, la strategie par defaut (`append`) empilerait des
doublons a chaque fois qu'une commande deja chargee est retraitee.

| Strategie | Comportement | Supportee sur Postgres ? |
|---|---|---|
| `append` | INSERT pur, jamais de mise a jour | Oui — ideal pour un flux d'evenements immuable (logs, clics) |
| `delete+insert` | DELETE des lignes matchant `unique_key` dans le batch, puis INSERT | Oui — ideal quand une ligne peut etre mise a jour (statut de commande qui change) |
| `merge` | UPSERT en une seule commande SQL `MERGE` | Snowflake/BigQuery/Databricks — **pas Postgres** dans dbt-postgres actuellement |
| `microbatch` | Traite le delta par tranches de temps fixes (jour/heure), rejouable batch par batch | Oui depuis dbt-core 1.9, execution generique par adapter |

`fct_orders` et `fct_order_items` utilisent `delete+insert` : une
commande peut changer de statut (`placed` → `shipped` →
`completed`), donc c'est une vraie MISE A JOUR de ligne existante, pas
un ajout. Si vos evenements sont strictement immuables (jamais
modifies apres creation — typiquement des logs), preferez `append` :
pas de `DELETE`, donc moins couteux.

## `on_schema_change`

Que faire si une nouvelle colonne apparait dans le SELECT du modele
apres que la table incrementale existe deja ?

- `ignore` (defaut) : la nouvelle colonne est silencieusement
  ignoree — bug garanti, a eviter.
- `append_new_columns` : ajoute la colonne via `ALTER TABLE ADD
  COLUMN`, ne supprime jamais rien.
- `sync_all_columns` : ajoute ET supprime des colonnes pour
  correspondre exactement au SELECT.
- `fail` : plante immediatement (le plus sur pour un modele sous
  contrat de donnees, module 07).

**Piege reel rencontre en construisant ce projet** : `fct_orders` a
`config.contract.enforced: true` (module 07). Avec
`on_schema_change='sync_all_columns'`, dbt refuse de compiler :

```
Invalid value for on_schema_change: sync_all_columns. Models
materialized as incremental with contracts enabled must set
on_schema_change to 'append_new_columns' or 'fail'
```

Logique : un contrat FIGE le schema — `sync_all_columns` pourrait le
faire deriver silencieusement a l'insu du contrat, contradiction
directe. D'ou `append_new_columns` dans le fichier final.

## Deuxieme piege reel : un high-water mark casse par des dates dans le futur

En validant ce projet, le tout premier jeu de donnees genere donnait
des `updated_at` calcules comme `ordered_at + delai_de_traitement`
(jusqu'a 5 jours pour une commande "retournee"). Pour les commandes
les plus recentes, ce calcul depassait `now()` — une commande
"mise a jour" dans le futur. Consequence concrete observee :

```bash
# on insere une commande TOUTE NEUVE avec updated_at = now()
dbt run --select fct_orders
# ... INSERT 0 0   <- ZERO ligne inseree. Le nouvel order_id=91 est ignore !
```

Pourquoi : le filtre `where updated_at > max(updated_at existant)`
comparait `now()` a une valeur DEJA superieure a `now()` (le
`max(updated_at)` d'une commande "future"). Le correctif, dans
[`postgres/init-scripts/01_raw_schema.sql`](../../postgres/init-scripts/01_raw_schema.sql) :

```sql
least(ordered_at.ts + status.settle_delay, now()) as updated_at
```

La lecon generale, valable en production : **un high-water mark ne
peut fonctionner que si la colonne utilisee ne va jamais "en avant"
de l'heure reelle du run.** Si votre source peut produire des
timestamps futurs (horloges desynchronisees entre serveurs, fuseaux
horaires mal geres, planification anticipee...), le pattern
`updated_at > max(updated_at)` silencieusement arrete d'ingerer de
nouvelles lignes des que la premiere anomalie apparait — sans aucune
erreur visible. Ajoutez un test de sante
(`dbt_expectations.expect_row_values_to_have_recent_data` ou un test
singulier `select * from {{ ref('fct_orders') }} where updated_at >
now()`) pour l'attraper avant que ca vous morde.

## Index depuis dbt

```sql
config(
    ...
    indexes=[
        {'columns': ['order_id'], 'unique': true},
        {'columns': ['customer_id']}
    ]
)
```

dbt cree ces index a la creation/reconstruction de la table
(post-hook automatique pour l'adapter Postgres). Un index unique sur
la cle de grain documente ET fait respecter l'invariant "1 ligne par
commande" au niveau base — en plus du test `unique` dbt (qui, lui, ne
s'execute qu'au `dbt test`, pas a chaque insertion).

## `--full-refresh` : le flag le plus dangereux de dbt

Il merite sa propre section, parce que son effet est **destructif** et
que rien ne vous le rappelle au moment ou vous le tapez.

`--full-refresh` fait deux choses sur un modele incremental :

1. `is_incremental()` renvoie `False` (le `where` de reprise est
   ignore) ;
2. dbt **DROP puis recree** la table, au lieu d'y inserer un delta.

Consequences a mesurer avant de le lancer :

| Contexte | Effet de `--full-refresh` |
|---|---|
| Local, 200 lignes | 2 secondes, aucun risque |
| Prod, 200 M de lignes | des heures de calcul, une facture warehouse |
| Table dont la source ne garde que 30 jours | **perte definitive de tout l'historique au-dela de 30 jours** |

Ce troisieme cas est le vrai piege : la table incrementale avait
accumule 3 ans d'evenements que la source, elle, ne conserve plus.
`--full-refresh` reconstruit "proprement"... 30 jours. Aucune erreur,
aucun avertissement, une table verte et 97 % de l'historique perdu.

Deux protections a connaitre :

```sql
{{ config(materialized='incremental', full_refresh=false) }}
```

`full_refresh=false` dans la config du modele fait **ignorer** le flag
sur ce modele precis — la bonne pratique sur toute table dont
l'historique n'est pas reconstructible depuis la source.

Et le reflexe systematique : verifier `target=` avant d'appuyer sur
Entree.

```bash
dbt run --select fct_orders --full-refresh
# Concurrency: 4 threads (target='dev')   <- LIRE CETTE LIGNE
```

## Tester un modele incremental correctement

```bash
dbt run --select fct_orders --full-refresh   # reconstruction complete, baseline
dbt run --select fct_orders                  # run incrementel : doit inserer 0 ligne si rien n'a change
```

Si le deuxieme run insere N lignes alors que rien n'a change en
amont, votre condition `is_incremental()` est fausse (probablement
une colonne source qui change a chaque run, comme un
`current_timestamp` non maitrise — voir le piege du module 04 sur
`loaded_at`).

## Exercice

`stg_returns` est un flux d'evenements **immuable** (un retour, une
fois enregistre, n'est jamais modifie). Concevez
`fct_returns` en incremental avec la strategie la plus legere
possible (justifiez pourquoi ce n'est PAS `delete+insert`).

### Solution

```sql
-- models/marts/returns/fct_returns.sql
{{
    config(
        materialized='incremental',
        incremental_strategy='append',
    )
}}

select
    return_id,
    order_item_id,
    reason,
    refund_amount_cents,
    returned_at
from {{ ref('stg_returns') }}

{% if is_incremental() %}
where returned_at > (select coalesce(max(returned_at), '1900-01-01'::timestamp) from {{ this }})
{% endif %}
```

Pourquoi `append` et pas `delete+insert` : `delete+insert` a un cout
en plus (le `DELETE` avant chaque `INSERT`) qui n'a de sens QUE si
une ligne deja chargee peut changer. Un retour, une fois cree, ne
change jamais (pas de `unique_key` necessaire non plus, puisqu'on ne
recherche jamais a en remplacer un). `append` est strictement
suffisant et moins couteux — utiliser `delete+insert` "par habitude"
sur un flux immuable est un gaspillage de performance frequent en
production.

## Suite

→ [Module 06 — Snapshots et SCD](../06-snapshots-scd/README.md)
