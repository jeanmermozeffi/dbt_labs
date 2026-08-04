# Module 08 — Semantic Layer et MetricFlow

## Objectifs

- Comprendre le probleme que le Semantic Layer resout (definir une
  metrique UNE fois, pas dans chaque outil BI).
- Ecrire un `semantic_model` (entities, dimensions, measures).
- Ecrire des `metrics` (simple, ratio) qui le consomment.
- Savoir pourquoi une "time spine" est obligatoire.

## Le probleme : chaque outil BI redefinit "chiffre d'affaires"

Sans Semantic Layer : Tableau calcule le CA d'une facon, Looker d'une
autre (l'un exclut les commandes annulees, l'autre pas), un analyste
en Python d'une troisieme. Trois chiffres differents pour "le meme"
KPI en reunion. Le dbt Semantic Layer centralise la DEFINITION dans
le projet dbt ; chaque outil consommateur interroge la meme
definition via l'API MetricFlow, au lieu de la reimplementer.

## Semantic model : decrire un modele en termes d'analyse

[`models/marts/core/_core__semantic_models.yml`](../../models/marts/core/_core__semantic_models.yml) :

```yaml
semantic_models:
  - name: sem_fct_orders
    model: ref('fct_orders')
    defaults:
      agg_time_dimension: ordered_at

    entities:
      - name: order
        type: primary
        expr: order_id
      - name: customer
        type: foreign
        expr: customer_id

    dimensions:
      - name: ordered_at
        type: time
        type_params:
          time_granularity: day
      - name: order_status
        type: categorical

    measures:
      - name: order_count
        agg: count
        expr: order_id
      - name: total_revenue_cents
        agg: sum
        expr: total_paid_cents
      - name: total_items_sold
        agg: sum
        expr: total_quantity
```

Vocabulaire :
- **`entities`** : les cles (primaire = grain du modele, foreign =
  cles vers d'autres semantic models — permet a MetricFlow de
  joindre automatiquement plusieurs semantic models entre eux).
- **`dimensions`** : les axes d'analyse (`categorical` = une valeur
  discrete, `time` = un axe temporel avec une granularite).
- **`measures`** : les agregations DE BASE (`sum`, `count`, `avg`...)
  disponibles pour construire des metriques. Une measure n'est PAS
  encore une metrique consommable — c'est la brique.

## Metrics : ce que les outils BI interrogent reellement

```yaml
metrics:
  - name: order_count
    type: simple
    type_params:
      measure: order_count

  - name: total_revenue
    type: simple
    type_params:
      measure: total_revenue_cents

  - name: average_order_value
    type: ratio
    type_params:
      numerator: total_revenue    # <- reference une METRIQUE, pas une measure
      denominator: order_count
```

**Piege reel rencontre en ecrivant ce fichier** : pour un metric
`type: ratio`, `numerator`/`denominator` doivent referencer des
**metriques deja definies** (ici `total_revenue` et `order_count`),
PAS directement des measures (`total_revenue_cents`). Premiere
tentative :

```
Parsing Error in metric average_order_value
  The metric `total_revenue_cents` does not exist but was referenced.
```

dbt cherchait un metric nomme `total_revenue_cents` — qui n'existe
pas, seule la MEASURE porte ce nom. Le correctif : reference le nom
du metric `total_revenue` (dont le `type_params.measure` vaut, lui,
`total_revenue_cents`). Un niveau d'indirection a bien garder en
tete : `measure` (donnee brute agregeable) → `metric type: simple`
(l'expose) → `metric type: ratio`/`derived` (compose D'AUTRES
metrics, jamais directement de measures).

## La "time spine" : obligatoire des qu'il y a des metrics

Deuxieme erreur rencontree, a la toute premiere compilation :

```
The semantic layer requires a time spine model with granularity DAY
or smaller in the project, but none was found.
```

MetricFlow a besoin d'une table calendaire de reference pour
calculer des metriques sur des periodes ("cumulatif", "vs periode
precedente", jointures temporelles). Solution : declarer
[`dim_dates`](../../models/marts/core/dim_dates.sql) (deja construite
au module 02 avec `dbt_utils.date_spine`) comme time spine, dans
[`_core__models.yml`](../../models/marts/core/_core__models.yml) :

```yaml
- name: dim_dates
  time_spine:
    standard_granularity_column: date_day
  columns:
    - name: date_day
      granularity: day
```

Deux choses necessaires ensemble : la propriete `time_spine` au
niveau du modele, ET `granularity: day` sur la colonne elle-meme —
oublier l'une ou l'autre reproduit l'erreur.

## Interroger les metriques

Ce projet valide que les definitions **compilent** (`dbt parse`),
suffisant pour committer en confiance. Pour reellement EXECUTER des
requetes de metriques (`mf query`, `dbt sl query`), il faut en plus
installer `dbt-metricflow` (package separe, pas requis pour ce
bootcamp) :

```bash
pip install "dbt-metricflow[postgres]"
mf query --metrics total_revenue --group-by order_status
```

En production, c'est generalement un outil BI (Tableau, Hex, Mode...)
ou dbt Cloud qui appelle l'API du Semantic Layer a votre place — vous
n'ecrivez jamais ces requetes a la main au quotidien, seulement la
DEFINITION des semantic models/metrics.

## Exercice

Ajoutez un metric `items_per_order` (nombre moyen d'articles par
commande) : `type: ratio` entre le nombre total d'items vendus et le
nombre de commandes.

### Solution

```yaml
# models/marts/core/_core__semantic_models.yml
metrics:
  ...
  - name: total_items_sold
    label: "Nombre total d'articles vendus"
    type: simple
    type_params:
      measure: total_items_sold

  - name: items_per_order
    label: "Nombre moyen d'articles par commande"
    type: ratio
    type_params:
      numerator: total_items_sold
      denominator: order_count
```

Notez qu'il a fallu d'abord promouvoir la measure `total_items_sold`
(deja definie dans le `semantic_model`) en metric `type: simple` —
exactement le piege documente plus haut : un `ratio` ne peut pas
pointer directement vers une measure.

Validez sans avoir besoin de `dbt-metricflow` :

```bash
dbt parse   # doit reussir silencieusement ; toute erreur de semantic layer apparait ici
```

## Suite

→ [Module 09 — Orchestration et CI/CD](../09-orchestration-ci-cd/README.md)
