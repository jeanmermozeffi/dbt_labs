# Module 02 — Modelisation dimensionnelle

## Objectifs

- Comprendre le role precis de chaque couche : staging / intermediate / marts.
- Appliquer la modelisation en etoile (Kimball) : faits, dimensions, grain.
- Connaitre les conventions de nommage dbt et pourquoi elles existent.

## Les trois couches, et la responsabilite EXACTE de chacune

### Staging (`models/staging/`) — 1 modele par source, zero logique metier

Regle stricte : **un renommage/cast, jamais un JOIN entre deux
sources**. Ouvrez [`stg_orders.sql`](../../models/staging/stg_orders.sql) :
renommer les colonnes, rien d'autre. Pourquoi cette rigueur ?

- Si une source change de nom de colonne, un seul fichier a corriger.
- Tout le reste du projet peut faire confiance a des noms stables et
  documentes (`_staging__models.yml`), independamment du bazar dans
  le systeme source.

Materialise en `view` (voir `dbt_project.yml`) : pas de stockage
dedie, toujours a jour, le cout de recalcul est negligeable pour du
simple renommage.

### Intermediate (`models/intermediate/`) — la logique metier qui ne merite pas d'exister seule

Regardez [`int_order_amounts.sql`](../../models/intermediate/int_order_amounts.sql)
(agregation lignes → commande) et
[`int_payments_pivoted.sql`](../../models/intermediate/int_payments_pivoted.sql)
(pivot des paiements). Ce sont de vraies transformations (agregation,
pivot), mais **personne ne les interroge directement** — elles
n'existent que pour etre assemblees dans `fct_orders`. D'ou
`+materialized: ephemeral` dans `dbt_project.yml` : dbt les inline en
CTE, zero objet cree en base.

Regle pratique : si vous devez faire un `group by` ou un `pivot`
avant de pouvoir joindre proprement deux choses, ca va en
intermediate — pas directement dans le mart final (qui deviendrait
imbitable a lire).

#### "Zero objet cree en base" : verifiez-le, ne me croyez pas

C'est l'affirmation la plus contre-intuitive du module, et elle est
observable en trois commandes :

```bash
dbt ls --resource-type model | wc -l
# 15   <- dbt connait 15 modeles
```

```bash
psql ... -c "select count(*) from information_schema.tables
             where table_schema in ('dbt_jeff_staging','dbt_jeff_marts');"
# 13   <- il n'en existe que 13 physiquement
```

Les deux manquants sont exactement les deux `int_*` :

```bash
dbt ls --select intermediate --resource-type model
# dbt_labs.intermediate.int_order_amounts
# dbt_labs.intermediate.int_payments_pivoted

psql ... -c "select count(*) from information_schema.tables
             where table_name like 'int_%';"
# 0
```

**Ou sont-ils passes ?** Dans le SQL compile de leurs consommateurs :

```bash
dbt compile --select fct_orders
grep -n "__dbt__cte" target/compiled/dbt_labs/models/marts/core/fct_orders.sql
```

```sql
 8: with  __dbt__cte__int_order_amounts as (
33: ),  __dbt__cte__int_payments_pivoted as (
133:     select * from __dbt__cte__int_order_amounts
```

dbt a **recopie le corps entier** de chaque modele ephemeral en CTE,
en tete de la requete qui l'utilise. D'ou les consequences pratiques,
qui decoulent toutes de ce seul mecanisme :

| Consequence | Pourquoi |
|---|---|
| Impossible de faire `select * from int_order_amounts` | L'objet n'existe pas |
| Impossible de tester un modele ephemeral directement | Un test dbt est un `SELECT` sur un objet ; il n'y en a pas |
| Impossible de le snapshotter (module 06) | Meme raison |
| Le SQL des marts devient long et duplique | Chaque consommateur embarque sa propre copie |

Ce dernier point est le vrai arbitrage : `ephemeral` est gratuit en
stockage mais **recalcule la logique dans chaque consommateur**. Avec
un seul consommateur (le cas ici), c'est le bon choix. Des que trois
marts utilisent le meme `int_*` sur un gros volume, passez-le en
`view` ou `table` — vous echangez du stockage contre un calcul unique
et la possibilite de le tester.

### Marts (`models/marts/`) — l'interface consommee par le reste du monde

C'est ce que la BI, les analystes, le Semantic Layer interrogent.
Deux types d'objets, la modelisation en etoile de Kimball :

