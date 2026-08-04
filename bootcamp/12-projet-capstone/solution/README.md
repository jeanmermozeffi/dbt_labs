# Solution commentee — domaine "returns"

Tout le code cite ici existe reellement dans le repo et a ete valide
par un `dbt build` complet (101 noeuds, `PASS=99 ERROR=0`) avant
d'etre documente. Ce n'est pas du pseudo-code.

## 1. Staging — [`models/staging/stg_returns.sql`](../../../models/staging/stg_returns.sql)

```sql
with source as (
    select * from {{ source('raw', 'returns') }}
),

renamed as (
    select
        return_id,
        order_item_id,
        reason,
        refund_amount_cents,
        {{ cents_to_dollars('refund_amount_cents') }} as refund_amount,
        returned_at,
        {{ dbt.current_timestamp() }} as loaded_at
    from source
)

select * from renamed
```

Rien que du renommage/cast — meme discipline que tous les autres
`stg_*`. `{{ dbt.current_timestamp() }}` (et pas `current_timestamp`
en dur) parce que c'est ce qui permet de figer cette colonne dans les
unit tests via `overrides.macros` (module 03).

Tests, dans
[`models/staging/_staging__models.yml`](../../../models/staging/_staging__models.yml) :

```yaml
- name: stg_returns
  columns:
    - name: return_id
      tests: [unique, not_null]
    - name: order_item_id
      tests:
        - relationships:
            arguments:
              to: ref('stg_order_items')
              field: order_item_id
    - name: reason
      tests:
        - accepted_values:
            arguments:
              values: ['damaged', 'wrong_item', 'no_longer_needed', 'defective']
    - name: refund_amount_cents
      tests:
        - not_negative
```

`not_negative` est le test generique "maison" du module 03
([`macros/generic_tests/test_not_negative.sql`](../../../macros/generic_tests/test_not_negative.sql)) —
reutilise ici tel quel, aucune ligne de macro supplementaire a
ecrire : c'est exactement l'interet de l'avoir promu en generique.

## 2. Table de faits — [`models/marts/returns/fct_returns.sql`](../../../models/marts/returns/fct_returns.sql)

```sql
{{ config(materialized='incremental', incremental_strategy='append') }}

with returns as (
    select * from {{ ref('stg_returns') }}
    {% if is_incremental() %}
    where returned_at > (select coalesce(max(returned_at), '1900-01-01'::timestamp) from {{ this }})
    {% endif %}
),

order_items as (
    select order_item_id, order_id, product_id
    from {{ ref('stg_order_items') }}
),

final as (
    select
        r.return_id, r.order_item_id, oi.order_id, oi.product_id,
        r.reason, r.refund_amount_cents, r.returned_at
    from returns r
    inner join order_items oi on oi.order_item_id = r.order_item_id
)

select * from final
```

`incremental_strategy='append'`, pas `delete+insert` : un retour est
un evenement immuable (jamais mis a jour une fois enregistre), donc
pas besoin de `unique_key` ni de la depense d'un `DELETE` avant
chaque `INSERT` — exactement le raisonnement du module 05.

`product_id`/`order_id` sont recuperes par jointure plutot que
stockes directement sur `raw.returns` : c'est le role d'une table de
faits de porter TOUTES les cles etrangeres utiles a l'analyse, meme
si la source brute n'en fournit qu'une (`order_item_id`).

## 3. Mart — [`models/marts/returns/product_return_rates.sql`](../../../models/marts/returns/product_return_rates.sql)

Point le plus delicat, la division par zero :

```sql
round(sum(is_returned)::numeric / nullif(count(*), 0), 4) as return_rate
```

