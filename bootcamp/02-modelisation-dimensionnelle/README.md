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
produit), avec : `order_month`, `category`, `items_sold`,
`revenue_cents`. Utilisez `fct_order_items`, `dim_products` et
`dim_dates` (deja construits). Filtrez les commandes annulees.

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

Points a remarquer dans cette solution :

- **`inner join` sur `dates`**, pas `left join` : si une commande a
  une date hors de la plage generee par `dim_dates`
  (`date_spine_start_date` dans `dbt_project.yml`), on VEUT que la
  ligne disparaisse silencieusement plutot que de fausser
  l'agregation avec un mois `NULL`. En pratique, ajoutez un test
  `dbt_expectations.expect_table_row_count_to_equal` entre
  `fct_order_items` filtre et le resultat pour detecter cette perte
  si elle survient un jour.
- Le filtre `order_status != 'cancelled'` est applique **avant**
  toute jointure/agregation, dans la CTE `order_items` — pas apres
  coup avec un `having`, plus couteux et moins lisible.
- Grain explicite dans le `group by 1,2,3,4` : exactement les 4
  colonnes annoncees dans l'objectif de l'exercice, ni plus ni moins.

## Suite

→ [Module 03 — Tests et qualite de donnees](../03-tests-qualite-donnees/README.md)