- **Dimensions** (`dim_*`) — le "qui/quoi/ou" : `dim_customers`,
  `dim_products`, `dim_dates`. Grain = 1 ligne par entite.
- **Faits** (`fct_*`) — le "quoi il s'est passe" : `fct_orders`
  (grain = 1 commande), `fct_order_items` (grain = 1 ligne de
  commande). Une table de faits contient des cles etrangeres vers les
  dimensions + des mesures numeriques (montants, quantites).

**Le grain d'abord, toujours.** Avant d'ecrire une ligne de SQL pour
un mart, ecrivez en commentaire "grain = 1 ligne par ___". Toutes les
`group by` en decoulent. `fct_orders` et `fct_order_items` de ce
projet existent tous les deux parce qu'ils repondent a des questions
a un grain different (le total d'une commande vs. le detail par
produit) — fusionner les deux forcerait soit une double comptabilisation
des montants de commande, soit la perte du detail produit.

## Construire la couche, et observer ce qui apparait

A la fin du [module 01](../01-fondamentaux/README.md), vous aviez
**2 marts sur 7** (`fct_orders` et `dim_customers` seulement).
Completons :

```bash
dbt build --select marts
```

```
Done. PASS=32 WARN=0 ERROR=0 SKIP=0 NO-OP=2 TOTAL=34
```

```bash
psql ... -c "select table_schema, count(*) from information_schema.tables
             where table_schema like '${POSTGRES_SCHEMA}%' group by 1 order by 1;"
```

```
 dbt_jeff_marts   | 7      <- les 7, cette fois
 dbt_jeff_seeds   | 2
 dbt_jeff_staging | 6
```

Deux details a noter dans ce bilan :

- **`NO-OP=2`** : les deux exposures (module 07). Elles font partie du
  graphe mais ne contiennent aucun SQL — dbt n'a rien a executer.
- **`--select marts` a suffi**, sans reconstruire le staging : les
  vues `stg_*` existaient deja et rien ne dependait d'elles qui ait
  change. dbt ne reconstruit que ce que vous selectionnez ; c'est
  `+marts` qu'il aurait fallu ecrire pour inclure l'amont.

## Un choix d'architecture assume : les dimensions dependent des faits

Regle Kimball classique : les faits referencent les dimensions, pas
l'inverse. Ouvrez [`dim_customers.sql`](../../models/marts/core/dim_customers.sql) :
il fait `from {{ ref('fct_orders') }}` pour calculer
`lifetime_value_cents`, `lifetime_order_count`... Est-ce une
violation ?

Non : c'est le pattern "dimension enrichie", tres courant en pratique
(RFM, LTV directement sur `dim_customers`). Ce qui compte n'est pas
"qui reference qui" litteralement, mais **l'absence de cycle** :
`fct_orders` ne depend d'aucun mart, donc `dim_customers → fct_orders`
est une arete valide dans un DAG toujours acyclique. Vérifiez :

```bash
dbt ls --select +dim_customers --resource-type model   # fct_orders y est
dbt ls --select +fct_orders --resource-type model      # dim_customers n'y est PAS
```

Le risque a surveiller si vous adoptez ce pattern : ne jamais faire
en sorte qu'un fait depende de la dimension qui, elle-meme, en
depend — dbt refusera de toute facon de compiler un cycle, mais mieux
vaut le comprendre que le decouvrir a l'erreur.

## Conventions de nommage (celles de ce projet, alignees sur le style guide dbt Labs)

| Prefixe | Couche | Exemple |
|---|---|---|
| `stg_` | staging | `stg_customers` |
| `int_` | intermediate | `int_order_amounts` |
| `dim_` | marts, dimension | `dim_customers` |
| `fct_` | marts, fait | `fct_orders` |
| `_xxx__yyy.yml` | fichier YAML de proprietes | `_staging__sources.yml` |

Le prefixe `_` + double underscore sur les YAML n'est pas cosmetique :
dans un explorateur de fichiers trie alphabetiquement, `_` remonte
tout en haut du dossier — vous voyez les definitions/tests avant les
modeles SQL. Le `__` separe "dossier" de "type de contenu"
(`_staging__sources.yml` vs `_staging__models.yml`), pour eviter que
deux dossiers differents produisent le meme nom de fichier.

## Exercice

Construisez un nouveau mart `monthly_category_revenue`
(`models/marts/core/`), grain = 1 ligne par (mois x categorie
produit), avec : le mois, la `category`, `items_sold` et
`revenue_cents`. Utilisez `fct_order_items`, `dim_products` et
`dim_dates` (deja construits). Filtrez les commandes annulees.