`nullif(count(*), 0)` transforme un denominateur de `0` en `NULL` —
`x / NULL` renvoie `NULL` en SQL (pas d'erreur de division par
zero), qu'on neutralise ensuite avec `coalesce(a.return_rate, 0)`
dans la CTE finale. Sans ce `nullif`, un produit jamais vendu (donc
absent de `aggregated`, donc `count(*) = 0` n'arrive en fait jamais
ici via le `left join`... mais **si vous aviez fait un `inner join`
au lieu d'un `left join`** entre `dim_products` et `aggregated`, ce
produit aurait simplement disparu du rapport — un bug silencieux de
perimetre, pas une erreur visible. C'est exactement pour ca que le
`left join dim_products -> aggregated` + `coalesce(..., 0)` est le
bon reflexe : toujours partir de la dimension complete, jamais de
l'agregat qui peut avoir des trous.

Contrat + grants, dans
[`_returns__models.yml`](../../../models/marts/returns/_returns__models.yml) :

```yaml
- name: product_return_rates
  config:
    contract:
      enforced: true
    grants:
      select: ['bi_reader']
  columns:
    - name: product_id
      data_type: integer
      constraints:
        - type: primary_key
        - type: not_null
    - name: return_rate
      data_type: numeric(6, 4)
      tests:
        - dbt_expectations.expect_column_values_to_be_between:
            arguments: { min_value: 0, max_value: 1 }
    ...
```

`numeric(6, 4)` (et pas `numeric` seul) pour eviter l'avertissement
Postgres "unintended rounding" du module 07 — et le SQL du modele
caste explicitement au meme type
(`cast(coalesce(a.return_rate, 0) as numeric(6, 4))`) pour que le
contrat et la realite correspondent exactement.

## 4. Gouvernance — [`models/groups.yml`](../../../models/groups.yml) + [`dbt_project.yml`](../../../dbt_project.yml)

```yaml
# groups.yml
groups:
  - name: returns
    owner: { name: "Customer Experience Team", email: cx-analytics@example.com }
```

```yaml
# dbt_project.yml, sous models.dbt_labs.marts
returns:
  +group: returns
```

`product_return_rates` est `access: public` (l'interface officielle
du domaine) ; `fct_returns` reste en acces par defaut (`protected`,
referençable ailleurs dans le projet mais pas expose comme interface
publique documentee) — la meme logique qu'entre `dim_*`/`fct_*`
(public) et `int_*` (private) dans le domaine `core` (module 10). Le
module 10 documente aussi l'erreur exacte obtenue en testant
volontairement un mauvais choix d'`access` sur ce meme repo.

## 5. Semantic layer — [`_returns__semantic_models.yml`](../../../models/marts/returns/_returns__semantic_models.yml)

```yaml
semantic_models:
  - name: sem_fct_returns
    model: ref('fct_returns')     # <- la table de FAITS, pas le mart agrege
    defaults:
      agg_time_dimension: returned_at
    entities:
      - name: return
        type: primary
        expr: return_id
      - name: order_item
        type: foreign
        expr: order_item_id
    dimensions:
      - name: returned_at
        type: time
        type_params: { time_granularity: day }
      - name: reason
        type: categorical
    measures:
      - name: return_count
        agg: count
        expr: return_id
      - name: total_refunded_cents
        agg: sum
        expr: refund_amount_cents

metrics:
  - name: return_count
    type: simple
    type_params: { measure: return_count }
  - name: total_refunded
    type: simple
    type_params: { measure: total_refunded_cents }
```

**Pourquoi `sem_fct_returns` pointe sur `fct_returns` et pas sur
`product_return_rates`** (la question posee dans le cahier des
charges) : MetricFlow re-agrege lui-meme les measures selon les
dimensions demandees a chaque requete (`group by reason`,
`group by returned_at__month`...). Si le semantic model portait sur
`product_return_rates` (deja agrege par produit), toute demande de
ventilation par `reason` serait structurellement impossible — la
donnee n'existe plus a ce grain. Regle generale : **un semantic model
se construit sur le grain le plus FIN disponible**, jamais sur un
agregat, precisement pour ne fermer aucune question future.

## 6. Exposure — [`models/marts/_marts__exposures.yml`](../../../models/marts/_marts__exposures.yml)

```yaml
- name: product_return_rate_report
  type: analysis
  depends_on:
    - ref('product_return_rates')
  owner: { name: "Data Platform Team", email: data-platform@example.com }
```

## Verification finale

```bash
dbt build
# ... Finished running 2 exposures, 3 incremental models, 2 seeds, 1 snapshot,
#     4 table models, 80 data tests, 3 unit tests, 6 view models
# Done. PASS=99 WARN=0 ERROR=0 SKIP=0 NO-OP=2 TOTAL=101
```

Les `NO-OP=2` sont les deux **exposures** : une exposure ne contient
aucun SQL, dbt n'a donc rien a executer — elle apparait dans le
decompte parce qu'elle fait partie du graphe, pas parce qu'un travail
a eu lieu. Voir [reference-cli.md](../../reference-cli.md) pour la
lecture complete de ce bilan.

Et la question metier du cahier des charges :

```sql
select product_name, category, items_sold, items_returned, return_rate
from "dbt_jeff_marts".product_return_rates
where items_sold >= 5   -- seuil de significativite arbitraire mais explicite
order by return_rate desc
limit 5;
```

Le seuil `items_sold >= 5` n'est PAS dans le mart lui-meme — c'est un
choix d'analyse ponctuel, pas une regle metier permanente. Le
distinguer explicitement (au lieu de le coder en dur dans
`product_return_rates`) est le meme reflexe que le module 02 sur "que
mettre en staging vs en aval" : une regle qui peut changer selon qui
regarde ne doit jamais etre figee dans la couche partagee.