**Sous-question a trancher vous-meme** : comment representez-vous "le
mois" ? Une seule colonne texte (`'2026-05'`), ou plusieurs colonnes
(`year_number`, `month_number`, `month_name`) ? Les deux marchent —
justifiez votre choix avant de regarder la solution.

### Solution

```sql
-- models/marts/core/monthly_category_revenue.sql

with order_items as (

    select * from {{ ref('fct_order_items') }}
    where order_status != 'cancelled'

),

dates as (

    select date_day, year_number, month_number, month_name
    from {{ ref('dim_dates') }}

),

products as (

    select product_id, category from {{ ref('dim_products') }}

),

joined as (

    select
        d.year_number,
        d.month_number,
        d.month_name,
        p.category,
        oi.quantity,
        oi.line_amount_cents

    from order_items oi
    inner join products p on p.product_id = oi.product_id
    inner join dates d on d.date_day = cast(oi.ordered_at as date)

),

final as (

    select
        year_number,
        month_number,
        month_name,
        category,
        count(*) as line_items,
        sum(quantity) as items_sold,
        sum(line_amount_cents) as revenue_cents

    from joined
    group by 1, 2, 3, 4

)

select * from final
order by year_number, month_number, category
```

**Reponse a la sous-question** : trois colonnes
(`year_number`, `month_number`, `month_name`), pas une chaine
`'2026-05'`. Une chaine se trie correctement par hasard (parce que
`YYYY-MM` est lexicographiquement ordonne) mais interdit tout
`where month_number = 12` ou toute comparaison d'annee sans
`substring()`. On garde les composantes separees dans le mart, et on
laisse la couche de restitution les concatener si elle le souhaite.

Notez aussi la colonne `line_items` (`count(*)`), non demandee dans
l'enonce : elle est quasi gratuite une fois le `group by` ecrit, et
c'est elle qui permet de distinguer "10 000 EUR sur 2 grosses
commandes" de "10 000 EUR sur 400 petites". Ajouter une mesure de
volumetrie a cote d'une mesure de montant est un reflexe qui evite
beaucoup de conclusions hatives.

Points a remarquer dans cette solution :

- **`inner join` sur `dates`**, pas `left join` : si une commande a
  une date hors de la plage generee par `dim_dates`
  (`date_spine_start_date` dans `dbt_project.yml`), on VEUT que la
  ligne disparaisse silencieusement plutot que de fausser
  l'agregation avec un mois `NULL`.

  **Mais "silencieusement" est le mot dangereux** : verifiez, ne
  supposez pas. Le controle tient en une requete :

  ```sql
  select
    (select count(*) from {{ ref('fct_order_items') }}
      where order_status != 'cancelled')                    as en_entree,
    (select count(*) from {{ ref('fct_order_items') }} oi
      join {{ ref('dim_dates') }} d on d.date_day = cast(oi.ordered_at as date)
     where oi.order_status != 'cancelled')                  as apres_join;
  ```

  Sur ce projet aujourd'hui : **159 et 159**, aucune perte — la date
  spine couvre 2025-01-01 → 2027-08-03 alors que les commandes vont
  de 2026-04-30 a 2026-07-28. Confortable, mais ce n'est vrai que
  tant que `date_spine_start_date` reste en avance sur vos donnees.
  Figez-le dans un test singulier (`tests/`) plutot que de le
  reverifier a la main :

  ```sql
  -- tests/assert_no_order_items_outside_date_spine.sql
  select oi.order_item_id, oi.ordered_at
  from {{ ref('fct_order_items') }} oi
  left join {{ ref('dim_dates') }} d on d.date_day = cast(oi.ordered_at as date)
  where d.date_day is null
  ```

  Un test qui ne retourne aucune ligne aujourd'hui, et qui hurlera le
  jour ou la spine prendra du retard.
- Le filtre `order_status != 'cancelled'` est applique **avant**
  toute jointure/agregation, dans la CTE `order_items` — pas apres
  coup avec un `having`, plus couteux et moins lisible.
- Grain explicite dans le `group by 1,2,3,4` : exactement les 4
  colonnes annoncees dans l'objectif de l'exercice, ni plus ni moins.

## Suite

→ [Module 03 — Tests et qualite de donnees](../03-tests-qualite-donnees/README.md)
